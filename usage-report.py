#!/usr/bin/env python3
"""Z.AI coding-plan usage report for the Omarchy bar (ernestodisa.zai-usage widget).

Aggregates the account-level quota windows from `omp usage --json` and adds an
estimated per-agent split (omp / hermes / opencode) summed from each tool's own
local usage records inside the nearest-resetting quota window.

Shares are by tokens (input + output + cache), so they approximate credit
consumption; exact credits per agent are not exposed by the API. hermes only
aggregates per session: a session spanning the window start counts in full.

Sources:
  omp       ~/.omp/agent/sessions/**/*.jsonl   (assistant messages, provider zai*)
            ~/.omp/stats.db lags sessions by days in current omp builds.
  hermes    ~/.hermes/state.db  -> session_model_usage (billing zai / api.z.ai)
  opencode  ~/.local/share/opencode/opencode.db -> message data tokens (zai*)
  zcode     ~/.zcode/cli/db/db.sqlite -> model_usage rows (account:zai* providers)
  claude    ~/.claude/projects/**/*.jsonl -> assistant usage (provider unknown: estimate)
  pi        ~/.pi/agent/sessions/**/*.jsonl -> assistant usage (zai/zhipu providers)
  kilo      ~/.local/share/kilo/kilo.db -> message tokens (zai provider or unknown)

Output: single JSON object on stdout:
  {"ok": true, "plan": "lite", "windows": [...],
   "split": {"window": "5h", "agents": [{"name", "tokens", "requests"}...]}}
Errors print {"ok": false, "error": "..."} and still exit 0.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
OMP_SESSIONS = os.path.join(HOME, ".omp", "agent", "sessions")
HERMES_DB = os.path.join(HOME, ".hermes", "state.db")
OPENCODE_DB = os.path.join(HOME, ".local", "share", "opencode", "opencode.db")
ZCODE_DB = os.path.join(HOME, ".zcode", "cli", "db", "db.sqlite")
CLAUDE_DIR = os.path.join(HOME, ".claude", "projects")
PI_DIR = os.path.join(HOME, ".pi", "agent", "sessions")
KILO_DB = os.path.join(HOME, ".local", "share", "kilo", "kilo.db")
FETCH_TIMEOUT = 20  # seconds, matches the omp usage-status plugin


def iso_to_ms(value):
    """ISO-8601 string -> epoch milliseconds, or None."""
    try:
        t = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if t.tzinfo is None:
            t = t.replace(tzinfo=timezone.utc)
        return t.timestamp() * 1000.0
    except (ValueError, TypeError, OverflowError):
        return None


def fetch_quota() -> dict:
    proc = subprocess.run(
        ["omp", "usage", "--json"],
        capture_output=True,
        text=True,
        timeout=FETCH_TIMEOUT,
    )
    if proc.returncode != 0:
        first = (proc.stderr or "no output").strip().splitlines()
        raise RuntimeError(first[0] if first else f"omp usage exited {proc.returncode}")
    return json.loads(proc.stdout)


def omp_agent_usage(since_ms: float):
    """Token/request totals from omp session JSONL files touched since `since_ms`."""
    if not os.path.isdir(OMP_SESSIONS):
        return None
    tokens = 0
    requests = 0
    for dirpath, _dirs, files in os.walk(OMP_SESSIONS):
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, name)
            try:
                if os.stat(path).st_mtime * 1000 < since_ms:
                    continue  # untouched since the window started
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if '"assistant"' not in line or '"usage"' not in line:
                            continue  # cheap prefilter before JSON.parse
                        try:
                            entry = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        msg = entry.get("message") or {}
                        usage = msg.get("usage")
                        if msg.get("role") != "assistant" or not usage:
                            continue
                        if not str(msg.get("provider") or "").startswith("zai"):
                            continue
                        ts = msg.get("timestamp")
                        if not isinstance(ts, (int, float)) or ts < since_ms:
                            continue
                        tokens += (
                            int(usage.get("input") or 0)
                            + int(usage.get("output") or 0)
                            + int(usage.get("cacheRead") or 0)
                            + int(usage.get("cacheWrite") or 0)
                        )
                        requests += 1
            except OSError:
                continue
    return (tokens, requests) if requests else None


def hermes_agent_usage(since_ms: float):
    if not os.path.exists(HERMES_DB):
        return None
    try:
        con = sqlite3.connect(f"file:{HERMES_DB}?mode=ro", uri=True, timeout=2)
        try:
            row = con.execute(
                """
                SELECT COALESCE(SUM(input_tokens+output_tokens+cache_read_tokens
                                      +cache_write_tokens+reasoning_tokens), 0),
                       COALESCE(SUM(api_call_count), 0)
                FROM session_model_usage
                WHERE last_seen >= ?
                  AND (billing_provider LIKE 'zai%'
                       OR billing_base_url LIKE '%api.z.ai%')
                """,
                (since_ms / 1000.0,),  # hermes stores float seconds
            ).fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    tokens, requests = int(row[0] or 0), int(row[1] or 0)
    return (tokens, requests) if requests else None


def opencode_agent_usage(since_ms: float):
    if not os.path.exists(OPENCODE_DB):
        return None
    try:
        con = sqlite3.connect(f"file:{OPENCODE_DB}?mode=ro", uri=True, timeout=2)
        try:
            row = con.execute(
                """
                SELECT COALESCE(SUM(json_extract(data,'$.tokens.input')
                                      +json_extract(data,'$.tokens.output')
                                      +COALESCE(json_extract(data,'$.tokens.reasoning'),0)
                                      +COALESCE(json_extract(data,'$.tokens.cache.read'),0)
                                      +COALESCE(json_extract(data,'$.tokens.cache.write'),0)), 0),
                       COUNT(json_extract(data,'$.tokens'))
                FROM message
                WHERE json_extract(data,'$.role') = 'assistant'
                  AND json_extract(data,'$.providerID') LIKE 'zai%'
                  AND time_created >= ?
                """,
                (since_ms,),
            ).fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    tokens, requests = int(row[0] or 0), int(row[1] or 0)
    return (tokens, requests) if requests else None


def zcode_agent_usage(since_ms: float):
    """Model requests from zcode (Z.ai's official CLI), ~/.zcode/cli/db/db.sqlite.

    One model_usage row is one model request. zcode's input_tokens already
    includes cached input (the provider reports inputTokens inclusive of
    cacheRead), so cache columns are deliberately NOT added — they would
    double-count.
    """
    if not os.path.exists(ZCODE_DB):
        return None
    try:
        con = sqlite3.connect(f"file:{ZCODE_DB}?mode=ro", uri=True, timeout=2)
        try:
            row = con.execute(
                """
                SELECT COALESCE(SUM(input_tokens+output_tokens+reasoning_tokens), 0),
                       COUNT(*)
                FROM model_usage
                WHERE provider_id LIKE 'account:zai%'
                  AND started_at >= ?
                """,
                (since_ms,),
            ).fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    tokens, requests = int(row[0] or 0), int(row[1] or 0)
    return (tokens, requests) if requests else None


def claude_code_agent_usage(since_ms: float):
    """Tokens from Claude Code session JSONLs (~/.claude/projects/**/*.jsonl).

    Claude Code records usage but not the provider, so every assistant
    message counts — an estimate that is only accurate when Claude Code is
    pointed at Z.ai (its common coding-plan setup).
    """
    if not os.path.isdir(CLAUDE_DIR):
        return None
    tokens = requests = 0
    for dirpath, _dirs, files in os.walk(CLAUDE_DIR):
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, name)
            try:
                if os.stat(path).st_mtime * 1000 < since_ms:
                    continue  # untouched since the window started
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if '"assistant"' not in line or '"usage"' not in line:
                            continue  # cheap prefilter before JSON.parse
                        try:
                            entry = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if entry.get("type") != "assistant":
                            continue
                        usage = (entry.get("message") or {}).get("usage")
                        if not isinstance(usage, dict):
                            continue
                        ms = iso_to_ms(entry.get("timestamp") or "")
                        if ms is None or ms < since_ms:
                            continue
                        tokens += (int(usage.get("input_tokens") or 0)
                                   + int(usage.get("output_tokens") or 0)
                                   + int(usage.get("cache_creation_input_tokens") or 0)
                                   + int(usage.get("cache_read_input_tokens") or 0))
                        requests += 1
            except OSError:
                continue
    return (tokens, requests) if requests else None


def pi_agent_usage(since_ms: float):
    """Tokens from pi session JSONLs (~/.pi/agent/sessions/**/*.jsonl).

    pi records the provider per assistant message; only zai/zhipu providers
    count toward the plan. Usage fields are models.dev style
    (input/output/cacheRead/cacheWrite, disjoint).
    """
    if not os.path.isdir(PI_DIR):
        return None
    tokens = requests = 0
    for dirpath, _dirs, files in os.walk(PI_DIR):
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, name)
            try:
                if os.stat(path).st_mtime * 1000 < since_ms:
                    continue
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if '"assistant"' not in line or '"usage"' not in line:
                            continue
                        try:
                            entry = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        msg = entry.get("message") or {}
                        usage = msg.get("usage")
                        if msg.get("role") != "assistant" or not isinstance(usage, dict):
                            continue
                        provider = str(msg.get("provider") or "").lower()
                        if not (provider.startswith("zai") or provider.startswith("zhipu")):
                            continue
                        ts = msg.get("timestamp")
                        if not isinstance(ts, (int, float)):
                            ts = iso_to_ms(entry.get("timestamp") or "")
                        if not isinstance(ts, (int, float)) or ts < since_ms:
                            continue
                        tokens += (int(usage.get("input") or 0)
                                   + int(usage.get("output") or 0)
                                   + int(usage.get("cacheRead") or 0)
                                   + int(usage.get("cacheWrite") or 0))
                        requests += 1
            except OSError:
                continue
    return (tokens, requests) if requests else None


def kilo_agent_usage(since_ms: float):
    """Tokens from Kilo Code's local DB (~/.local/share/kilo/kilo.db).

    Kilo (opencode lineage) stores message rows as JSON in a `message` table.
    Rows that record no provider still count — same estimate caveat as the
    Claude Code reader.
    """
    if not os.path.exists(KILO_DB):
        return None
    try:
        con = sqlite3.connect(f"file:{KILO_DB}?mode=ro", uri=True, timeout=2)
        try:
            row = con.execute(
                """
                SELECT COALESCE(SUM(json_extract(data,'$.tokens.input')
                                      +json_extract(data,'$.tokens.output')
                                      +COALESCE(json_extract(data,'$.tokens.reasoning'),0)
                                      +COALESCE(json_extract(data,'$.tokens.cache.read'),0)
                                      +COALESCE(json_extract(data,'$.tokens.cache.write'),0)), 0),
                       COUNT(json_extract(data,'$.tokens'))
                FROM message
                WHERE json_extract(data,'$.role') = 'assistant'
                  AND time_created >= ?
                  AND (json_extract(data,'$.providerID') LIKE 'zai%'
                       OR json_extract(data,'$.providerID') IS NULL)
                """,
                (since_ms,),
            ).fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    tokens, requests = int(row[0] or 0), int(row[1] or 0)
    return (tokens, requests) if requests else None


def agent_split(since_ms: float) -> list:
    readers = (
        ("omp", omp_agent_usage),
        ("hermes", hermes_agent_usage),
        ("opencode", opencode_agent_usage),
        ("zcode", zcode_agent_usage),
        ("claude-code", claude_code_agent_usage),
        ("pi", pi_agent_usage),
        ("kilo-code", kilo_agent_usage),
    )
    agents = []
    for name, read in readers:
        try:
            usage = read(since_ms)
        except Exception:
            usage = None  # a missing/broken source just drops out of the split
        if usage and usage[0] > 0:
            agents.append({"name": name, "tokens": usage[0], "requests": usage[1]})
    agents.sort(key=lambda a: a["tokens"], reverse=True)
    return agents


def quota_windows(quota: dict, now_ms: float) -> list:
    windows = []
    for report in quota.get("reports") or []:
        for limit in report.get("limits") or []:
            amount = limit.get("amount") or {}
            if not amount.get("limit"):
                continue
            window = limit.get("window") or {}
            resets_at = window.get("resetsAt")
            windows.append(
                {
                    "id": window.get("id") or window.get("label")
                    or limit.get("label") or "quota",
                    "fraction": float(amount.get("usedFraction") or 0.0),
                    "used": amount.get("used") or 0,
                    "limit": amount.get("limit") or 0,
                    "resetsIn": (resets_at - now_ms) / 1000.0 if resets_at else None,
                }
            )
    windows.sort(key=lambda w: (w["resetsIn"] is None, w["resetsIn"] or 0))
    return windows


def nearest_window(quota: dict, now_ms: float):
    """Window with the nearest reset that has already started, with its start."""
    best = None
    for report in quota.get("reports") or []:
        for limit in report.get("limits") or []:
            window = limit.get("window") or {}
            resets_at, duration = window.get("resetsAt"), window.get("durationMs")
            if not resets_at or not duration:
                continue
            start = resets_at - duration
            if start > now_ms:
                continue
            if best is None or resets_at < best[1]:
                best = (window.get("id") or "quota", resets_at, start)
    return best


def main() -> int:
    now_ms = time.time() * 1000
    quota = fetch_quota()
    plan = None
    for report in quota.get("reports") or []:
        plan = (report.get("metadata") or {}).get("planType") or plan

    nearest = nearest_window(quota, now_ms)
    split = {"window": nearest[0] if nearest else None, "agents": []}
    if nearest:
        split["agents"] = agent_split(nearest[2])

    print(
        json.dumps(
            {
                "ok": True,
                "plan": plan,
                "fetchedAt": now_ms,
                "windows": quota_windows(quota, now_ms),
                "split": split,
            }
        )
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # keep the bar widget informed instead of crashing
        print(json.dumps({"ok": False, "error": str(exc)}))
        sys.exit(0)

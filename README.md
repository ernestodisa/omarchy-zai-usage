# Z.AI Usage — Omarchy bar widget

Z.AI coding-plan quota in the Omarchy bar, with an **estimated per-agent
split** (omp / hermes / opencode / zcode / claude-code / pi / kilo-code) inside the nearest-resetting quota window.
English below · Español al final.

Click the icon for a panel: per-window progress bars (5h / weekly), reset
countdowns, per-agent token/request estimates, and a manual refresh. Colors
shift to warn/critical thresholds as you approach the quota.

**The split is an estimate** by tokens (input + output + cache); exact credits
per agent are not exposed by the API. It is computed from each tool's own
local usage records, so agents that don't leave local records (or other
machines) are not counted.

## Install

```bash
omarchy plugin add https://github.com/ernestodisa/omarchy-zai-usage.git --enable
```

## Removal

Delete the widget entry from `~/.config/omarchy/shell.json`, then:

```bash
omarchy plugin remove ernestodisa.zai-usage
```

## Requirements

- **`omp` CLI** (hard dependency) with a Z.ai coding plan configured — quota
  windows come from `omp usage --json`. Without it the widget shows an error.
- Optional, for the per-agent split only: local records of
  [omp](https://github.com/) (`~/.omp/agent/sessions/`),
  Hermes (`~/.hermes/state.db`), OpenCode
  (`~/.local/share/opencode/opencode.db`), zcode, Z.ai's official CLI
  (`~/.zcode/cli/db/db.sqlite`), Claude Code (`~/.claude/projects/`),
  pi (`~/.pi/agent/sessions/`) and Kilo Code
  (`~/.local/share/kilo/kilo.db`). Missing sources are skipped. Two
  approximations: Claude Code rows record no provider, so they count in full
  (accurate when Claude Code is pointed at Z.ai); zcode's input count already
  includes cached tokens as Z.ai reports it, so its figure is the closest to
  what the plan actually bills.
- `python3` (standard library only). No network calls from the plugin itself;
  no API key is read or stored by the widget — omp holds the credentials.

## Settings

Optional — on the widget entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "ernestodisa.zai-usage", "settings": { "intervalSec": 300, "warnAtPercent": 70, "critAtPercent": 90 } }
```

| Key | Default | Note |
|---|---|---|
| `intervalSec` | `300` | quota refresh interval (30–3600 s) |
| `warnAtPercent` | `70` | warn color threshold |
| `critAtPercent` | `90` | critical color threshold |

## Notes

- "Z.AI" and its logo are trademarks of Z.ai; the icon is included solely for
  identification, no affiliation.
- The plugin never writes user configuration.

## License

MIT — see [LICENSE](LICENSE).

---

# Z.AI Usage — widget de la barra Omarchy (español)

Cuota del coding plan de Z.AI en la barra de Omarchy, con **split estimado por
agente** (omp / hermes / opencode / zcode / claude-code / pi / kilo-code) dentro de la ventana que reinicia primero.

Clic en el ícono para el panel: barras de progreso por ventana (5h / semanal),
cuenta regresiva de reinicio, estimaciones de tokens/peticiones por agente y
refresco manual. Los colores cambian al acercarte a los umbrales.

**El split es una estimación** por tokens (input + output + cache); los
créditos exactos por agente no los expone la API.

## Instalación

```bash
omarchy plugin add https://github.com/ernestodisa/omarchy-zai-usage.git --enable
```

## Desinstalación

Borra la entrada del widget de `~/.config/omarchy/shell.json` y corre:

```bash
omarchy plugin remove ernestodisa.zai-usage
```

## Requisitos

- **CLI `omp`** (dependencia dura) con un coding plan de Z.AI configurado:
  las ventanas vienen de `omp usage --json`. Sin él, el widget marca error.
- Opcional (solo para el split): registros locales de omp
  (`~/.omp/agent/sessions/`), Hermes (`~/.hermes/state.db`), OpenCode
  (`~/.local/share/opencode/opencode.db`), zcode, el CLI oficial de Z.ai
  (`~/.zcode/cli/db/db.sqlite`), Claude Code (`~/.claude/projects/`), pi
  (`~/.pi/agent/sessions/`) y Kilo Code
  (`~/.local/share/kilo/kilo.db`). Las fuentes ausentes se omiten. Dos
  aproximaciones: Claude Code no registra proveedor, así que se cuenta
  completo (es exacto si Claude Code apunta a Z.ai); el conteo de zcode ya
  incluye tokens de cache como los reporta Z.ai, así que es la cifra más
  cercana a lo que el plan cobra de verdad.
- `python3` (solo librería estándar). El plugin no hace llamadas de red ni
  lee llaves: las credenciales las guarda omp.

## Notas

- "Z.AI" y su logo son marcas de Z.ai; el ícono va solo para identificación.
- El plugin nunca escribe tu configuración.

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "ernestodisa.zai-usage"
  ipcTarget: "ernestodisa.zai-usage"
  manageIpc: false

  readonly property int intervalSec: Math.max(30, setting("intervalSec", 300))
  readonly property int warnAt: setting("warnAtPercent", 70)
  readonly property int critAt: setting("critAtPercent", 90)

  property bool fetching: false
  property var report: null
  property string errorText: ""
  // Panel countdowns read this instead of Date.now() so "hace Xs" stays
  // truthful while the panel sits open.
  property double nowMs: Date.now()

  // Absolute path of the sibling report script (Qt.resolvedUrl gives file:// URI).
  readonly property string scriptPath: {
    var u = Qt.resolvedUrl("./usage-report.py").toString()
    if (u.indexOf("file://") === 0) u = u.substring(7)
    return decodeURIComponent(u)
  }

  readonly property var windows: report && report.ok ? (report.windows || []) : []
  // Window with the nearest reset drives the bar label and color.
  readonly property var primary: {
    var best = null
    for (var i = 0; i < windows.length; i++) {
      var w = windows[i]
      if (w.resetsIn === null || w.resetsIn === undefined) continue
      if (best === null || w.resetsIn < best.resetsIn) best = w
    }
    return best
  }
  readonly property int primaryPct: primary ? Math.round(primary.fraction * 100) : -1
  readonly property var split: report && report.ok ? (report.split || null) : null
  readonly property var agents: split && split.agents ? split.agents : []
  readonly property bool hasSplit: split && split.window && agents.length > 0

  // History: downsampled cumulative samples of the current quota window.
  readonly property var history: report && report.ok ? report.history : null
  readonly property var historyPoints: history && history.points ? history.points.slice(-32) : []
  readonly property var historyNames: {
    var totals = {}
    for (var i = 0; i < historyPoints.length; i++) {
      var ag = historyPoints[i].agents || {}
      for (var k in ag) totals[k] = (totals[k] || 0) + ag[k]
    }
    return Object.keys(totals).sort(function(a, b) { return totals[b] - totals[a] })
  }
  readonly property real historyMax: {
    var mx = 0
    for (var i = 0; i < historyPoints.length; i++) {
      var tot = 0
      var ag = historyPoints[i].agents || {}
      for (var k in ag) tot += ag[k]
      if (tot > mx) mx = tot
    }
    return mx
  }
  readonly property var agentColors: ["#7aa2f7", "#e0af68", "#9ece6a", "#bb9af7", "#f7768e", "#7dcfff", "#c0caf5", "#ff9e64"]

  function agentColor(name) {
    var h = 0
    for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0
    return agentColors[h % agentColors.length]
  }

  readonly property color okColor: "#4ade80"
  readonly property color warnColor: "#facc15"
  readonly property color critColor: "#f87171"
  readonly property color statusColor: primaryPct < 0 ? Color.muted
      : primaryPct >= critAt ? critColor
      : primaryPct >= warnAt ? warnColor
      : okColor
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string panelFont: bar ? bar.fontFamily : Style.font.family

  function fmtTokens(n) {
    if (n >= 1000000) return (n / 1000000).toFixed(1).replace(/\.0$/, "") + "M"
    if (n >= 1000) return (n / 1000).toFixed(1).replace(/\.0$/, "") + "K"
    return String(Math.round(n))
  }

  function fmtDuration(sec) {
    if (sec === null || sec === undefined) return "?"
    var mins = Math.max(0, Math.round(sec / 60))
    var d = Math.floor(mins / 1440)
    var h = Math.floor((mins % 1440) / 60)
    var m = mins % 60
    if (d > 0) return d + "d" + h + "h"
    if (h > 0) return m > 0 ? h + "h" + m + "m" : h + "h"
    return m + "m"
  }

  function fmtAgo() {
    if (!report) return ""
    var sec = Math.max(0, Math.round((nowMs - (report.fetchedAt || nowMs)) / 1000))
    if (sec < 5) return "actualizado ahora"
    if (sec < 90) return "actualizado hace " + sec + "s"
    return "actualizado hace " + Math.round(sec / 60) + "m"
  }

  function barGlyphs(fraction, width) {
    var filled = Math.max(0, Math.min(width, Math.round((fraction || 0) * width)))
    return "█".repeat(filled) + "░".repeat(width - filled)
  }

  function agentShare(a) {
    var total = 0
    for (var i = 0; i < agents.length; i++) total += agents[i].tokens
    return total > 0 ? a.tokens / total : 0
  }

  function refreshNow() {
    root.refresh()
  }

  function tooltipTextValue() {
    var lines = ["Z.AI coding plan"]
    for (var i = 0; i < windows.length; i++) {
      var w = windows[i]
      lines.push(w.id + " " + Math.round(w.fraction * 100) + "% · "
        + fmtTokens(w.used) + "/" + fmtTokens(w.limit) + " · ↺" + fmtDuration(w.resetsIn))
    }
    if (errorText !== "") lines.push("⚠ " + errorText)
    return lines.join("\n")
  }

  function refresh() {
    if (!fetchProc.running && !root.fetching) {
      root.fetching = true
      fetchProc.running = true
    }
  }

  onOpenedChanged: {
    root.nowMs = Date.now()
    if (root.opened) root.refresh()
  }
  onReportChanged: root.nowMs = Date.now()

  IpcHandler {
    target: "ernestodisa.zai-usage"

    function toggle(): string { root.toggle(); return "ok" }
    function open(): string { root.open(); return "ok" }
    function refresh(): string { root.refreshNow(); return "ok" }
  }

  Process {
    id: fetchProc
    command: ["python3", root.scriptPath]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          root.report = parsed
          root.errorText = parsed && parsed.ok ? "" : String((parsed && parsed.error) || "unknown error")
        } catch (e) {
          root.errorText = "bad output: " + e
        }
      }
    }

    onExited: function(_exitCode) {
      root.fetching = false
    }
  }

  // Keeps the quota windows fresh; the panel refreshes on open and on demand.
  Timer {
    interval: root.intervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Keeps "actualizado hace Xs" honest while the panel sits open.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  implicitWidth: row.implicitWidth + Style.space(3)
  implicitHeight: Style.bar.sizeHorizontal

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(1.5)

    Image {
      anchors.verticalCenter: parent.verticalCenter
      source: Qt.resolvedUrl("./assets/zai-mark.svg")
      width: Style.space(18)
      height: width
      fillMode: Image.PreserveAspectFit
      smooth: true
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.primaryPct >= 0 ? (root.primaryPct + "%")
          : (root.errorText !== "" ? "⚠" : "…")
      color: root.statusColor
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      renderType: Text.NativeRendering

      Behavior on color {
        ColorAnimation { duration: 160 }
      }
    }
  }

  MouseArea {
    id: button
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) root.refreshNow()
      else root.toggle()
    }
    onContainsMouseChanged: {
      if (!root.bar || !root.bar.showTooltip) return
      if (containsMouse) root.bar.showTooltip(button, root.tooltipTextValue())
      else root.bar.hideTooltip(button)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: root.close()
      onActivateRequested: root.refreshNow()
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Z.AI Coding Plan"
            meta: (root.report && root.report.plan ? root.report.plan : "—")
              + (root.fetching ? " · actualizando…" : " · " + root.fmtAgo())
            foreground: root.foreground
            fontFamily: root.panelFont

            iconComponent: Component {
              Item {
                width: Style.font.display
                height: Style.font.display

                Image {
                  anchors.fill: parent
                  source: Qt.resolvedUrl("./assets/zai-mark.svg")
                  fillMode: Image.PreserveAspectFit
                  smooth: true
                }
              }
            }
          }

          // ---------------- quota windows ----------------
          Column {
            width: parent.width
            spacing: Style.space(10)

            Repeater {
              model: root.windows

              delegate: Column {
                required property var modelData
                readonly property var w: modelData
                width: parent.width
                spacing: Style.space(2)

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    text: w.id
                    width: parent.width - pctText.implicitWidth - parent.spacing
                    color: root.foreground
                    font.family: root.panelFont
                    font.pixelSize: Style.font.body
                    font.bold: root.primary && w.id === root.primary.id
                    elide: Text.ElideRight
                  }
                  Text {
                    id: pctText
                    text: Math.round(w.fraction * 100) + "%"
                    color: (w.fraction * 100) >= root.critAt ? root.critColor
                      : (w.fraction * 100) >= root.warnAt ? root.warnColor
                      : root.okColor
                    font.family: root.panelFont
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    text: root.barGlyphs(w.fraction, 24)
                    color: (w.fraction * 100) >= root.critAt ? root.critColor
                      : (w.fraction * 100) >= root.warnAt ? root.warnColor
                      : root.okColor
                    font.family: root.panelFont
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    text: root.fmtTokens(w.used) + " / " + root.fmtTokens(w.limit)
                      + "   ↺" + root.fmtDuration(w.resetsIn)
                    color: root.foreground
                    opacity: 0.75
                    font.family: root.panelFont
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          // ---------------- per-agent split ----------------
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.hasSplit

            Text {
              width: parent.width
              text: root.hasSplit
                ? "Agentes · ventana " + root.split.window + " (estimado)" : ""
              color: root.foreground
              opacity: 0.6
              font.family: root.panelFont
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Repeater {
              model: root.agents

              delegate: Column {
                required property var modelData
                readonly property var a: modelData
                readonly property real share: root.agentShare(a)
                width: parent.width
                spacing: Style.space(2)

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    text: a.name
                    width: 90
                    color: root.foreground
                    font.family: root.panelFont
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    text: root.barGlyphs(share, 14)
                    color: root.foreground
                    font.family: root.panelFont
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    text: Math.round(share * 100) + "%"
                    width: parent.width - parent.children[0].width
                      - parent.children[1].width - parent.spacing * 2
                    horizontalAlignment: Text.AlignRight
                    color: root.foreground
                    font.family: root.panelFont
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }

                Text {
                  width: parent.width
                  text: root.fmtTokens(a.tokens) + " tokens · " + a.requests + " requests"
                  color: root.foreground
                  opacity: 0.6
                  font.family: root.panelFont
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Text {
              width: parent.width
              text: "Share por tokens; los créditos exactos por agente no los expone la API."
              color: root.foreground
              opacity: 0.45
              font.family: root.panelFont
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------------- history sparkline ----------------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.historyPoints.length > 1

            Text {
              width: parent.width
              text: root.hasSplit
                ? "Historia · ventana " + root.split.window + " (acumulado)"
                : "Historia (acumulado)"
              color: root.foreground
              opacity: 0.6
              font.family: root.panelFont
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Item {
              width: parent.width
              height: 44

              Row {
                anchors.centerIn: parent
                spacing: 1

                Repeater {
                  model: root.historyPoints

                  delegate: Item {
                    required property var modelData
                    readonly property var p: modelData
                    width: 5
                    height: 44

                    Column {
                      anchors.bottom: parent.bottom
                      width: parent.width
                      height: 44
                      spacing: 0

                      Repeater {
                        model: root.historyNames

                        delegate: Rectangle {
                          required property var modelData
                          readonly property string n: modelData
                          readonly property real v: (p.agents && p.agents[n]) ? p.agents[n] : 0
                          width: parent.width
                          height: v > 0 && root.historyMax > 0 ? Math.max(2, v / root.historyMax * 42) : 0
                          color: root.agentColor(n)
                          visible: height > 0
                        }
                      }
                    }
                  }
                }
              }
            }

            Flow {
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: root.historyNames

                delegate: Row {
                  required property var modelData
                  spacing: 4

                  Rectangle {
                    width: 8
                    height: 8
                    radius: 2
                    color: root.agentColor(modelData)
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: modelData
                    color: root.foreground
                    opacity: 0.75
                    font.family: root.panelFont
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          // ---------------- footer ----------------
          Row {
            width: parent.width
            spacing: Style.space(8)

            PanelActionButton {
              iconText: "↻"
              tooltipText: "Actualizar ahora (r)"
              foreground: root.foreground
              fontFamily: root.panelFont
              onClicked: root.refreshNow()
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.errorText !== "" ? "⚠ " + root.errorText : "Esc cierra · r actualiza"
              color: root.errorText !== "" ? root.critColor : root.foreground
              opacity: root.errorText !== "" ? 1 : 0.45
              font.family: root.panelFont
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width - parent.children[0].width - parent.spacing
            }
          }
        }
      }
    }
  }
}

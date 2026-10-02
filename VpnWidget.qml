import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// omarchy-proton bar widget: the external IP of regular traffic and of the
// torrent tunnel, plus a panel to switch the desktop VPN, import configs from
// the drop folder and run the leak check.
//
// This file holds no VPN logic. State comes from `vpn-status --json`, and every
// action is one of the vpnkit commands in /usr/local/bin, so what the panel
// shows is what the command line shows.
Panel {
  id: vpn
  moduleName: "io.github.ralphk-86.omarchy-proton"

  // Must match VERSION and manifest.json (tests/check.sh verifies it).
  readonly property string kitVersion: "0.3.2"

  readonly property string statusCmd: "/usr/local/bin/vpn-status"
  readonly property string toggleCmd: "/usr/local/bin/vpn-toggle"
  readonly property string syncCmd: "/usr/local/bin/vpnkit-sync"
  readonly property string verifyCmd: "/usr/local/bin/vpn-verify"
  readonly property string qbtCmd: "/usr/local/bin/qbittorrent"
  readonly property string pickCmd: "/usr/local/bin/vpnkit-pick"
  readonly property string importCmd: "/usr/local/bin/vpn-import"
  // The torrent tunnel's interface; it exists only inside the namespace.
  property string torrentIf: "pqbt0"
  property string torrentNs: "qbtvpn"
  property string regularIf: ""
  readonly property string diagnoseCmd: "/usr/local/bin/vpn-diagnose"
  // The last leak check's output, for vpn-diagnose to hand to the AI agent.
  readonly property string reportFile: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/vpnkit-last-check.txt"
  // Screenshot mode: with "demoStatusFile" set on this widget's shell.json
  // entry, the widget shows that file instead of the real status and ignores
  // clicks. Used to make preview images without anyone's real servers or IPs
  // (see CONTRIBUTING.md). Unset it with an empty string.
  readonly property string demoFile: String(setting("demoStatusFile", ""))
  readonly property bool demo: demoFile !== ""
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")

  // Nerd Font glyphs, by codepoint so the file stays plain ASCII.
  readonly property string gVpn: String.fromCodePoint(0xF0582)
  readonly property string gDirect: String.fromCodePoint(0xF059F)
  readonly property string gTorrent: String.fromCodePoint(0xF01DA)
  readonly property string gCheck: String.fromCodePoint(0xF012C)
  readonly property string gCopy: String.fromCodePoint(0xF018F)
  readonly property string gAlert: String.fromCodePoint(0xF0026)
  readonly property string gBusy: String.fromCodePoint(0xF0450)
  readonly property string gMagnet: String.fromCodePoint(0xF0347)
  readonly property string gFolder: String.fromCodePoint(0xF024B)
  readonly property string gTrash: String.fromCodePoint(0xF01B4)
  readonly property string gShield: String.fromCodePoint(0xF0565)
  readonly property string gWrench: String.fromCodePoint(0xF05B7)
  readonly property string gFilePlus: String.fromCodePoint(0xF0752)
  readonly property string gRobot: String.fromCodePoint(0xF06A9)
  readonly property string gLan: String.fromCodePoint(0xF0317)

  // --- state from vpn-status -------------------------------------------------
  property bool loaded: false
  property bool installed: true
  property string version: ""
  property string folder: ""
  property string prefix: ""
  property int inbox: 0
  property bool desktopVpn: false
  property string conn: ""
  property string externalIp: ""
  // Kill switch: armed when a server is picked, removed only by "Normal
  // connection". `blocked` = a VPN is wanted but no tunnel is up, so regular
  // traffic is being rejected instead of leaving from the home IP.
  property bool killswitch: false
  property string wanted: ""
  property bool blocked: false
  property bool qbtKnown: false
  property bool qbtConfigured: true
  property bool qbtNs: false
  property bool qbtTunnel: false
  property string qbtIp: ""
  property string qbtServer: ""
  property string qbtConn: ""
  property string pendingTorrent: ""
  // Which traffic the server list is choosing for: "regular" or "torrents".
  property string tab: "regular"
  property bool qbtRunning: false
  property bool qbtProtected: false
  property bool qbtUnprotected: false
  // Other torrent apps running outside the tunnel (only qBittorrent is routed in).
  property var otherApps: []
  readonly property string otherAppsText: otherApps.join(", ")
  property var profiles: []

  property string pendingTarget: ""
  property string armedRemove: ""
  property string message: ""
  property string lastError: ""
  // Omarchy's default AI agent (`omarchy default agent`); empty when none.
  property string aiAgent: ""
  property string verifySummary: ""
  property var verifyFailures: []
  property bool blinkOn: true

  // --- derived ---------------------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, Color.accent)
  readonly property bool vertical: bar ? bar.vertical : false

  readonly property bool busy: actionProcess.running
  readonly property bool syncing: syncProcess.running || pickProcess.running
  readonly property bool switchingTorrent: torrentProcess.running
  readonly property bool verifying: verifyProcess.running
  // Setup runs in a visible Omarchy terminal (sudo asks there), the same way
  // Omarchy's own installers do. The panel only knows it was started; it is
  // done when the installed version matches this widget's.
  property bool settingUp: false
  readonly property bool needsUpdate: installed && loaded && version !== kitVersion
  readonly property bool needsSetup: !installed || needsUpdate

  // The one signal that must never be missed: qBittorrent outside the tunnel.
  readonly property bool danger: qbtUnprotected || otherApps.length > 0
  readonly property bool torrentDown: loaded && qbtKnown && qbtConfigured && !qbtTunnel
  // A VPN that is up without its kill switch was started before the hook ran.
  readonly property bool unguarded: desktopVpn && !killswitch
  readonly property bool alert: danger || torrentDown || blocked || unguarded
  readonly property bool showIps: setting("showIps", true) !== false
  readonly property int refreshIntervalSec: {
    var n = parseInt(String(setting("refreshIntervalSec", 5)), 10)
    return isFinite(n) ? Math.max(2, Math.min(300, n)) : 5
  }

  readonly property string regularText: blocked ? "blocked" : (externalIp !== "" ? externalIp : "...")
  readonly property string torrentText: qbtTunnel ? (qbtIp !== "" ? qbtIp : "...") : (qbtKnown ? "down" : "?")
  readonly property string barText: {
    if (!installed) return gWrench
    if (danger) return gAlert + " TORRENT LEAK"
    var regular = blocked ? gAlert : (desktopVpn ? gVpn : gDirect)
    var showTorrent = qbtConfigured || qbtRunning
    if (vertical || !showIps) return showTorrent ? regular + " " + gTorrent : regular
    return regular + " " + regularText + (showTorrent ? "  " + gTorrent + " " + torrentText : "")
  }

  readonly property string heroTitle: !installed ? "Setup needed"
    : (blocked ? "Traffic blocked" : (desktopVpn ? prettyName(conn) : "Normal connection"))
  readonly property string heroMeta: !installed ? "One step left before the VPN works"
    : (busy ? "Switching"
      : (blocked ? (wanted !== "" ? prettyName(wanted) : "The VPN") + " is down, kill switch is holding"
        : (unguarded ? "VPN is on WITHOUT the kill switch, pick it again"
          : (desktopVpn ? "Through the VPN, kill switch on" : "Regular traffic uses your own IP"))))

  readonly property string torrentTitle: {
    if (!qbtKnown) return "Status unavailable"
    if (!qbtConfigured) return "No torrent tunnel yet"
    if (qbtTunnel) return (qbtServer !== "" ? prettyName(qbtServer) : "Tunnel up") + (qbtIp !== "" ? " · " + qbtIp : "")
    return qbtNs ? "Tunnel down, torrents blocked" : "Tunnel not started, torrents blocked"
  }
  readonly property string torrentDetail: {
    if (qbtUnprotected) return "qBittorrent is running OUTSIDE the tunnel. Close it now."
    if (otherApps.length > 0) return otherAppsText + " is not in the torrent tunnel: it uses your regular connection. Close it and use qBittorrent."
    if (!qbtConfigured) return "Put one config in the torrent subfolder, then refresh. Until then qBittorrent will not start."
    if (qbtProtected) return "qBittorrent is running inside the tunnel"
    if (qbtRunning) return "qBittorrent is running, location unknown"
    return "qBittorrent is not running"
  }
  readonly property string folderShort: folder.replace(/^\/home\/[^\/]+/, "~")

  // Cursor rows, top to bottom.
  property bool cursorActive: false
  property int cursorIndex: 0
  readonly property int setupIndex: needsSetup ? 0 : -1
  readonly property int baseIndex: needsSetup ? 1 : 0
  // "Normal connection" exists for regular traffic only: torrents never
  // leave without a tunnel.
  readonly property int offIndex: tab === "regular" ? baseIndex : -1
  readonly property int firstServerIndex: tab === "regular" ? baseIndex + 1 : baseIndex
  readonly property int refreshIndex: firstServerIndex + profiles.length
  readonly property int pickIndex: refreshIndex + 1
  readonly property int launchIndex: pickIndex + 1
  readonly property int verifyIndex: launchIndex + 1
  // "Troubleshoot with AI" appears only when something is wrong.
  readonly property bool showAi: installed && (verifyFailures.length > 0 || blocked || torrentDown || danger)
  readonly property int aiIndex: showAi ? verifyIndex + 1 : -1
  readonly property int rowCount: installed ? (showAi ? aiIndex + 1 : verifyIndex + 1) : 1

  // "proton-se-21" -> "Sweden 21", "vpn-us-ny-45" -> "USA NY 45"
  function prettyName(name) {
    var s = String(name || "")
    if (prefix !== "" && s.indexOf(prefix + "-") === 0) s = s.slice(prefix.length + 1)
    var parts = s.split("-")
    if (!/^[a-z]{2}$/i.test(parts[0])) return s
    var country = {
      ca: "Canada", se: "Sweden", us: "USA", uk: "UK", gb: "UK",
      nl: "Netherlands", ch: "Switzerland", de: "Germany", fr: "France",
      jp: "Japan", au: "Australia", is: "Iceland", es: "Spain", it: "Italy",
      no: "Norway", pl: "Poland", fi: "Finland", dk: "Denmark", ie: "Ireland",
      ro: "Romania", at: "Austria", be: "Belgium", sg: "Singapore", mx: "Mexico",
      br: "Brazil", cz: "Czechia", pt: "Portugal", hk: "Hong Kong", in: "India"
    }[parts[0].toLowerCase()] || parts[0].toUpperCase()
    var rest = []
    for (var i = 1; i < parts.length; i++) rest.push(/^\d+$/.test(parts[i]) ? parts[i] : parts[i].toUpperCase())
    return rest.length > 0 ? country + " " + rest.join(" ") : country
  }

  function refresh(force) {
    if (statusProcess.running) return
    var args = force ? "--refresh --json" : "--json"
    statusProcess.command = demo
      ? ["cat", demoFile]
      : ["bash", "-c", "[ -x " + statusCmd + " ] || exit 127; exec " + statusCmd + " " + args]
    statusProcess.running = true
  }

  function applyStatus(exitCode, output) {
    if (exitCode === 127) { installed = false; loaded = true; return }
    installed = true
    var j = null
    try { j = JSON.parse(String(output || "").trim()) } catch (e) { return }
    if (!j) return
    version = String(j.version || "")
    folder = String(j.folder || "")
    prefix = String(j.prefix || "")
    inbox = parseInt(j.inbox, 10) || 0
    desktopVpn = j.desktop_vpn === true
    conn = String(j.conn || "")
    externalIp = j.external_ip && j.external_ip !== "unknown" && j.external_ip !== "blocked" ? String(j.external_ip) : ""
    killswitch = j.killswitch === true
    wanted = String(j.wanted || "")
    blocked = j.blocked === true
    qbtKnown = j.qbt_known === true
    qbtConfigured = j.qbt_configured !== false
    qbtNs = j.qbt_ns === true
    qbtTunnel = j.qbt_tunnel === true
    qbtIp = String(j.qbt_ip || "")
    qbtServer = String(j.qbt_server || "")
    qbtConn = String(j.qbt_conn || "")
    qbtRunning = j.qbt_running === true
    qbtProtected = j.qbt_protected === true
    qbtUnprotected = j.qbt_unprotected === true
    var apps = j.other_torrent_apps instanceof Array ? j.other_torrent_apps : []
    if (JSON.stringify(apps) !== JSON.stringify(otherApps)) otherApps = apps
    aiAgent = String(j.ai_agent || "")
    torrentIf = String(j.torrent_if || "pqbt0")
    torrentNs = String(j.torrent_ns || "qbtvpn")
    regularIf = String(j.regular_if || "")
    if (demo) { message = ""; lastError = ""; if (j.demo_verify) verifySummary = String(j.demo_verify) }
    var next = j.profiles instanceof Array ? j.profiles : []
    if (JSON.stringify(next) !== JSON.stringify(profiles)) profiles = next
    loaded = true
    if (cursorIndex >= rowCount) cursorIndex = rowCount - 1
  }

  function switchTo(name) {
    if (busy || !installed) return
    if (demo) return
    // Nothing to do only when the requested state is fully in place already.
    if (name === "off" ? (!desktopVpn && !killswitch) : (desktopVpn && conn === name && killswitch)) return
    if (name !== "off" && name === qbtConn) {
      lastError = prettyName(name) + " carries the torrent tunnel. Pick another server, or choose a different torrent server first."
      return
    }
    pendingTarget = name
    lastError = ""
    message = ""
    actionProcess.command = [toggleCmd, name]
    actionProcess.running = true
  }

  function quickToggle() {
    if (desktopVpn || killswitch) switchTo("off")
    else if (profiles.length > 0) switchTo(profiles[0])
  }

  // Refresh: import whatever is waiting in the drop folder, then re-read status.
  function sync() {
    if (syncing || !installed) return
    if (demo) return
    lastError = ""
    message = ""
    syncProcess.command = ["sudo", "-n", syncCmd, "sync"]
    syncProcess.running = true
  }

  function applySync(exitCode, output) {
    var j = null
    try { j = JSON.parse(String(output || "").trim()) } catch (e) {}
    if (exitCode !== 0 || !j) {
      lastError = "Could not read the folder. Run setup again from this panel."
      refresh(true)
      return
    }
    var parts = []
    var imported = j.imported instanceof Array ? j.imported : []
    if (imported.length > 0) {
      var names = []
      for (var i = 0; i < imported.length; i++) names.push(prettyName(imported[i]))
      parts.push("Imported " + names.join(", ") + ".")
    }
    if (j.torrent) parts.push("Torrent tunnel: " + prettyName(j.torrent) + ".")
    if (j.note) parts.push(String(j.note))
    var skipped = j.skipped instanceof Array ? j.skipped : []
    var errors = []
    for (var k = 0; k < skipped.length; k++) errors.push(skipped[k].file + ": " + skipped[k].reason)
    if (parts.length === 0 && errors.length === 0) parts.push("Nothing new in " + folderShort + ".")
    message = parts.join(" ")
    lastError = errors.join("\n")
    refresh(true)
  }

  function inRegularUse(name) { return (desktopVpn && conn === name) || wanted === name }

  // Choose which server carries the torrent tunnel.
  function chooseTorrent(name) {
    if (demo || switchingTorrent || !installed || name === qbtConn) return
    if (inRegularUse(name)) {
      lastError = prettyName(name) + " carries your regular traffic. One config cannot be used twice at the same time."
      return
    }
    if (qbtRunning) {
      lastError = "Close qBittorrent first, then choose its server."
      return
    }
    lastError = ""
    message = ""
    pendingTorrent = name
    torrentProcess.command = ["sudo", "-n", syncCmd, "torrent", name]
    torrentProcess.running = true
  }

  // First click arms, a second click within three seconds deletes.
  function requestRemove(name) {
    if (removeProcess.running) return
    if (demo) return
    if (armedRemove !== name) {
      armedRemove = name
      disarmTimer.restart()
      return
    }
    armedRemove = ""
    lastError = ""
    message = ""
    removeProcess.command = ["sudo", "-n", syncCmd, "remove", name]
    removeProcess.running = true
  }

  // Choose configs in the standard file dialog; they are moved into the drop
  // folder and imported (vpn-import), exactly like Refresh.
  function pickFiles() {
    if (demo || syncing || !installed) return
    lastError = ""
    message = ""
    pickProcess.command = ["bash", "-c", "files=$(" + pickCmd + ") || exit 3; mapfile -t f <<<\"$files\"; exec " + importCmd + " \"${f[@]}\""]
    pickProcess.running = true
    close()
  }

  // Desktop notifications for the moments that matter, only on a change of
  // state (never at startup, never in screenshot mode). Sent the way Omarchy's
  // own crash watcher does it: critical ones get through Do Not Disturb, and
  // when there is a problem and an AI agent is chosen, clicking the toast
  // starts vpn-diagnose, which hands the problem to that agent.
  function notify(urgency, title, body, problem) {
    if (demo || !loaded) return
    var argv = ["omarchy-notification-send", "--urgency", urgency,
                "--glyph", urgency === "critical" ? gAlert : gVpn]
    if (urgency !== "critical") argv.push("--app-name", "VPN")
    var ai = (problem || "") !== "" && aiAgent !== ""
    argv.push(title, ai ? body + " Click to troubleshoot with AI." : body)
    // --exec takes the rest of the line as argv; the shell never re-parses it.
    if (ai) argv.push("--exec", diagnoseCmd, problem)
    Quickshell.execDetached(argv)
  }
  onBlockedChanged: if (blocked) notify("critical", "VPN dropped",
    (wanted !== "" ? prettyName(wanted) : "The server") + " is not connected. The kill switch is blocking regular traffic until you pick a server or Normal connection.",
    "The VPN dropped: " + (wanted !== "" ? wanted : "the chosen server") + " is selected but not connected, so the kill switch is blocking regular traffic.")
  onTorrentDownChanged: if (torrentDown) notify("normal", "Torrent tunnel down",
    "qBittorrent has no network until the tunnel is back. Nothing leaks.",
    "The torrent tunnel (namespace qbtvpn) is down, so qBittorrent has no network.")
  onQbtUnprotectedChanged: if (qbtUnprotected) notify("critical", "qBittorrent is outside the tunnel",
    "A qBittorrent process is running outside the VPN namespace. Close it now.",
    "A qBittorrent process is running outside the qbtvpn namespace, so its traffic may not go through the tunnel.")
  onOtherAppsTextChanged: if (otherAppsText !== "") notify("critical", otherAppsText + " is not in the torrent tunnel",
    "Only qBittorrent opened from this panel or its launcher uses the torrent tunnel. " + otherAppsText + " uses your regular connection. Close it and use qBittorrent.",
    "A torrent app other than qBittorrent (" + otherAppsText + ") is running outside the qbtvpn namespace, so it uses the regular connection instead of the torrent tunnel.")

  // The problem as one sentence for the agent, from what the panel knows now.
  function currentProblem() {
    if (verifyFailures.length > 0)
      return "The leak check (vpn-verify) found " + verifyFailures.length + " failing check" + (verifyFailures.length === 1 ? "" : "s") + "."
    if (qbtUnprotected) return "A qBittorrent process is running outside the qbtvpn namespace."
    if (otherApps.length > 0) return "A torrent app other than qBittorrent (" + otherAppsText + ") is running outside the qbtvpn namespace."
    if (blocked) return "The VPN dropped: " + (wanted !== "" ? wanted : "the chosen server") + " is selected but not connected, so the kill switch is blocking regular traffic."
    if (torrentDown) return "The torrent tunnel (namespace qbtvpn) is down, so qBittorrent has no network."
    return ""
  }

  function troubleshoot() {
    if (demo || !installed) return
    Quickshell.execDetached([diagnoseCmd, currentProblem()])
    close()
  }

  function verify() {
    if (verifying || !installed) return
    if (demo) return
    verifySummary = ""
    verifyFailures = []
    // The report is kept for vpn-diagnose. tee runs as you; only vpn-verify is root.
    verifyProcess.command = ["bash", "-c", "sudo -n \"$1\" 2>&1 | tee \"$2\"", "vpn-verify", verifyCmd, reportFile]
    verifyProcess.running = true
  }

  function applyVerify(output) {
    var lines = String(output || "").split("\n")
    var fails = []
    var summary = ""
    for (var i = 0; i < lines.length; i++) {
      var f = lines[i].match(/\[FAIL\]\s*(.*)$/)
      if (f) fails.push(f[1])
      var r = lines[i].match(/Result:\s*(\d+) passed,\s*(\d+) failed/)
      if (r) summary = r[2] === "0" ? r[1] + " checks passed, no leaks found" : r[2] + " of " + (parseInt(r[1], 10) + parseInt(r[2], 10)) + " checks FAILED"
    }
    verifyFailures = fails
    verifySummary = summary !== "" ? summary : "The check could not run. Run setup again from this panel."
    if (fails.length > 0)
      notify("critical", "Leak check failed",
             fails.length + (fails.length === 1 ? " check failed: " : " checks failed, first: ") + fails[0],
             currentProblem())
  }

  function runSetup() {
    if (settingUp) return
    if (demo) return
    lastError = ""
    message = "Setup is running in a terminal window. It asks for your password there."
    settingUp = true
    setupTimeout.restart()
    Quickshell.execDetached(["omarchy", "launch", "floating", "terminal", "with", "presentation",
                             Util.shellQuote(pluginDir + "/install.sh")])
    close()
  }

  function launchQbt() {
    if (!installed || qbtRunning || !qbtTunnel) return
    if (demo) return
    Quickshell.execDetached([qbtCmd])
    close()
  }

  function openFolder() {
    if (folder === "") return
    Quickshell.execDetached(["bash", "-c", "mkdir -p " + Util.shellQuote(folder + "/torrent") + " && xdg-open " + Util.shellQuote(folder)])
    close()
  }

  function copy(text) {
    if (String(text || "") === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = Math.max(0, Math.min(rowCount - 1, index))
  }

  function moveCursor(dy) {
    if (!cursorActive) { cursorActive = true; return }
    setCursor(cursorIndex + dy)
  }

  function activateCursor() {
    if (!cursorActive) return
    if (cursorIndex === setupIndex) runSetup()
    else if (cursorIndex === offIndex) switchTo("off")
    else if (cursorIndex === refreshIndex) sync()
    else if (cursorIndex === pickIndex) pickFiles()
    else if (cursorIndex === launchIndex) launchQbt()
    else if (cursorIndex === verifyIndex) verify()
    else if (cursorIndex === aiIndex) troubleshoot()
    else if (cursorIndex >= firstServerIndex && cursorIndex < refreshIndex) pickServer(profiles[cursorIndex - firstServerIndex])
  }

  // A click on a server row: for the tab that is showing.
  function pickServer(name) {
    if (tab === "torrents") chooseTorrent(name)
    else switchTo(name)
  }

  function setTab(value) {
    if (value === tab) return
    tab = value
    lastError = ""
    if (cursorIndex >= rowCount) cursorIndex = rowCount - 1
  }

  function deleteAtCursor() {
    if (!cursorActive) return
    var i = cursorIndex - firstServerIndex
    if (i >= 0 && i < profiles.length) requestRemove(profiles[i])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    armedRemove = ""
    if (panelFlick) panelFlick.contentY = 0
    refresh(true)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    onExited: function(exitCode) { vpn.applyStatus(exitCode, statusStdout.text) }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    onExited: function(exitCode) {
      var target = vpn.pendingTarget
      vpn.pendingTarget = ""
      if (exitCode !== 0) {
        vpn.lastError = target === "off"
          ? "Could not switch to the normal connection. Run vpn-rescue in a terminal."
          : vpn.prettyName(target) + " did not answer. Traffic is blocked until you pick another server or Normal connection."
      }
      vpn.refresh(true)
    }
  }

  Process {
    id: torrentProcess
    running: false
    command: []
    stderr: StdioCollector { id: torrentStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var target = vpn.pendingTorrent
      vpn.pendingTorrent = ""
      if (exitCode !== 0) vpn.lastError = String(torrentStderr.text || "").replace(/^vpnkit-sync:\s*/, "").trim() || "Could not switch the torrent server."
      else vpn.message = "Torrents now use " + vpn.prettyName(target) + "."
      vpn.refresh(true)
    }
  }

  Process {
    id: pickProcess
    running: false
    command: []
    stdout: StdioCollector { id: pickStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(pickStdout.text || "").trim()
      if (exitCode === 3) return            // dialog cancelled
      if (exitCode !== 0 && out === "") vpn.notify("normal", "Import failed", "Run vpn-import in a terminal to see why.")
      else vpn.notify("normal", "Servers imported", out.split("\n").filter(function(l) { return l.indexOf("imported: ") === 0 }).map(function(l) { return vpn.prettyName(l.slice(10)) }).join(", ") || out.split("\n")[0])
      vpn.refresh(true)
    }
  }

  Process {
    id: syncProcess
    running: false
    command: []
    stdout: StdioCollector { id: syncStdout; waitForEnd: true }
    onExited: function(exitCode) { vpn.applySync(exitCode, syncStdout.text) }
  }

  Process {
    id: removeProcess
    running: false
    command: []
    stderr: StdioCollector { id: removeStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) vpn.lastError = String(removeStderr.text || "").replace(/^vpnkit-sync:\s*/, "").trim() || "Could not remove the server."
      else vpn.message = "Server removed."
      vpn.refresh(true)
    }
  }

  Process {
    id: verifyProcess
    running: false
    command: []
    stdout: StdioCollector { id: verifyStdout; waitForEnd: true }
    onExited: function(exitCode) { vpn.applyVerify(verifyStdout.text) }
  }

  Timer {
    id: setupTimeout
    interval: 15 * 60 * 1000
    onTriggered: vpn.settingUp = false
  }

  onVersionChanged: if (settingUp && version === kitVersion) {
    settingUp = false
    message = "Setup finished."
  }

  Timer {
    interval: vpn.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: vpn.refresh(false)
  }

  Timer {
    id: disarmTimer
    interval: 3000
    onTriggered: vpn.armedRemove = ""
  }

  Timer {
    interval: 500
    running: vpn.danger
    repeat: true
    onTriggered: vpn.blinkOn = !vpn.blinkOn
    onRunningChanged: if (!running) vpn.blinkOn = true
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: vpn.bar
    text: vpn.barText
    active: vpn.alert
    dimmed: vpn.danger && !vpn.blinkOn
    // Tooltip suppressed because the panel is the detail view.
    tooltipText: ""
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) vpn.quickToggle()
      else if (buttonCode === Qt.MiddleButton) vpn.refresh(true)
      else vpn.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: vpn
    bar: vpn.bar
    open: vpn.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(860))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) vpn.moveCursor(dy)
        else if (dx < 0) vpn.setTab("regular")
        else if (dx > 0) vpn.setTab("torrents")
      }
      onActivateRequested: vpn.activateCursor()
      onCloseRequested: vpn.close()
      onDeleteRequested: vpn.deleteAtCursor()
      onTabRequested: function(direction) { vpn.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") vpn.sync()
        else if (t === "o" || t === "O") vpn.switchTo("off")
        else if (t === "c" || t === "C") vpn.copy(vpn.externalIp)
        else if (t === "v" || t === "V") vpn.verify()
        else if ((t === "a" || t === "A") && vpn.showAi) vpn.troubleshoot()
        else if (t === "t" || t === "T") vpn.setTab(vpn.tab === "regular" ? "torrents" : "regular")
      }

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
            id: hero
            width: parent.width
            title: vpn.heroTitle
            meta: vpn.heroMeta
            detail: vpn.installed ? vpn.regularText : ""
            foreground: vpn.foreground
            fontFamily: vpn.fontFamily
            iconOpacity: vpn.desktopVpn || vpn.blocked || !vpn.installed ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: !vpn.installed ? vpn.gWrench : (vpn.blocked ? vpn.gAlert : (vpn.desktopVpn ? vpn.gVpn : vpn.gDirect))
                color: vpn.blocked || vpn.unguarded ? vpn.urgent : vpn.foreground
                font.family: vpn.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: vpn.message !== ""
            width: parent.width
            text: vpn.message
            color: vpn.dim
            font.family: vpn.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: vpn.lastError !== ""
            width: parent.width
            text: vpn.lastError
            color: vpn.urgent
            font.family: vpn.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          ChoiceRow {
            visible: vpn.needsSetup
            width: parent.width
            rowIndex: vpn.setupIndex
            glyph: vpn.gWrench
            title: vpn.settingUp ? "Setting up" : (vpn.installed ? "Update the system part" : "Finish setup")
            subtitle: vpn.installed
              ? "The widget was updated; the helpers need to match. Asks for your password"
              : "Installs the kill switch and helpers. Asks for your password once"
            isPending: vpn.settingUp
            isCurrent: true
            onChosen: vpn.runSetup()
          }

          // Torrents at a glance, under the regular-traffic header.
          RowLayout {
            visible: vpn.installed
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: vpn.danger || vpn.torrentDown ? vpn.gAlert : vpn.gTorrent
              color: vpn.danger || vpn.torrentDown ? vpn.urgent : vpn.foreground
              font.family: vpn.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              Layout.preferredWidth: Style.space(22)
              Layout.leftMargin: Style.space(6)
              Layout.alignment: Qt.AlignVCenter
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(1)

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: !vpn.qbtKnown || !vpn.qbtConfigured || !vpn.qbtTunnel ? "Torrents: " + vpn.torrentTitle
                  : "Torrents: " + (vpn.qbtConn !== "" ? vpn.prettyName(vpn.qbtConn) : (vpn.qbtServer !== "" ? vpn.prettyName(vpn.qbtServer) : "tunnel up"))
                color: vpn.torrentDown ? vpn.urgent : vpn.foreground
                font.family: vpn.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: (vpn.qbtTunnel && vpn.qbtIp !== "" ? vpn.qbtIp + " \u00b7 " : "") + vpn.torrentDetail
                color: vpn.danger ? vpn.urgent : vpn.dim
                font.family: vpn.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            PanelActionButton {
              visible: vpn.qbtIp !== ""
              iconText: vpn.gCopy
              tooltipText: "Copy torrent IP"
              foreground: vpn.foreground
              fontFamily: vpn.fontFamily
              Layout.alignment: Qt.AlignVCenter
              Layout.rightMargin: Style.space(6)
              onClicked: vpn.copy(vpn.qbtIp)
            }
          }

          PanelSeparator {
            visible: vpn.installed
            foreground: vpn.foreground
          }

          Column {
            visible: vpn.installed
            width: parent.width
            spacing: Style.space(10)

            // Which traffic the list below chooses a server for.
            ButtonGroup {
              anchors.horizontalCenter: parent.horizontalCenter
              focusable: false
              options: [
                { value: "regular", label: "Regular traffic", icon: vpn.gDirect,
                  tooltip: "Choose where your browser and apps go out" },
                { value: "torrents", label: "Torrents", icon: vpn.gTorrent,
                  tooltip: "Choose the server qBittorrent uses" }
              ]
              value: vpn.tab
              foreground: vpn.foreground
              fontFamily: vpn.fontFamily
              onChanged: function(v) { vpn.setTab(v) }
            }

            // Which network interface the traffic of this tab uses.
            InterfaceLine {
              width: parent.width
              name: vpn.tab === "torrents" ? vpn.torrentIf : vpn.regularIf
              detail: vpn.tab === "torrents"
                ? "Only inside the " + vpn.torrentNs + " namespace. qBittorrent only; other torrent apps cannot use it"
                : (vpn.blocked ? "Blocked by the kill switch until a server connects"
                  : (vpn.desktopVpn ? "The VPN tunnel for your browser and apps" : "Your own connection, no VPN"))
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: vpn.tab === "regular"
              text: "Picking a server turns the kill switch on. It stays on until Normal connection."
              color: vpn.dim
              font.family: vpn.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: vpn.tab === "torrents"
              text: vpn.qbtRunning ? "Close qBittorrent to change its server."
                : "One server cannot carry torrents and regular traffic at the same time."
              color: vpn.dim
              font.family: vpn.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              ChoiceRow {
                visible: vpn.tab === "regular"
                width: parent.width
                rowIndex: vpn.offIndex
                glyph: vpn.gDirect
                title: "Normal connection"
                subtitle: "No VPN, your own IP"
                isCurrent: vpn.loaded && !vpn.desktopVpn && !vpn.killswitch
                isPending: vpn.pendingTarget === "off"
                onChosen: vpn.switchTo("off")
              }

              Repeater {
                model: vpn.profiles
                ChoiceRow {
                  required property var modelData
                  required property int index
                  readonly property string profile: String(modelData)
                  readonly property bool regularHere: vpn.inRegularUse(profile)
                  readonly property bool torrentsHere: vpn.qbtConn === profile
                  // Taken by the other tab: shown, labelled, not selectable.
                  readonly property bool takenElsewhere: vpn.tab === "regular" ? torrentsHere : regularHere
                  width: parent.width
                  rowIndex: vpn.firstServerIndex + index
                  glyph: vpn.tab === "torrents" ? vpn.gTorrent : vpn.gVpn
                  title: vpn.prettyName(profile)
                  subtitle: vpn.armedRemove === profile ? "Click the trash again to delete this server"
                    : takenElsewhere ? (vpn.tab === "regular" ? "Used for torrents" : "Carries your regular traffic")
                    : (vpn.tab === "regular" && vpn.blocked && vpn.wanted === profile) ? "Down, traffic blocked. Click to retry"
                    : profile
                  isCurrent: vpn.tab === "regular" ? (vpn.desktopVpn && vpn.conn === profile) : torrentsHere
                  isPending: vpn.tab === "regular" ? vpn.pendingTarget === profile : vpn.pendingTorrent === profile
                  opacity: takenElsewhere ? 0.55 : 1.0
                  badge: takenElsewhere ? (vpn.tab === "regular" ? vpn.gTorrent : vpn.gVpn) : ""
                  actionGlyph: regularHere || torrentsHere ? "" : vpn.gTrash
                  actionTooltip: "Delete this server"
                  actionUrgent: true
                  onChosen: vpn.pickServer(profile)
                  onActionChosen: vpn.requestRemove(profile)
                }
              }

              ChoiceRow {
                width: parent.width
                rowIndex: vpn.refreshIndex
                glyph: vpn.gFolder
                title: vpn.syncing ? "Importing"
                  : (vpn.inbox > 0 ? "Import " + vpn.inbox + (vpn.inbox === 1 ? " new config" : " new configs") : "Refresh servers")
                subtitle: vpn.profiles.length === 0 && vpn.inbox === 0
                  ? "Put WireGuard .conf files in " + vpn.folderShort + " first"
                  : "Reads " + vpn.folderShort
                isPending: vpn.syncing
                isCurrent: vpn.inbox > 0
                actionGlyph: vpn.gFolder
                actionTooltip: "Open the folder"
                onChosen: vpn.sync()
                onActionChosen: vpn.openFolder()
              }

              ChoiceRow {
                width: parent.width
                rowIndex: vpn.pickIndex
                glyph: vpn.gFilePlus
                title: "Import from files"
                subtitle: "Choose .conf files, for example in Downloads"
                onChosen: vpn.pickFiles()
              }
            }
          }

          PanelSeparator {
            visible: vpn.installed
            foreground: vpn.foreground
          }

          Column {
            visible: vpn.installed
            width: parent.width
            spacing: Style.space(6)

            ChoiceRow {
              visible: vpn.qbtConfigured
              width: parent.width
              rowIndex: vpn.launchIndex
              glyph: vpn.gMagnet
              title: vpn.qbtRunning ? "qBittorrent is open" : "Open qBittorrent"
              subtitle: vpn.qbtTunnel ? "Always starts inside the tunnel" : "Refuses to start while the tunnel is down"
              enabled: vpn.qbtTunnel && !vpn.qbtRunning
              opacity: enabled ? 1.0 : 0.55
              onChosen: vpn.launchQbt()
            }

            ChoiceRow {
              width: parent.width
              rowIndex: vpn.verifyIndex
              glyph: vpn.gShield
              title: vpn.verifying ? "Checking" : "Check for leaks"
              subtitle: vpn.verifying ? "Takes about twenty seconds"
                : (vpn.verifySummary !== "" ? vpn.verifySummary : "Routes, DNS, IPv6, kill switch, torrent tunnel")
              isPending: vpn.verifying
              onChosen: vpn.verify()
            }

            Text {
              textFormat: Text.PlainText
              visible: vpn.verifyFailures.length > 0
              width: parent.width
              text: vpn.verifyFailures.join("\n")
              color: vpn.urgent
              font.family: vpn.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            ChoiceRow {
              visible: vpn.showAi
              width: parent.width
              rowIndex: vpn.aiIndex
              glyph: vpn.gRobot
              title: "Troubleshoot with AI"
              subtitle: vpn.aiAgent !== "" ? "Opens " + vpn.aiAgent + " with what went wrong. It asks before changing anything."
                : "Choose an AI agent first (Omarchy menu: Setup, Defaults, Agent)"
              onChosen: vpn.troubleshoot()
            }
          }
        }
      }
    }
  }

  component InterfaceLine: RowLayout {
    id: ifLine
    property string name: ""
    property string detail: ""
    visible: name !== ""
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: vpn.gLan
      color: vpn.dim
      font.family: vpn.fontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
      Layout.preferredWidth: Style.space(22)
      Layout.leftMargin: Style.space(6)
      Layout.alignment: Qt.AlignVCenter
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: "Interface: " + ifLine.name
        color: vpn.foreground
        font.family: vpn.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: ifLine.detail
        color: vpn.dim
        font.family: vpn.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    PanelActionButton {
      iconText: vpn.gCopy
      tooltipText: "Copy interface name"
      foreground: vpn.foreground
      fontFamily: vpn.fontFamily
      Layout.alignment: Qt.AlignVCenter
      Layout.rightMargin: Style.space(6)
      onClicked: vpn.copy(ifLine.name)
    }
  }

  component ChoiceRow: CursorSurface {
    id: choice

    property int rowIndex: 0
    property string glyph: ""
    property string title: ""
    property string subtitle: ""
    property bool isCurrent: false
    property bool isPending: false
    // Optional small button at the right edge (delete a server, open folder).
    property string badge: ""
    property string actionGlyph: ""
    property string actionTooltip: ""
    property bool actionUrgent: false

    signal chosen()
    signal actionChosen()

    hasCursor: vpn.cursorActive && vpn.cursorIndex === rowIndex
    current: isCurrent || isPending
    foreground: vpn.foreground
    fill: vpn.hoverFill
    currentFill: vpn.selectedFill
    implicitHeight: choiceInner.implicitHeight + Style.spacing.xl

    Row {
      id: choiceInner
      anchors.left: parent.left
      anchors.right: actionButton.visible ? actionButton.left : parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        id: choiceGlyph
        textFormat: Text.PlainText
        text: choice.isPending ? vpn.gBusy : (choice.isCurrent && choice.glyph !== vpn.gFolder && choice.glyph !== vpn.gWrench ? vpn.gCheck : choice.glyph)
        color: choice.isCurrent || choice.isPending ? vpn.foreground : vpn.dim
        font.family: vpn.fontFamily
        font.pixelSize: Style.font.body
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter

        NumberAnimation on rotation {
          running: choice.isPending
          from: 0
          to: 360
          duration: 900
          loops: Animation.Infinite
        }

        onRotationChanged: if (!choice.isPending && rotation !== 0) rotation = 0
      }

      Column {
        width: parent.width - Style.space(30)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: choice.title + (choice.badge !== "" ? "  " + choice.badge : "")
          color: vpn.foreground
          font.family: vpn.fontFamily
          font.pixelSize: Style.font.body
          font.bold: choice.isCurrent
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: choice.subtitle
          visible: text !== ""
          color: vpn.dim
          font.family: vpn.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: choice.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: vpn.setCursor(choice.rowIndex)
      onClicked: choice.chosen()
    }

    // Declared after the row's MouseArea so it sits on top and takes its own clicks.
    PanelActionButton {
      id: actionButton
      visible: choice.actionGlyph !== ""
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      iconText: choice.actionGlyph
      tooltipText: choice.actionTooltip
      foreground: vpn.foreground
      hoverColor: choice.actionUrgent ? vpn.urgent : vpn.foreground
      fontFamily: vpn.fontFamily
      onClicked: choice.actionChosen()
    }
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Thin wrapper around the `aws-vpn-client` CLI. Every command prints JSON, so
// state is rebuilt from `list-profiles` + `list-connections` on each poll and
// connect/disconnect just kick the CLI and poll faster until things settle.
Item {
  id: root

  property var settings: ({})
  // Profile the user picked last (persisted by the panel in shell.json).
  property string preferredProfile: ""

  property bool installed: true
  property var profiles: []          // [{ name, authType, importedAt }]
  property var connections: []       // [{ name, status, updatedAt }]
  property var details: null         // byte counters for the active profile
  property string lastError: ""
  property string actionStatus: ""
  property string pendingProfile: "" // profile a connect/disconnect is working on
  property string pendingAction: ""  // "connect" | "disconnect" | ""
  // Queued connect that runs once the current disconnect finishes (switching).
  property string _queuedConnect: ""
  // Set when a disconnect has to wait for a still-running `connect` (stuck in
  // sign-in) to be stopped first.
  property string _disconnectAfterExit: ""
  // True while the in-flight disconnect is cancelling a sign-in, not tearing
  // down an established tunnel.
  property bool _cancellingSignIn: false

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 2, 3600)
  readonly property bool busy: actionProcess.running || pendingAction !== ""

  // The connection the bar cares about: anything not plainly disconnected.
  readonly property var activeConnection: {
    for (var i = 0; i < connections.length; i++) {
      if (!isDisconnected(connections[i].status)) return connections[i]
    }
    return null
  }
  readonly property string activeProfile: activeConnection ? activeConnection.name : ""
  readonly property string activeStatus: activeConnection ? activeConnection.status : "Disconnected"
  readonly property bool connected: activeConnection !== null && isConnected(activeConnection.status)
  readonly property bool transitioning: busy || (activeConnection !== null && !connected)
  readonly property bool disconnecting: pendingAction === "disconnect"
  // Signing in / establishing the tunnel. Covers a connect we started and one
  // the daemon reports as in progress (e.g. after our wait timed out).
  readonly property bool connecting: !disconnecting && (pendingAction === "connect" || (activeConnection !== null && !connected))

  readonly property string selectedProfile: {
    if (activeProfile !== "") return activeProfile
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].name === preferredProfile) return preferredProfile
    }
    return profiles.length > 0 ? profiles[0].name : ""
  }

  readonly property string statusText: {
    if (!installed) return "aws-vpn-client not installed"
    if (pendingAction === "connect") return "Signing in to " + pendingProfile + "…"
    if (pendingAction === "disconnect") return (_cancellingSignIn ? "Cancelling sign-in to " : "Disconnecting ") + pendingProfile + "…"
    if (activeConnection) return statusLabel(activeStatus) + " · " + activeProfile
    if (profiles.length === 0) return "No profiles imported"
    return "Disconnected"
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function isConnected(status) {
    return /^connected$/i.test(String(status || ""))
  }

  function isDisconnected(status) {
    var s = String(status || "")
    return s === "" || /^(disconnected|failed|error|idle)$/i.test(s)
  }

  // CLI states are PascalCase identifiers ("WaitingForIdentity"); make the
  // sign-in one read naturally and split the rest into words.
  function statusLabel(status) {
    var s = String(status || "")
    if (/^waitingforidentity$/i.test(s)) return "Waiting for sign-in"
    return s.replace(/([a-z])([A-Z])/g, "$1 $2")
  }

  function statusFor(name) {
    for (var i = 0; i < connections.length; i++) {
      if (connections[i].name === name) return connections[i].status
    }
    return "Disconnected"
  }

  function formatBytes(n) {
    var value = Number(n || 0)
    var units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while (value >= 1024 && i < units.length - 1) { value /= 1024; i++ }
    return (i === 0 ? value.toFixed(0) : value.toFixed(1)) + " " + units[i]
  }

  function formatSince(iso) {
    var t = Date.parse(String(iso || ""))
    if (!isFinite(t)) return ""
    var secs = Math.max(0, Math.floor((Date.now() - t) / 1000))
    var h = Math.floor(secs / 3600)
    var m = Math.floor((secs % 3600) / 60)
    if (h > 0) return h + "h " + m + "m"
    if (m > 0) return m + "m"
    return secs + "s"
  }

  function parseJson(text, fallback) {
    try {
      var value = JSON.parse(String(text || "").trim() || "null")
      return value === null ? fallback : value
    } catch (e) {
      return fallback
    }
  }

  function flash(message) {
    actionStatus = message
    actionStatusTimer.restart()
  }

  function refresh() {
    if (!profilesProcess.running) profilesProcess.running = true
    if (!connectionsProcess.running) connectionsProcess.running = true
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  function refreshDetails() {
    if (activeProfile === "" || detailsProcess.running) return
    detailsProcess.command = ["aws-vpn-client", "get-connection-status", "--profile-name", activeProfile, "--show-details"]
    detailsProcess.running = true
  }

  function run(action, profile) {
    if (profile === "" || actionProcess.running) return
    lastError = ""
    pendingAction = action
    pendingProfile = profile
    actionProcess.command = ["aws-vpn-client", action, "--profile-name", profile]
    actionProcess.running = true
    fastPoll.restart()
  }

  function connect(profile) {
    var name = profile || selectedProfile
    if (name === "") return
    // AWS VPN Client runs one tunnel at a time; switching means hand-over.
    if (activeProfile !== "" && activeProfile !== name) {
      _queuedConnect = name
      run("disconnect", activeProfile)
      return
    }
    if (activeProfile === name && connected) return
    run("connect", name)
  }

  // Also cancels a sign-in that is in progress or was abandoned halfway (e.g.
  // the browser tab was closed), so the user can start a fresh one.
  function disconnect() {
    if (disconnecting) return
    _queuedConnect = ""
    var name = pendingAction === "connect" ? pendingProfile : (activeProfile !== "" ? activeProfile : pendingProfile)
    if (name === "") return
    _cancellingSignIn = connecting
    if (actionProcess.running) {
      // `connect` is still blocked waiting on sign-in: stop it, then disconnect
      // once it has exited (see actionProcess.onExited).
      _disconnectAfterExit = name
      pendingAction = "disconnect"
      pendingProfile = name
      actionProcess.running = false
      return
    }
    run("disconnect", name)
  }

  function toggle() {
    if (disconnecting) return
    if (connecting || activeConnection) disconnect()
    else if (!busy) connect(selectedProfile)
  }

  // Called by polling while an action is pending: clear it once the CLI's
  // reported state matches what we asked for.
  function settlePending() {
    if (pendingAction === "" || actionProcess.running) return
    var status = statusFor(pendingProfile)
    // A stale "Failed" from an earlier attempt can linger for a beat, so only
    // believe failures once the new attempt has had a few seconds to start.
    var failed = /fail|error/i.test(status) && fastPoll.ticks >= 5
    var done = pendingAction === "connect" ? isConnected(status) || failed : isDisconnected(status)
    if (!done) return
    var finished = pendingAction
    var name = pendingProfile
    pendingAction = ""
    pendingProfile = ""
    if (finished === "connect") {
      if (isConnected(status)) {
        flash("Connected to " + name)
        Quickshell.execDetached(["notify-send", "-a", "AWS VPN", "-i", "network-vpn", "AWS VPN connected", name])
      } else {
        lastError = "Connection to " + name + " failed (" + status + ")"
      }
    } else {
      flash(_cancellingSignIn ? "Sign-in to " + name + " cancelled" : "Disconnected " + name)
      _cancellingSignIn = false
      if (_queuedConnect !== "") {
        var next = _queuedConnect
        _queuedConnect = ""
        connect(next)
      }
    }
  }

  onConnectionsChanged: {
    settlePending()
    if (connected) refreshDetails()
    else details = null
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Poll every second while a connect/disconnect is in flight (SAML logins can
  // take a while in the browser), giving up after two minutes.
  Timer {
    id: fastPoll
    property int ticks: 0
    interval: 1000
    repeat: true
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      ticks += 1
      root.refresh()
      if (root.pendingAction === "" || ticks >= 120) {
        if (root.pendingAction !== "") {
          root.lastError = root.pendingAction === "connect"
            ? "Sign-in to " + root.pendingProfile + " didn't finish. Disconnect to cancel it, then connect again."
            : "Timed out disconnecting " + root.pendingProfile
          root._cancellingSignIn = false
          root.pendingAction = ""
          root.pendingProfile = ""
          root._queuedConnect = ""
        }
        stop()
      }
    }
  }

  Timer {
    id: pollWatchdog
    interval: 8000
    repeat: false
    onTriggered: {
      if (profilesProcess.running) profilesProcess.running = false
      if (connectionsProcess.running) connectionsProcess.running = false
      if (detailsProcess.running) detailsProcess.running = false
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 2500
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: profilesProcess
    command: ["aws-vpn-client", "list-profiles"]
    stdout: StdioCollector { id: profilesStdout; waitForEnd: true }
    stderr: StdioCollector { id: profilesStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 127) { root.installed = false; return }
      root.installed = true
      if (exitCode !== 0) {
        root.lastError = String(profilesStderr.text || "Could not list profiles").trim()
        return
      }
      var raw = root.parseJson(profilesStdout.text, [])
      var list = []
      for (var i = 0; i < raw.length; i++) {
        list.push({
          name: String(raw[i]["profile-name"] || ""),
          authType: String(raw[i]["auth-type"] || ""),
          importedAt: String(raw[i]["imported-at"] || "")
        })
      }
      root.profiles = list
    }
  }

  Process {
    id: connectionsProcess
    command: ["aws-vpn-client", "list-connections"]
    stdout: StdioCollector { id: connectionsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 127) { root.installed = false; return }
      if (exitCode !== 0) return
      var raw = root.parseJson(connectionsStdout.text, [])
      var list = []
      for (var i = 0; i < raw.length; i++) {
        list.push({
          name: String(raw[i]["profile-name"] || ""),
          status: String(raw[i]["connection-status"] || ""),
          updatedAt: String(raw[i]["last-updated-at"] || "")
        })
      }
      root.connections = list
    }
  }

  Process {
    id: detailsProcess
    stdout: StdioCollector { id: detailsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var raw = root.parseJson(detailsStdout.text, null)
      var attempt = raw ? raw["latest-connection-attempt"] : null
      root.details = attempt ? (attempt.details || null) : null
    }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (root._disconnectAfterExit !== "") {
        var name = root._disconnectAfterExit
        root._disconnectAfterExit = ""
        Qt.callLater(function() { root.run("disconnect", name) })
        return
      }
      if (exitCode !== 0) {
        // Nothing to tear down after a cancelled sign-in is still a success.
        if (root._cancellingSignIn && root.pendingAction === "disconnect") {
          root.lastError = ""
          root.flash("Sign-in to " + root.pendingProfile + " cancelled")
          root._cancellingSignIn = false
          root.pendingAction = ""
          root.pendingProfile = ""
          root.refresh()
          return
        }
        var err = String(actionStderr.text || actionStdout.text || "").replace(/\s+/g, " ").trim()
        root.lastError = err !== "" ? err : (root.pendingAction + " failed (exit " + exitCode + ")")
        root.pendingAction = ""
        root.pendingProfile = ""
        root._queuedConnect = ""
        root.refresh()
        return
      }
      root.refresh()
    }
  }
}

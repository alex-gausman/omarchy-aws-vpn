import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget + popup for AWS Client VPN.
//
// Bar: left click opens the panel, right click connects/disconnects the
// selected profile, middle click refreshes.
// Panel: on/off switch in the header, a PROFILES list to pick (and connect to)
// a profile, and live tunnel stats while connected.
Panel {
  id: root
  moduleName: "alex.aws-vpn"
  ipcTarget: "alex.aws-vpn"
  manageIpc: false

  property string focusSection: "header"
  property int profileIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property string vpnGlyph: "󰖂"
  readonly property color barIconColor: vpn.connected ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property bool headerHasCursor: cursorActive && focusSection === "header" && vpn.installed
  readonly property string toggleHint: vpn.connecting ? "Cancel sign-in" : vpn.activeConnection ? "Disconnect " + vpn.activeProfile : (vpn.selectedProfile !== "" ? "Connect to " + vpn.selectedProfile : "No profile")

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Service {
    id: vpn
    settings: root.settings
    preferredProfile: String(root.setting("profile", ""))
  }

  // Remember the chosen profile inline on this widget's shell.json entry.
  function persistProfile(name) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.profile = name
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Clicking the connected (or signing-in) profile disconnects it, which also
  // abandons a stuck sign-in so it can be started again.
  function chooseProfile(profile) {
    if (!profile || vpn.disconnecting) return
    if (vpn.activeProfile === profile.name || vpn.pendingProfile === profile.name) {
      vpn.disconnect()
      return
    }
    if (vpn.busy) return
    if (profile.name !== vpn.preferredProfile) persistProfile(profile.name)
    vpn.preferredProfile = profile.name
    vpn.connect(profile.name)
  }

  function ensureCursor() {
    if (profileIndex >= vpn.profiles.length) profileIndex = Math.max(0, vpn.profiles.length - 1)
    if (focusSection === "profiles" && vpn.profiles.length === 0) focusSection = "header"
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy > 0) {
      if (focusSection === "header" && vpn.profiles.length > 0) { focusSection = "profiles"; profileIndex = 0 }
      else if (focusSection === "profiles" && profileIndex < vpn.profiles.length - 1) profileIndex++
    } else if (dy < 0) {
      if (focusSection === "profiles") {
        if (profileIndex <= 0) focusSection = "header"
        else profileIndex--
      }
    }
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") vpn.toggle()
    else if (focusSection === "profiles") chooseProfile(vpn.profiles[profileIndex])
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    vpn.refresh()
    vpn.refreshDetails()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { vpn.refresh(); return "ok" }
    function connect(profile: string): string { vpn.connect(profile); return "ok" }
    function disconnect(): string { vpn.disconnect(); return "ok" }
    function toggleVpn(): string { vpn.toggle(); return "ok" }
    function status(): string { return vpn.statusText }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: vpn.statusText
    iconComponent: Component {
      Item {
        Text {
          id: barGlyph
          anchors.centerIn: parent
          text: root.vpnGlyph
          color: vpn.lastError !== "" && !vpn.connected ? root.urgent : root.barIconColor
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont

          SequentialAnimation on opacity {
            running: vpn.transitioning
            loops: Animation.Infinite
            NumberAnimation { to: 0.35; duration: 500; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutQuad }
          }
          Binding on opacity { when: !vpn.transitioning; value: 1.0 }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) vpn.toggle()
      else if (buttonCode === Qt.MiddleButton) vpn.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "t" || t === "T") vpn.toggle()
        else if (t === "d" || t === "D") vpn.disconnect()
        else if (t === "r" || t === "R") vpn.refresh()
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

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.cursorActive = true; root.focusSection = "header" }

            PanelHero {
              id: hero
              width: parent.width
              title: vpn.activeProfile !== "" ? vpn.activeProfile : (vpn.selectedProfile !== "" ? vpn.selectedProfile : "AWS VPN")
              meta: vpn.activeConnection && vpn.pendingAction === "" ? vpn.statusLabel(vpn.activeStatus) : vpn.statusText
              detail: vpn.connected && vpn.activeConnection ? "Up " + vpn.formatSince(vpn.activeConnection.updatedAt) : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: vpn.connected ? 1.0 : 0.5
              iconComponent: Component {
                Text {
                  text: root.vpnGlyph
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: vpn.installed && vpn.profiles.length > 0
                  checked: vpn.activeConnection !== null || vpn.pendingAction === "connect"
                  // Only a disconnect swallows clicks; during sign-in the
                  // switch stays live so a stuck sign-in can be cancelled.
                  busy: vpn.disconnecting
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: vpn.toggle()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.toggleHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: vpn.connecting && vpn.lastError === ""
            width: parent.width
            text: "Finish signing in in your browser. If the sign-in was interrupted, turn the switch off to cancel it, then connect again."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: vpn.actionStatus !== "" || vpn.lastError !== ""
            width: parent.width
            text: vpn.lastError !== "" ? vpn.lastError : vpn.actionStatus
            color: vpn.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: !vpn.installed
            width: parent.width
            text: "aws-vpn-client is not installed or not on PATH."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          // Tunnel counters while connected.
          Column {
            visible: vpn.connected && vpn.details !== null
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "TRAFFIC"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              StatCell { label: "󰁅 In"; value: vpn.details ? vpn.formatBytes(vpn.details["tunnel-bytes-in"]) : "" }
              StatCell { label: "󰁝 Out"; value: vpn.details ? vpn.formatBytes(vpn.details["tunnel-bytes-out"]) : "" }
            }
          }

          PanelSeparator {
            visible: vpn.installed
            foreground: root.foreground
          }

          Column {
            visible: vpn.installed
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "PROFILES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: vpn.profiles.length === 0
              width: parent.width
              text: "No profiles. Import one with\naws-vpn-client import-profile"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: profileColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: vpn.profiles
                ProfileRow {
                  required property var modelData
                  required property int index
                  width: profileColumn.width
                  profile: modelData
                  rowIndex: index
                }
              }
            }
          }
        }
      }
    }
  }

  component StatCell: ColumnLayout {
    property string label: ""
    property string value: ""
    Layout.fillWidth: true
    spacing: Style.space(1)

    Text {
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  component ProfileRow: CursorSurface {
    id: profileRow
    property var profile: null
    property int rowIndex: 0
    readonly property string name: profile ? profile.name : ""
    readonly property string status: vpn.statusFor(name)
    readonly property bool isActive: vpn.activeProfile === name
    readonly property bool isPending: vpn.pendingProfile === name
    readonly property bool isSelected: vpn.selectedProfile === name

    hasCursor: root.cursorActive && root.focusSection === "profiles" && root.profileIndex === rowIndex
    current: isActive || isPending
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: profileInner.implicitHeight + Style.spacing.xl

    RowLayout {
      id: profileInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: profileRow.isActive ? "󰖂" : (profileRow.isSelected ? "󰄬" : " ")
        color: profileRow.isActive || profileRow.isPending ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        Layout.preferredWidth: Style.space(22)
        horizontalAlignment: Text.AlignHCenter

        SequentialAnimation on opacity {
          running: profileRow.isPending
          loops: Animation.Infinite
          NumberAnimation { to: 0.35; duration: 420; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: profileRow.name
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: profileRow.isActive
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: {
            var parts = []
            if (profileRow.isPending) parts.push(vpn.pendingAction === "connect" ? "Signing in…" : "Disconnecting…")
            else parts.push(vpn.statusLabel(profileRow.status))
            if (profileRow.profile && profileRow.profile.authType) parts.push(profileRow.profile.authType.toUpperCase())
            return parts.join(" · ")
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      id: profileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: vpn.disconnecting || (vpn.busy && !profileRow.isActive && !profileRow.isPending) ? Qt.ArrowCursor : Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.focusSection = "profiles"; root.profileIndex = profileRow.rowIndex }
      onClicked: root.chooseProfile(profileRow.profile)
    }

    PanelToolTip {
      visible: profileMouse.containsMouse
      text: vpn.connecting && (profileRow.isActive || profileRow.isPending) ? "Cancel sign-in" : (profileRow.isActive ? "Disconnect" : "Connect")
      fontFamily: root.fontFamily
    }
  }
}

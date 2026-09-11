import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "ksavona.display-profiles"
  ipcTarget: "ksavona.display-profiles"
  manageIpc: false
  readonly property string displayLayoutCommand: (Quickshell.env("HOME") || "") + "/.local/bin/omarchy-display-layout"

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the brightness + state methods below.
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property string internalMonitor: ""
  property string externalMonitor: ""
  property string focusedMonitor: ""
  property bool internalEnabled: false
  property bool mirrorEnabled: false
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0
  property var layoutDisplays: []
  property bool displayDetailsOpen: false
  property string expandedDisplay: ""
  property bool identifyOpen: false
  property string displayMode: "extend"
  property string draggingDisplay: ""
  property real dragPreviewX: 0
  property real dragPreviewY: 0

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Cursor model shared by keyboard and mouse. Sections:
  //   "brightness" - single slider row, selectedIndex = -1 sentinel
  //                  (mirrors Audio's slider rows). Only present if a
  //                  controllable backlight was detected.
  //   "scale"      - 6 Button scale presets; treated as a single
  //                  horizontal row from j/k's perspective. h/l moves
  //                  between presets, identical to bluetooth's header.
  //   "monitors"   - vertical display row list for enabling/disabling displays;
  //                  j/k walks each row.
  // Mouse hover on a target updates root state via the components' `hovered`
  // signal so keyboard cursor and pointer share one highlight.
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scaleValues: {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.availableScales(scalePresets, display.width, display.height)
    }
    return scalePresets
  }
  property string focusSection: "scale"
  property int selectedIndex: 0
  property bool cursorActive: false

  // Text size slider — curated macOS-style notches (px). The panel snaps to
  // these stops; the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section —
  // otherwise h/l on the text-size slider can jump focus to another row.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  readonly property var visibleSections: {
    var list = []
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    list.push("scale")
    if (displays.length > 1) list.push("monitors")
    return list
  }

  function sectionCount(section) {
    if (section === "brightness") return 0  // only the slider sentinel at -1
    if (section === "textsize") return 0    // slider sentinel at -1, like brightness
    if (section === "scale") return scaleValues.length
    if (section === "monitors") return displays.length
    return 0
  }

  function sectionIsSingleRow(section) {
    // brightness and text size are lone sliders; scale presets sit horizontally.
    return section === "brightness" || section === "textsize" || section === "scale"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize") return -1
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        // Coming up from below — land on the last navigable row of the prev
        // section, or its sentinel for single-row sections.
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  // h/l: in scale section, walks the preset row; everywhere else, no-op
  // because adjustBrightness handles horizontal motion on the brightness
  // slider.
  function moveCursorH(delta) {
    if (focusSection !== "scale") return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > scaleValues.length - 1) next = scaleValues.length - 1
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    setBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    if (focusSection === "scale" && selectedIndex >= 0 && selectedIndex < scaleValues.length) {
      setScale(scaleValues[selectedIndex])
      return
    }
    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {
      var d = displays[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
    }
    // brightness: no separate action; the slider value is the action.
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionIsSingleRow(focusSection)) {
      // brightness/text size use the -1 sentinel; scale clamps into the presets.
      if (focusSection === "brightness" || focusSection === "textsize") selectedIndex = -1
      else if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = 0
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height (lots of displays). Mirrors audio's
  // ensureCursorVisible helper.
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      scale: root.monitorScale,
      displays: root.displays
    })
  }

  IpcHandler {
    target: "ksavona.display-profiles"

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
    if (!layoutStateProc.running) layoutStateProc.running = true
  }

  function updateLayoutDisplays(json) {
    try {
      var next = JSON.parse(String(json || "[]"))
      if (Array.isArray(next)) root.layoutDisplays = next
    } catch (e) {}
  }

  function layoutDisplay(name) {
    for (var i = 0; i < layoutDisplays.length; i++)
      if (layoutDisplays[i].name === name) return layoutDisplays[i]
    return null
  }

  function identifyNumber(screenName) {
    for (var i = 0; i < layoutDisplays.length; i++)
      if (layoutDisplays[i].name === screenName) return i + 1
    return 0
  }

  function displayWidth(d) {
    return Number(d.transform) % 2 ? Number(d.height) / Number(d.scale) : Number(d.width) / Number(d.scale)
  }

  function displayHeight(d) {
    return Number(d.transform) % 2 ? Number(d.width) / Number(d.scale) : Number(d.height) / Number(d.scale)
  }

  function replaceLayoutDisplay(name, changes) {
    var next = []
    for (var i = 0; i < layoutDisplays.length; i++) {
      var d = layoutDisplays[i]
      if (d.name === name) {
        var replacement = {}
        for (var key in d) replacement[key] = d[key]
        for (var changed in changes) replacement[changed] = changes[changed]
        next.push(replacement)
      } else next.push(d)
    }
    layoutDisplays = next
  }

  function applyLayout() {
    if (!layoutDisplays.length || layoutProc.running) return
    layoutProc.command = [displayLayoutCommand, "apply", JSON.stringify(layoutDisplays)]
    layoutProc.running = true
  }

  function setDisplayScale(name, scale) {
    replaceLayoutDisplay(name, { scale: Number(scale) })
    applyLayout()
  }

  function setDisplayTransform(name, transform) {
    replaceLayoutDisplay(name, { transform: Number(transform) })
    applyLayout()
  }

  function setDisplayPosition(name, x, y) {
    // Hyprland accepts overlapping virtual outputs. Keep the exact position
    // the user chose; the canvas scales to show the entire arrangement.
    replaceLayoutDisplay(name, { x: Math.round(x), y: Math.round(y) })
    applyLayout()
  }

  function mirrorDisplay(target, source) {
    mirrorProc.command = [displayLayoutCommand, "mirror", target, source]
    if (!mirrorProc.running) mirrorProc.running = true
  }

  function useExtendMode() {
    displayMode = "extend"
    restoreExtendedLayout()
  }

  function restoreExtendedLayout() {
    if (layoutProc.running) return
    layoutProc.command = [displayLayoutCommand, "extend"]
    layoutProc.running = true
  }

  function duplicateMain() {
    var main = internalMonitor || (layoutDisplays.length ? layoutDisplays[0].name : "")
    if (!main || mirrorProc.running) return
    displayMode = "duplicate"
    mirrorProc.command = [displayLayoutCommand, "duplicate-main", main]
    mirrorProc.running = true
  }

  function setBrightness(value) {
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  function normalizeScale(scale) {
    return Model.normalizeScale(scale)
  }

  function activeScaleIndex() {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.matchingScaleIndex(scaleValues, monitorScale, display.width, display.height)
    }
    return -1
  }

  function effectiveScale(scale) {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.cleanScale(scale, display.width, display.height)
    }
    return normalizeScale(scale)
  }

  // Playful mood-name for a given brightness percent. Bands intentionally
  // span ~10–20 points so casual tweaks change the label, while small
  // nudges within one band don't.
  function brightnessName(percent) {
    return Model.brightnessName(percent)
  }

  function updateDisplays(displaysJson) {
    var parsed = Model.parseDisplays(displaysJson)
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  function toggleDisplay(name, enabled) {
    if (!name) return
    if (enabled && root.enabledDisplayCount <= 1) return

    actionProc.command = ["hyprctl", "keyword", "monitor", name + (enabled ? ",disable" : ",preferred,auto,auto")]
    if (!actionProc.running) actionProc.running = true
  }

  function setScale(scale) {
    actionProc.command = ["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale]
    if (!actionProc.running) actionProc.running = true
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  // KeyboardPanel primes focus at open-time, so SUPER-bound IPC summons land
  // with j/k ready to navigate. Keep a default landing point, but don't paint
  // the cursor until hover or the first navigation key.
  onOpenedChanged: {
    if (opened) {
      refresh()
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        focusSection = "scale"
        selectedIndex = 0
      }
      cursorActive = false
    }
  }

  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: clampCursor()
  onScaleValuesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()

  // Only poll while the panel is open; the bar glyph tracks monitor count via
  // Quickshell.screens, and open-time refresh + Component.onCompleted cover the
  // rest. External brightness changes are reflected whenever the panel is open.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== ""
        root.brightnessPercent = root.brightnessAvailable ? Math.max(0, Math.min(100, parseInt(brightness, 10))) : 0
        root.internalMonitor = String(lines[1] || "").trim()
        root.externalMonitor = String(lines[2] || "").trim()
        root.internalEnabled = String(lines[3] || "").trim() !== ""
        root.mirrorEnabled = String(lines[4] || "").trim() === root.externalMonitor && root.externalMonitor !== ""
        root.focusedMonitor = String(lines[5] || "").trim()
        root.monitorScale = root.normalizeScale(String(lines[6] || "").trim())
        root.updateDisplays(String(lines[7] || "[]").trim())
      }
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT call refresh() after a brightness set completes. The local
    // brightnessPercent we just wrote is authoritative; re-reading via
    // `omarchy-brightness-display` races the hardware/driver and can
    // return an empty string, which the parser then coerces to 0 —
    // visible as a "bounce to zero" after h/l keypresses. External
    // brightness changes are still picked up by the 5s periodic refresh,
    // the open-time refresh, and Component.onCompleted.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  Process {
    id: layoutStateProc
    command: [root.displayLayoutCommand, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateLayoutDisplays(text)
    }
  }

  Process {
    id: layoutProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  Process {
    id: mirrorProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  Timer {
    id: identifyTimer
    interval: 3000
    repeat: false
    onTriggered: root.identifyOpen = false
  }

  // One click-through overlay per output. The number is deliberately large so
  // it remains readable from the other side of a room when identifying cables.
  Variants {
    model: Quickshell.screens
    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.identifyOpen
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "kris-monitor-identify"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region {}
      Rectangle {
        width: Style.space(116)
        height: width
        radius: width / 2
        color: Util.alpha(Color.background, 0.94)
        border.color: Color.accent
        border.width: Style.space(2)
        anchors.centerIn: parent
        Text {
          anchors.centerIn: parent
          text: String(root.identifyNumber(modelData.name))
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.displayLarge * 2
          font.bold: true
        }
      }
    }
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
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
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else if (root.focusSection === "scale") root.moveCursorH(dx)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Display"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                textFormat: Text.PlainText
                text: {
                  if (root.brightnessAvailable) {
                    return root.brightnessName(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent).toUpperCase()
                  }
                  return "FIXED BRIGHTNESS"
                }
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Brightness ----------
          PanelSeparator {
            visible: root.brightnessAvailable
            foreground: root.bar.foreground
          }

          Column {
            visible: root.brightnessAvailable
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

              PanelSectionHeader {
                id: brightnessHeader
                text: "BRIGHTNESS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: brightnessPercent
                textFormat: Text.PlainText
                text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: brightnessSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 1
                maximum: 100
                step: 1
                value: root.brightnessPercent
                integer: true
                onMoved: function(v) { root.previewBrightness(v) }
                onReleased: function(v) {
                  brightnessDebounce.stop()
                  root.setBrightness(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "brightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Text size ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

              PanelSectionHeader {
                id: textSizeHeader
                text: "TEXT SIZE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: textSizePx
                textFormat: Text.PlainText
                text: (textSizeSlider.dragging
                       ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                       : root.displayedTextPx()) + "px"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: textSizeRow
              width: parent.width
              height: textSizeSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: textSizeSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.textSizeStops.length - 1
                step: 1
                integer: true
                tickCount: root.textSizeStops.length
                value: root.currentTextIndex()
                onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "textsize"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Scale ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(scaleHeader.implicitHeight, scaleMonitor.implicitHeight)

              PanelSectionHeader {
                id: scaleHeader
                text: "SCALE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Name the monitor SCALE targets, since it only applies to the
              // focused one.
              Text {
                id: scaleMonitor
                textFormat: Text.PlainText
                text: root.focusedMonitor
                // Only worth naming when more than one display is in play.
                visible: root.focusedMonitor !== "" && root.enabledDisplayCount > 1
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Grid {
              id: scaleRow
              width: parent.width
              columns: root.scaleValues.length
              spacing: Style.spacing.xs

              readonly property real cellWidth: root.scaleValues.length > 0
                ? (width - spacing * (columns - 1)) / columns
                : 0

              Repeater {
                model: root.scaleValues

                ScalePill {
                  required property string modelData
                  required property int index

                  scaleValue: modelData
                  scaleIndex: index
                  width: scaleRow.cellWidth
                }
              }
            }
          }

          // ---------- Monitors ----------
          PanelSeparator {
            visible: root.displays.length > 1
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.displays.length > 1

            PanelSectionHeader {
              text: "DISPLAYS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.displays

              MonitorRow {
                required property var modelData
                required property int index

                width: panelColumn.width
                display: modelData
                rowIndex: index
              }
            }
          }

          // ---------- Display arrangement and per-output controls ----------
          PanelSeparator {
            visible: root.layoutDisplays.length > 1
            foreground: root.bar.foreground
          }

          Column {
            visible: root.layoutDisplays.length > 1
            width: parent.width
            spacing: Style.space(10)

            Button {
              width: parent.width
              text: (root.displayDetailsOpen ? "▾" : "▸") + "  ARRANGEMENT & INDIVIDUAL SETTINGS"
              fontSize: Style.font.caption
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.displayDetailsOpen = !root.displayDetailsOpen
            }

            Column {
              visible: root.displayDetailsOpen
              width: parent.width
              spacing: Style.space(10)

              Row {
                spacing: Style.spacing.xs
                Button {
                  text: "IDENTIFY"
                  fontSize: Style.font.caption; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily; bordered: true
                  onClicked: { root.identifyOpen = true; identifyTimer.restart() }
                }
                Button {
                  text: "EXTEND"
                  active: root.displayMode === "extend"
                  fontSize: Style.font.caption; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily; bordered: true
                  onClicked: root.useExtendMode()
                }
                Button {
                  text: "DUPLICATE"
                  active: root.displayMode === "duplicate"
                  fontSize: Style.font.caption; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily; bordered: true
                  onClicked: root.duplicateMain()
                }
              }

              Text {
                width: parent.width
                text: root.displayMode === "duplicate"
                  ? "Duplicate mirrors the main display exactly. Choose Extend to restore the saved independent layout."
                  : "Drag a display to place it. On release it snaps to the nearest display edge without overlap."
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              DisplayCanvas { width: parent.width }

              Repeater {
                model: root.layoutDisplays
                DisplaySettings {
                  required property var modelData
                  width: parent.width
                  display: modelData
                }
              }

              Text {
                width: parent.width
                text: "Text size remains system-wide: Wayland/GTK applications do not expose a safe per-monitor text-size setting. Use each display’s Scale above for per-monitor readability."
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  component DisplayCanvas: Item {
    id: canvas
    implicitHeight: Style.space(170)
    clip: true

    function logicalWidth(d) {
      return Number(d.transform) % 2 ? Number(d.height) / Number(d.scale) : Number(d.width) / Number(d.scale)
    }
    function logicalHeight(d) {
      return Number(d.transform) % 2 ? Number(d.width) / Number(d.scale) : Number(d.height) / Number(d.scale)
    }
    function displayX(d) {
      return d.name === root.draggingDisplay ? root.dragPreviewX : Number(d.x)
    }
    function displayY(d) {
      return d.name === root.draggingDisplay ? root.dragPreviewY : Number(d.y)
    }
    function minX() {
      var n = Infinity
      for (var i = 0; i < root.layoutDisplays.length; i++) n = Math.min(n, displayX(root.layoutDisplays[i]))
      return isFinite(n) ? n : 0
    }
    function minY() {
      var n = Infinity
      for (var i = 0; i < root.layoutDisplays.length; i++) n = Math.min(n, displayY(root.layoutDisplays[i]))
      return isFinite(n) ? n : 0
    }
    function totalWidth() {
      var right = -Infinity
      var left = minX()
      for (var i = 0; i < root.layoutDisplays.length; i++) {
        var d = root.layoutDisplays[i]
        right = Math.max(right, displayX(d) + logicalWidth(d))
      }
      return isFinite(right) ? Math.max(1, right - left) : 1
    }
    function totalHeight() {
      var bottom = -Infinity
      var top = minY()
      for (var i = 0; i < root.layoutDisplays.length; i++) {
        var d = root.layoutDisplays[i]
        bottom = Math.max(bottom, displayY(d) + logicalHeight(d))
      }
      return isFinite(bottom) ? Math.max(1, bottom - top) : 1
    }
    readonly property real factor: Math.max(0.01, Math.min((width - Style.space(24)) / totalWidth(),
                                                            (height - Style.space(24)) / totalHeight()))

    Rectangle {
      anchors.fill: parent
      color: Util.alpha(root.bar.foreground, 0.05)
      border.color: Util.alpha(Color.accent, 0.5)
      border.width: 1
    }

    Repeater {
      model: root.layoutDisplays
      delegate: Rectangle {
        id: tile
        required property var modelData
        readonly property var display: modelData
        property real startX: 0
        property real startY: 0
        x: Style.space(12) + (canvas.displayX(display) - canvas.minX()) * canvas.factor
        y: Style.space(12) + (canvas.displayY(display) - canvas.minY()) * canvas.factor
        // Do not impose a minimum tile size: a distant monitor must make the
        // whole model shrink rather than overflow or get clipped.
        width: canvas.logicalWidth(display) * canvas.factor
        height: canvas.logicalHeight(display) * canvas.factor
        color: display.focused ? Util.alpha(Color.accent, 0.35) : Util.alpha(root.bar.foreground, 0.13)
        border.color: display.focused ? Color.accent : Util.alpha(root.bar.foreground, 0.7)
        border.width: Style.space(1)
        opacity: display.enabled ? 1 : 0.35

        Column {
          anchors.centerIn: parent
          width: parent.width - Style.space(8)
          Text {
            width: parent.width; horizontalAlignment: Text.AlignHCenter
            text: String(root.identifyNumber(tile.display.name))
            color: root.bar.foreground; font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title; font.bold: true
          }
          Text {
            width: parent.width; horizontalAlignment: Text.AlignHCenter
            text: tile.display.name
            color: root.bar.foreground; font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption; elide: Text.ElideRight
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.SizeAllCursor
          property real pointerStartX: 0
          property real pointerStartY: 0
          property real layoutStartX: 0
          property real layoutStartY: 0
          onPressed: function(mouse) {
            pointerStartX = mouse.x
            pointerStartY = mouse.y
            layoutStartX = canvas.displayX(tile.display)
            layoutStartY = canvas.displayY(tile.display)
            root.draggingDisplay = tile.display.name
            root.dragPreviewX = layoutStartX
            root.dragPreviewY = layoutStartY
          }
          onPositionChanged: function(mouse) {
            if (!pressed) return
            root.dragPreviewX = layoutStartX + (mouse.x - pointerStartX) / canvas.factor
            root.dragPreviewY = layoutStartY + (mouse.y - pointerStartY) / canvas.factor
          }
          onReleased: {
            root.setDisplayPosition(tile.display.name, root.dragPreviewX, root.dragPreviewY)
            root.draggingDisplay = ""
          }
        }
      }
    }
  }

  component DisplaySettings: Column {
    id: settings
    required property var display
    width: parent ? parent.width : 0
    spacing: Style.space(8)

    Button {
      width: parent.width
      text: (root.expandedDisplay === settings.display.name ? "▾  " : "▸  ") + settings.display.name
      fontSize: Style.font.caption; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily; bordered: true
      onClicked: root.expandedDisplay = root.expandedDisplay === settings.display.name ? "" : settings.display.name
    }

    Column {
      visible: root.expandedDisplay === settings.display.name
      width: parent.width
      spacing: Style.space(8)

      Text { text: "SCALE"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
      Row {
        spacing: Style.spacing.xs
        Repeater {
          model: ["1", "1.25", "1.6", "2", "3", "4"]
          Button {
            required property string modelData
            text: modelData + "x"
            active: Number(settings.display.scale) === Number(modelData)
            fontSize: Style.font.caption; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily; bordered: true
            onClicked: root.setDisplayScale(settings.display.name, modelData)
          }
        }
      }

      Text { text: "ROTATION & FLIP"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
      Grid {
        columns: 3; spacing: Style.spacing.xs
        Repeater {
          model: [
            { label: "LANDSCAPE", value: 0 }, { label: "90°", value: 1 }, { label: "180°", value: 2 },
            { label: "270°", value: 3 }, { label: "FLIP H", value: 4 }, { label: "FLIP V", value: 6 }
          ]
          Button {
            required property var modelData
            text: modelData.label
            active: Number(settings.display.transform) === Number(modelData.value)
            fontSize: Style.font.caption; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily; bordered: true
            onClicked: root.setDisplayTransform(settings.display.name, modelData.value)
          }
        }
      }

    }
  }

  component ScalePill: Button {
    id: pill
    required property string scaleValue
    required property int scaleIndex

    text: root.effectiveScale(scaleValue) + "x"
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.activeScaleIndex() === scaleIndex
    hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === scaleIndex

    onClicked: root.setScale(scaleValue)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "scale"
      root.selectedIndex = pill.scaleIndex
    }
  }

  component MonitorRow: CursorSurface {
    id: monitorRow
    required property var display
    required property int rowIndex

    readonly property bool isFocused: display && display.focused
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)

    hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
    current: isFocused
    foreground: root.bar.foreground
    fill: Style.hoverFillFor(root.bar.foreground, Color.accent)
    currentFill: Style.selectedFillFor(root.bar.foreground, Color.accent)
    implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
    opacity: canToggle ? 1.0 : 0.45

    Row {
      id: monitorInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: "󰍹"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.name + (monitorRow.display.focused ? " · focused" : "")
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.enabled ? "󰄬" : ""
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: monitorRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
        root.cursorActive = true
        root.focusSection = "monitors"
        root.selectedIndex = monitorRow.rowIndex
      }
      onClicked: if (monitorRow.canToggle) root.toggleDisplay(monitorRow.display.name, monitorRow.display.enabled)
    }
  }
}

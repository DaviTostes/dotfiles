import Quickshell
import QtQuick
import "../hyprconf"

// Tooltip rendered as a layer-shell popup so it is never clipped
// by the bar surface (plain QML Popups are cut off at the panel edge).
PopupWindow {
  id: tip

  property Item target
  property string text: ""
  property string subtitle: ""
  property bool rich: false
  property bool shown: false
  property Component content: null
  // place the body to the LEFT of the target, vertically centered (the right
  // bar's fan pills: a tooltip below one pill would cover the next one and
  // swallow the clicks meant for it)
  property bool leftOfTarget: false

  // tooltips flip above their target when there is not enough space below it
  // (pills near the bottom of the vertical side bar)
  readonly property bool above: {
    if (!tip.target || !tip.target.QsWindow || !tip.target.QsWindow.window) return false;
    const win = tip.target.QsWindow.window;
    const sh = win.screen ? win.screen.height : 1080;
    const p = tip.target.mapToItem(null, 0, 0);
    return (p.y + tip.target.height + 8 + tip.implicitHeight) > (sh - 4);
  }

  // body reports its measured size here (ids are not always resolvable
  // from window-level bindings during hot reload)
  property int contentW: 64
  property int contentH: 0

  // ----- window lifetime -------------------------------------------------
  // quickshell tears a layer/popup window down as soon as it stops being
  // visible and rebuilds it — Wayland surface, GL context, glyph atlas and
  // all — on the next show (ProxyWindowBase::deleteOnInvisible, and both
  // WlrLayershell and ProxyPopupWindow override it to true). A tip that
  // mapped straight off `mouse.containsMouse` therefore paid that whole cost
  // every time the pointer crossed a pill, which is by far the most frequent
  // window churn in the shell.
  //
  // `showDelay` makes the window wait for a short dwell first, so sweeping
  // the pointer across the bar creates nothing and only a deliberate hover
  // pops the tip. The close fade still lingers (`hideTimer`) — but only when
  // a window actually exists, which is why visibility is driven by the
  // explicit `windowUp` flag instead of a binding.
  property int showDelay: 260
  property bool dwelled: showDelay <= 0
  /// true while the window should exist (`active` plus the close fade)
  property bool windowUp: false
  readonly property bool active: tip.shown && tip.target != null

  visible: tip.windowUp
  Timer { id: hideTimer; interval: 170; onTriggered: tip.windowUp = false }
  Timer { id: showTimer; interval: tip.showDelay; onTriggered: tip.dwelled = true }

  // the one place that decides whether the window exists
  function syncWindow() {
    if (!tip.active) {
      showTimer.stop();
      if (tip.showDelay > 0) tip.dwelled = false;
      if (tip.windowUp) hideTimer.restart();
      return;
    }
    if (tip.dwelled) {
      hideTimer.stop();
      tip.windowUp = true;
    } else {
      // still waiting out the dwell: never create a window for a pointer
      // that is only passing through. If one is already up (its close fade
      // is running) hold it instead of tearing it down to rebuild it a
      // moment later — the tip just fades back in.
      if (tip.windowUp) hideTimer.stop();
      showTimer.restart();
    }
  }

  onActiveChanged: tip.syncWindow()
  onDwelledChanged: tip.syncWindow()

  color: "transparent"

  implicitWidth: contentW + 24
  implicitHeight: contentH + 16
  // the anchor is only computed when the popup is first shown; re-run it on
  // every show and on size changes, or the popup drifts out of place when
  // the bar layout (or the popup content) changes while it is hidden
  onVisibleChanged: if (visible) anchor.updateAnchor()
  onImplicitWidthChanged: if (visible) anchor.updateAnchor()
  onImplicitHeightChanged: if (visible) anchor.updateAnchor()

  anchor {
    window: tip.target ? tip.target.QsWindow.window : null
    edges: tip.above ? Edges.Bottom : Edges.Top
    gravity: tip.above ? Edges.Top : Edges.Bottom
  }

  anchor.onAnchoring: {
    // the anchor rect must match the target's box: without horizontal
    // edges/gravity the popup is centered on the rect, so a 1px rect would
    // center the popup on the pill's left edge instead of its middle.
    const p = tip.target.mapToItem(null, 0, 0);
    const win = tip.target.QsWindow.window;
    const ww = win && win.width > 0 ? win.width : 1920;
    const sh = win && win.screen ? win.screen.height : 1080;
    // Pills in the narrow vertical side bar sit on the right edge: place their
    // tips to the LEFT (vertically centered, clamped to the bar's window
    // height) so a tip can never cover the bar or run off the screen. The
    // intelligence fan asks for this explicitly; the other side-bar pills get
    // it automatically here.
    const sideBar = win && win.width > 0 && win.width <= 64;
    if (tip.leftOfTarget || sideBar) {
      const wh = win && win.height > 0 ? win.height : 1040;
      anchor.rect.x = p.x - tip.implicitWidth - 14;
      anchor.rect.y = Math.max(8, Math.min(
          p.y + tip.target.height / 2 - tip.implicitHeight / 2,
          wh - tip.implicitHeight - 8));
      anchor.rect.width = tip.implicitWidth;
      anchor.rect.height = 1;
      return;
    }
    if ((p.x + tip.target.width / 2) > ww / 2) {
      // right-hand edge of the top bar: right-align the tip with the pill so
      // it stays on screen
      anchor.rect.x = p.x + tip.target.width - tip.implicitWidth;
      anchor.rect.width = tip.implicitWidth;
    } else {
      anchor.rect.x = p.x;
      anchor.rect.width = tip.target.width;
    }
    anchor.rect.height = 1;
    // flip above the target when it sits too low for the tip to fit below
    anchor.rect.y = tip.above ? p.y - 7 : p.y + tip.target.height + 6;
  }

  // the frame and the body share one wrapper so the fade + slide animates
  // the whole popup: animating only the Rectangle left the content (the
  // clock's calendar) opaque and stationary while the frame faded out
  Item {
    id: fade
    anchors.fill: parent
    opacity: tip.shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
    transform: Translate {
      y: tip.shown ? 0 : -5
      Behavior on y { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
    }

    Rectangle {
      anchors.fill: parent
      color: Theme.bg
      radius: 6
      border.color: Theme.border
      border.width: 1
    }

    Item {
      id: body
      anchors.centerIn: parent
      implicitWidth: tip.content
          ? (loader.item ? loader.item.implicitWidth : 0)
          : (tip.rich ? richLabel.implicitWidth : col.implicitWidth)
      implicitHeight: tip.content
          ? (loader.item ? loader.item.implicitHeight : 0)
          : (tip.rich ? richLabel.implicitHeight : col.implicitHeight)
      onImplicitWidthChanged: tip.contentW = Math.max(64, implicitWidth)
      onImplicitHeightChanged: tip.contentH = implicitHeight
      Component.onCompleted: {
        tip.contentW = Math.max(64, implicitWidth);
        tip.contentH = implicitHeight;
      }

      // instantiate the content component only while the tip is on screen:
      // otherwise a heavy tip body (the clock's calendar + notification list)
      // is built at shell start even though it is never shown
      Loader {
        id: loader
        anchors.centerIn: parent
        active: tip.content != null && tip.visible
        sourceComponent: tip.content
      }

      Text {
        id: richLabel
        anchors.centerIn: parent
        visible: tip.content == null && tip.rich
        textFormat: Text.RichText
        text: tip.text
        font.family: Theme.font
        font.pixelSize: 12
        color: Theme.text
      }

      Column {
        id: col
        anchors.centerIn: parent
        visible: tip.content == null && !tip.rich
        spacing: 2

        Text {
          text: tip.text
          font.family: Theme.font
          font.bold: true
          font.pixelSize: 12
          color: Theme.text
        }

        Text {
          visible: tip.subtitle !== ""
          text: tip.subtitle
          font.family: Theme.font
          font.pixelSize: 11
          color: Theme.muted
        }
      }
    }
  }
}

import Quickshell
import QtQuick

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

  // body reports its measured size here (ids are not always resolvable
  // from window-level bindings during hot reload)
  property int contentW: 64
  property int contentH: 0

  visible: shown && target != null
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
    edges: Edges.Top
    gravity: Edges.Bottom
  }

  anchor.onAnchoring: {
    // The anchor rect must match the target's box: without horizontal
    // edges/gravity the popup is centered on the rect, so a 1px rect would
    // center the popup on the pill's left edge instead of its middle.
    const p = tip.target.mapToItem(null, 0, 0);
    anchor.rect.x = p.x;
    anchor.rect.y = p.y + tip.target.height + 6;
    anchor.rect.width = tip.target.width;
    anchor.rect.height = 1;
  }

  Rectangle {
    anchors.fill: parent
    color: "#222"
    radius: 6
    border.color: "#3a3a3a"
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

    Loader {
      id: loader
      anchors.centerIn: parent
      active: tip.content != null
      sourceComponent: tip.content
    }

    Text {
      id: richLabel
      anchors.centerIn: parent
      visible: tip.content == null && tip.rich
      textFormat: Text.RichText
      text: tip.text
      font.family: "Agave Nerd Font"
      font.pixelSize: 12
      color: "#dcdfe1"
    }

    Column {
      id: col
      anchors.centerIn: parent
      visible: tip.content == null && !tip.rich
      spacing: 2

      Text {
        text: tip.text
        font.family: "Agave Nerd Font"
        font.bold: true
        font.pixelSize: 12
        color: "#ffffff"
      }

      Text {
        visible: tip.subtitle !== ""
        text: tip.subtitle
        font.family: "Agave Nerd Font"
        font.pixelSize: 11
        color: "#8a8a8a"
      }
    }
  }
}

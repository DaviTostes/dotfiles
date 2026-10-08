import Quickshell
import QtQuick
import QtQuick.Shapes
import "../hyprconf"

// Concave (inverted) corner tile drawn where two bar edges meet, in the bar
// color, so the four edges read as one closed frame.
// `corner`: 0 = top-left, 1 = top-right, 2 = bottom-right, 3 = bottom-left.
PanelWindow {
  id: root

  required property var screen
  required property int corner
  property real radius: 8
  // distance of the inner corner from the screen edges (bar thickness),
  // horizontal and vertical may differ (thin side/bottom edges)
  property real edgeX: 28
  property real edgeY: 28

  anchors.top: root.corner <= 1
  anchors.bottom: root.corner >= 2
  anchors.left: root.corner === 0 || root.corner === 3
  anchors.right: root.corner === 1 || root.corner === 2

  margins.top: root.corner <= 1 ? root.edgeY : 0
  margins.bottom: root.corner >= 2 ? root.edgeY : 0
  margins.left: (root.corner === 0 || root.corner === 3) ? root.edgeX : 0
  margins.right: (root.corner === 1 || root.corner === 2) ? root.edgeX : 0

  implicitWidth: root.radius
  implicitHeight: root.radius
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer

    // base fill sits in the top-left of the square; rotating picks the corner
    transform: Rotation {
      angle: root.corner * 90
      origin.x: root.radius / 2
      origin.y: root.radius / 2
    }

    ShapePath {
      strokeWidth: 0
      fillColor: Theme.bg
      startX: 0
      startY: root.radius

      PathArc {
        x: root.radius
        y: 0
        radiusX: root.radius
        radiusY: root.radius
        direction: PathArc.Clockwise
      }

      PathLine { x: 0; y: 0 }
      PathLine { x: 0; y: root.radius }
    }
  }
}

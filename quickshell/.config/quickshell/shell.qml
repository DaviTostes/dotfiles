//@ pragma UseQApplication
import Quickshell
import QtQuick
import "bar"

Scope {
  Variants {
    model: Quickshell.screens;

    delegate: Component {
      Bar {
        required property var modelData
        screen: modelData
      }
    }
  }
}

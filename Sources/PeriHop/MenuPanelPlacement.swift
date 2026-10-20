import Foundation

/// A screen rectangle in points. The menu bar panel uses this so its top stays under the status item.
struct PanelRect: Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var midX: Double { x + width / 2 }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
}

/// Keeps the menu panel under the status item when its content changes size.
enum MenuPanelPlacement {
    /// How far the panel's top may sit from the status item before it counts as detached.
    static let attachSlack = 24.0

    static func isAttached(panel: PanelRect, button: PanelRect) -> Bool {
        guard panel.width > 1, panel.height > 1, button.width > 1, button.height > 1 else { return false }
        let underTheIcon = panel.x < button.maxX && panel.maxX > button.x
        return abs(panel.maxY - button.y) < attachSlack && underTheIcon
    }

    /// Places the panel so its top edge meets the status item, centered on it, and inside the visible screen.
    static func frame(panelWidth: Double, panelHeight: Double, button: PanelRect, visible: PanelRect, margin: Double = 4) -> PanelRect {
        var x = button.midX - panelWidth / 2
        let y = button.y - panelHeight
        if x + panelWidth > visible.maxX - margin {
            x = visible.maxX - panelWidth - margin
        }
        if x < visible.x + margin {
            x = visible.x + margin
        }
        return PanelRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }
}

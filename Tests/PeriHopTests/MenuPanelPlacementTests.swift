import Testing
@testable import PeriHop

@Suite struct MenuPanelPlacementTests {
    private let button = PanelRect(x: 900, y: 850, width: 28, height: 24)
    private let visible = PanelRect(x: 0, y: 0, width: 1440, height: 850)

    @Test func aPanelUnderTheStatusItemCountsAsAttached() {
        let panel = PanelRect(x: 764, y: 620, width: 300, height: 230)
        #expect(MenuPanelPlacement.isAttached(panel: panel, button: button))
    }

    @Test func aPanelInTheMiddleOfTheScreenIsDetached() {
        let panel = PanelRect(x: 570, y: 310, width: 300, height: 230)
        #expect(!MenuPanelPlacement.isAttached(panel: panel, button: button))
    }

    @Test func placementKeepsTheTopAgainstTheStatusItem() {
        let placed = MenuPanelPlacement.frame(panelWidth: 300, panelHeight: 280, button: button, visible: visible)
        #expect(placed.y == button.y - 280)
        #expect(placed.midX == button.midX)
        #expect(MenuPanelPlacement.isAttached(panel: placed, button: button))
    }

    @Test func placementStaysOnScreenWhenTheIconIsAtTheEdge() {
        let edge = PanelRect(x: 1410, y: 850, width: 28, height: 24)
        let placed = MenuPanelPlacement.frame(panelWidth: 300, panelHeight: 200, button: edge, visible: visible)
        #expect(placed.maxX <= visible.maxX - 4)
        #expect(placed.y == edge.y - 200)
        #expect(MenuPanelPlacement.isAttached(panel: placed, button: edge))
    }
}

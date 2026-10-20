import Testing
import Foundation
@testable import PeriHop

struct DockDisplayTests {
    @Test func listsExternalNamesAndSkipsTheBuiltInPanel() {
        let listed = DockDisplay.listed(from: [
            (id: "builtin", builtin: true, name: "Built-in Retina Display"),
            (id: "dell", builtin: false, name: "DELL 27'"),
            (id: "", builtin: false, name: "Nameless"),
            (id: "blank", builtin: false, name: "  "),
        ])

        #expect(listed.map(\.id) == ["dell", "blank"])
        #expect(listed.map(\.name) == ["DELL 27'", "Display"])
    }
}

struct DiagnosticWindowTests {
    @Test func clearMovesTheWindowForwardInsideSixHours() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let uncleared = DiagnosticReport.windowStart(now: now, clearedAt: nil)
        #expect(uncleared == now.addingTimeInterval(-6 * 60 * 60))

        let recent = now.addingTimeInterval(-60 * 60)
        #expect(DiagnosticReport.windowStart(now: now, clearedAt: recent) == recent)

        let old = now.addingTimeInterval(-10 * 60 * 60)
        #expect(DiagnosticReport.windowStart(now: now, clearedAt: old) == uncleared)
    }
}

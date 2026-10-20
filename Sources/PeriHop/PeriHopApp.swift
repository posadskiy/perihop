import AppKit
import SwiftUI

@main
struct PeriHopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI's menu bar window draws no icon and turns transparent when its content
        // changes size. The status item in StatusMenu owns the panel and keeps it under the icon.
        MenuBarExtra("PeriHop", isInserted: .constant(false)) {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        StatusMenu.shared.start(model: model)
    }
}

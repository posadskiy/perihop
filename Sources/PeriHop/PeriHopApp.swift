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

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            model.open(url)
        }
    }

    /// At shutdown the devices are freed first, as they are before sleep, so
    /// they are not left paired to a Mac that is off.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.poweringOff else { return .terminateNow }
        Task { @MainActor in
            await model.prepareForPowerOff()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

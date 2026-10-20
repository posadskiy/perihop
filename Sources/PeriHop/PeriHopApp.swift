import SwiftUI

@main
struct PeriHopApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

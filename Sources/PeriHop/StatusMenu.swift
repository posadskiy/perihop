import AppKit
import Combine
import SwiftUI

/// The menu bar icon and the panel under it. SwiftUI's menu bar window draws no icon on this
/// macOS, and it loses its background and recenters when Settings changes the content size.
@MainActor
final class StatusMenu: NSObject {
    static let shared = StatusMenu()

    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private var panel: StatusMenuPanel?
    private var host: MenuHostingView?
    private var iconCancellable: AnyCancellable?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var closedAt = 0.0
    private var placing = false

    func start(model: AppModel) {
        guard statusItem == nil else { return }
        self.model = model
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.setAccessibilityLabel("PeriHop")
        statusItem = item
        updateIcon()
        iconCancellable = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { _ in
                StatusMenu.shared.updateIcon()
            }
    }

    func updateIcon() {
        let symbol = model?.menuSymbol ?? "keyboard"
        let configured = NSImage(systemSymbolName: symbol, accessibilityDescription: "PeriHop")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        configured?.isTemplate = true
        statusItem?.button?.image = configured
        statusItem?.button?.setAccessibilityLabel("PeriHop")
    }

    func relayoutSoon() {
        relayout()
        Task { @MainActor in
            relayout()
            try? await Task.sleep(nanoseconds: 50_000_000)
            relayout()
        }
    }

    /// Opens the panel, for `perihop://show`.
    func open() {
        guard panel?.isVisible != true else { return }
        show()
    }

    #if DEBUG
    /// Draws the open panel into a PNG, so a change to the menu can be
    /// looked at without a screen recording permission.
    func snapshot(to url: URL) {
        open()
        relayout()
        guard let host else { return }
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        // The panel's material is not part of the view, so stand in for it.
        let dark = host.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: dark ? 0.16 : 0.94, alpha: 1).setFill()
        host.bounds.fill()
        NSGraphicsContext.restoreGraphicsState()
        host.displayIgnoringOpacity(host.bounds, in: context)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif

    @objc private func toggle() {
        if ProcessInfo.processInfo.systemUptime - closedAt < 0.25 { return }
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    private func show() {
        let panel = buildPanel()
        relayout()
        model?.menuVisible = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem?.button?.highlight(true)
        Task { await model?.refresh() }
        installMonitors()
        relayoutSoon()
    }

    private func close() {
        guard panel?.isVisible == true else { return }
        closedAt = ProcessInfo.processInfo.systemUptime
        panel?.orderOut(nil)
        model?.menuVisible = false
        statusItem?.button?.highlight(false)
        removeMonitors()
    }

    private func buildPanel() -> StatusMenuPanel {
        if let panel { return panel }
        let host = MenuHostingView(rootView: MenuRoot(model: model!))
        host.sizingOptions = [.intrinsicContentSize]
        let panel = StatusMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // The material and corner radius of a system menu. The hosting view
        // sits inside it and still decides the size.
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 14
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            host.topAnchor.constraint(equalTo: backdrop.topAnchor),
            host.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        panel.contentView = backdrop
        self.host = host
        self.panel = panel
        return panel
    }

    fileprivate func relayout() {
        guard let panel, let host, !placing else { return }
        let intrinsic = host.intrinsicContentSize
        let fitted = host.fittingSize
        let size = intrinsic.width > 40 && intrinsic.height > 20 ? intrinsic : fitted
        guard size.width > 40, size.height > 20 else { return }
        let frame = frameUnderStatusItem(size: size, near: panel)
        guard !sameFrame(panel.frame, frame) else { return }
        placing = true
        panel.setFrame(frame, display: true, animate: false)
        placing = false
    }

    private func sameFrame(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5
            && abs(lhs.origin.y - rhs.origin.y) < 0.5
            && abs(lhs.width - rhs.width) < 0.5
            && abs(lhs.height - rhs.height) < 0.5
    }

    private func frameUnderStatusItem(size: NSSize, near panel: NSWindow) -> NSRect {
        let button = statusButtonFrame() ?? fallbackButtonFrame(near: panel)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: button.midX, y: button.midY)) } ?? panel.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let placed = MenuPanelPlacement.frame(
            panelWidth: size.width,
            panelHeight: size.height,
            button: PanelRect(button),
            visible: PanelRect(visible)
        )
        return NSRect(placed)
    }

    private func statusButtonFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let rect = window.convertToScreen(button.bounds)
        guard rect.width > 1, rect.height > 1 else { return nil }
        return rect
    }

    /// Keeps the panel under the menu bar even when the status item's window is not available.
    private func fallbackButtonFrame(near panel: NSWindow) -> NSRect {
        let screen = panel.screen ?? NSScreen.main
        let top = screen?.visibleFrame.maxY ?? panel.frame.maxY
        let x = screen?.visibleFrame.maxX ?? panel.frame.maxX
        return NSRect(x: x - 28, y: top, width: 24, height: 24)
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in StatusMenu.shared.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                StatusMenu.shared.closeIfClick(outside: event)
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let closeOnEscape = MainActor.assumeIsolated { () -> Bool in
                guard event.keyCode == 53 else { return false }
                if StatusMenu.shared.panel?.firstResponder is NSTextView { return false }
                StatusMenu.shared.close()
                return true
            }
            return closeOnEscape ? nil : event
        }
    }

    private func closeIfClick(outside event: NSEvent) {
        guard panel?.isVisible == true else { return }
        if event.window === panel || event.window === statusItem?.button?.window { return }
        close()
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        globalMonitor = nil
        localMonitor = nil
        keyMonitor = nil
    }
}

private struct MenuRoot: View {
    var model: AppModel

    var body: some View {
        ContentView()
            .environmentObject(model)
            .fixedSize()
    }
}

private final class StatusMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class MenuHostingView: NSHostingView<MenuRoot> {
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                StatusMenu.shared.relayout()
            }
        }
    }
}

private extension PanelRect {
    init(_ rect: NSRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}

private extension NSRect {
    init(_ rect: PanelRect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}

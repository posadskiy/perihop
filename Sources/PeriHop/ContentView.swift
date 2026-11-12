import AppKit
import SwiftUI

enum MenuLayout {
    static let width: CGFloat = 340
    static let padding: CGFloat = 14
}

struct ContentView: View {
    private enum Page {
        case devices
        case setup
        case settings
        case about
    }

    @EnvironmentObject private var model: AppModel
    @State private var page = Page.devices

    var body: some View {
        Group {
            switch model.devices.isEmpty && page == .devices ? .setup : page {
            case .devices:
                DevicesPage(
                    onSetup: { page = .setup },
                    onSettings: { page = .settings }
                )
            case .setup:
                SetupView(onDone: model.devices.isEmpty ? nil : { page = .devices })
            case .settings:
                SettingsView(onDone: { page = .devices }, onAbout: { page = .about })
            case .about:
                InfoView(onDone: { page = .settings })
            }
        }
        .frame(width: MenuLayout.width)
        .onChange(of: page) { StatusMenu.shared.relayoutSoon() }
        #if DEBUG
        .onChange(of: model.debugPage) { _, name in
            switch name {
            case "setup": page = .setup
            case "settings": page = .settings
            case "about": page = .about
            default: page = .devices
            }
        }
        #endif
    }
}

private struct DevicesPage: View {
    var onSetup: () -> Void
    var onSettings: () -> Void

    @EnvironmentObject private var model: AppModel

    private var handoff: HandoffCoordinator { model.handoff }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.peerState == .untrusted {
                Notice(
                    symbol: "exclamationmark.shield",
                    text: "The other Mac's pairing code changed. Trust it in Settings before switching."
                )
            } else if model.peerState == .outdated {
                Notice(
                    symbol: "arrow.down.circle",
                    text: "The other Mac runs an older PeriHop. Update it so the two can switch."
                )
            }

            VStack(spacing: 6) {
                ForEach(model.devices, id: \.address) { device in
                    DeviceRow(device: device)
                }
            }

            if let hint = handoff.hint {
                Notice(symbol: "hand.tap", text: hint)
            } else if let summary = handoff.summary, !handoff.isSwitching {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions

            Divider()

            HStack {
                Button("Edit Devices…", action: onSetup)
                    .disabled(handoff.isSwitching)
                Spacer()
                Button("Quit PeriHop") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(MenuLayout.padding)
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("PeriHop").font(.headline)
            Spacer()
            PeerBadge(state: model.peerState, action: onSettings)
            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }

    @ViewBuilder
    private var actions: some View {
        let here = model.devices.filter { handoff.connected.contains($0.address) }
        let away = model.devices.filter { !handoff.connected.contains($0.address) }
        if handoff.isSwitching {
            HStack {
                ProgressView().controlSize(.small)
                Text("Switching…").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { handoff.stop() }
            }
        } else if model.devices.count > 1 {
            HStack(spacing: 8) {
                if !away.isEmpty {
                    Button {
                        model.bringHere(model.devices)
                    } label: {
                        Label(here.isEmpty ? "Use All Here" : "Use the Rest Here", systemImage: "arrow.down.to.line")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !here.isEmpty, model.isLinked {
                    Button {
                        model.sendAway(here)
                    } label: {
                        Label("Send All", systemImage: "arrow.up.forward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Send the devices on this Mac to the other Mac")
                }
            }
            .controlSize(.large)
        }
    }
}

private struct DeviceRow: View {
    let device: DeviceEntry

    @EnvironmentObject private var model: AppModel

    private var state: DeviceState { model.handoff.state(for: device.address) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.kind.symbol)
                .font(.system(size: 15))
                .frame(width: 32, height: 32)
                .foregroundStyle(state == .here ? Color.white : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(state == .here ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 4)
            trailing
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
        .accessibilityElement(children: .combine)
    }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    private var subtitle: String {
        switch state {
        case .unknown:
            return "Checking…"
        case .here:
            if let percent = model.batteries[device.address] {
                return "On this Mac · \(percent)%"
            }
            return "On this Mac"
        case .onOtherMac:
            return "On the other Mac"
        case .away:
            return "Not connected"
        case .moving(let text):
            return text
        case .waiting:
            return "Waiting for it to wake…"
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .moving, .waiting:
            ProgressView().controlSize(.small)
        case .here:
            if model.isLinked {
                Button("Send") { model.sendAway([device]) }
                    .controlSize(.small)
                    .disabled(model.handoff.isSwitching)
                    .help("Send to the other Mac")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Connected")
            }
        case .unknown, .onOtherMac, .away, .failed:
            Button("Use Here") { model.bringHere([device]) }
                .controlSize(.small)
                .disabled(model.handoff.isSwitching)
        }
    }
}

private struct PeerBadge: View {
    let state: PeerLinkState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text).font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.quinary))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var text: String {
        switch state {
        case .notLinked: return "Link other Mac"
        case .reachable(let bluetooth): return bluetooth ? "Other Mac · Bluetooth" : "Other Mac"
        case .unreachable: return "Other Mac asleep"
        case .untrusted: return "Not trusted"
        case .outdated: return "Update other Mac"
        }
    }

    private var color: Color {
        switch state {
        case .reachable: return .green
        case .notLinked, .unreachable: return .gray
        case .untrusted, .outdated: return .orange
        }
    }

    private var help: String {
        switch state {
        case .notLinked:
            return "Link your other Mac in Settings so the two can pass devices in one click."
        case .reachable(let bluetooth):
            return bluetooth
                ? "The other Mac answers over Bluetooth. The network is keeping the two apart."
                : "The other Mac answers."
        case .unreachable:
            return "The other Mac is asleep or away. Use Here still works."
        case .untrusted:
            return "The other Mac's pairing code changed."
        case .outdated:
            return "The other Mac runs an older PeriHop."
        }
    }
}

struct Notice: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.12)))
    }
}

/// A titled group on the Settings and Setup pages.
struct MenuSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The title row of a page that is not the device list.
struct PageHeader: View {
    let title: String
    let onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Back")
            }
            Text(title).font(.headline)
            Spacer()
        }
    }
}

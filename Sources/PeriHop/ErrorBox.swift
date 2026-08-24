import SwiftUI
import AppKit

/// Bounded, selectable error text with an explicit copy button — keeps long
/// blueutil output inside the popover instead of overflowing it, and makes
/// grabbing it for investigation a single click.
struct ErrorBox: View {
    var message: String

    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copyToClipboard()
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(didCopy ? Color.green : Color.secondary)
            .help("Copy error message")
        }
        .padding(8)
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            didCopy = false
        }
    }
}

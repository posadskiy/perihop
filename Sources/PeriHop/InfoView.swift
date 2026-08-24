import SwiftUI
import AppKit

struct InfoView: View {
    var onDone: () -> Void

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "keyboard")
                Text("PeriHop").font(.headline)
                Spacer()
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                labeledRow("Author") {
                    Text("Dimitri Posadskiy").font(.caption)
                }
                labeledRow("Website") {
                    Link("posadskiy.com", destination: URL(string: "https://posadskiy.com")!)
                        .font(.caption)
                }
                labeledRow("Support") {
                    Link("support@posadskiy.com", destination: URL(string: "mailto:support@posadskiy.com")!)
                        .font(.caption)
                }
                labeledRow("GitHub") {
                    Link("posadskiy/perihop", destination: URL(string: "https://github.com/posadskiy/perihop")!)
                        .font(.caption)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Link("Report an Issue", destination: URL(string: "https://github.com/posadskiy/perihop/issues/new/choose")!)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Third-Party Licenses") {
                    openThirdPartyLicenses()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder
    private func labeledRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            content()
        }
    }

    private func openThirdPartyLicenses() {
        // Bundled into Contents/Resources by build.sh so the notice travels
        // with the actual distributed app, not just the source repo. Falls
        // back to GitHub for `swift run` dev builds, which have no bundle.
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "md") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "https://github.com/posadskiy/perihop/blob/main/THIRD_PARTY_LICENSES.md") {
            NSWorkspace.shared.open(url)
        }
    }
}

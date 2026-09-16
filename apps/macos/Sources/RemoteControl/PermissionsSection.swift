import SwiftUI
import RemoteControlCore

struct PermissionsSection: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SectionCard(title: "macOS Permissions") {
            ForEach(PermissionKind.allCases) { kind in
                PermissionRow(kind: kind, granted: model.permissions.isGranted(kind))
                if kind != PermissionKind.allCases.last {
                    Divider()
                }
            }
        }
    }
}

/// One row per permission, each naming the capability that is unavailable and
/// what specifically breaks without it. Never a generic "permissions missing".
struct PermissionRow: View {

    @EnvironmentObject private var model: AppModel
    let kind: PermissionKind
    let granted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(granted ? Color.green : Color.orange)
                Text(kind.title).font(.body.weight(.medium))
                Spacer()
                Text(granted ? "Granted" : "Not granted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(granted ? kind.grantedSummary : kind.consequenceWhenMissing)
                .font(.caption)
                .foregroundStyle(granted ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)

            if !granted {
                HStack(spacing: 8) {
                    Button("Open \(kind.title) Settings\u{2026}") {
                        model.permissions.openSettings(for: kind)
                    }
                    Button("Request\u{2026}") {
                        model.permissions.request(kind)
                    }
                    .help("Asks macOS to show its own permission dialog.")
                }
                Text("After changing it in System Settings, come back \u{2014} this updates automatically.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

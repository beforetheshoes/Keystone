import SwiftUI

struct SyncStatusBadge: View {
    var status: AppFeature.SyncStatus

    @State private var sizeLabel: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.kstText(size: 11))
                .foregroundStyle(KstColor.ink2)
            Spacer()
            if let sizeLabel {
                Text(sizeLabel)
                    .font(.kstMono(size: 10))
                    .foregroundStyle(KstColor.ink3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .task { sizeLabel = Self.computeWorkspaceSize() }
    }

    private var dotColor: Color {
        switch status {
        case .local:    KstColor.ink3
        case .syncing:  KstColor.amber
        case .synced:   KstColor.sage
        }
    }

    private var label: String {
        switch status {
        case .local:
            return "Local"
        case .syncing:
            return "Syncing…"
        case let .synced(lastAt):
            if let lastAt {
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .short
                return "Synced · \(f.localizedString(for: lastAt, relativeTo: Date()))"
            }
            return "Synced"
        }
    }

    private static func computeWorkspaceSize() -> String? {
        let folder = AppDatabase.workspaceFolder
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        guard total > 0 else { return nil }

        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: total)
    }
}

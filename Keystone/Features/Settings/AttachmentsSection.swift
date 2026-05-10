import SwiftUI
import Dependencies

/// Settings → Attachments. Sits as a sibling Section inside
/// `SettingsView`'s Form, between Storage (folder location) and
/// Behavior. Surfaces total count, total bytes, an MIME-bucket
/// breakdown, and a button that opens the cross-database search
/// sheet. Stats refresh on appear and after the sheet dismisses
/// (since the user may have deleted attachments while it was open).
struct AttachmentsSection: View {
    @Dependency(\.databaseClient) private var dbClient

    @State private var stats: AssetStats?
    @State private var isSearchSheetPresented = false

    var body: some View {
        Section {
            LabeledContent("Total files") {
                Text(formattedCount(stats?.totalCount))
                    .font(.kstMono(size: 12))
                    .foregroundStyle(KstColor.ink1)
            }
            LabeledContent("Total size") {
                Text(formattedBytes(stats?.totalBytes))
                    .font(.kstMono(size: 12))
                    .foregroundStyle(KstColor.ink1)
            }
            LabeledContent("By type") {
                Text(breakdownString)
                    .font(.kstMono(size: 12))
                    .foregroundStyle(KstColor.ink2)
                    .multilineTextAlignment(.trailing)
            }
            if let s = stats, s.encryptedCount > 0 {
                LabeledContent("Encrypted") {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                        Text("\(s.encryptedCount)")
                            .font(.kstMono(size: 12))
                    }
                    .foregroundStyle(KstColor.ink2)
                }
            }

            Button {
                isSearchSheetPresented = true
            } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Search attachments…")
                }
            }
            .disabled((stats?.totalCount ?? 0) == 0)
        } header: {
            Text("Attachments")
        } footer: {
            Text("Search the workspace by filename, plus the extracted text inside PDFs and other documents. Encrypted attachments match by filename only.")
        }
        .task { await refresh() }
        .sheet(isPresented: $isSearchSheetPresented, onDismiss: {
            Task { await refresh() }
        }) {
            AttachmentSearchView()
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 460)
                #endif
        }
    }

    @MainActor
    private func refresh() async {
        // `Seed.workspaceID` is the single-workspace constant the rest
        // of the app threads through. No multi-workspace surface yet.
        stats = (try? dbClient.assetStats(Seed.workspaceID)) ?? .empty
    }

    private var breakdownString: String {
        guard let s = stats else { return "—" }
        var parts: [String] = []
        if s.imageCount    > 0 { parts.append("\(s.imageCount) image\(s.imageCount == 1 ? "" : "s")") }
        if s.pdfCount      > 0 { parts.append("\(s.pdfCount) PDF\(s.pdfCount == 1 ? "" : "s")") }
        if s.documentCount > 0 { parts.append("\(s.documentCount) doc\(s.documentCount == 1 ? "" : "s")") }
        if s.otherCount    > 0 { parts.append("\(s.otherCount) other") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func formattedCount(_ n: Int?) -> String {
        guard let n else { return "—" }
        return n.formatted(.number)
    }

    private func formattedBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

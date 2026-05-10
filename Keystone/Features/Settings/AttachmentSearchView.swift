import SwiftUI
import Dependencies
#if canImport(AppKit)
import AppKit
#endif

/// Cross-database attachment search, presented as a sheet from
/// `AttachmentsSection`. Type filter mirrors the MIME buckets in
/// `AssetStats`. Tapping a result opens Quick Look (decrypted
/// to a temp file when the asset is encrypted, defensive against
/// not-yet-synced files via `QuickLookManager.present(urls:)`).
struct AttachmentSearchView: View {
    @Dependency(\.databaseClient) private var dbClient
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var typeFilter: AssetTypeFilter = .all
    @State private var hits: [AssetSearchHit] = []
    @State private var isSearching = false
    /// Bumped on every keystroke / filter change. The async search
    /// task captures the value at start time and bails out before
    /// publishing if the user has typed again — avoids the classic
    /// stale-result-overwrites-fresh-result race on slow searches.
    @State private var searchToken: Int = 0

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Picker("Type", selection: $typeFilter) {
                    Text("All").tag(AssetTypeFilter.all)
                    Text("Images").tag(AssetTypeFilter.images)
                    Text("PDFs").tag(AssetTypeFilter.pdfs)
                    Text("Documents").tag(AssetTypeFilter.documents)
                    Text("Other").tag(AssetTypeFilter.other)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                resultList
            }
            .navigationTitle("Search Attachments")
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
            .onChange(of: query)      { _, _ in scheduleSearch() }
            .onChange(of: typeFilter) { _, _ in scheduleSearch() }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(KstColor.ink2)
            TextField("Filename or document text", text: $query)
                .textFieldStyle(.plain)
                .font(.kstText(size: 13))
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(KstColor.ink3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(KstColor.paper2, in: RoundedRectangle(cornerRadius: KstRadius.r2))
    }

    // MARK: - Results

    @ViewBuilder
    private var resultList: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView(
                "Type to search",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Find attachments by filename or by text inside PDFs and documents.")
            )
            .frame(maxHeight: .infinity)
        } else if hits.isEmpty && !isSearching {
            ContentUnavailableView(
                "No matches",
                systemImage: "doc.questionmark",
                description: Text("Nothing in this workspace matched “\(query)”.")
            )
            .frame(maxHeight: .infinity)
        } else {
            List(hits) { hit in
                AttachmentSearchHitRow(hit: hit) {
                    openQuickLook(for: hit)
                }
                .contentShape(Rectangle())
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Actions

    private func scheduleSearch() {
        searchToken &+= 1
        let token = searchToken
        let q = query
        let filter = typeFilter
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hits = []
            isSearching = false
            return
        }
        isSearching = true
        Task {
            // ~150 ms debounce so each keystroke doesn't fire SQL.
            try? await Task.sleep(nanoseconds: 150_000_000)
            if token != searchToken { return }
            let results = (try? dbClient.searchAssets(Seed.workspaceID, q, filter, 200)) ?? []
            await MainActor.run {
                if token == searchToken {
                    hits = results
                    isSearching = false
                }
            }
        }
    }

    private func openQuickLook(for hit: AssetSearchHit) {
        // Resolve through the dependency so encrypted assets get
        // decrypted to a temp file. The preflight inside
        // QuickLookManager.present(urls:) handles missing-file
        // (not-yet-synced) cases with a placeholder alert.
        guard let url = try? dbClient.assetDecryptedURL(hit.id) else { return }
        #if canImport(AppKit)
        QuickLookManager.shared.present(urls: [url])
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}

private struct AttachmentSearchHitRow: View {
    let hit: AssetSearchHit
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: glyphName)
                    .font(.system(size: 18))
                    .foregroundStyle(KstColor.ink2)
                    .frame(width: 24, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(hit.originalFilename)
                            .font(.kstText(size: 13, weight: .medium))
                            .foregroundStyle(KstColor.ink0)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if hit.isEncrypted {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(KstColor.ink3)
                                .help("Encrypted attachment — protected record")
                        }
                    }
                    Text(metaLine)
                        .font(.kstMono(size: 11))
                        .foregroundStyle(KstColor.ink2)
                    if let snippet = hit.snippet {
                        Text(snippet)
                            .font(.kstText(size: 12))
                            .foregroundStyle(KstColor.ink2)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var glyphName: String {
        guard let mime = hit.mimeType else { return "doc" }
        if mime.hasPrefix("image/") { return "photo" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("text/") || mime.hasPrefix("application/vnd.openxmlformats-officedocument") || mime == "application/msword" || mime == "application/rtf" {
            return "doc.text"
        }
        return "doc"
    }

    private var metaLine: String {
        var parts: [String] = []
        if let ext = hit.fileExtension, !ext.isEmpty { parts.append(ext.uppercased()) }
        if let size = hit.byteSize { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
}

import SwiftUI
import ComposableArchitecture

/// Lookup-first creation sheet. Shown when the user clicks **+ New** on a
/// database whose `database_id` has a `LookupProvider` registered (books,
/// movies, tv_shows, vendors). The user types in the search field; results
/// from the provider stream in as they type. Picking a candidate fires
/// `lookupCandidatePicked`, which creates the record + applies the payload
/// + opens the detail.
///
/// Escape hatches:
/// - The "Create blank" button skips the picker (matches the original
///   `+ New` behavior).
/// - Press Esc / click outside to close.
struct RecordLookupSheet: View {
    @Bindable var store: StoreOf<AppFeature>
    let databaseID: String
    let databaseName: String
    /// Provider-registry key. Defaults to `databaseID` (matches the
    /// pre-views behavior), but a saved view can override — e.g. the
    /// Restaurants view passes `"restaurant"` so its MapKit search is
    /// constrained to food/drink POIs even though records still land
    /// in the Vendors database.
    var lookupProviderKey: String? = nil
    /// Kind value to stamp onto records created via the "Create blank"
    /// escape hatch. The lookup-picked path doesn't need this (the
    /// provider's apply payload carries kind itself).
    var presetKind: String? = nil
    /// When non-nil, the sheet is in "re-enrich" mode: picking a
    /// candidate updates this existing record rather than creating a
    /// new one.
    var existingRecordID: String? = nil
    /// Initial value loaded into the search field. Empty for fresh
    /// creation; the existing record's title for re-enrich.
    var initialQuery: String = ""

    @State private var query: String = ""
    @State private var candidates: [LookupCandidate] = []
    @State private var loading: Bool = false
    @State private var lastSearchedQuery: String = ""

    @FocusState private var fieldFocused: Bool

    private var isReenrich: Bool { existingRecordID != nil }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                header

                searchField
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                Divider()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                footer
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: 560, maxHeight: 560)
            .background(KstColor.paper0)
            .clipShape(RoundedRectangle(cornerRadius: KstRadius.r4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: KstRadius.r4, style: .continuous)
                    .strokeBorder(KstColor.ink4, lineWidth: 0.5)
            )
            .kstShadow2()
        }
        .onAppear {
            if query.isEmpty { query = initialQuery }
            fieldFocused = true
        }
        .task(id: query) { await runSearch() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(isReenrich ? "Re-enrich \(singularName)" : "New \(singularName)")
                .font(.kstDisplay(size: 18, weight: .semibold))
                .foregroundStyle(KstColor.ink0)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(KstColor.ink3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(KstColor.ink3)
            TextField("Search \(databaseName.lowercased())…", text: $query)
                .textFieldStyle(.plain)
                .font(.kstText(size: 14))
                .foregroundStyle(KstColor.ink0)
                .focused($fieldFocused)
                .onSubmit { Task { await runSearch(force: true) } }
            if loading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(KstColor.paper1)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
            placeholder(text: "Type at least 2 characters to search.")
        } else if loading && candidates.isEmpty {
            placeholder(text: "Searching…")
        } else if !loading && candidates.isEmpty {
            placeholder(text: "No matches. Try a different spelling, or create a blank record.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(candidates) { candidate in
                        Button(action: { pick(candidate) }) {
                            CandidateRow(candidate: candidate)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func placeholder(text: String) -> some View {
        Text(text)
            .font(.kstText(size: 13))
            .foregroundStyle(KstColor.ink3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            // The "Create blank" escape hatch only makes sense when
            // we're creating a new record. Re-enrich already has a
            // record; users who want a different match just adjust the
            // query, and Esc/× cancels.
            if !isReenrich {
                KstButton(style: .standard, action: createBlank) {
                    Text("Create blank")
                }
            }
        }
    }

    private var singularName: String {
        databaseName.hasSuffix("s") ? String(databaseName.dropLast()) : databaseName
    }

    private func close() {
        store.send(.closeLookup)
    }

    private func pick(_ candidate: LookupCandidate) {
        if let recordID = existingRecordID {
            store.send(.lookupCandidatePickedForExisting(
                databaseID: databaseID,
                recordID: recordID,
                candidate: candidate
            ))
        } else {
            store.send(.lookupCandidatePicked(databaseID: databaseID, candidate: candidate))
        }
    }

    private func createBlank() {
        let presets: [String: String] = presetKind.map { ["kind": $0] } ?? [:]
        store.send(.closeLookup)
        store.send(.createBlankRecord(databaseID: databaseID, presets: presets))
    }

    private func runSearch(force: Bool = false) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            await MainActor.run { candidates = []; loading = false }
            return
        }
        if !force, trimmed == lastSearchedQuery { return }

        // Debounce: 250ms gives a fast typist room to keep typing without
        // burning API quota. Cancellation propagates from `.task(id:)`.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }

        let key = lookupProviderKey ?? databaseID
        guard let provider = LookupRegistry.provider(for: key) else { return }

        await MainActor.run { loading = true }
        let results = await provider.searchCandidates(query: trimmed)
        if Task.isCancelled { return }
        await MainActor.run {
            self.candidates = results
            self.loading = false
            self.lastSearchedQuery = trimmed
        }
    }
}

// MARK: - Candidate row

private struct CandidateRow: View {
    let candidate: LookupCandidate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cover
                .frame(width: 44, height: 60)
                .background(KstColor.paper2)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title)
                    .font(.kstText(size: 14, weight: .medium))
                    .foregroundStyle(KstColor.ink0)
                    .lineLimit(2)
                if let subtitle = candidate.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.kstText(size: 12))
                        .foregroundStyle(KstColor.ink2)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var cover: some View {
        if let url = candidate.coverURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure, .empty:
                    Image(systemName: "photo")
                        .font(.system(size: 14))
                        .foregroundStyle(KstColor.ink3)
                @unknown default:
                    Color.clear
                }
            }
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 14))
                .foregroundStyle(KstColor.ink3)
        }
    }
}

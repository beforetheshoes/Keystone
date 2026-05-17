import SwiftUI
import ComposableArchitecture

/// Cover-only picker — opens from "Search covers…" in the gallery card
/// context menu and the detail-view kebab. Fans out across every
/// registered `CoverProvider` for the active database (Google Books +
/// Open Library for books; TMDB for movies / TV). Selecting a thumbnail
/// downloads it and attaches as the record's cover; no other
/// properties are touched.
struct CoverPickerSheet: View {
    @Bindable var store: StoreOf<AppFeature>
    var state: AppFeature.CoverPickerSheetState

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { store.send(.closeCoverPicker) }

            VStack(alignment: .leading, spacing: 12) {
                header

                searchField
                    .padding(.horizontal, 16)

                Divider()

                content
                    .frame(minHeight: 320, maxHeight: 560)

                footer
            }
            .frame(width: 640)
            .background(KstColor.paper0)
            .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                    .strokeBorder(KstColor.ink4, lineWidth: 0.5)
            )
            .kstShadow2()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(KstColor.ink2)
            VStack(alignment: .leading, spacing: 1) {
                Text("Search covers")
                    .font(.kstDisplay(size: 16, weight: .semibold))
                    .foregroundStyle(KstColor.ink0)
                Text(state.recordTitle)
                    .font(.kstText(size: 12))
                    .foregroundStyle(KstColor.ink2)
                    .lineLimit(1)
            }
            Spacer()
            Button { store.send(.closeCoverPicker) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(KstColor.ink2)
                    .frame(width: 22, height: 22)
                    .background(KstColor.paper1)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(KstColor.ink3)
            TextField(
                "Title or title + author",
                text: Binding(
                    get: { state.query },
                    set: { store.send(.coverPickerQueryChanged($0)) }
                )
            )
            .textFieldStyle(.plain)
            .font(.kstText(size: 13))
            .onSubmit { store.send(.coverPickerSearchRequested) }

            Button("Search") { store.send(.coverPickerSearchRequested) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(state.query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(KstColor.paper1)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        if state.loading {
            VStack(spacing: 8) {
                Spacer()
                ProgressView()
                Text("Searching covers…")
                    .font(.kstText(size: 12))
                    .foregroundStyle(KstColor.ink2)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.candidates.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundStyle(KstColor.ink3)
                Text("No covers found.")
                    .font(.kstText(size: 13))
                    .foregroundStyle(KstColor.ink2)
                Text("Try refining the search above.")
                    .font(.kstText(size: 11))
                    .foregroundStyle(KstColor.ink3)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(state.candidates) { c in
                        CoverTile(candidate: c, applying: state.applying) {
                            store.send(.coverPickerCandidatePicked(c))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let warning = sourceWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(KstColor.ink2)
                    Text(warning)
                        .font(.kstText(size: 11))
                        .foregroundStyle(KstColor.ink2)
                }
            }
            HStack(spacing: 8) {
                if state.applying {
                    ProgressView().controlSize(.small)
                    Text("Downloading…")
                        .font(.kstText(size: 12))
                        .foregroundStyle(KstColor.ink2)
                }
                Spacer()
                Text(footerHint)
                    .font(.kstText(size: 11))
                    .foregroundStyle(KstColor.ink3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// Visible per-source warning when one of the registered providers
    /// errored out — typically a 429 / 503 from quota pressure. Helps
    /// the user understand why their hits come from only one source.
    private var sourceWarning: String? {
        let errored = state.sources.filter { $0.outcome == .errored }
        guard !errored.isEmpty else { return nil }
        let names = errored.map(\.sourceLabel).joined(separator: " + ")
        return "\(names) temporarily unavailable — check rate limits or try again in a moment."
    }

    private var footerHint: String {
        guard !state.sources.isEmpty else { return "" }
        // "12 results · Google Books 8 · Open Library 4"
        let sourceBreakdown = state.sources
            .filter { $0.outcome == .ok && $0.resultCount > 0 }
            .map { "\($0.sourceLabel) \($0.resultCount)" }
            .joined(separator: " · ")
        let total = state.candidates.count
        if sourceBreakdown.isEmpty { return "" }
        return "\(total) result\(total == 1 ? "" : "s") · \(sourceBreakdown)"
    }
}

private struct CoverTile: View {
    var candidate: CoverCandidate
    var applying: Bool
    var onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: candidate.thumbnailURL ?? candidate.coverURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fit)
                            case .failure:
                                ZStack {
                                    KstColor.paper2
                                    Image(systemName: "photo")
                                        .font(.system(size: 22))
                                        .foregroundStyle(KstColor.ink3)
                                }
                            default:
                                ZStack {
                                    KstColor.paper2
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        Text(candidate.sourceLabel)
                            .font(.kstText(size: 9, weight: .semibold))
                            .foregroundStyle(KstColor.paper0)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous)
                            .strokeBorder(hovering ? KstColor.ink2 : KstColor.ink4, lineWidth: hovering ? 1.5 : 0.5)
                    )

                Text(candidate.title)
                    .font(.kstText(size: 11, weight: .medium))
                    .foregroundStyle(KstColor.ink0)
                    .lineLimit(1)
                if let subtitle = candidate.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.kstText(size: 10))
                        .foregroundStyle(KstColor.ink2)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(applying)
        .opacity(applying ? 0.5 : 1.0)
        .onHover { hovering = $0 }
    }
}

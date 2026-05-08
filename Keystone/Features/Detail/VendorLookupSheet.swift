import SwiftUI
import ComposableArchitecture

#if canImport(MapKit)

/// Interactive Apple Maps lookup for a vendor record.
///
/// Triggered by the "Look up on Apple Maps" menu item on a vendor's
/// detail view. On appear, runs `VendorLookupService.enrich`. Three
/// outcomes:
///
/// - `.resolved` — top result was a confident name match. Shown as a
///   single "Confident match" card the user just confirms.
/// - `.ambiguous` — multiple candidates without a clear winner. User
///   picks from a list.
/// - `.notFound` — nothing in MapKit's database. Sheet shows a "no
///   matches" state and offers manual close.
///
/// Tapping "Apply" on a card writes phone/website/address/kind/place_id
/// to the vendor record via `AppFeature.updatePropertyValue`. We always
/// honor MapKit values over whatever the user had typed — the user
/// explicitly chose to override by picking this candidate.
@available(iOS 26.0, macOS 26.0, *)
struct VendorLookupSheet: View {
    @Bindable var store: StoreOf<AppFeature>
    let recordID: String
    let currentName: String
    let currentAddress: String?

    @Environment(\.dismiss) private var dismiss

    @State private var loading = true
    @State private var candidates: [VendorEnrichment] = []
    @State private var resolved: VendorEnrichment? = nil
    @State private var didSearch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Look up on Apple Maps")
                    .font(.kstDisplay(size: 16))
                    .foregroundStyle(KstColor.ink0)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(KstColor.ink2)
                        .frame(width: 22, height: 22)
                        .background(KstColor.paper2)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            HStack(spacing: 6) {
                Text("Searching for")
                    .font(.kstText(size: 12))
                    .foregroundStyle(KstColor.ink2)
                Text(currentName)
                    .font(.kstText(size: 12, weight: .semibold))
                    .foregroundStyle(KstColor.ink0)
                if let addr = currentAddress, !addr.isEmpty {
                    Text("·")
                        .font(.kstText(size: 12))
                        .foregroundStyle(KstColor.ink3)
                    Text(addr)
                        .font(.kstText(size: 12))
                        .foregroundStyle(KstColor.ink2)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider().background(KstColor.ink4)

            // Body
            ZStack {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let r = resolved {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionLabel("CONFIDENT MATCH")
                            CandidateCard(enrichment: r) { apply(r) }
                        }
                        .padding(20)
                    }
                } else if !candidates.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionLabel("MULTIPLE MATCHES — PICK ONE")
                            ForEach(Array(candidates.enumerated()), id: \.offset) { _, c in
                                CandidateCard(enrichment: c) { apply(c) }
                            }
                        }
                        .padding(20)
                    }
                } else if didSearch {
                    VStack(spacing: 8) {
                        Text("No matches found in Apple Maps")
                            .font(.kstText(size: 13))
                            .foregroundStyle(KstColor.ink2)
                        Text("This vendor may be too small or local for MapKit's database.")
                            .font(.kstText(size: 12))
                            .foregroundStyle(KstColor.ink3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 480)
        .background(KstColor.paper0)
        .task {
            await runLookup()
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.kstText(size: 10, weight: .semibold))
            .foregroundStyle(KstColor.ink3)
            .tracking(0.6)
    }

    private func runLookup() async {
        let outcome = await VendorLookupService.enrich(
            name: currentName,
            address: currentAddress
        )
        await MainActor.run {
            switch outcome {
            case .resolved(let e):
                resolved = e
            case .ambiguous(let list):
                candidates = list
            case .notFound:
                break
            }
            loading = false
            didSearch = true
        }
    }

    private func apply(_ enrichment: VendorEnrichment) {
        let fields: [(String, String?)] = [
            ("phone",    enrichment.phone),
            ("website",  enrichment.website),
            ("address",  enrichment.address),
            ("locality", enrichment.locality),
            ("kind",     enrichment.kind),
            ("place_id", enrichment.placeID),
        ]
        for (key, valueOpt) in fields {
            guard let value = valueOpt, !value.isEmpty else { continue }
            store.send(.updatePropertyValue(recordID: recordID, key: key, value: value))
        }
        dismiss()
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct CandidateCard: View {
    let enrichment: VendorEnrichment
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let addr = enrichment.address {
                Text(addr)
                    .font(.kstText(size: 13, weight: .medium))
                    .foregroundStyle(KstColor.ink0)
                    .multilineTextAlignment(.leading)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let locality = enrichment.locality {
                    detailRow(icon: "building.2.fill", text: locality)
                }
                if let phone = enrichment.phone {
                    detailRow(icon: "phone.fill", text: phone)
                }
                if let website = enrichment.website {
                    detailRow(icon: "link", text: website)
                }
                if let kind = enrichment.kind {
                    detailRow(icon: "tag.fill", text: "Categorized as \(kind)")
                }
                if let pid = enrichment.placeID {
                    detailRow(icon: "mappin.circle.fill", text: "Place ID: \(pid)")
                }
            }

            HStack {
                Spacer()
                Button(action: onApply) {
                    Text("Apply")
                        .font(.kstText(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background(KstColor.ink0)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KstColor.paper1)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private func detailRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(KstColor.ink3)
                .frame(width: 14)
            Text(text)
                .font(.kstText(size: 12))
                .foregroundStyle(KstColor.ink2)
                .lineLimit(1)
        }
    }
}

#endif

import SwiftUI
import ComposableArchitecture

/// Watch-progress block for a TV Shows detail view. Two numeric
/// steppers — current season and current episode — bracketed by the
/// total episode count (which is enriched from TMDB and lives on the
/// record's `episode_count` property).
struct TVProgressField: View {
    var store: StoreOf<AppFeature>
    var record: RecordRow

    private var currentSeason: Int {
        Int(record.values["current_season"] ?? "") ?? 0
    }

    private var currentEpisode: Int {
        Int(record.values["current_episode"] ?? "") ?? 0
    }

    private var totalSeasons: Int {
        Int(record.values["season_count"] ?? "") ?? 0
    }

    private var totalEpisodes: Int {
        Int(record.values["episode_count"] ?? "") ?? 0
    }

    private var fraction: Double {
        guard totalEpisodes > 0, currentEpisode > 0 else { return 0 }
        return min(1.0, Double(currentEpisode) / Double(totalEpisodes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Watch progress")
                .font(.kstText(size: 11, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(KstColor.ink2)

            HStack(spacing: 14) {
                Stepper(
                    label: "Season",
                    value: currentSeason,
                    bound: totalSeasons,
                    onChange: { value in
                        store.send(.updatePropertyValue(
                            recordID: record.id,
                            key: "current_season",
                            value: String(value)
                        ))
                    }
                )
                Stepper(
                    label: "Episode",
                    value: currentEpisode,
                    bound: totalEpisodes,
                    onChange: { value in
                        store.send(.updatePropertyValue(
                            recordID: record.id,
                            key: "current_episode",
                            value: String(value)
                        ))
                    }
                )
                Spacer()
                if totalEpisodes > 0 {
                    Text("\(Int(fraction * 100))%")
                        .font(.kstText(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(KstColor.ink0)
                }
            }
        }
        .padding(14)
        .background(KstColor.paper1)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
    }
}

private struct Stepper: View {
    var label: String
    var value: Int
    /// Upper bound, when known. `0` means "no bound" and we don't
    /// clamp on the up-button.
    var bound: Int
    var onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.kstText(size: 12))
                .foregroundStyle(KstColor.ink2)
                .frame(width: 56, alignment: .leading)
            Button { adjust(-1) } label: { Image(systemName: "minus") }
                .buttonStyle(.bordered)
                .controlSize(.small)
            TextField("0", text: Binding(
                get: { String(value) },
                set: { newRaw in
                    let n = clamp(Int(newRaw) ?? 0)
                    onChange(n)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 50)
            .monospacedDigit()
            Button { adjust(1) } label: { Image(systemName: "plus") }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if bound > 0 {
                Text("/ \(bound)")
                    .font(.kstText(size: 12))
                    .foregroundStyle(KstColor.ink3)
            }
        }
    }

    private func adjust(_ delta: Int) {
        onChange(clamp(value + delta))
    }

    private func clamp(_ n: Int) -> Int {
        if bound > 0 { return max(0, min(bound, n)) }
        return max(0, n)
    }
}

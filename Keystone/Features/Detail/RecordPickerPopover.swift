import SwiftUI
import ComposableArchitecture
import Dependencies

struct RecordPickerPopover: View {
    var targetDatabaseID: String
    var excludingRecordIDs: Set<String> = []
    /// Privacy-lock hidden set; passed straight to `dbClient.records` so
    /// protected records never appear in the relation picker. Defaults
    /// to empty so callers that haven't been threaded through the lock
    /// state still compile (and silently fail open — preferable for a
    /// picker that shouldn't crash on missing context).
    var hiddenRecordIDs: Set<String> = []
    var onPick: (RecordRow) -> Void

    @State private var query: String = ""
    @State private var records: [RecordRow] = []
    @FocusState private var focused: Bool
    @Dependency(\.databaseClient) private var dbClient

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(KstColor.ink3)
                TextField("Find record…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.kstText(size: 13))
                    .focused($focused)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(KstColor.paper3).frame(height: 0.5) }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filtered) { rec in
                        Button(action: { onPick(rec) }) {
                            HStack(spacing: 10) {
                                Glyph(tone: rec.tone, text: rec.glyph, size: 18, radius: 4)
                                Text(rec.title)
                                    .font(.kstText(size: 13))
                                    .foregroundStyle(KstColor.ink0)
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if filtered.isEmpty {
                        Text("No matches.")
                            .font(.kstText(size: 12))
                            .foregroundStyle(KstColor.ink3)
                            .padding(20)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 300)
        .background(KstColor.paper0)
        .onAppear {
            focused = true
            records = (try? dbClient.records(targetDatabaseID, hiddenRecordIDs)) ?? []
        }
    }

    private var filtered: [RecordRow] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = records.filter { !excludingRecordIDs.contains($0.id) }
        if q.isEmpty { return pool }
        return pool.filter { $0.title.lowercased().contains(q) }
    }
}

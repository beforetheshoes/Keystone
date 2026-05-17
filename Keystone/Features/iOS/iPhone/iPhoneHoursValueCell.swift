#if !os(macOS)
import SwiftUI

/// iPhone-flavor counterpart to `RestaurantHoursValueCell`. Renders
/// the parsed schedule inline and presents `RestaurantHoursEditor`
/// inside a full-height sheet when the user taps the "Edit" chevron.
///
/// The editor lives-writes through the same `draft` binding the rest
/// of the property card uses, so dismissing the sheet doesn't require
/// an explicit save — every change has already flushed via `onCommit`.
struct iPhoneHoursValueCell: View {
    var rawValue: String
    @Binding var draft: String
    var property: PropertyRow
    var recordID: String
    var onCommit: () -> Void

    @State private var sheetOpen: Bool = false

    var body: some View {
        Button {
            draft = rawValue
            sheetOpen = true
        } label: {
            HStack(alignment: .top, spacing: 6) {
                RestaurantHoursView(raw: rawValue)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(KstColor.ink3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $sheetOpen) {
            NavigationStack {
                ScrollView {
                    let canStructure = RestaurantHoursModel.parse(draft) != nil
                        || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if canStructure {
                        RestaurantHoursEditor(rawValue: $draft, onCommit: onCommit)
                            .padding(16)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Couldn't parse structured hours — editing as plain text.")
                                .font(.kstText(size: 12, weight: .medium))
                                .foregroundStyle(KstColor.ink3)
                            PropertyValueField(
                                property: property,
                                value: $draft,
                                onCommit: onCommit,
                                recordID: recordID
                            )
                        }
                        .padding(16)
                    }
                }
                .background(KstColor.paper0)
                .navigationTitle("Hours")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { sheetOpen = false }
                            .font(.kstText(size: 14, weight: .semibold))
                    }
                }
            }
        }
    }
}
#endif

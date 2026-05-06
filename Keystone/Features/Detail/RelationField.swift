import SwiftUI
import ComposableArchitecture
import Dependencies

struct RelationField: View {
    @Bindable var store: StoreOf<AppFeature>
    var property: PropertyRow
    @State private var pickerOpen = false
    @State private var targetDatabaseID: String?
    @Dependency(\.databaseClient) private var dbClient

    var body: some View {
        HStack(spacing: 6) {
            ForEach(linksForProperty) { link in
                Button(action: {
                    store.send(.setNav(.record(databaseID: link.targetDatabaseID, recordID: link.targetRecordID)))
                }) {
                    HStack(spacing: 6) {
                        Glyph(tone: link.targetTone, text: link.targetGlyph, size: 16, radius: 4)
                        Text(link.targetTitle).font(.kstText(size: 13))
                    }
                    .foregroundStyle(KstColor.ink0)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(KstColor.paper2)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Remove relation", role: .destructive) {
                        store.send(.removeRelation(relationID: link.id))
                    }
                }
            }

            if let targetDB = targetDatabaseID {
                Button(action: { pickerOpen = true }) {
                    Text(linksForProperty.isEmpty ? "+ Add" : "+")
                        .font(.kstText(size: 11.5))
                        .foregroundStyle(KstColor.ink3)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(KstColor.paper1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $pickerOpen) {
                    RecordPickerPopover(
                        targetDatabaseID: targetDB,
                        excludingRecordIDs: Set(linksForProperty.map(\.targetRecordID))
                    ) { picked in
                        store.send(.addRelation(propertyID: property.id, targetRecordID: picked.id))
                        pickerOpen = false
                    }
                }
            } else {
                Text("—")
                    .font(.kstText(size: 13))
                    .foregroundStyle(KstColor.ink3)
            }
        }
        .onAppear {
            targetDatabaseID = (try? dbClient.relationTargetDatabaseID(property.id)) ?? nil
        }
    }

    private var linksForProperty: [RelationLink] {
        store.currentOutgoingRelations.filter { $0.propertyID == property.id }
    }
}

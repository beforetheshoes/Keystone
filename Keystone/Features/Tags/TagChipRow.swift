import SwiftUI
import ComposableArchitecture

struct TagChipRow: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var pickerOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("TAGS")
                    .font(.kstText(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(KstColor.ink2)
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(store.currentRecordTags) { tag in
                    TagChip(tag: tag) {
                        store.send(.detachTag(tagID: tag.id))
                    }
                }
                Button(action: { pickerOpen = true }) {
                    Text(store.currentRecordTags.isEmpty ? "+ Add tag" : "+")
                        .font(.kstText(size: 11.5))
                        .foregroundStyle(KstColor.ink3)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(KstColor.paper1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                    TagPicker(store: store) { pickerOpen = false }
                }
            }
        }
    }
}

private struct TagChip: View {
    var tag: TagModel
    var onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tag.color.base).frame(width: 6, height: 6)
            Text(tag.name)
                .font(.kstText(size: 11.5, weight: .medium))
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .opacity(0.6)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 8)
        .foregroundStyle(tag.color.ink)
        .background(tag.color.soft)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .onHover { hovering = $0 }
    }
}

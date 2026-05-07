import SwiftUI
import UniformTypeIdentifiers
import ComposableArchitecture

/// Wraps the FILES grid with drag-and-drop support for `.fileURL`.
struct AssetGridDropTarget<Content: View>: View {
    @Bindable var store: StoreOf<AppFeature>
    @ViewBuilder var content: () -> Content
    @State private var isDropping = false

    var body: some View {
        content()
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                    .fill(isDropping ? KstColor.ceruleanSoft.opacity(0.5) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                    .strokeBorder(
                        isDropping ? KstColor.cerulean : Color.clear,
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropping) { providers in
                handleDrop(providers)
            }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var anyHandled = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            anyHandled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL? = {
                    if let url = item as? URL { return url }
                    if let data = item as? Data {
                        return URL(dataRepresentation: data, relativeTo: nil)
                    }
                    return nil
                }()
                guard let url else { return }
                Task { @MainActor in
                    store.send(.importAsset(fileURL: url))
                }
            }
        }
        return anyHandled
    }
}

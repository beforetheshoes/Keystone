import SwiftUI
import ComposableArchitecture
import UniformTypeIdentifiers

struct AssetsSection: View {
    @Bindable var store: StoreOf<AppFeature>
    @State private var pickerOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("FILES")
                    .font(.kstText(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(KstColor.ink2)
                if !store.currentRecordAssets.isEmpty {
                    Text("\(store.currentRecordAssets.count)")
                        .font(.kstText(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(KstColor.ink3)
                }
                Spacer()
                Button(action: { pickerOpen = true }) {
                    Text("+ Attach file…")
                        .font(.kstText(size: 12))
                        .foregroundStyle(KstColor.ink2)
                }
                .buttonStyle(.plain)
            }

            AssetGridDropTarget(store: store) {
                if store.currentRecordAssets.isEmpty {
                    HStack {
                        Text("Drop files here, or click + Attach file…")
                            .font(.kstText(size: 13))
                            .foregroundStyle(KstColor.ink3)
                        Spacer()
                    }
                    .padding(.vertical, 18)
                    .padding(.horizontal, 12)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 180), spacing: 10)],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        ForEach(store.currentRecordAssets) { asset in
                            AssetTileView(store: store, asset: asset)
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $pickerOpen,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                for url in urls {
                    store.send(.importAsset(fileURL: url))
                }
            }
        }
    }
}

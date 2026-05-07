import SwiftUI
import ComposableArchitecture
import Dependencies

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct AssetTileView: View {
    @Bindable var store: StoreOf<AppFeature>
    var asset: AssetRecord

    @State private var thumbnail: PlatformImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.clear
                if let thumbnail {
                    #if canImport(AppKit)
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    #else
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    #endif
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(height: 100)
            .frame(maxWidth: .infinity)
            .background(KstColor.paper2)
            .clipped()

            VStack(alignment: .leading, spacing: 1) {
                Text(asset.originalFilename)
                    .font(.kstText(size: 12, weight: .medium))
                    .foregroundStyle(KstColor.ink0)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(formatBytes(asset.byteSize))
                    .font(.kstMono(size: 10))
                    .foregroundStyle(KstColor.ink2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KstColor.paper0)
        .overlay(
            RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous)
                .strokeBorder(KstColor.ink4, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: KstRadius.r3, style: .continuous))
        .modifier(AssetTileHoverShadow(active: hovering))
        .offset(y: hovering ? -1 : 0)
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture {
            #if os(macOS)
            // Tap = Quick Look on macOS. The point is a floating preview
            // the user can keep open while filling in the record's
            // detail page beside it. "Open" stays in the context menu
            // for opening in Preview (or whatever the default app is).
            store.send(.quickLookAsset(assetID: asset.id))
            #else
            store.send(.openAsset(assetID: asset.id))
            #endif
        }
        .contextMenu {
            #if os(macOS)
            Button("Quick Look") {
                store.send(.quickLookAsset(assetID: asset.id))
            }
            #endif
            Button("Open") {
                store.send(.openAsset(assetID: asset.id))
            }
            #if os(macOS)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([asset.absoluteURL])
            }
            #endif
            Divider()
            Button("Delete", role: .destructive) {
                store.send(.deleteAsset(assetID: asset.id))
            }
        }
        .task(id: asset.id) {
            thumbnail = await AssetThumbnailService.shared.thumbnail(
                for: asset.absoluteURL,
                size: CGSize(width: 240, height: 200)
            )
        }
    }
}

private struct AssetTileHoverShadow: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        if active { AnyView(content.kstShadow2()) } else { AnyView(content) }
    }
}

private func formatBytes(_ bytes: Int64?) -> String {
    guard let bytes else { return "—" }
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB]
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}

import SwiftUI
import ComposableArchitecture
#if os(iOS)
import PhotosUI
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Editable cover image for the record-detail hero. Always renders a
/// fixed-size squircle: image when set, gradient + initials otherwise.
/// Click opens the file picker; right-click / long-press opens the
/// Replace / Remove context menu.
struct CoverAvatar: View {
    var store: StoreOf<AppFeature>
    var record: RecordRow
    var size: CGFloat = 72

    @State private var hovering = false
    /// Lazily-loaded cover. Stays nil until iCloud Drive has
    /// materialized the underlying file (no-op for local paths). The
    /// view shows the initials/gradient fallback in the meantime,
    /// then swaps in the image once it's available.
    @State private var loadedImage: Image?
    @State private var loadedFor: URL?
    #if os(macOS)
    @State private var fileImporterOpen = false
    #else
    @State private var photoPickerOpen = false
    @State private var photoSelection: PhotosPickerItem?
    #endif

    private var corner: CGFloat { size * 0.22 } // Apple-squircle proportion

    var body: some View {
        Button(action: presentPicker) {
            ZStack {
                imageOrFallback

                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(KstColor.ink4.opacity(0.4), lineWidth: 0.5)

                if hovering {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(.black.opacity(0.35))
                    Image(systemName: "camera")
                        .font(.system(size: max(14, size * 0.28), weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .fixedSize()
        .onHover { hovering = $0 }
        .contextMenu {
            Button(record.coverAssetID == nil ? "Choose photo…" : "Replace photo…") {
                presentPicker()
            }
            if record.coverAssetID != nil {
                Button("Remove photo", role: .destructive) {
                    store.send(.clearCoverImage(recordID: record.id))
                }
            }
        }
        #if os(macOS)
        .fileImporter(
            isPresented: $fileImporterOpen,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            store.send(.setCoverImage(recordID: record.id, fileURL: url))
        }
        #else
        .photosPicker(isPresented: $photoPickerOpen, selection: $photoSelection, matching: .images)
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            Task { await ingest(photoItem: item) }
        }
        #endif
    }

    @ViewBuilder
    private var imageOrFallback: some View {
        Group {
            if let img = loadedImage {
                img
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(LinearGradient(
                        colors: [record.tone.base, record.tone.ink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: size, height: size)
                    .overlay {
                        Text(record.glyph)
                            .font(.kstDisplay(size: max(14, size * 0.40), weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .task(id: record.coverImageURL) {
            await loadCoverIfNeeded()
        }
    }

    /// Resolve the record's cover image asynchronously so iCloud Drive
    /// placeholders can be materialized before the bytes are read. The
    /// synchronous `LocalImage.load` path returns nil for placeholders,
    /// which made covers stay invisible on iPhone (where every cover is
    /// always a placeholder until it's been opened once).
    private func loadCoverIfNeeded() async {
        let url = record.coverImageURL
        if loadedFor == url, loadedImage != nil { return }
        guard let url else {
            loadedImage = nil
            loadedFor = nil
            return
        }
        // `awaitMaterialization` is a no-op for non-iCloud paths and
        // returns immediately when the file is already local — so this
        // is free on macOS-imported workspaces and only does real work
        // on the first iPhone read of each cover.
        guard await UbiquityFile.awaitMaterialization(url) else {
            return  // Timed out; next .task fire (re-render) retries.
        }
        let img = LocalImage.load(url)
        loadedImage = img
        loadedFor = url
    }

    private func presentPicker() {
        #if os(macOS)
        fileImporterOpen = true
        #else
        photoPickerOpen = true
        #endif
    }

    #if os(iOS)
    private func ingest(photoItem: PhotosPickerItem) async {
        guard let data = try? await photoItem.loadTransferable(type: Data.self) else { return }
        let ext = (photoItem.supportedContentTypes.first?.preferredFilenameExtension) ?? "jpg"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: tmp)
            store.send(.setCoverImage(recordID: record.id, fileURL: tmp))
        } catch {}
        photoSelection = nil
    }
    #endif
}

/// Synchronous local-file image loader. AsyncImage is intended for remote
/// URLs; for our `Assets/` files it adds layout indeterminacy and can leak
/// the loaded image's natural size into the parent before the frame clamp
/// applies.
enum LocalImage {
    static func load(_ url: URL) -> Image? {
        guard url.isFileURL else { return nil }
        #if canImport(AppKit)
        if let ns = NSImage(contentsOf: url) {
            return Image(nsImage: ns)
        }
        #elseif canImport(UIKit)
        if let data = try? Data(contentsOf: url), let ui = UIImage(data: data) {
            return Image(uiImage: ui)
        }
        #endif
        return nil
    }
}

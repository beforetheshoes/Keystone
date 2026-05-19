#if os(macOS)
import SwiftUI
import AppKit
import ComposableArchitecture

/// AppKit-backed gallery for macOS. Replaces SwiftUI's `LazyVStack`
/// path inside `GalleryView` when running on the Mac, because SwiftUI's
/// container layout engine could not render a populated (271-card)
/// gallery without 60+ second main-thread freezes — confirmed across
/// multiple Time Profiler traces in both Debug and Release builds.
///
/// Design follows the documented pattern in axiom-macos/skills/
/// appkit-interop.md:
///
/// - One `NSHostingView<GalleryCard>` per `NSCollectionViewItem`,
///   created ONCE in `viewDidLoad` and reused via `rootView =
///   newCard`. Per the skill: "Each `NSHostingView` creates a full
///   SwiftUI view hierarchy. Rebuilding on every cell reuse causes
///   jank during scrolling. Instead, create the hosting view once and
///   update its `rootView` property."
/// - `NSHostingView.sizingOptions = []` so the host view's intrinsic
///   sizing doesn't fight the collection view's compositional layout
///   (which owns sizing).
/// - Coordinator is `NSCollectionViewDataSource` +
///   `NSCollectionViewDelegate`, holding a sectioned diffable data
///   source. Section identifier = `RecordGroup.key`; item identifier =
///   `RecordRow.id`. Snapshot updates animate incrementally instead
///   of full-reloading.
/// - `NSCollectionViewCompositionalLayout` with computed column count
///   from the layout environment's effective width. Cell height is
///   `cellWidth * 1.5` (2:3 cover) plus a fixed text-row reserve.
/// - Section headers via supplementary views, hosted in their own
///   reusable `NSHostingView<GroupSectionHeader>`. Only emitted for
///   sections with non-empty labels (the no-grouping case has a
///   single section with empty label and gets no header).
/// - Context menu via `menu(for:)` override on the collection-view
///   subclass — single menu attached at the grid level, item is
///   identified via hit-testing. This is what replaces the
///   per-card `.contextMenu` modifier that was contributing 542
///   eager `Button` views to every layout pass in the SwiftUI version.
struct MacGalleryCollectionView: NSViewRepresentable {
    let db: DBRow
    let properties: [PropertyRow]
    let buckets: [RecordGroup]
    let coverSize: GalleryCoverSize
    let statusProperty: PropertyRow?
    let metaByRecordID: [String: PropertyMetaContent]
    let store: StoreOf<AppFeature>?
    let onOpen: (RecordRow) -> Void

    private let horizontalPadding: CGFloat = 20
    private let interItemSpacing: CGFloat = 14
    private let interRowSpacing: CGFloat = 14

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let collectionView = GalleryNSCollectionView()
        collectionView.collectionViewLayout = makeLayout(coordinator: context.coordinator)
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        // The wrapping NSScrollView's documentView handles its own
        // background; collection view itself stays transparent so the
        // SwiftUI `.background(KstColor.paper0)` modifier paints
        // through.

        collectionView.register(
            GalleryItemView.self,
            forItemWithIdentifier: GalleryItemView.reuseIdentifier
        )
        collectionView.register(
            SectionHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: SectionHeaderView.reuseIdentifier
        )

        // Diffable data source — section key + record id, both String.
        let dataSource = NSCollectionViewDiffableDataSource<String, String>(
            collectionView: collectionView
        ) { [weak coordinator = context.coordinator] cv, indexPath, itemID in
            let item = cv.makeItem(
                withIdentifier: GalleryItemView.reuseIdentifier,
                for: indexPath
            ) as! GalleryItemView
            guard let coordinator,
                  let record = coordinator.recordsByID[itemID] else {
                return item
            }
            item.configure(
                db: coordinator.parent.db,
                properties: coordinator.parent.properties,
                record: record,
                statusProperty: coordinator.parent.statusProperty,
                coverSize: coordinator.parent.coverSize,
                meta: coordinator.parent.metaByRecordID[record.id] ?? .empty,
                store: coordinator.parent.store,
                onOpen: coordinator.parent.onOpen
            )
            return item
        }
        dataSource.supplementaryViewProvider = { [weak coordinator = context.coordinator] cv, kind, indexPath in
            guard kind == NSCollectionView.elementKindSectionHeader,
                  let coordinator else { return nil }
            let view = cv.makeSupplementaryView(
                ofKind: kind,
                withIdentifier: SectionHeaderView.reuseIdentifier,
                for: indexPath
            ) as! SectionHeaderView
            let sectionID = coordinator.dataSource
                .snapshot()
                .sectionIdentifiers[indexPath.section]
            let label = coordinator.groupLabelByKey[sectionID] ?? ""
            let count = coordinator.dataSource
                .snapshot()
                .numberOfItems(inSection: sectionID)
            view.configure(label: label, count: count)
            return view
        }

        context.coordinator.dataSource = dataSource
        context.coordinator.collectionView = collectionView
        collectionView.delegate = context.coordinator
        collectionView.contextMenuProvider = { [weak coordinator = context.coordinator] indexPath in
            coordinator?.menu(forItemAt: indexPath)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        // Initial snapshot. We pass the buckets through the coordinator
        // so subsequent `updateNSView` calls take the same path —
        // refreshing the parent reference and re-applying the snapshot
        // diff.
        context.coordinator.parent = self
        context.coordinator.applySnapshot(buckets: buckets)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // The skill's rule: refresh the coordinator's parent reference
        // on every update so bindings (here: `onOpen`, `store`) stay
        // current. Stale parent = stale closures = action dispatches
        // landing in the wrong place. The layout closure reads
        // `coverSize` through this reference, so once `parent` is
        // updated, the next layout pass sees the new size.
        let oldCoverSize = context.coordinator.parent.coverSize
        context.coordinator.parent = self
        context.coordinator.applySnapshot(buckets: buckets)

        // When the user picks a different cover-size preset (small /
        // medium / large), the section provider needs to recompute
        // column count and cell dimensions. Invalidate the layout to
        // force the section provider closure to re-run with the new
        // `coverSize`. Only invalidate when the size actually changed
        // — invalidating on every reducer update would force an
        // unnecessary re-layout pass per CloudKit tick.
        if oldCoverSize != coverSize,
           let collectionView = context.coordinator.collectionView {
            collectionView.collectionViewLayout?.invalidateLayout()
        }
    }

    // MARK: - Layout

    private func makeLayout(coordinator: Coordinator) -> NSCollectionViewCompositionalLayout {
        // The padding/spacing constants are `let` on the struct so
        // capturing them by value is safe. `coverSize` is a *prop*
        // that changes when the user picks a different gallery size
        // preset — capturing its value here would freeze the layout
        // to whatever size was active when the view was first created.
        // Instead the closure reads `coordinator.parent.coverSize`,
        // which is refreshed on every `updateNSView`, and the layout
        // is explicitly invalidated when `coverSize` changes (see
        // `updateNSView`).
        let layoutHorizontalPadding = horizontalPadding
        let layoutInterItemSpacing = interItemSpacing
        let layoutInterRowSpacing = interRowSpacing
        return NSCollectionViewCompositionalLayout { [weak coordinator] sectionIndex, env in
            let currentCoverSize = coordinator?.parent.coverSize ?? .medium
            let containerWidth = env.container.effectiveContentSize.width
            let usable = max(0, containerWidth - layoutHorizontalPadding * 2)
            // Match the SwiftUI path's column-count formula so resize
            // behavior is identical between the two implementations.
            let perColumn = currentCoverSize.minimumColumnWidth + layoutInterItemSpacing
            let columnCount = max(1, Int(usable / perColumn))
            let itemWidth = (usable - CGFloat(columnCount - 1) * layoutInterItemSpacing) / CGFloat(columnCount)
            // 2:3 cover (height = width * 1.5) plus reserved text-row
            // space. The text block reserves 2 lines of title (~40pt)
            // and 1 line of meta (~20pt) plus 24pt of padding =
            // ~84pt. Round to 88 for breathing room.
            let textReserve: CGFloat = 88
            let itemHeight = ceil(itemWidth * 1.5) + textReserve

            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0 / CGFloat(columnCount)),
                heightDimension: .absolute(itemHeight)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)

            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .absolute(itemHeight)
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: groupSize,
                subitem: item,
                count: columnCount
            )
            group.interItemSpacing = .fixed(layoutInterItemSpacing)

            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = layoutInterRowSpacing
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0,
                leading: layoutHorizontalPadding,
                bottom: 18,
                trailing: layoutHorizontalPadding
            )

            // Section header is only emitted for sections that have
            // a non-empty label. The single-section "no grouping"
            // case has an empty label and gets no header.
            let sectionID = coordinator?.dataSource
                .snapshot()
                .sectionIdentifiers[safe: sectionIndex]
            let label = sectionID.flatMap { coordinator?.groupLabelByKey[$0] } ?? ""
            if !label.isEmpty {
                let headerSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(28)
                )
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: headerSize,
                    elementKind: NSCollectionView.elementKindSectionHeader,
                    alignment: .top
                )
                section.contentInsets.top = 12
                section.boundarySupplementaryItems = [header]
            }

            return section
        }
    }

    // MARK: - Coordinator

    /// Holds the data source, the lookup tables (id → record, key →
    /// section label), and the click/right-click handlers.
    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate {
        fileprivate var parent: MacGalleryCollectionView
        fileprivate var dataSource: NSCollectionViewDiffableDataSource<String, String>!
        fileprivate weak var collectionView: NSCollectionView?

        /// Lookup: `RecordRow.id → RecordRow`. Refreshed on every
        /// `applySnapshot` so cell-configuration callbacks have the
        /// current record object even across reorderings.
        fileprivate var recordsByID: [String: RecordRow] = [:]
        /// Lookup: `RecordGroup.key → label`. Used by both the
        /// supplementary-view provider and the compositional layout's
        /// section provider to decide whether to emit a header.
        fileprivate var groupLabelByKey: [String: String] = [:]

        init(parent: MacGalleryCollectionView) {
            self.parent = parent
        }

        /// Refresh the lookup tables from the latest buckets, then
        /// apply a diffable snapshot. Items added/removed/reordered
        /// flow through as incremental updates, not full reloads.
        fileprivate func applySnapshot(buckets: [RecordGroup]) {
            recordsByID = Dictionary(
                uniqueKeysWithValues: buckets.flatMap { bucket in
                    bucket.rows.map { ($0.id, $0) }
                }
            )
            // RecordGroup.key may repeat across buckets in the no-
            // grouping case (single ungrouped bucket) — but with one
            // bucket there's no collision. With grouping each
            // bucket has a unique key by construction.
            groupLabelByKey = Dictionary(
                uniqueKeysWithValues: buckets.map { ($0.key, $0.label) }
            )

            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            for bucket in buckets {
                snapshot.appendSections([bucket.key])
                snapshot.appendItems(bucket.rows.map(\.id), toSection: bucket.key)
            }
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        // MARK: NSCollectionViewDelegate

        func collectionView(
            _ collectionView: NSCollectionView,
            didSelectItemsAt indexPaths: Set<IndexPath>
        ) {
            guard let indexPath = indexPaths.first,
                  let id = dataSource.itemIdentifier(for: indexPath),
                  let record = recordsByID[id] else { return }
            parent.onOpen(record)
            // Single-shot — clear selection so re-tapping the same
            // record still fires `onOpen`.
            collectionView.deselectItems(at: indexPaths)
        }

        // MARK: Context menu

        fileprivate func menu(forItemAt indexPath: IndexPath) -> NSMenu? {
            guard let id = dataSource.itemIdentifier(for: indexPath),
                  let record = recordsByID[id],
                  let store = parent.store else { return nil }
            let db = parent.db

            let menu = NSMenu()
            if !CoverProviderRegistry.providers(for: db.id).isEmpty {
                let mi = NSMenuItem(title: "Search covers…", action: #selector(searchCoversAction(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = MenuPayload(
                    action: .searchCovers,
                    record: record,
                    db: db,
                    store: store
                )
                menu.addItem(mi)
            }
            if LookupRegistry.provider(for: db.id) != nil {
                let mi = NSMenuItem(title: "Re-enrich…", action: #selector(reenrichAction(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = MenuPayload(
                    action: .reenrich,
                    record: record,
                    db: db,
                    store: store
                )
                menu.addItem(mi)
            }
            return menu.items.isEmpty ? nil : menu
        }

        // Menu payload: NSMenuItem.representedObject is `Any?`, so we
        // bundle the per-click context into a small reference type
        // and dispatch from the `@objc` action method below.
        private final class MenuPayload {
            enum Kind { case searchCovers, reenrich }
            let action: Kind
            let record: RecordRow
            let db: DBRow
            let store: StoreOf<AppFeature>
            init(action: Kind, record: RecordRow, db: DBRow, store: StoreOf<AppFeature>) {
                self.action = action
                self.record = record
                self.db = db
                self.store = store
            }
        }

        @objc private func searchCoversAction(_ sender: NSMenuItem) {
            guard let p = sender.representedObject as? MenuPayload else { return }
            p.store.send(.openCoverPicker(
                databaseID: p.db.id,
                recordID: p.record.id,
                currentTitle: p.record.title
            ))
        }

        @objc private func reenrichAction(_ sender: NSMenuItem) {
            guard let p = sender.representedObject as? MenuPayload else { return }
            p.store.send(.openReenrichLookup(
                databaseID: p.db.id,
                databaseName: p.db.name,
                recordID: p.record.id,
                currentTitle: p.record.title
            ))
        }
    }
}

// MARK: - Custom NSCollectionView

/// Subclass exists for two reasons:
/// 1. Override `menu(for:)` so right-click on a cell produces the
///    context menu without needing a per-cell NSMenu. The
///    `contextMenuProvider` closure (set by the wrapper) returns the
///    menu for a given indexPath.
/// 2. Suppress the focus ring around the whole collection view.
private final class GalleryNSCollectionView: NSCollectionView {
    var contextMenuProvider: ((IndexPath) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let pointInView = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: pointInView) else {
            return super.menu(for: event)
        }
        return contextMenuProvider?(indexPath) ?? super.menu(for: event)
    }
}

// MARK: - Item view

/// Hosts a single `GalleryCard` inside an `NSHostingView`. The hosting
/// view is created exactly once in `loadView` and is reused for every
/// record that comes through `configure(...)` — per the skill's
/// performance contract, the SwiftUI view hierarchy is diffed
/// internally instead of being torn down and rebuilt on cell reuse.
final class GalleryItemView: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("GalleryItem")

    private var hostingView: NSHostingView<GalleryCard>?

    override func loadView() {
        // Override `loadView` (not `viewDidLoad`) so we can construct
        // the view without a nib. Default `NSCollectionViewItem`
        // implementation looks for a nib named after the class, which
        // we don't ship.
        view = NSView()
        view.wantsLayer = true
    }

    func configure(
        db: DBRow,
        properties: [PropertyRow],
        record: RecordRow,
        statusProperty: PropertyRow?,
        coverSize: GalleryCoverSize,
        meta: PropertyMetaContent,
        store: StoreOf<AppFeature>?,
        onOpen: @escaping (RecordRow) -> Void
    ) {
        let card = GalleryCard(
            db: db,
            properties: properties,
            record: record,
            statusProperty: statusProperty,
            coverSize: coverSize,
            meta: meta,
            store: store,
            onTap: { onOpen(record) }
        )

        if let hostingView {
            hostingView.rootView = card
        } else {
            let h = NSHostingView(rootView: card)
            // Disable NSHostingView's auto-sizing constraints — the
            // collection view's compositional layout owns sizing.
            // Per the skill: "Disable constraints you don't need for
            // performance or when surrounding AppKit views already
            // handle layout."
            h.sizingOptions = []
            h.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(h)
            NSLayoutConstraint.activate([
                h.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                h.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                h.topAnchor.constraint(equalTo: view.topAnchor),
                h.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            hostingView = h
        }
    }
}

// MARK: - Section header view

/// Hosts `GroupSectionHeader` (the same SwiftUI view the iOS path
/// uses) inside an `NSHostingView` for each non-empty section. Reused
/// across section recycling via `rootView` updates, same as
/// `GalleryItemView`.
final class SectionHeaderView: NSView, NSCollectionViewElement {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SectionHeader")

    private var hostingView: NSHostingView<GroupSectionHeader>?

    func configure(label: String, count: Int) {
        let header = GroupSectionHeader(label: label, count: count)
        if let hostingView {
            hostingView.rootView = header
        } else {
            let h = NSHostingView(rootView: header)
            h.sizingOptions = []
            h.translatesAutoresizingMaskIntoConstraints = false
            addSubview(h)
            NSLayoutConstraint.activate([
                h.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                h.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
                h.topAnchor.constraint(equalTo: topAnchor),
                h.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            hostingView = h
        }
    }
}

// MARK: - Helpers

private extension Array {
    /// Safe index-or-nil subscript — used by the layout's section
    /// provider, which is sometimes called with an index slightly
    /// out of sync with the data source during reload transitions.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif

import SwiftUI
import ComposableArchitecture

struct DatabaseDetailView: View {
    @Bindable var store: StoreOf<AppFeature>
    /// Header/breadcrumb-source DBRow. When the route is a saved view
    /// (Nav.view), the caller passes a synthesized DBRow built from
    /// the view (id = view.id, name/icon = view's). Record-level actions
    /// have to use the *backing* database id — `effectiveDatabaseID`
    /// resolves that uniformly via the store's currentView slot.
    var db: DBRow

    @State private var deleteAllConfirming: Bool = false

    /// Backing database id for record reads/writes. Equals `db.id` for
    /// the plain database route, and `currentView.databaseID` when the
    /// active route is a saved view (so e.g. tapping a row in the
    /// Restaurants view navigates to a record in `vendors`, not in the
    /// non-existent `view-restaurants`).
    private var effectiveDatabaseID: String {
        store.currentView?.databaseID ?? db.id
    }

    /// Whether the active route is a saved view rather than a real
    /// database. Used to hide affordances (Delete all…) that don't make
    /// sense on a filtered presentation.
    private var isViewRoute: Bool { store.currentView != nil }

    /// True when an EnrichmentProvider is registered for the active
    /// (backing) database. Gates the "Re-enrich all visible…" menu
    /// item so it doesn't appear on databases that have no providers
    /// (e.g. Trips, Maintenance) where it'd be a no-op.
    private var hasRegisteredEnrichmentProvider: Bool {
        let key = store.currentView?.databaseID ?? db.id
        return EnrichmentService.registry.contains { $0.databaseKey == key }
    }

    /// Records still being enriched by an in-flight bulk pass, scoped
    /// to the currently-visible record set. Drives the inline
    /// "Enriching X of Y…" progress label.
    private var bulkEnrichingCount: Int {
        let visible = Set(store.derivedRecords.filteredSorted.map(\.id))
        return store.enrichingRecordIDs.intersection(visible).count
    }

    /// Show the Calendar item in the view switcher only when the
    /// database has a column the calendar can plot against.
    private var hasDateProperty: Bool {
        store.currentProperties.contains { $0.type == .date || $0.type == .dateTZ }
    }

    /// Properties to show in list/table columns. In view mode, only the
    /// view's pinned kind's columns + universal columns. In plain mode,
    /// universal columns only (kind-scoped columns hide from the
    /// generic table — visit the view to see them).
    private var visibleProperties: [PropertyRow] {
        let pinnedKind = store.currentView?.pinnedKind
        return store.currentProperties.filter { p in
            guard p.isVisible(forKind: pinnedKind) else { return false }
            if pinnedKind != nil, p.key == "kind" { return false }
            return true
        }
    }

    /// Records as they should appear in any view kind — already
    /// filtered + sorted by the off-MainActor `recomputeDerived` effect
    /// in `AppFeature`. The previous in-view `FilterEngine.apply` +
    /// `SortEngine.apply` per-body recompute was the proximate cause of
    /// the 24-second `LazyStack.place(subviews:...)` cascade observed
    /// during CloudKit sync; reading the pre-computed snapshot collapses
    /// that to a pointer copy.
    private var displayedRecords: [RecordRow] {
        store.derivedRecords.filteredSorted
    }

    /// Count of protected records currently hidden anywhere in the
    /// workspace (literal seed minus the per-session unlock allow-list).
    /// The cascade may add more, but the seed count is what the user
    /// actually flagged — surfacing it directly avoids "you have 7
    /// protected records" when only 1 is flagged + 6 are dependents.
    private var lockedCount: Int {
        store.protectedSeedIDs.subtracting(store.unlockedRecordIDs).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KstToolbar(breadcrumb: [db.name]) {
                ViewSwitcher(
                    selected: store.viewKind,
                    showsCalendar: hasDateProperty
                ) { store.send(.setViewKind($0)) }
                SortMenu(
                    properties: visibleProperties,
                    sortKey: store.sortKey,
                    sortAscending: store.sortAscending,
                    onSort: { store.send(.toggleSort($0)) },
                    onSetAscending: { _ in
                        // The reducer's `toggleSort` toggles direction
                        // when re-clicking the same key — so calling
                        // it again on the current key flips ascending.
                        if let key = store.sortKey {
                            store.send(.toggleSort(key))
                        }
                    },
                    onClear: {
                        if let key = store.sortKey {
                            // toggleSort cycles asc → desc → nil for a
                            // single key. Send one toggle when already
                            // descending, two when ascending.
                            if store.sortAscending {
                                store.send(.toggleSort(key))
                            }
                            store.send(.toggleSort(key))
                        }
                    }
                )
                GroupMenu(
                    properties: visibleProperties,
                    groupKey: store.groupKey,
                    setGroupKey: { store.send(.setGroupKey($0)) }
                )
                // Column visibility picker — only meaningful in the
                // table view (other views select their own subset of
                // properties to render). Skip it on gallery/list/etc.
                if store.viewKind == .table {
                    ColumnsMenu(
                        properties: visibleProperties,
                        hidden: store.hiddenColumns,
                        toggle: { key, hidden in
                            store.send(.setColumnHidden(key: key, hidden: hidden))
                        }
                    )
                }
                if store.viewKind == .gallery {
                    GallerySizeControl(
                        size: store.galleryCoverSize,
                        onChange: { store.send(.setGalleryCoverSize($0)) }
                    )
                }
                KstButton(style: .primary, action: {
                    store.send(.openLookup(databaseID: db.id, databaseName: db.name))
                }) {
                    Text("+ New")
                }
                Menu {
                    // Bulk Re-enrich — only meaningful when the
                    // active database (or view's backing database)
                    // actually has an EnrichmentProvider registered.
                    if hasRegisteredEnrichmentProvider {
                        Button("Re-enrich all visible…") {
                            store.send(.reenrichAllVisibleRecords)
                        }
                        .disabled(store.derivedRecords.filteredSorted.isEmpty)
                        Divider()
                    }
                    Button("Delete all records…", role: .destructive) {
                        deleteAllConfirming = true
                    }
                    // Hide bulk delete on the view route — the action
                    // would have to delete every backing-database
                    // record (e.g. every Vendor), not just the ones
                    // currently visible through the view's filter.
                    // Until we model that explicitly, the only "delete
                    // all" affordance lives on the underlying database
                    // page.
                    .disabled(store.currentRecords.isEmpty || isViewRoute)
                } label: {
                    Text("⋯")
                }
                #if os(macOS)
                .menuStyle(.button)
                .buttonStyle(.plain)
                .frame(height: 26).padding(.horizontal, 10)
                .background(KstColor.paper0)
                .overlay(
                    RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous)
                        .strokeBorder(KstColor.ink4, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: KstRadius.r2, style: .continuous))
                #endif
            }

            // Subheader: title, count
            HStack(spacing: 10) {
                Glyph(tone: db.accent, text: db.icon, size: 26, radius: 7)
                Text(db.name)
                    .font(.kstDisplay(size: 26, weight: .semibold))
                    .foregroundStyle(KstColor.ink0)
                    .kerning(-0.4)
                if !store.filters.isEmpty {
                    Text("\(displayedRecords.count) of \(store.currentRecords.count)")
                        .font(.kstText(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(KstColor.ink2)
                } else {
                    Text("\(displayedRecords.count)")
                        .font(.kstText(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(KstColor.ink2)
                }
                if bulkEnrichingCount > 0 {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Enriching \(bulkEnrichingCount) of \(displayedRecords.count)…")
                            .font(.kstText(size: 12, weight: .medium))
                            .foregroundStyle(KstColor.ink2)
                            .monospacedDigit()
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .background(KstColor.paper0)
            .overlay(alignment: .bottom) { KstHairline() }

            // Filter bar applies in every view kind — gallery, list,
            // and dashboard render `displayedRecords` (filtered + sorted)
            // so user-added filter chips narrow them just like in table.
            FilterBar(
                store: store,
                properties: visibleProperties,
                unfilteredRecords: store.currentRecords
            )

            switch store.viewKind {
            case .table:    TableView(
                db: db,
                properties: visibleProperties.filter { !store.hiddenColumns.contains($0.key) },
                records: displayedRecords,
                groups: GroupEngine.group(displayedRecords, key: store.groupKey, properties: visibleProperties),
                sortKey: store.sortKey,
                sortAscending: store.sortAscending,
                onOpen: { rec in store.send(.setNav(.record(databaseID: effectiveDatabaseID, recordID: rec.id))) },
                onSort: { store.send(.toggleSort($0)) },
                onOpenRelation: { targetDB, targetID in store.send(.setNav(.record(databaseID: targetDB, recordID: targetID))) },
                onSetAlignment: { propertyID, alignment in
                    store.send(.setColumnAlignment(propertyID: propertyID, alignment: alignment))
                },
                onUpdateValue: { recordID, key, value in
                    store.send(.updatePropertyValue(recordID: recordID, key: key, value: value))
                },
                onAddPropertyOption: { propertyID, option in
                    store.send(.addPropertyOption(propertyID: propertyID, option: option))
                },
                onRemovePropertyOption: { propertyID, option in
                    store.send(.removePropertyOption(propertyID: propertyID, option: option))
                }
            )
            case .gallery:  GalleryView(
                db: db,
                properties: visibleProperties,
                records: displayedRecords,
                groups: GroupEngine.group(displayedRecords, key: store.groupKey, properties: visibleProperties),
                coverSize: store.galleryCoverSize,
                onOpen: { rec in store.send(.setNav(.record(databaseID: effectiveDatabaseID, recordID: rec.id))) },
                store: store
            )
            case .list:     ListView(
                db: db,
                properties: visibleProperties,
                records: displayedRecords,
                groups: GroupEngine.group(displayedRecords, key: store.groupKey, properties: visibleProperties)
            ) { rec in store.send(.setNav(.record(databaseID: effectiveDatabaseID, recordID: rec.id))) }
            case .dashboard: DashboardView(store: store, db: db, properties: visibleProperties, records: displayedRecords)
            case .calendar: CalendarView(
                db: db,
                properties: visibleProperties,
                records: displayedRecords,
                onOpen: { rec in store.send(.setNav(.record(databaseID: effectiveDatabaseID, recordID: rec.id))) }
            )
            default:
                Text("View not available")
                    .font(.kstText(size: 14))
                    .foregroundStyle(KstColor.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(KstColor.paper0)
            }

            // Privacy footer — appears whenever the workspace has any
            // currently-locked protected records (set ⇒ at least one
            // record is hidden somewhere). Tapping prompts for biometric
            // auth and unlocks every protected record for the session.
            // Workspace-wide rather than per-database for v1; the cascade
            // already crosses database boundaries (a protected trip
            // hides its activities from another database), so per-DB
            // counts would mislead.
            if lockedCount > 0 {
                ProtectedFooter(
                    lockedCount: lockedCount,
                    inFlight: store.authInFlight
                ) {
                    store.send(.unlockAllProtectedRequested)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KstColor.paper0)
        .confirmationDialog(
            "Delete all records in \(db.name)?",
            isPresented: $deleteAllConfirming,
            titleVisibility: .visible
        ) {
            Button("Delete \(store.currentRecords.count) record\(store.currentRecords.count == 1 ? "" : "s")", role: .destructive) {
                store.send(.deleteAllRecordsInDatabase(databaseID: db.id))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every record (including attached files) and can't be undone.")
        }
    }

}

/// Bottom-of-view button + label combo that surfaces protected-record
/// state. Lives in the database-detail layout so anywhere the user
/// browses records, the "show me what's hidden" affordance is one tap
/// away.
private struct ProtectedFooter: View {
    var lockedCount: Int
    var inFlight: Bool
    var onUnlock: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(KstColor.ink3)
            Text("\(lockedCount) protected record\(lockedCount == 1 ? "" : "s") hidden")
                .font(.kstText(size: 12))
                .foregroundStyle(KstColor.ink2)
            Spacer(minLength: 0)
            Button(action: onUnlock) {
                HStack(spacing: 6) {
                    if inFlight {
                        ProgressView().controlSize(.mini)
                    }
                    Text("Show all")
                        .font(.kstText(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(inFlight)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(KstColor.paper1)
        .overlay(alignment: .top) { KstHairline() }
    }
}

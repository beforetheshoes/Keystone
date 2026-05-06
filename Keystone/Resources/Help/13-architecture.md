# Architecture

For the curious. Skip this page unless you want to know how the sausage is made.

## Storage

Everything user-visible lives in **SQLite**. The database file is `~/Library/Containers/com.ryanleewilliams.keystone/Data/Library/Application Support/Keystone/workspace.sqlite`. Tables include `workspaces`, `areas`, `databases`, `properties`, `records`, `property_values`, `blocks`, `tags`, `record_tags`, `relations`, `assets`, `views`.

We use [GRDB](https://github.com/groue/GRDB.swift) for low-level access and Point-Free's [sqlite-data](https://github.com/pointfreeco/sqlite-data) for the CloudKit sync engine. Plain raw-SQL reads via `Row.fetchAll(db, sql:)` coexist with `@Table`-decorated structs that the sync engine uses to mirror rows to CloudKit.

## State management

The app is built with [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) (TCA). One `AppFeature` reducer owns navigation, overlays, and per-record loaded state. Side effects (database reads / writes, CloudKit sync) run inside `.run` effects via the `DatabaseClient` and `SyncEngineClient` dependencies.

## Cross-platform

The same code runs on macOS, iPhone, and iPadOS. The TCA reducer, persistence layer, and every feature view are 100% shared. Only the top-level chrome differs:

- **macOS** — `HStack`-based three-pane layout with a fixed warm-paper sidebar (`AppView.macLayout`).
- **iPad** — `NavigationSplitView` with sidebar + detail (`iPadShell`). Re-uses the macOS-style detail views (`HomeView`, `DatabaseDetailView`, `RecordDetailView`, etc.) since iPad has the screen real estate.
- **iPhone** — Custom 5-tab `TabView` (`iPhoneTabsView`) with bespoke iPhone-styled views: `iPhoneHomeView` (THIS WEEK + DATABASES grid + FAMILY list), `iPhoneBrowseView` (full database + tag list), `iPhoneRecordDetail` (centered avatar hero + Call/Message/Email action row + grouped properties + RELATED), `iPhoneSearchView` (Command Palette wrapper), `iPhoneProfileView` (sync + Help + about). The middle `+` tab intercepts selection to present Quick Capture.

The platform switch happens in `IOSShell` (size-class adaptive — regular size class lands on `iPadShell`, compact on `iPhoneTabsView`). `AppView` chooses between macOS layout and `IOSShell` via `#if os(macOS)`.

AppKit-only calls (NSWorkspace, NSImage, NSOpenPanel) are wrapped in `#if canImport(AppKit)` and have UIKit equivalents. File picking uses SwiftUI's cross-platform `.fileImporter` modifier.

## Block storage

Blocks store their content as `AttributedString` JSON-encoded into the `content_json` column. We use Foundation's default Markdown parsing scope, so inline bold/italic/strikethrough/links/code survive serialization without custom encoders. Block kind (paragraph, heading, bullet, etc.) lives in the `type` column; the editor maps each kind to a SwiftUI rendering.

## Sync

When enabled, sqlite-data's `SyncEngine` mirrors every registered table to a private CloudKit zone. Insert/update/delete on a row is replayed across devices last-write-wins. The `SyncEngineClient` TCA dependency wraps lifecycle (start/stop) and an observation `AsyncStream` of running/sending/fetching state, which the sidebar badge subscribes to.

## File assets

Assets are stored as files in `Assets/<uuid>.<ext>` next to the SQLite file. The database row holds the original filename, stored filename, relative path, MIME type, byte size, and SHA-256 content hash. Thumbnails are generated on demand via `QLThumbnailGenerator` with an in-memory mtime-keyed cache.

## No lock-in

You can SQL-query your workspace directly with `sqlite3 workspace.sqlite`. You can `cp -r Keystone/` to back up everything. You can decode every block by running its `content_json` through `JSONDecoder().decode(AttributedString.self, ...)`. The data is yours; the schema is open.

## Code layout

```
Keystone/
  App/                      KeystoneApp + commands
  Core/                     IDs, enums, value types
  Design/                   Color tokens, typography, glyph, logo
  Persistence/              Schema, migrations, reads/writes, sync
  Features/
    Sidebar/                Nav rail
    Home/                   Dashboard
    Database/               Table / Gallery / List / Dashboard views
    Detail/                 Record detail
    Editor/                 Block editor
    Tags/                   Tag UI
    Assets/                 File attachments + thumbnails
    Help/                   This Help section
    Palette/                ⌘K / ⌘N overlays
KeystoneTests/              Schema + smoke tests
```

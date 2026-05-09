# Keystone

Apple-native, local-first, Notion-like life management and knowledge system.

Written in SwiftUI with The Composable Architecture and SQLiteData (GRDB-backed). Ships as a single multi-platform target — same codebase runs on macOS and iOS / iPadOS, with iPhone-specific shells where the layout differs meaningfully.

This project was written with the assistance of Claude Code.

## Getting started

Requires Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open Keystone.xcodeproj
```

The macOS scheme builds and runs out of the box. On first launch the app creates `~/Library/Containers/com.ryanleewilliams.keystone/Data/Library/Application Support/Keystone/workspace.sqlite` and seeds it with sample records.

### Build / test from CLI

```bash
xcodebuild -project Keystone.xcodeproj -scheme Keystone -destination 'platform=macOS' build
xcodebuild -project Keystone.xcodeproj -scheme Keystone -destination 'platform=macOS' test
```

### Headless `--cli` mode

The compiled `Keystone.app` binary has two personas: launching it normally
brings up the SwiftUI app; passing `--cli <command> [args]` runs a headless
CLI against the same workspace database without ever showing a window.

```bash
BIN=~/Library/Developer/Xcode/DerivedData/Keystone-*/Build/Products/Debug/Keystone.app/Contents/MacOS/Keystone

"$BIN" --cli help                       # full command list
"$BIN" --cli list-databases              # JSON array of databases
"$BIN" --cli list-records vendors        # JSON array of records (filtered client-side)
"$BIN" --cli get-record <recordID>       # full record incl. props/blocks/assets/relations
"$BIN" --cli set-property <recordID> <key> <value>
"$BIN" --cli sql "SELECT COUNT(*) FROM records"   # raw SQL escape hatch
"$BIN" --cli enrich-all-vendors          # batch MapKit lookup for vendors w/o a place_id
"$BIN" --cli promote-relations           # promote text-fallback relation values to real links
```

Output is JSON to stdout; errors go to stderr with exit 1.

**Why a `--cli` flag and not a separate target?** The CLI shares the
GUI's iCloud entitlement, code-signing identity, and sandbox container
so it can read/write the live `workspace.sqlite` even while the GUI is
running. A standalone target would need duplicated entitlements and
would see a different sandbox — no shared data. The `@main KeystoneEntry`
struct in [`Keystone/App/KeystoneApp.swift`](Keystone/App/KeystoneApp.swift)
inspects `CommandLine.arguments` before SwiftUI's `App.main()` runs and
dispatches to `KeystoneCLI.run(...)` when `--cli` is the first argument.

For convenience, alias it:

```bash
alias keystone="$BIN --cli"
keystone list-databases
```

## Architecture

```
Keystone/
  App/           KeystoneEntry (CLI dispatch) + KeystoneApp + commands
  CLI/           KeystoneCLI — headless `--cli` mode (same binary, no SwiftUI)
  Core/          IDs, enums, value types
  Design/        Color tokens (warm paper + OKLCH accents), typography, glyph, logo, controls
  Persistence/   GRDB schema, migrations, DatabaseClient, seed data,
                 vendor MapKit enrichment service, Inbox watcher/importer
  Features/      TCA reducers + SwiftUI views
    Sidebar/
    Home/
    Database/    Table / Gallery / List / Dashboard, FilterBar
    Detail/      RecordDetailView + vendor lookup sheet + map preview
    Editor/      Block editor (paragraph / heading / list / table / quote / code …)
    Palette/     ⌘K command palette + ⌘N quick capture
    Tags/
    Help/
    iOS/         iPhone-specific shells (NavigationStack-driven)
  Resources/     Assets, Info.plist, entitlements, in-app Help markdown
KeystoneTests/   Smoke tests
project.yml      XcodeGen spec
```

## What's here today

- macOS three-pane shell: warm paper sidebar, life areas, Home dashboard, database views (table / gallery / list / dashboard), record detail with related records / notes / files / activity, ⌘K command palette, ⌘N quick capture
- iPhone-native shell with `NavigationStack`-driven home, database list, search, and record-detail views
- Block editor with rich-text paragraphs, headings, lists, checklists, quotes, code, and **editable Markdown tables** (per-cell `TextField`s, right-click to insert/delete rows + columns)
- **Inbox folder watcher** — drop any file (or a folder of files with frontmatter) into `<workspace>/Inbox/` and it auto-imports as a typed record with the original attached. Recursive subfolder handling for batch imports
- **CloudKit sync** via SQLiteData's `SyncEngine` with row-level metadata triggers; falls back to local-only mode if `SyncEngine.init` fails
- **Vendor enrichment** — vendors auto-link to Apple Maps via the iOS/macOS 26 `PlaceDescriptor` + `MKMapItemRequest` APIs. Confident matches auto-apply phone/website/address/locality/category/Place ID; ambiguous candidates surface in a "Look up on Apple Maps" sheet with a map preview tile and "Open in Maps" handoff on the detail page
- **Filter bar** above tables with type-aware editors (relation multi-pick, date range, select multi-pick, text-contains, number range, checkbox tri-state)
- **Per-column UI persistence** — column alignment overrides save to the property's `config_json` and sync via CloudKit; type-aware defaults right-align numbers/currency, center-align select/checkbox, left-align everything else; "cost"/"price"-named `.number` columns format as USD by default
- SQLite schema covering workspaces, areas, databases, properties, records, property values, tags, relations, blocks, assets, views — seeded once on first launch (canonical structural rows only; no demo data)
- Every record has a stable typed ID; UI reads through `DatabaseClient` (TCA dependency)
- Headless `--cli` mode for scripting — see above

## What's next

See the technical design doc (in `.claude/plans/`). Open threads:
- Templates + propagation
- `Workspace.keystone` package format for portable workspaces
- Markdown / JSON / CSV export
- CloudKit-shared workspaces
- Reminders / EventKit integration
- View persistence (filters, sort, hidden columns) on `views.config_json`

# Keystone

Apple-native, local-first, Notion-like life management and knowledge system.

Written in SwiftUI with The Composable Architecture and SQLiteData (GRDB-backed) on macOS. iOS / iPadOS targets are planned.

This project was scaffolded with the assistance of Claude Code.

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

## Architecture

```
Keystone/
  App/           KeystoneApp + commands
  Core/          IDs, enums, value types
  Design/        Color tokens (warm paper + OKLCH accents), typography, glyph, logo, controls
  Persistence/   GRDB schema, migrations, DatabaseClient, seed data
  Features/      TCA reducers + SwiftUI views
    Sidebar/
    Home/
    Database/    Table / Gallery / List / Dashboard
    Detail/
    Palette/     ⌘K command palette + ⌘N quick capture
KeystoneTests/   Smoke tests
project.yml      XcodeGen spec
```

## What's here today

- macOS three-pane shell matching the design prototype: warm paper sidebar, life areas, Home dashboard, database views (table / gallery / list / dashboard), record detail with related records / notes / files / activity, ⌘K command palette, ⌘N quick capture
- SQLite schema covering workspaces, areas, databases, properties, records, property values, tags, relations, views — seeded once on first launch
- Every record has a stable typed ID; UI reads through `DatabaseClient` (TCA dependency)

## What's next

See the technical design doc (in `.claude/plans/`). Build order from there:
- block editor / rich page body
- templates + propagation
- asset import + `Workspace.keystone` package format
- Markdown / JSON / CSV export+import
- CloudKit sync + workspace sharing
- Reminders / EventKit integration
- iOS / iPadOS surface

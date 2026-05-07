# Inbox folder

There's an `Inbox/` subfolder inside your workspace alongside `workspace.sqlite` and `Assets/`. Anything you drop into Inbox gets imported into Keystone as a new **Documents** record with the file attached as the cover.

The whole point: you can add records by saving a file from Finder, the Files app on iPhone/iPad, "Save to iCloud Drive" from any app, etc. — without ever launching Keystone yourself.

## How it works

1. **Drop a file** into `<workspace folder>/Inbox/`. From any device, any app — anywhere that can save to a folder.
2. **Keystone notices** within a second of the next time it's running and the folder change syncs (instant on the device that did the drop, ~seconds for other devices via iCloud Drive).
3. **A new record appears.** By default it lands in **Documents**, but a Markdown file with a `type:` frontmatter line lands in whichever database that names — see below. Title is the frontmatter `title:` if set, otherwise the filename without extension.
4. **The Inbox folder empties.** The original file moves to `Assets/` under a content-hashed name. Empty Inbox = "all imports are processed."

## Setting the type via frontmatter

Drop a Markdown file (`.md` / `.markdown`) whose first lines are a YAML frontmatter block, and Keystone uses it to route the import:

```
---
type: vehicles
title: 2019 Subaru Outback
make: Subaru
model: Outback
year: 2019
plate: ABC-123
---

Anything down here is the body — kept verbatim with the attached source file.
```

- `type:` must match a database id exactly (case-insensitive). The seeded ids are `people`, `pets`, `homes`, `maintenance`, `vehicles`, `documents`, and `events`. Anything else falls back to **Documents**.
- `title:` becomes the new record's title. Without it, the filename (minus extension) wins.
- Every other key is matched against that database's property keys. In the example above, `make`, `model`, `year`, and `plate` all line up with seeded Vehicle properties and get filled in. Unknown keys are ignored.
- Values are taken raw — quoted strings are unwrapped, but lists, nested maps, and folded scalars aren't supported. For dates, write ISO 8601 (`2019-04-12`).
- The Markdown source file itself is always attached to the new record as an asset, so the original is never lost.

## Folder bundles (markdown + companion)

If you drop a **subfolder** containing exactly one Markdown file plus one other file, and the Markdown body mentions the other file's name (`[scan](receipt.pdf)`, `![](receipt.pdf)`, or just the bare filename), the pair imports as a single record:

- The Markdown drives the type/title/properties (per the frontmatter rules above).
- The companion file is attached to that same record. It does **not** become the cover.

Folders that don't fit the bundle pattern have each file imported individually as if it had been dropped at the top level. Either way, the folder is removed when its contents have been processed.

Only one level of nesting is examined — files inside sub-subfolders are ignored.

## Where the Inbox lives

Wherever your workspace lives. If you set **Settings → Storage → iCloud Drive**, the Inbox is at:

```
~/Library/Mobile Documents/iCloud~com~ryanleewilliams~keystone/Documents/Inbox/
```

…which means dropping a file into iCloud Drive → Keystone → Inbox on any device puts it in the queue, and whichever device is running Keystone next picks it up. Drop from your iPhone Files app, see it on your Mac.

If you're using a custom folder or the App container, the Inbox is at `<that folder>/Inbox/`.

## Behavior details

- **Hidden / dot files are ignored.** macOS sprinkles `.DS_Store` etc. and Keystone skips them.
- **iCloud-not-yet-downloaded files are ignored.** They have a `.icloud` extension; once iCloud finishes downloading, the watcher picks them up next scan.
- **Files still being written are ignored.** A 2-second settle window catches the common save-then-finish case.
- **Duplicates are deduped by content hash.** Drop the same image twice → it gets imported once and the second copy is silently removed from Inbox.
- **The README in Inbox is preserved.** Keystone never imports its own helper file.
- **One transaction per file.** If something goes wrong mid-import, no half-state — the file stays in Inbox and the next scan tries again.

## What it doesn't do (yet)

- **Recursive folder watches.** Only the top level of `Inbox/` plus one level of subfolders is examined. Files nested deeper are skipped.
- **Full YAML.** Frontmatter parsing handles `key: value` pairs and quoted strings. Lists, nested maps, and folded scalars aren't supported.
- **Deleting from app removes from filesystem.** If you delete a record in the app, the asset file stays in `Assets/`. (You can clear orphaned assets manually for now.)

These are all reasonable next steps once you've used the basic flow for a bit.

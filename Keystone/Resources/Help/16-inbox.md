# Inbox folder

There's an `Inbox/` subfolder inside your workspace alongside `workspace.sqlite` and `Assets/`. Anything you drop into Inbox gets imported into Keystone as a new **Documents** record with the file attached as the cover.

The whole point: you can add records by saving a file from Finder, the Files app on iPhone/iPad, "Save to iCloud Drive" from any app, etc. — without ever launching Keystone yourself.

## How it works

1. **Drop a file** into `<workspace folder>/Inbox/`. From any device, any app — anywhere that can save to a folder.
2. **Keystone notices** within a second of the next time it's running and the folder change syncs (instant on the device that did the drop, ~seconds for other devices via iCloud Drive).
3. **A new record appears** in your **Documents** database. Title is the original filename without extension. The original file is attached as both an asset and the record's cover image (if it's an image).
4. **The Inbox folder empties.** The original file moves to `Assets/` under a content-hashed name. Empty Inbox = "all imports are processed."

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

- **Filing into the right database.** Everything lands in **Documents** for now; you can move records by editing the database property if needed.
- **Watching subfolders.** Top-level files only. Nested folders are skipped.
- **Custom rename / template hooks.** Title is just the filename minus extension.
- **Deleting from app removes from filesystem.** If you delete a record in the app, the asset file stays in `Assets/`. (You can clear orphaned assets manually for now.)

These are all reasonable next steps once you've used the basic flow for a bit.

# Storage location

By default, Keystone keeps your workspace inside its sandboxed app container — safe and private, but invisible in Finder. Settings (⌘,) lets you move that data somewhere you can actually see.

## Three options

### App container (default)

```
~/Library/Containers/com.ryanleewilliams.keystone/Data/Library/Application Support/Keystone/
```

Hidden from Finder unless you type the path. Cross-device sync only via CloudKit. Pick this if privacy/sandboxing matters more to you than file visibility.

### Custom folder

You pick the folder. Common picks:

- `~/Documents/Keystone/`
- `~/Dropbox/Keystone/`
- `~/Library/Mobile Documents/com~apple~CloudDocs/Keystone/` (a folder you've created in iCloud Drive yourself)
- `~/Sync/Keystone/` (Syncthing)

Whatever sync service you already use will sync the folder. Keystone takes a security-scoped bookmark of the folder when you pick it, so it can keep reading and writing across launches even under the macOS sandbox.

### iCloud Drive

Keystone uses its own iCloud Drive container. You'll see "Keystone" in Finder's iCloud Drive sidebar, and on iPhone/iPad you can browse the same files in **Files.app → iCloud Drive → Keystone**.

Files synced this way include the SQLite database (`workspace.sqlite`) and every imported asset (cover photos, attachments). For the iCloud option to appear available, you need:

1. Sign into iCloud on this Mac and enable iCloud Drive in System Settings.
2. (One-time, if you self-build) enable the **iCloud** capability in Xcode → *Signing & Capabilities*, with a CloudDocuments service and the container ID `iCloud.com.ryanleewilliams.keystone`.

## What happens when you switch

Keystone copies your existing `workspace.sqlite` and `Assets/` into the new location, points the preference at it, and asks you to **quit and reopen** so the still-open database connection can swap. The old copy stays where it is — Keystone never deletes it during a switch. Once you've confirmed the new location is happy, you can delete the old one yourself if you want the disk space back.

If anything fails mid-copy (disk full, permissions, network glitch on iCloud), Keystone aborts the switch and leaves you on the previous location. No partial state.

## Multi-device caveat

iCloud Drive is great for **single-device-at-a-time** use. Open Keystone on your Mac, edit some records, close it, then open the iPhone — works fine. Open it on **both** at the same time and start writing to the SQLite file from each, and you risk corruption (SQLite isn't designed for that). For seamless concurrent multi-device editing, lean on the CloudKit row-level sync (`SyncEngine`) — that's an additive layer that operates separately and handles conflicts at the row level instead of the file level.

## Where each piece goes

Wherever the workspace folder ends up, the structure is the same:

```
<workspace folder>/
  workspace.sqlite          # database
  workspace.sqlite-wal      # write-ahead log (transient)
  workspace.sqlite-shm      # shared memory (transient)
  Assets/
    a4f8…d2.jpg             # imported files, named by content hash
    …
```

The asset filenames are content hashes — drop one into a Markdown editor or another database and the hash is the stable identity.

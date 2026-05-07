# Storage location

The setting in Settings → Storage controls **where your files (`Inbox/` and `Assets/`) live** — somewhere you can see them in Finder/Files.app, or somewhere private to this device. The **database itself (`workspace.sqlite`) is always sandbox-private** regardless of which option you pick. That's a deliberate split: file-syncing services (iCloud Drive, Dropbox, Syncthing) can replace bytes mid-session and corrupt or destroy a live SQLite database. Records are synced device-to-device by CloudKit's row-level engine instead, which understands transactions and conflicts.

So: pick where your *files* go. Records sync separately and safely.

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

Keystone copies your existing `Assets/` and `Inbox/` into the new location and points the preference at it. The old copy stays where it is — Keystone never deletes it. Once you've confirmed the new location is happy, you can delete the old one yourself if you want the disk space back.

The database doesn't move when you switch storage — it stays at `~/Library/Containers/com.ryanleewilliams.keystone/Data/Library/Application Support/Keystone/workspace.sqlite` regardless. CloudKit handles record sync to other devices.

## Where each piece goes

```
<workspace folder, per Settings>/
  Inbox/
    README.md
    <files you drop here get auto-imported>
  Assets/
    a4f8…d2.jpg             # imported files, named by content hash
    …

~/Library/Containers/com.ryanleewilliams.keystone/Data/Library/Application Support/Keystone/
  workspace.sqlite          # database — always here, never in iCloud Drive
  workspace.sqlite-wal      # write-ahead log (transient)
  workspace.sqlite-shm      # shared memory (transient)
```

The asset filenames are content hashes — drop one into a Markdown editor or another database and the hash is the stable identity.

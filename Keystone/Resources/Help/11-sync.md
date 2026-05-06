# Sync

Keystone syncs your workspace to your private CloudKit database. Every record, property, block, tag, relation, and asset metadata row mirrors to iCloud and stays in sync across all your Macs, iPhones, and iPads signed into the same Apple ID.

Sync runs automatically on launch — no settings to flip, no env vars to set. The first time you run a build with CloudKit enabled, the engine creates the container record schema in your iCloud account; from there it's automatic.

## What gets synced

- Workspaces, areas, databases, properties
- Records and property values
- Blocks (the page bodies)
- Tags and tag attachments
- Relations
- Asset metadata (rows in the `assets` table)

## What doesn't get synced (yet)

- **The actual asset files.** Asset row metadata syncs; the bytes themselves don't yet ride along via CloudKit. Workaround for now: pick **iCloud Drive** in **Settings → Storage** and the file bytes will sync via iCloud Drive at the file system level. CloudKit asset payloads are a planned enhancement.
- **Sharing with other users.** Sync today is single-Apple-ID. CloudKit sharing (`CKShare`) is on the roadmap for sharing specific records (e.g. shared Pets database) with a partner.

## The status badge

Bottom of the sidebar shows the current state:

- **Local** (gray dot) — sync isn't running. Either iCloud isn't signed in, the entitlement isn't provisioned, or the env var `KEYSTONE_DISABLE_CLOUDKIT=1` is set.
- **Syncing…** (amber dot) — sending or fetching changes.
- **Synced** (green dot, with a relative timestamp) — caught up.

## Conflict resolution

The sync engine uses last-write-wins on the row level. If you edit the same property on two devices simultaneously, the later edit wins. Field-level merging is a future enhancement.

## Disabling temporarily

If you want to test offline behavior or run against a sandbox iCloud account, launch with:

```
KEYSTONE_DISABLE_CLOUDKIT=1 open Keystone.app
```

(or set that environment variable in the Xcode scheme). The engine stays dormant and the badge reads "Local."

## Storage location vs. sync

These are two different things:

- **Storage location** (Settings → Storage) controls *where files live on disk locally* — sandbox container, a folder you pick, or iCloud Drive.
- **CloudKit sync** is the *row-level cross-device sync* that moves database rows between your devices.

You can mix them: storage in iCloud Drive *and* CloudKit row sync (belt-and-suspenders), or sandbox container locally *and* CloudKit (private to this device's filesystem, but rows still mirror through iCloud).

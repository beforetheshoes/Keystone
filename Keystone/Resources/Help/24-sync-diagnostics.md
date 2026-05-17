# Sync diagnostics

Settings → **Sync Diagnostics** is a per-device window into what CloudKit sync is doing. Use it when something feels off — a record didn't appear on another device, the status badge has been stuck on "Syncing…" for a while, or you suspect a conflict ate one of your edits.

The log is **local-only.** Each device records its own view of sync activity; nothing on this page is replicated through iCloud. Clearing the log on one Mac doesn't affect anything else.

## What the inline summary shows

- **Last sync** — relative time of the most recent successful `sync_succeeded` event in the log.
- **Events (24h)** — total log entries in the last 24 hours. Idle activity is normal here; this is mostly an "is the engine alive?" pulse.
- **Conflicts (24h)** — `sync_failed` and `items_lost` events in the same window. Anything > 0 is worth opening the diagnostics sheet for.
- **Last error** — the most recent error detail. Truncated; the full text is on the diagnostics sheet.

## The diagnostics sheet

### Force pull

Calls `SyncEngine.fetchChanges()` immediately. CloudKit hands back any changes the server hasn't yet pushed to this device since the last fetch. **Note:** this is *not* a "re-fetch the last hour" knob — `CKSyncEngine` reads forward from the current server change-token. If you genuinely need to rebuild local state from scratch (e.g. a corrupted change-token), that's a separate maintenance action and isn't exposed here yet.

### Force push

Calls `SyncEngine.sendChanges()`. Useful when a write seems stuck — the engine is idle but you know you have local changes that haven't appeared on another device. Drains the local pending-changes queue.

### Refresh

Re-reads the log from the database. Cheap; safe to mash.

### Clear log

Drops every row in the local `sync_events` table. The actual sync engine is unaffected — only the diagnostic record. Use this to reset the view after troubleshooting.

## Event types

Each row in the log carries an `event_type` string. The diagnostic sheet color-codes them:

| Type                  | Tint  | Meaning                                                                                          |
|-----------------------|-------|--------------------------------------------------------------------------------------------------|
| `engine_started`      | green | Sync engine entered a settled state for the first time after launch.                             |
| `engine_stopped`      | gray  | Engine fell back to local-only (e.g. iCloud unavailable, or the env var `KEYSTONE_DISABLE_CLOUDKIT=1`). |
| `engine_init_failed`  | amber | The engine couldn't initialize. Details column has the underlying error.                         |
| `sync_began`          | gray  | Engine started a fetch / send cycle.                                                             |
| `sync_succeeded`      | green | Engine returned to idle without reporting an error.                                              |
| `sync_failed`         | amber | Force-pull / force-push raised an error, OR the post-sync diff detected lost rows.               |
| `force_pull_invoked`  | gray  | You tapped Force pull.                                                                           |
| `force_push_invoked`  | gray  | You tapped Force push.                                                                           |
| `items_lost`          | amber | A record that existed before a sync cycle wasn't in the database after. One row per missing record; `record_id` and `database_id` identify it. |
| `items_recovered`     | green | (Reserved for future auto-restore behavior.)                                                     |

### About conflict observability

Keystone's sync engine resolves field-level conflicts inside the SDK using last-write-wins. The SDK doesn't surface those decisions as discrete events, so the diagnostics here can't show "row X was overwritten by device Y." What they *can* show is the visible side effect: a record that was on this device before a sync cycle and isn't there after — that's the `items_lost` event, written by the recovery guard.

## CLI

```
.../Keystone.app/Contents/MacOS/Keystone --cli sync-diagnose [--limit N] [--hours N]
```

Prints the same summary numbers and recent events as the sheet, as JSON to stdout. The CLI binary doesn't run the sync engine itself, so `engine_state` will read `not_configured_in_cli` — but it sees the same `sync_events` rows the GUI app wrote, since both processes share the workspace SQLite file.

Useful for grepping for a specific event type:

```
… --cli sync-diagnose --limit 500 | jq '.events[] | select(.event_type == "items_lost")'
```

## When this log fills with noise

If you're seeing dozens of `engine_started` / `engine_stopped` cycles, that's a CloudKit-availability flap (network drops, account switches, rapid sleep/wake). Not a Keystone bug per se, but worth investigating at the system level — sync's effective uptime is the union of those settled windows.

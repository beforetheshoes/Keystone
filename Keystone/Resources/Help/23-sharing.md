# Sharing

You can share an individual Keystone record with another iCloud user — most commonly a partner or family member co-planning a trip.

## What can be shared

- **One record at a time.** Open a record's detail view, tap `⋯` → **Share record…**, and the macOS / iOS sharing sheet appears. The recipient gets the record itself, its property values, its block content (notes), and any files attached to it.
- **Whole-database sharing** ("share my entire Trips database with my spouse") is a planned follow-up, not in this version.

## How it works under the hood

Sharing rides on Apple's **CloudKit shared database**. When you share a record, Keystone:

1. Asks CloudKit to create a `CKShare` for that record's CloudKit row.
2. Hands you a system sharing sheet — invite by Mail, Messages, or copyable link.
3. The recipient taps the invitation, which opens Keystone on their device. Their copy of the app fetches the shared record into a separate **shared zone**, kept in sync alongside their own private records.

## Permissions

The default is **Read & Write** — the partner can edit the trip alongside you. You can switch a recipient to read-only inside the sharing sheet at any time. The system sharing UI also lets you remove individual participants without revoking the entire share.

Conflict resolution is **last-writer-wins** — the same model that already governs sync between your own devices. There's no diff/merge UI. Two simultaneous edits to the same field will land whichever was committed last.

**Public links are not offered.** Shares are always scoped to specific invitees. For protected records this is a hard requirement (see "Sharing protected records").

## Sharing protected records

Each protected record has its own encryption key (see [Privacy lock](22-privacy-lock.md)). When you share a protected record, Keystone wraps **only that record's key** into the CKShare's encrypted metadata. The recipient's device extracts the key on accept and decrypts the shared record locally.

Important consequences:

- **Sharing one protected record never exposes another.** Even if you share several protected trips with the same partner, each one ships its own key. Any protected record you've not shared with them stays inaccessible.
- **Revocation cuts off future updates, not history.** Once a recipient has decrypted plaintext, that plaintext exists on their device. Removing them from the share stops new edits from arriving, but doesn't reach back into their cache.

## Revoking a share

Open the record → `⋯` → **Share record…** → in the sharing sheet, tap **Stop Sharing** (or remove a single participant). The CKShare is deleted; participants lose access on their next sync. Their local copy of the record becomes read-only and is eventually evicted by CloudKit.

## What doesn't follow into a share

- **Tags.** Your tag taxonomy is workspace-private. The shared record arrives at the recipient untagged from their perspective.
- **Cross-database relations.** Links to other records (related Activities under a shared Trip, vendors, people) stay local. The recipient sees the trip's body and properties, but not the full relation graph rooted in your private workspace.
- **Linked child records.** Sharing a Trip does not automatically share its Activities, Lodging, or Transportation records. Each is its own record — share them individually if the recipient should see them.

## Requirements

- Both you and the recipient must be signed into iCloud and have CloudKit sync working in Keystone (the sidebar sync footer should say *Synced*, not *Local only*).
- The record must have round-tripped to CloudKit at least once. Brand-new records take ~10–30 seconds to sync; share preparation will fail before that with a "record not yet synchronized" error.

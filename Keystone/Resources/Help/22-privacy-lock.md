# Privacy lock

Keystone has two complementary protections:

- **App-launch lock** — biometric prompt before the workspace is visible at all.
- **Per-record protection** — individual records (and any record that links to them) stay hidden from sidebar, search, calendar, and database views until you authenticate. Their **content is also encrypted at rest** — see "What gets encrypted" below.

Turn either or both on under **Settings → Privacy**.

## App-launch lock

Toggle **Require biometric on launch** to make Keystone show a lock screen at startup. You unlock with Touch ID, Face ID, Optic ID, or — on hardware without biometrics — your Mac account password. Keystone does not bypass this on background-and-resume; the lock only applies to fresh launches and to **Lock Now** (`⌃⌘L`).

## Per-record protection

A protected record disappears from every list, search result, calendar plot, and relations panel. Mark a record as protected from its detail view's `⋯` menu → **Mark as protected**. Today only Trips have an `is_protected` field, but the toggle generalizes to any database that adds the property in the future.

When you protect a record, Keystone also hides every record that links to it. Activities, Lodging, and Transportation that reference a protected Trip vanish too — otherwise their titles and date ranges would leak the trip indirectly.

### What you'll see when something's hidden

A small footer appears at the bottom of any database view that has hidden records: "*N protected records hidden — Show all*". Tap it once for a single biometric prompt that reveals everything for the rest of the session. You can also unlock records one at a time by deep-linking to them (the detail pane shows an inline "Authenticate to view" prompt).

The session unlock is **memory-only** and clears on quit. Use **Keystone → Lock Now** (`⌃⌘L`) to clear it without quitting.

### "Always hide protected records (even with launch lock off)"

Toggle this on to use per-record protection without the launch lock. Off (and launch lock off too) makes protection a no-op — the property is preserved on disk but no filtering happens. Useful if you want to mark records for future privacy without enabling auth right now.

## What gets encrypted

When you mark a record protected, Keystone runs an encryption pass over its content and the content of every cascade-linked child record:

- **Property values** — text, numbers, dates, JSON. Stored as AES-GCM ciphertext in the row's `enc_value` column; the typed plaintext columns are nulled.
- **Block content** — the body / notes you typed in the record's editor. Same AES-GCM treatment in the `enc_content` column.
- **Asset files** — every file attached to the record gets its bytes replaced in place with ciphertext (prefixed with the magic `KSTENC1` so a forensic look at the file can tell it's not the original). Quick Look and Open decrypt to a per-session temp file at view time.
- **Sidecar markdowns** (vehicle maintenance and similar) — deleted from the workspace folder while protected. Regenerated on un-protect.

### What still leaks

The encryption is content-only. Structural metadata stays in plaintext so the rest of Keystone keeps working:

- The **existence** of the record (its `id`, `database_id`, `created_at`, `sort_index`).
- The fact that `is_protected = true` for a given row.
- The **relation graph** — which records link to which, even when both are encrypted.
- Tag membership.

Removing these would mean moving protected records to an isolated encrypted store; not in this version.

### Key management

A 256-bit key is generated on demand and stored in the **iCloud Keychain** (service `com.ryanleewilliams.keystone.protection-key`). Devices signed into the same iCloud account with iCloud Keychain enabled get the key automatically and can decrypt protected records. Devices without iCloud Keychain see a per-device key — protected records won't decrypt there until the user re-enables iCloud Keychain.

Keystone never prompts for a passphrase. The biometric layer (`Settings → Privacy → Require biometric on launch`) is what gates everyday access to the key on this device.

### Threat model

Encryption-at-rest defends against:

- A **leaked SQLite file** — backup, recovered drive, exported via Files.app.
- A **leaked iCloud Drive folder** — when you've placed the workspace there, the file lives in a sync-eligible location an attacker might reach.
- A **breached CloudKit zone** — Keystone ships encrypted blobs to CloudKit, so the server-side records are opaque even to Apple.

It does NOT defend against:

- An **unlocked Mac with the user's Keychain available** — anyone using your Mac while signed in can decrypt via the app or `--cli`.
- A **CLI consumer with Keychain access** — `keystone --cli` shares your keychain and can read protected records by design (so scripts and automation keep working).
- An attacker who can **coerce or capture your biometric** — the device-owner-auth fallback is only as strong as the auth itself.

## What this is not

- **Not synced.** The session unlock allow-list lives only in the running app; quitting locks again. CloudKit doesn't carry unlock state across devices, only the encrypted content.

## Keyboard shortcut

| Action     | Shortcut |
|------------|----------|
| Lock Now   | ⌃⌘L      |

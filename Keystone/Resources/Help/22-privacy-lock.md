# Privacy lock

Keystone has two complementary protections:

- **App-launch lock** — biometric prompt before the workspace is visible at all.
- **Per-record protection** — individual records (and any record that links to them) stay hidden from sidebar, search, calendar, and database views until you authenticate.

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

## What this is not

- **Not encryption.** The SQLite database itself is unencrypted on disk. Anyone with file access can read it directly. This is a UI affordance to keep protected content out of casual view, not protection against an offline attacker.
- **Not a CLI gate.** `keystone --cli` commands bypass the filter intentionally — scripts and automation operate on the full workspace. If a CLI consumer would leak data, harden the consumer, not the lock.
- **Not synced.** The unlock allow-list lives only in the running app; quitting locks again. CloudKit doesn't carry lock state across devices.

## Keyboard shortcut

| Action     | Shortcut |
|------------|----------|
| Lock Now   | ⌃⌘L      |

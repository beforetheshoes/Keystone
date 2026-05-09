# Collections

Keystone seeds a **Collections** area with four databases for tracking media you've consumed (or want to): **Books**, **Movies**, **TV Shows**, and **Restaurants**. Books / Movies / TV open in gallery view by default — cover-art-forward — while Restaurants opens in table view since the per-record cover is less useful than the comparison table.

## Adding a record — search-first

Click **+ New** on Books, Movies, or TV Shows and a search sheet opens. Type the title; results stream in as you type, with cover thumbnails. Pick the right one and Keystone creates the record with every field already filled in.

| Database | Provider | What you type | What gets filled in |
|----------|----------|---------------|---------------------|
| Books | Google Books (free, optional key) | Title (or "title author") | ISBN, publisher, published date, page count, cover image |
| Movies | TMDB (key required) | Title | TMDB ID, release date, runtime, overview, poster |
| TV Shows | TMDB (key required) | Title | TMDB ID, first-air date, season count, episode count, overview, poster |
| Vendors | Apple Maps | Business name (or "name city") | Phone, address, locality, place ID, website |

If a record genuinely isn't in the provider's database (a self-published book, a private vendor), use the **Create blank** button at the bottom of the sheet — that drops you into a fresh record the same way the old + New did.

## Background enrichment (still there)

The launch-time enrichment pass still runs as a fallback. If you typed a title manually (e.g. via the Inbox import) and it has the right name, Keystone will fill in the rest within a few seconds of the next launch. The trigger property is the one that's blank — `isbn` for Books, `tmdb_id` for Movies and TV, `place_id` for Vendors. Once it's set, the record is considered enriched and skipped on future passes.

## Status as a cycle pill

The **Status** column on each Collections database renders as a soft pill instead of a free-form text field. Tap it to cycle to the next option; right-click for a menu showing every option plus a **Clear** entry.

| Database | Cycle |
|----------|-------|
| Books | `to_read` → `reading` → `read` → `abandoned` |
| Movies | `to_watch` → `watched` → `dropped` |
| TV Shows | `to_watch` → `watching` → `watched` → `dropped` |
| Restaurants | `want_to_try` → `visited` |

This same cycle-on-tap UX is now available to any select property whose `config_json` carries an `options` list. Existing select columns without options (e.g. `vendors.kind`, `vehicle_maintenance.kind`, `people.relationship`) keep their free-form text editor and accept arbitrary input.

## Restaurants → Vendors

Restaurants don't get their own enrichment provider. Instead, each Restaurant record carries a **Vendor** relation pointing at the existing **Vendors** database — and the Vendors MapKit pass takes care of phone, address, website, place ID. Type a restaurant name into the Vendor cell and Keystone auto-creates the vendor stub for you (existing Inbox-style stub creation). Within ~10 seconds the linked vendor record fills in.

The advantage of the relation indirection: vendors you also visit for non-dining reasons (a coffee shop you also note as a meeting venue, say) deduplicate naturally — one vendor record, many uses.

## What's not here yet

- **Per-record "Re-enrich" button** — once a record is enriched, the only way to re-run lookup is to delete the trigger property and wait for the next launch pass. A toolbar action that re-opens the search sheet pre-populated with the current title is on the list.
- **Restaurant search** — Restaurants delegate enrichment to their linked Vendor, so they currently use the plain blank-create flow. A combined "create restaurant + linked vendor" sheet is a follow-up.
- **Multi-select tags** for genres / favorites — `options` adds single-select cycling. The `multiSelect` PropertyType isn't wired to a real editor yet.
- **Humanized status labels** — values display as `to_read` rather than "To read". Localization is umbrella-out-of-scope for now.

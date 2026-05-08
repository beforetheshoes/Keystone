# Collections

Keystone seeds a **Collections** area with four databases for tracking media you've consumed (or want to): **Books**, **Movies**, **TV Shows**, and **Restaurants**. Books / Movies / TV open in gallery view by default — cover-art-forward — while Restaurants opens in table view since the per-record cover is less useful than the comparison table.

## What auto-fills

If you've added an API key under **Settings → API Keys** (see [Enrichment & API keys](18-enrichment.md)), three of the four databases auto-enrich newly added records:

| Database | Provider | What you type | What gets filled in |
|----------|----------|---------------|---------------------|
| Books | Google Books (free, optional key) | Title + Author | ISBN, publisher, published date, page count, cover image |
| Movies | TMDB (key required) | Title + Year | TMDB ID, release date, runtime, overview, poster |
| TV Shows | TMDB (key required) | Title + Year | TMDB ID, first-air date, season count, episode count, overview, poster |

The trigger property is the one that's blank after you create the record — `isbn` for Books, `tmdb_id` for Movies and TV. Once that field has a value, Keystone considers the record "enriched" and skips it on future passes.

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

- **Per-record "Enrich now" button** — the launch and post-Inbox passes catch most records. If you need to retry a single record, edit a property to clear its trigger field and the next launch picks it up.
- **Ambiguous-match picker UI** — when a provider sees multiple plausible candidates without a clear winner, it currently skips the record and logs the count. Vendors have an interactive picker; media records will get one in a follow-up.
- **Multi-select tags** for genres / favorites — `options` adds single-select cycling. The `multiSelect` PropertyType isn't wired to a real editor yet.
- **Humanized status labels** — values display as `to_read` rather than "To read". Localization is umbrella-out-of-scope for now.

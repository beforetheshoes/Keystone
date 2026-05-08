# Enrichment & API keys

Keystone can fill in missing fields on certain databases automatically by looking up records in third-party services. Vendors get phone, address, and website from Apple Maps. Books, Movies, and TV shows can pull cover art and metadata from Google Books and The Movie Database (TMDB).

## How it works

Each supported database has a **provider** that watches for records missing a "trigger" property — the marker that says "this record hasn't been enriched yet":

| Database | Provider | Trigger property |
|----------|----------|------------------|
| Vendors | Apple Maps | `place_id` |
| Books | Google Books | `isbn` |
| Movies | TMDB | `tmdb_id` |
| TV Shows | TMDB | `tmdb_id` |

When a record exists without its trigger property filled in, Keystone runs the matching provider in the background and writes anything it finds. The trigger property gets set as part of the lookup, so the same record isn't re-checked on every launch.

Enrichment runs on three triggers:

1. **App launch** — a single pass shortly after startup, catching records that arrived via CloudKit or were created while you were offline.
2. **After Inbox import** — when a new record lands via the Inbox folder (e.g. a Markdown file with `vendor: Acme` frontmatter), Keystone runs a pass immediately so the new record gets linked without waiting for the next launch.
3. **CLI** — `./keystone --cli enrich-all-vendors --database <key>` runs a one-shot pass against any registered database.

Only **confident** matches auto-apply. If a provider returns multiple plausible candidates without a clear winner, the record is left alone — Vendors surface the candidates in the **Look up on Apple Maps** sheet on the detail page, where you can pick the right one. Books / Movies / TV currently only auto-apply on confident matches; an interactive picker is planned.

## API keys

Some providers need an API key. You enter them under **Settings → API Keys**. Each row has:

- A **SecureField** for the key value. Paste your key and tab away (or press Return) to save.
- A **Test** button that fires a single no-op API call against the saved key so you can confirm it works.

| Provider | Key required? | Where to get one |
|----------|---------------|------------------|
| Apple Maps (Vendors) | No | Built into the OS. |
| Google Books | Optional | Without a key the API works at lower rate limits. With a key, get one free at [console.cloud.google.com](https://console.cloud.google.com/) → APIs & Services → Library → Books API. |
| TMDB | Required | Free account at [themoviedb.org](https://www.themoviedb.org/) → Settings → API → request a v4 read-access token. |

Keys live in the macOS Keychain (service `com.ryanleewilliams.keystone.api-keys`). They're never written to app preferences or backed up alongside Keystone's data folder.

## What gets filled in

### Vendors (Apple Maps)
Phone, website, full address, compact city/state locality, category, and the durable Apple Place ID used to refresh the record later.

### Books (Google Books)
ISBN, publisher, published date, page count, author (if missing), and the cover image — downloaded and attached as the record's cover.

### Movies (TMDB)
TMDB ID, release date, runtime in minutes, plot overview, and the poster image as the cover.

### TV Shows (TMDB)
TMDB ID, first-air date, season count, episode count, plot overview, and the poster image as the cover.

## What enrichment doesn't do

- **Overwrite values you've already typed.** Existing field values are preserved; only blank fields get filled.
- **Run continuously.** Each provider runs once per launch (and once after each Inbox import). To force a fresh pass, restart Keystone or use the CLI.
- **Retry failures aggressively.** A failed network call leaves the record un-enriched; the next launch retries.
- **Cache image downloads.** Cover images are content-hash deduped through the regular asset path, but a re-enrich on a different cover URL writes a new asset.

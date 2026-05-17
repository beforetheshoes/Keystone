# Enrichment & API keys

Keystone can fill in missing fields on certain databases automatically by looking up records in third-party services. Vendors get phone, address, and website from Apple Maps. Books, Movies, and TV shows can pull cover art and metadata from Google Books and The Movie Database (TMDB).

## How it works

Each supported database has a **provider** that watches for records missing a "trigger" property — the marker that says "this record hasn't been enriched yet":

| Database | Provider | Trigger property |
|----------|----------|------------------|
| Vendors | Apple Maps | `place_id` |
| Restaurants | Apple Maps + website scrape | `place_id` then `web_enriched_at` |
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
| TMDB | Required | Free account at [themoviedb.org](https://www.themoviedb.org/) → Settings → API. Either the v3 API key (32-char hex) or the v4 read-access token (a JWT) works — Keystone detects which you pasted and authenticates accordingly. |

Keys live in the macOS Keychain (service `com.ryanleewilliams.keystone.api-keys`). They're never written to app preferences or backed up alongside Keystone's data folder.

## What gets filled in

### Vendors (Apple Maps)
Phone, website, full address, compact city/state locality, category, and the durable Apple Place ID used to refresh the record later.

### Restaurants (Apple Maps, then website scrape, then OpenStreetMap)
On top of the Vendors pass, restaurants get a second pass that fetches the restaurant's own website and pulls out:

- **Logo** — apple-touch-icon first, then the largest declared favicon, then the Open Graph image, falling back to `/apple-touch-icon.png` and `/favicon.ico`. Attached as the record's cover image.
- **Hours, rating, price band** — read from the page's [schema.org JSON-LD](https://schema.org/Restaurant) block when present. Chain restaurants and most modern indie sites publish this; bare WordPress or static sites usually don't, and those fields stay blank for you to fill in by hand.
- **Menu URL** — taken from the JSON-LD `hasMenu` field, or discovered by probing `/menu`, `/menus`, `/food` on the restaurant's domain.

**OpenStreetMap fallback for hours**: when the restaurant's own site doesn't publish hours, Keystone queries the public [Overpass](https://overpass-api.de/) endpoint within ~125 m of the place's MapKit coordinate, matches by name, and reads the OSM `opening_hours` tag. Coverage varies by region — Western Europe is excellent, US is patchy, rural areas are sparse. OSM data is © OpenStreetMap contributors under the [ODbL](https://www.openstreetmap.org/copyright); the hours field doesn't surface this inline, but the data ultimately credits to OSM.

The website scrape (and OSM fallback) only run once per restaurant. Use **Re-enrich…** on the detail view if the restaurant's site changes (e.g. new hours after a remodel). No third-party API key required.

#### Editing hours by hand

Tap the pencil next to the hours grid on a restaurant detail page to open the structured per-day editor. Each weekday has a three-way toggle (Closed / 24h / Hours) and accepts one or more time ranges, so a venue that closes between lunch and dinner can list both windows. The header presets — **Set weekdays…**, **Set weekends…**, **Set every day…** — fill matching days in one shot, and each row's **⋯** menu copies that day's hours to the weekdays, weekends, or every day. A close time earlier than its open time (e.g. 6:00 PM – 2:00 AM) is treated as wrapping past midnight; the "Open now" pill on the detail view honors the wrap.

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

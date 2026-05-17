# Collections

Keystone seeds a **Collections** area with three databases — **Books**, **Movies**, **TV Shows** — plus a **Restaurants** *view* over the Vendors database. Books / Movies / TV open in gallery view by default — cover-art-forward — while Restaurants opens in table view since the per-record cover is less useful than the comparison table.

## Adding a record — search-first

Click **+ New** on Books, Movies, TV Shows, or Restaurants and a search sheet opens. Type the title; results stream in as you type, with cover thumbnails. Pick the right one and Keystone creates the record with every field already filled in.

| Source | Provider | What you type | What gets filled in |
|--------|----------|---------------|---------------------|
| Books | Google Books (free, optional key) | Title (or "title author") | ISBN, publisher, published date, page count, **description, tags (genres)**, cover image |
| Movies | TMDB (key required) | Title | TMDB ID, release date, runtime, overview, **tags (genres)**, poster |
| TV Shows | TMDB (key required) | Title | TMDB ID, first-air date, season count, episode count, overview, **tags (genres)**, poster |
| Vendors | Apple Maps | Business name (or "name city") | Phone, address, locality, place ID, website |
| Restaurants | Apple Maps (food & drink POIs only) | Restaurant name (or "name city") | Phone, address, locality, place ID, website, `kind = restaurant` |

If a record genuinely isn't in the provider's database (a self-published book, a private vendor), use the **Create blank** button at the bottom of the sheet — that drops you into a fresh record with the right kind preset.

## Restaurants is a view of Vendors

Restaurants used to be its own database with a `vendor` foreign-key over to Vendors — adding a restaurant meant creating two rows manually. Now Restaurants is a **saved view** of the Vendors database with `kind = "restaurant"` pinned: every restaurant is a Vendor with restaurant-specific fields, and the Restaurants sidebar entry is just a pre-filtered Vendors list with restaurant-only columns surfaced.

What this means in practice:

- **One step to add.** "+ New" on Restaurants opens a MapKit search constrained to food / drink POIs (`.restaurant`, `.cafe`, `.bakery`, `.brewery`, `.winery`, `.distillery`, `.nightlife`). Pick a result and you get one Vendor record with `kind = "restaurant"` and every column filled in — no separate vendor stub to attach.
- **Restaurant-specific columns** (`cuisine`, `price_range`, `rating`, `status`, `last_visited`, `hours`) live on the Vendors table tagged with `applicable_kinds: ["restaurant"]`. The detail view hides them on non-restaurant vendor records; the generic Vendors list hides them as columns. The Restaurants view promotes them.
- **The same vendor record serves multiple purposes.** A café you also note as a meeting venue is one row in Vendors, visible from both the Restaurants view and (the moment you set its kind to something else, or leave it as `restaurant`) the plain Vendors page.

## Filter chips on the Restaurants view

Above the Restaurants list, the **+ Filter** menu offers chip filters that are most useful for dining:

- **Cuisine** — pulls distinct values from your existing entries (free-form; type whatever you want).
- **Price** — `$` / `$$` / `$$$` / `$$$$` segmented filter.
- **Rating** — numeric range (≥ 4.0, between 3.5 and 4.5, …).
- **Status** — `want_to_try` / `visited`.
- **Locality** — distinct city values (populated by the Apple Maps lookup).
- **Last visited** — date range.
- **Open now** — three-way Any / Open / Closed against the venue's stored `hours`. Compares against the venue's hours in your local time. Records without a parseable hours payload never match.

## Status as a cycle pill

The **Status** column on each Collections database renders as a soft pill instead of a free-form text field. Tap it to cycle to the next option; right-click for a menu showing every option plus a **Clear** entry.

| Source | Cycle |
|--------|-------|
| Books | `to_read` → `reading` → `read` → `abandoned` |
| Movies | `to_watch` → `watched` → `dropped` |
| TV Shows | `to_watch` → `watching` → `watched` → `dropped` |
| Restaurants | `want_to_try` → `visited` |

This same cycle-on-tap UX is available to any select property whose `config_json` carries an `options` list.

## Hours format

The `hours` property stores a JSON blob, one weekday key per day, with one or more open intervals. Times are local to the venue (no time-zone field) and given in 24-hour `HH:MM`. Slot times past `24:00` represent wrap-into-the-next-day venues (a bar that closes at 02:00 stores `"close": "26:00"`).

```json
{
  "mon": [{"open": "08:00", "close": "22:00"}],
  "tue": [{"open": "08:00", "close": "22:00"}],
  "fri": [{"open": "11:00", "close": "23:30"}],
  "sat": [{"open": "10:00", "close": "23:30"}]
}
```

Apple Maps doesn't expose opening hours through `MKMapItem` in a way we can reliably auto-fill, so for now you populate `hours` by hand when you want **Open Now** filtering to work on a given venue.

## Reading & watch progress

Books and TV Shows each get a dedicated progress block at the top of the detail page:

- **Books — page or percent.** Toggle the mode in the block header. *Pages* mode shows "Page X of Y" with ± steppers; Y defaults to `page_count` from Google Books, but you can override it via the **Readable pages** field next to the count (useful when the official page count includes index / appendices you don't intend to read). *Percent* mode swaps in a 0–100 input. Either way, a fill bar on the cover (gallery) and a full bar on the detail page show progress at a glance.
- **Books auto-status.** Setting `current_page > 0` on a `to_read` book flips status to `reading` and stamps `started_date` if blank. Hitting `current_page == readable_pages` flips status to `read` and stamps `finished_date`. Manually set `abandoned` is never overridden.
- **TV — current season + current episode.** ± steppers, total clamped to `episode_count`. The cover fill bar tracks `current_episode / episode_count`.

## Tags (multi-select)

Books, Movies, and TV Shows each carry a `tags` property — chips, not a single value. Enrichment pre-populates from the provider:

- **Books**: Google Books `categories` are split on `/` and inserted as leaf tags (e.g. `"Fiction / Mystery"` becomes `Fiction` + `Mystery`).
- **Movies / TV Shows**: TMDB `genres` are inserted by name (e.g. `Thriller`, `Drama`).

You can also add your own tags from the detail page (`+` button next to the chip row, or pick from previously-used tags in the popover). Filter chips above the list / gallery / table treat `multiSelect` like `select` — picking a tag value matches every record that has it.

## View ergonomics — sort, filter, group, cover size

The toolbar above every collection now carries:

- **Filter chips** — the same `+ Filter` menu that used to be table-only is now visible in gallery and list too. Predicate types stay the same: select-is-any-of, date-range, number-range, text-contains, multiSelect (tag is any of).
- **Sort menu** — pick any sortable property + asc/desc; clear sort goes back to the database's natural order. Tapping a table column header still works and lights up the toolbar menu.
- **Group menu** — bucket records by status, tag, or any select / multi-select / checkbox / relation property. Section headers appear in gallery, list, and table; "None" returns to a flat list.
- **Gallery cover size** — small / medium / large (only visible in gallery view). Larger covers mean fewer cards per row.

All four settings persist per-database, so "Books in gallery, grouped by status, large covers, sorted by `started_date` descending" survives relaunch. View prefs live in a local-only table (`database_view_prefs`) — they're per-device, not synced through CloudKit, so each of your devices can have its own preferred layout.

## Search covers (cover-only picker)

Right-click any Books / Movies / TV gallery card (or open the kebab menu on the detail page) and pick **Search covers…** to swap the cover without touching any other field. The picker fans out across every registered source for that database:

- **Books**: Google Books + Open Library, side by side. Each thumbnail carries a small source badge so you can prefer one over the other.
- **Movies / TV**: TMDB posters from the same search the lookup sheet uses.

The initial query is the record's title (plus the author hint for books); you can refine and re-search. Picking a thumbnail downloads the full-size image and attaches it as the record's cover — nothing else changes. Unlike **Re-enrich…**, no description / publisher / page-count writes happen, so a manually-edited record's data stays intact.

## Stats

Books, Movies, and TV Shows each get a stats experience in two tiers:

1. **Dashboard summary** — switch any Collections database to the **Dashboard** tab in the toolbar segmented switcher. You'll see a hero row (total / currently in progress / completed this year / lifetime volume in pages, hours, or episodes) plus the most useful summary cards: pace over the last 12 months, status mix as a donut, and top tags. TV adds a "Currently watching" card with each show's season / episode progress bar.

2. **Show more stats →** at the bottom of the summary opens a dedicated stats page with:
   - **Pace per month** with a `Last 12 months / 5 years / All time` segmented control. The chart is horizontally scrollable, so picking a longer window lets you drag back through history.
   - **Status donut** with absolute counts in the legend.
   - **Decade distribution** — when published / released / first aired, bucketed by decade.
   - **Top tags / genres** — top 20. Tap any row to filter the underlying database by that tag.
   - **Books**: Top authors (top 20) + Currently reading list with progress bars.
   - **Movies**: Runtime distribution (< 90 min / 90–120 / 120–150 / 150+ min).
   - **TV Shows**: Currently watching list with season / episode progress bars.
   - **Reading / Watching pattern (3D)** — at the bottom of every deep page, a `Chart3D` (WWDC25) heatmap plots a year × month × count grid as a field of 3D bars. Drag to rotate. Reveals "I read more in summer", "2024 outpaced 2023", "January is always a dry spell" at a glance. Hidden until at least two years of activity are recorded.

On iPhone, tap the chart-bar icon in the Books / Movies / TV Shows toolbar to push the deep stats page onto the navigation stack. The dashboard summary doesn't show up on iPhone (no view switcher in the iPhone shell), so the toolbar entry is the only way in.

Built on Swift Charts: vectorized bar plots, sector marks for the donut, the scrollable-axes pattern from WWDC23 for the pace chart, and `Chart3D` from WWDC25 for the activity heatmap.

## What's not here yet

- **A dedicated hours editor.** The Hours cell is a plain text field today; type the JSON yourself. A weekday-by-weekday time-range editor is a follow-up.
- **MapKit hours autofill** — the same `MKMapItem` shape that lacks a stable hours surface today. We'll wire it the moment Apple ships a usable API.
- **Humanized status labels** — values display as `to_read` rather than "To read".
- **Reading sessions log** — current-page is a single number; a per-session log (timestamps + pages read) would surface streaks and pace, but it's a sub-table not yet modeled.

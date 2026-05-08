# Properties

Properties are the typed fields on a record. Each database defines its own set; for example, `People` has `Name`, `Relation`, `Birthday`, `Phone`, `Email`, `Last seen`. Each property has a **type** that determines how it's stored and rendered.

## Property types

- `title` — the record's name. Always shown in the hero block.
- `text` — free-form short text.
- `number` — integer or decimal. Rendered with monospaced digits.
- `date` — text-formatted date string. (Date pickers are coming; for now type the string.)
- `select` — a single-choice value, rendered as a soft pill.
- `phone` — text formatted with monospaced digits.
- `email` — text.
- `relation` — points at another record. See **Relations**.

Other types (currency, multiSelect, checkbox, file, url, location, computed, rollup) are defined in the schema and reserved for future use.

## Editing values

Click a value to edit. Edits commit on every keystroke — there's no "save" button. Switch to another record, navigate away, or quit the app at any time without losing work.

If you want to clear a value, select it and delete the text — empty values become `—` placeholders.

## Adding properties

You can't add properties to a database from the UI yet. They're defined in the seed data and (future) the database settings. The schema supports it; the UI will follow.

## Looking up vendor info from Apple Maps

Vendors have a built-in helper that fills in phone, website, full address, a compact **City, ST** locality, and category from Apple Maps. On any vendor's detail page, open the `⋯` menu and pick **Look up on Apple Maps**.

- If Apple Maps has a confident match for the vendor's name (and the existing address, when present), you'll see a single **Confident match** card. Click **Apply** to copy the fields onto the record.
- If Apple Maps returns multiple plausible candidates without a clear winner, the sheet shows them all so you can pick the right one.
- If nothing matches, the vendor is probably too small or local for MapKit's database — that's normal for private sellers and one-person shops.

Once a vendor is resolved, its detail page shows a **Location** preview tile with a map and an **Open in Maps** button that hands off to the Maps app for directions, hours, photos, and reviews.

The lookup also stores Apple's stable **Place ID** so future re-lookups reuse the exact place even if the business renames or moves.

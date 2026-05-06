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

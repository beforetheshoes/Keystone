# Records & databases

Keystone's core idea: every piece of information is a **record** that belongs to a **database**.

## What's a database?

A database is a typed collection: `People`, `Pets`, `Homes`, `Vehicles`, `Documents`, `Events`, `Maintenance`. Each database defines its own set of properties (typed fields) that all records in that database share.

You can think of a database like a Notion database, an Airtable base, or a folder of structured cards in Finder.

## What's a record?

A record is one item inside a database — `Eleanor Marsh` (a Person), `Juno` (a Pet), `Bernal House` (a Home). Every record has:

- A **title**
- A **glyph** (a colored 1–2 letter icon, auto-generated from the title)
- An **accent tone** inherited from the database
- **Property values** for each property the database defines
- A **page body** of blocks (notes, headings, lists, etc.)
- **Tags**
- **Relations** to other records
- **Files** (attachments)

## Areas

Databases are grouped into **areas** in the sidebar — `Family`, `Home`, `Mobility`, `Records`, `Plans`. Areas are purely organizational; they don't change what records can do.

## How records get created

- `⌘N` (Quick capture) — pick a kind, type a name, hit Return.
- `+ New` button on any database view — creates a blank `Untitled` record and opens it.
- Drag a file onto a record's FILES section — the file becomes an attached asset on that record.

## Changing a record's type

Open a record. The colored type pill below its title (`Person`, `Vehicle`, `Document`, …) is a menu — click it and pick a different database to move the record there. The record's title, glyph, page body, tags, attachments, and any free-form relations carry over. Property values whose key and type also exist in the new database are kept (e.g., `name` survives the move from People to Pets); everything else is dropped, along with any relations bound to a property of the old database. There's no undo, so be deliberate.

## How records get deleted

Open the record. Click the `⋯` menu in the toolbar. Pick **Delete record**. The record, all its property values, blocks, tags, and relations are removed; attached files are kept (delete those individually if you want).

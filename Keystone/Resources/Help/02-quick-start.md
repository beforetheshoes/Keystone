# Quick start

A five-minute tour. Open Keystone and follow along.

## What you see at launch

- **Mac:** the warm-paper sidebar on the left lists your life areas + databases + tags + Help; the main pane on the right shows Home.
- **iPhone:** five tabs across the bottom — **Home**, **Browse**, **+**, **Search**, **Profile**. Home shows THIS WEEK / DATABASES / FAMILY at a glance.
- **iPad:** sidebar + detail layout, same shape as Mac. Sidebar collapses in portrait; tap the leading toolbar button to bring it back.

## Create a record

1. Press `⌘N` (Mac/iPad) or tap the **+** tab (iPhone) to open **Quick capture**.
2. Pick a kind (Person, Pet, Vehicle, Document, Event, Note).
3. Type a title and press Return.

The record opens. You can also click `+ New` in the top toolbar of any database view to add a record without the picker.

## Edit properties

The hero block at the top of a record holds the title — click and edit. Below it is the **properties grid** with typed fields like `Birthday`, `Phone`, `Email`. Click any value and start typing — edits save automatically as you type.

## Tag it

Below the properties is the **TAGS** row. Click `+ Add tag`, search for an existing tag, or type a new name and create one. Tags are great for slicing across databases ("everything tagged `medical`", regardless of what kind of record it is).

## Link it to other records

Some properties are **relations** (e.g. a Pet's `Vet` field, an Event's `With` field). Instead of typing text, you pick a target record. Click `+ Add` next to a relation field to open a record picker.

You'll also see a **RELATED** section if the record has hand-curated cross-database links, and a **LINKED FROM** section showing every record that links back here.

## Add files

Drag a file from Finder onto the **FILES** section, or click `+ Attach file…`. The file is copied into your Keystone folder and a real thumbnail appears. Click to open, right-click to reveal in Finder or delete.

## Write a page body

Below FILES is the **NOTES** section — a block editor. Just start typing. Press Return for a new paragraph. Type `# `, `- `, `[] `, `> ` at the start of a line for headings, bullets, checklists, quotes. See **Block editor** for the full list.

## Find anything

`⌘K` opens the command palette. Search across every record and database in your workspace.

## Where the data lives

Everything is in `~/Library/Containers/com.ryanleewilliams.keystone/Data/Library/Application Support/Keystone/`:

- `workspace.sqlite` — your database
- `Assets/` — your attached files

You can `cd` there in Terminal whenever you want to see your data raw.

# Tags

Tags slice across databases. Apply `medical` to a person, a pet, and a document, and you can pull up everything tagged `medical` from one place.

## Scope

Tags have one of two scopes:

- **Global** — available on any record in any database. Use this for cross-cutting concepts (`urgent`, `family`, `medical`).
- **Database** — only available on records in a specific database. Use this for category-like values that only make sense in one context (`property` for Documents, `vaccinated` for Pets).

You set a tag's scope when you create it. You can't change a tag's scope after the fact yet.

## Color

Each tag has an accent color (cerulean, iris, sage, amber, graphite). The chip in the detail view + the dot in the sidebar use that color.

## Applying tags

On a record's detail view, find the **TAGS** row (between the properties grid and the notes section). Click `+ Add tag` to open the picker:

- Type to filter existing tags. Pick one to attach.
- Type a name that doesn't exist yet, choose a scope and color, click **Create and attach** — the tag is created and attached in one step.

Hover a tag chip and click the `✕` to detach it from the record.

## Filtering by tag

Tags appear in the sidebar under their own collapsible **Tags** group. Click any tag to see every record across the workspace that has it, in one list.

## Seeded tags

Fresh installs come with four starter tags: `family` (cerulean, attached to all eight people), `medical` (sage, attached to the two pets), `urgent` (amber, no attachments), `property` (sage, scoped to Documents, attached to deeds and titles).

# Keystone — doc ownership map

When changing or adding a feature in any of these areas, **also update the matching Help page** in the same diff. The in-app Help section is shipped to users; if it goes stale, users see incorrect instructions.

| Feature area              | Doc file                                                              |
|---------------------------|-----------------------------------------------------------------------|
| Welcome / philosophy      | [01-welcome.md](Keystone/Resources/Help/01-welcome.md)               |
| Quick start tutorial      | [02-quick-start.md](Keystone/Resources/Help/02-quick-start.md)       |
| Records / databases / areas | [03-records-and-databases.md](Keystone/Resources/Help/03-records-and-databases.md) |
| Properties (typed fields) | [04-properties.md](Keystone/Resources/Help/04-properties.md)         |
| Tags                      | [05-tags.md](Keystone/Resources/Help/05-tags.md)                     |
| Relations / RELATED panel | [06-relations.md](Keystone/Resources/Help/06-relations.md)           |
| Block editor              | [07-block-editor.md](Keystone/Resources/Help/07-block-editor.md)     |
| File attachments / assets | [08-files-and-attachments.md](Keystone/Resources/Help/08-files-and-attachments.md) |
| Quick capture (⌘N)        | [09-quick-capture.md](Keystone/Resources/Help/09-quick-capture.md)   |
| Command palette (⌘K)      | [10-command-palette.md](Keystone/Resources/Help/10-command-palette.md) |
| CloudKit sync             | [11-sync.md](Keystone/Resources/Help/11-sync.md)                     |
| Keyboard shortcuts        | [12-keyboard-shortcuts.md](Keystone/Resources/Help/12-keyboard-shortcuts.md) |
| Architecture (internals)  | [13-architecture.md](Keystone/Resources/Help/13-architecture.md)     |
| Profile / cover images    | [14-profile-images.md](Keystone/Resources/Help/14-profile-images.md) |
| Storage location          | [15-storage-location.md](Keystone/Resources/Help/15-storage-location.md) |
| Inbox folder              | [16-inbox.md](Keystone/Resources/Help/16-inbox.md)                   |
| Travel area / templates   | [17-travel.md](Keystone/Resources/Help/17-travel.md)                 |
| Enrichment & API keys     | [18-enrichment.md](Keystone/Resources/Help/18-enrichment.md)         |
| Calendar view             | [19-calendar.md](Keystone/Resources/Help/19-calendar.md)             |
| Collections (media)       | [20-collections.md](Keystone/Resources/Help/20-collections.md)       |

## Process

1. Implement / change the feature.
2. Update the corresponding doc page (or pages — a feature might touch multiple).
3. If the change introduces a new feature area not covered above, add a new topic file under `Keystone/Resources/Help/`, register it in `HelpTopics.all` (in `Keystone/Features/Help/HelpTopics.swift`), add a row to this table, and ensure `testHelpTopicsResolve` still passes.
4. Bump the relevant section's wording for terminology consistency: tags-vs-labels, records-vs-objects, etc.

## Rendering notes

The in-app Help renderer supports: `# / ## / ###` headings, paragraphs, `- ` and `* ` bullets, `1. ` numbered lists, fenced code blocks (```), `> ` blockquotes, `---` dividers, and inline `**bold**` / `*italic*` / `` `code` `` / `[links](url)`. Everything else degrades to plain text — keep doc syntax inside this set.

# Block editor

The **NOTES** section on every record is a block editor. Each line is a block with a kind: paragraph, heading, list item, quote, divider, etc. Each block stores rich text as an `AttributedString`.

## Block kinds

- **Paragraph** — body text, the default
- **Heading 1 / 2 / 3** — three sizes
- **Bulleted list item** — `- ` prefix
- **Numbered list item** — `1. ` prefix
- **Checklist item** — toggle + text, with strike-through when checked
- **Quote** — left-bordered, italic
- **Divider** — horizontal rule

## Markdown shortcuts

Type these at the start of a paragraph block; the kind switches as soon as you hit space:

- `# ` → heading 1
- `## ` → heading 2
- `### ` → heading 3
- `- ` or `* ` → bullet
- `1. ` → numbered item
- `[] ` or `[ ] ` → checklist (unchecked)
- `> ` → quote
- `--- ` → divider (and a fresh paragraph appears below)

## Keyboard

- **Return** — splits the current block at the cursor; the half after the cursor moves into a new paragraph below, and focus jumps there.
- **Backspace at the start of an empty block** — deletes the block, focus jumps to the previous block.
- **`⌘B`, `⌘I`** — bold, italic on the current selection (system shortcuts).

## Inline formatting

The editor uses Apple's modern `TextEditor` with attributed-string editing. You can apply bold, italic, strikethrough, inline code, and links to selections. Formatting is preserved when you split a block — bold text stays bold on both sides.

## ⋯ menu

Hover the left gutter of any block to reveal a `⋯` menu. From there you can **Change to** any other block kind, or **Delete** the block.

## Where blocks live

Each block is a row in the `blocks` table. Their text is JSON-encoded `AttributedString` content stored in `content_json`. Round-trip through SQLite preserves all inline formatting.

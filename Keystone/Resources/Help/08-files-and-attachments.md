# Files & attachments

Every record has a **FILES** section. Drag a PDF, image, or any other file onto the section, or click `+ Attach file…` to pick from a dialog. Keystone copies the file into your workspace folder and registers it as an asset attached to the current record.

On Mac, drop is via Finder. On iPad, drop works between apps in Split View / Slide Over. On iPhone, use the `+ Attach file…` button — it opens the iOS document picker.

## How attachment works

1. Keystone copies the file into `~/Library/Containers/com.ryanleewilliams.keystone/Data/Library/Application Support/Keystone/Assets/`.
2. The stored filename is a fresh UUID with the original extension preserved (e.g., `b3f8…ac2.pdf`).
3. SHA-256 hash, byte size, and MIME type are computed and recorded.
4. An asset row is inserted, attached to the current record.
5. A QuickLook thumbnail is generated and shown in the tile.

The original file you dropped in is left alone — you keep your copy, Keystone keeps its copy.

## Tile actions

- **Click** a tile → opens the file in its default app via `NSWorkspace`.
- **Right-click** (Mac) or **long-press** (iOS) a tile:
  - **Open** — same as click.
  - **Reveal in Finder** — Mac only; opens Finder selecting the stored file.
  - **Delete** — removes the asset row and the file on disk.

## Multiple files at once

Drop several files in a single drag — they all import. Or `⌘`-select multiple files in the Attach panel.

## Where things live

```
~/Library/Containers/com.ryanleewilliams.keystone/Data/Library/Application Support/Keystone/
  workspace.sqlite       # database
  Assets/                # file storage
    b3f8…ac2.pdf         # one row in `assets`
    7d12…91f.heic
    …
```

You can `cd` there in Terminal at any time. Files are real files; the database row's `relative_path` column is `Assets/<stored-filename>`.

## What's not (yet) supported

- Inbox folder watcher — drop a file into the workspace folder and have it auto-imported. Coming.
- OCR / text extraction from PDFs — the `extracted_text` column exists but isn't populated.
- Asset deduplication via the SHA hash — duplicates create new rows for now.
- Drag *out* of Keystone (e.g., dragging a tile back to Finder).

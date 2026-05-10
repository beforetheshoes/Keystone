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

## Attachments overview in Settings

Open **Settings → Attachments** for a workspace-wide view of every file you've attached:

- **Total files** and **Total size** across every record.
- **By type** breakdown — images, PDFs, documents, and other — bucketed by MIME type so `.jpg` and `.heic` count together.
- **Encrypted** — count of attachments stored as ciphertext because their record is protected.
- **Search attachments…** — opens a sheet that searches across every database in the workspace by **filename** *and* by the **extracted text** inside PDFs and other documents (when available). A type filter (All / Images / PDFs / Documents / Other) narrows the results. Tap a result to Quick Look the file.

Attachments belonging to **protected records are searched by filename only** — the extracted-text content of an encrypted attachment is never surfaced through the global Settings search, even though the column itself stays plaintext today.

## When an attachment hasn't finished syncing

On a fresh Mac that's still pulling the workspace down from iCloud, a record may show an attachment whose bytes haven't arrived yet. Quick Look used to fail silently in that case; now Keystone shows a **placeholder alert** explaining that the file is still downloading. Try again once iCloud has caught up — there's no retry button.

## What's not (yet) supported

- Inbox folder watcher — drop a file into the workspace folder and have it auto-imported. Coming.
- Asset deduplication via the SHA hash — duplicates create new rows for now.
- Drag *out* of Keystone (e.g., dragging a tile back to Finder).

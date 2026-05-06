# Profile images

Every record can have a cover image — a real photo that replaces the colored initials avatar (the **glyph**) wherever the record appears.

## Setting an image

1. Open the record's detail view.
2. Hover the avatar in the hero (the rounded square top-left of the page). On iPhone, tap it.
3. Pick **Choose photo…** from the menu.
   - **Mac / iPad:** macOS file picker, scoped to images.
   - **iPhone:** iOS Photos picker.
4. The image copies into your workspace's `Assets/` folder, gets content-hashed, and is set as the record's cover.

## Where it shows up

Once a cover is set, it replaces the glyph in:

- The detail-view hero (full size, gradient frame removed)
- Table view rows (small thumbnail)
- List view rows
- Gallery cards (full-bleed banner — the striped tinted hero is replaced by the photo)
- Dashboard "RECENT" rows
- iPhone Home → Family list
- iPhone database lists
- Mac Home → Family / Upcoming / Documents rows

The colored glyph remains the fallback whenever no cover is set, so records without photos still look distinctive.

## Replacing or removing

Open the same hover/tap menu on the avatar:

- **Replace photo…** — pick a different image. The previous file stays in the record's attachments list (it's just no longer designated as the cover) so you don't lose it.
- **Remove photo** — clears the cover. The glyph + accent color come back.

## Where the image lives

Cover images are stored exactly like any other attachment — in
`~/Library/Containers/com.ryanleewilliams.keystone/Data/Library/Application Support/Keystone/Assets/`. The `assets` table records the file's hash, MIME type, and size; the `records.cover_asset_id` column points at the chosen one.

## Tips

- **Crop in Photos first.** Keystone displays covers with `aspectRatio(.fill)` and clips to the rounded rectangle, so wide or tall images get center-cropped. If the framing matters, crop before importing.
- **HEIC, JPEG, PNG, WebP, GIF** all import without conversion. The Photos picker on iOS hands back data in the original format when possible.
- **CloudKit sync** mirrors the asset along with the cover-asset-id pointer, so a cover set on Mac shows up on iPhone (and vice versa) once sync is wired up.

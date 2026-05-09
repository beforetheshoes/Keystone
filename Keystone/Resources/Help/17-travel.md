# Travel area

Keystone seeds a **Travel** area with four databases for trip planning: **Trips**, **Activities**, **Lodging**, and **Transportation**. They're modeled on the structures used by stand-alone trip-planning apps but live alongside the rest of your workspace, so a Trip can pull people from your **People** database, vendors from **Vendors**, attached scans from your existing assets, and so on.

## The four databases

### Trips

The top-level container. Each Trip has:

- **Name** — the display title (e.g. "Tokyo 2026").
- **Notes** — long-form free text.
- **Start** / **End** — optional dates marking the trip window.
- **Locked** — a checkbox that flags the trip as protected. Future per-trip biometric lock will hide locked trips behind Touch ID / Face ID until you explicitly unlock; for now it's a marker only.

### Activities

Things you do *during* a trip — a museum visit, a dinner, a tour booking. Each Activity has:

- **Title** — what it is.
- **Trip** — links the activity back to its parent Trip. Open the Trip to see all linked Activities; open the Activity to jump back.
- **Vendor** — links to the existing **Vendors** database. Reuses MapKit-driven vendor enrichment for phone / address / website, so an entry like "teamLab Planets" gets auto-populated once you add the vendor record.
- **Start** / **End** — when it happens, with the event-local IANA time zone stored alongside the instant.
- **Address** — structured address with autocomplete + an inline map. Pinned on the trip's route map.
- **Cost** — currency-formatted, so totals roll up cleanly later.
- **Notes** — anything else.

### Lodging

Where you stay. Properties parallel Activities with hospitality-specific extras:

- **Name**, **Trip**, **Vendor**, **Notes**, **Cost**.
- **Check-in** / **Check-out** — the stay window, with the event-local IANA time zone.
- **Address** — structured address pinned on the trip's route map.
- **Confirmation** — the booking reference.

### Transportation

How you get there. Properties:

- **Name**, **Trip**, **Vendor** (the airline / rail operator / car rental), **Cost**, **Notes**.
- **Kind** — flight / train / car / bus / ferry, etc.
- **Legs** — a JSON column for multi-leg journeys (e.g. SFO → NRT → ITM). The current editor accepts free-form JSON; a structured per-leg editor with airport autocomplete and per-leg time zones ships in a follow-up.

## Linking trips together

The **Trip** relation property on Activities, Lodging, and Transportation is the spine of a trip plan. A Trip's record-detail view lists every related record automatically — so once you've linked half a dozen Activities and a Lodging to "Tokyo 2026", the trip page shows them all.

Vendors flow through the Travel area the same way they do in Vehicle Maintenance: pick an existing vendor by name, or type a new one and Keystone creates the vendor stub for you on the fly.

## Trip detail layout

Open a Trip and you get a bespoke layout below the standard property fields:

- **Itinerary** — every linked Activity and Lodging stop, grouped by **event-local day**. A 9 PM dinner in Paris stays under "Paris-time Jun 3" no matter where you're sitting when you read it. Within a day, items sort by absolute instant. Tap any row to jump to the underlying record.
- **Calendar** — an embedded week-view scoped to the trip's start/end window, drawing the same activities + lodging stops onto a time grid in their event-local time. Use the toolbar inside the calendar to switch to Day or Month if you need a different framing; navigation chevrons stay inside the trip's window.
- **Route** — a MapKit map pinning every Activity and Lodging address. The map auto-frames so all pins fit. Stops without a structured address (no autocomplete pick) don't appear; pick a suggestion to drop a pin.
- **Total** — sum of the **Cost** property across linked Activities, Lodging, and Transportation, plus a summary line counting activities, lodging stays, and transportation legs (drawn from each Transportation row's `legs` JSON).

The augmentation only renders for Trip records — every other database (People, Vendors, Books, …) keeps the standard detail layout.

## What's not here yet

- **Per-trip biometric lock** that honors the **Locked** checkbox — ships with the privacy-lock work.
- **Multi-leg transportation editor** — `legs` accepts raw JSON today.

These are tracked as their own follow-up issues; the seeded shape here is the foundation they all build on.

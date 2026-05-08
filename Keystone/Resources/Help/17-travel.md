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
- **Start** / **End** — when it happens. Plain dates today; time-zone-aware variants land in a follow-up.
- **Cost** — currency-formatted, so totals roll up cleanly later.
- **Notes** — anything else.

### Lodging

Where you stay. Properties parallel Activities with hospitality-specific extras:

- **Name**, **Trip**, **Vendor**, **Notes**, **Cost**.
- **Check-in** / **Check-out** — the stay window.
- **Confirmation** — the booking reference.

### Transportation

How you get there. Properties:

- **Name**, **Trip**, **Vendor** (the airline / rail operator / car rental), **Cost**, **Notes**.
- **Kind** — flight / train / car / bus / ferry, etc.
- **Legs** — a JSON column for multi-leg journeys (e.g. SFO → NRT → ITM). The current editor accepts free-form JSON; a structured per-leg editor with airport autocomplete and per-leg time zones ships in a follow-up.

## Linking trips together

The **Trip** relation property on Activities, Lodging, and Transportation is the spine of a trip plan. A Trip's record-detail view lists every related record automatically — so once you've linked half a dozen Activities and a Lodging to "Tokyo 2026", the trip page shows them all.

Vendors flow through the Travel area the same way they do in Vehicle Maintenance: pick an existing vendor by name, or type a new one and Keystone creates the vendor stub for you on the fly.

## What's not here yet

- **Calendar view** of activities by day — coming with the calendar view-kind work.
- **Bespoke Trip detail page** with itinerary timeline, mini-calendar, and route map — coming after calendar lands.
- **Per-trip biometric lock** that honors the **Locked** checkbox — ships with the privacy-lock work.
- **Time-zone-aware date properties** — the existing date type is used for now; a `date+tz` type lands shortly and the seed will migrate to it.
- **Multi-leg transportation editor** — `legs` accepts raw JSON today.

These are tracked as their own follow-up issues; the seeded shape here is the foundation they all build on.

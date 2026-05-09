# Maintenance scheduling

Keystone tracks recurring maintenance by combining three things:

1. **The Service Catalog** — a database of recurring services. Each row
   is a thing that needs to happen periodically (replace engine oil,
   inspect brakes, replace brake fluid). Rows carry a mileage interval,
   a time interval, or both.
2. **Event records** — one record per service performed (e.g. one
   `Vehicle Maintenance` row per shop visit). Each event links back to
   the catalog rows it satisfies via the `Services` (multi-relation)
   property.
3. **A pure next-due engine** — given a vehicle's current mileage and
   the most recent event for each catalog row, computes status:
   `OVERDUE`, `DUE SOON`, `NEVER`, or `OK`.

## How statuses are computed

For each (vehicle, catalog row) pair, the engine looks at the newest
event that references that catalog row, then projects the next due
date and mileage by adding the row's intervals. "Whichever comes
first" is honored — both deadlines are evaluated and the more urgent
one drives the status.

- **OVERDUE** — current mileage has passed the next-due mileage, or
  today's date has passed the next-due date.
- **DUE SOON** — within 1,500 miles or 60 days of either deadline.
- **NEVER** — no event has ever covered this catalog row, and the
  vehicle has rolled past at least one interval (or year) without it.
- **OK** — both deadlines comfortably in the future, or the vehicle
  hasn't yet passed its first interval.

Stepped intervals (e.g. brake fluid "first at 60k/3yr, then every
30k/2yr") use a `stage` (`first` / `recurring`) and a `predecessor`
relation. The recurring row stays dormant until the first-stage row
has at least one event; once it does, the recurring row takes over.

## The Honda Maintenance Schedule

The repository ships with the U.S. Normal Conditions schedule from the
Honda Maintenance Schedule PDF, applied to both the 2015 Honda Fit and
2018 Honda CR-V. The 4WD-only items (rear differential fluid) are
scoped to the CR-V. The Severe Conditions variant in the PDF is *not*
seeded — these vehicles are treated as Normal-condition use.

To use a different schedule for a different vehicle, add catalog rows
in the Service Catalog database and set their `Vehicles` relation
appropriately.

## Sidecar workflow (the Cars folder)

The `Cars/` tree at the workspace root is the canonical store for
maintenance receipts. Each receipt is a PDF plus a sidecar markdown
file with YAML frontmatter:

```
---
type: vehicle_maintenance
title: "2024-03-12 - Oil change"
vehicle: "2018 Honda CR-V"
date: "2024-03-12"
kind: "service"
vendor: "East Coast Honda"
mileage: 84210
cost: "82.31"
services: [svc-honda-engine-oil-normal, svc-honda-tire-rotation-normal]
---
```

Two CLI commands turn that tree into a queryable, alert-able state in
Keystone:

- `keystone --cli backfill-sidecar-frontmatter --root Cars/` — walks
  every sidecar, parses its body, and fills in any missing `vendor`,
  `mileage`, `cost`, and `services`. Existing values are never
  overwritten. `--dry-run` shows what would change.
- `keystone --cli import-sidecars --root Cars/` — reads each sidecar
  and upserts a `vehicle_maintenance` record. Vehicles are auto-created
  by name if missing. The vehicle's `current_mileage` snapshot is
  recomputed from the high-water mark across its events.
- `keystone --cli maintenance-status [--vehicle "<title>"]` — prints
  the next-due / overdue table per vehicle.

Both file-touching commands are idempotent. Re-runs land on the same
record IDs and produce no further frontmatter diff.

## Generality (home, vet records)

The catalog uses a `subject_kind` discriminator (`vehicle` / `home` /
`pet`) and a per-kind `Vehicles` relation today. When home or pet
maintenance records arrive, the same engine takes over with new
catalog rows scoped to those subjects — no further schema work
required.

## Future: Apple Reminders

The next-due engine fires a `MaintenanceReminderSink` callback when a
status moves between buckets. The default implementation is a no-op;
once an Apple Reminders / EventKit integration lands, replace
`MaintenanceReminders.current` and reminders surface automatically.

# Calendar

The Calendar view plots records on a date grid. Any database with at least one **date** or **date+time-zone** property can switch to Calendar from the view switcher (Table / Gallery / List / Dashboard / **Calendar**). The Calendar option is hidden for databases without a date column — there's nothing to plot.

## Layouts

The toolbar at the top of the calendar offers four layouts:

- **Month** — a 6-week grid showing the whole month at a glance. Single-day events render as pills inside the day cell; ranged events (Activities with a start *and* end, lodging with check-in *and* check-out) render as continuous bars across the days they span.
- **Week** — seven columns (one per day of the week) with a 24-hour vertical timeline. Timed events are positioned by their event-local start hour and sized to their duration. All-day events sit in a separate lane above the hours.
- **Day** — a single day, full-screen vertical timeline. Same hour positioning as Week.
- **Compact** — a small mini-month on the left plus an agenda list on the right. The mini-month shows event-density dots per day; tapping a day re-anchors the agenda. Useful when you want both a calendar overview and a chronological agenda at once.

Use the chevron arrows to step ±1 (one month / week / day depending on layout). **Today** jumps back to the current day.

## Anchor property

When a database has more than one date column (Activities has both **Start** and **End**), the toolbar shows a small picker so you can choose which column drives the calendar. The default is the first date column in property order.

If a paired end-property exists by name convention — `start`+`end`, `begin`+`end`, `check_in`+`check_out`, `from`+`to`, `open`+`close` — the Calendar auto-detects the pair and renders ranged events as bars. Otherwise events render as one-day pills at the anchor date.

## Time zones

For `date_tz` properties, events render on their **event-local** day, not the viewer's day. A 23:00 dinner reservation in Paris stays on May 8 in the calendar even when you're viewing it from Pacific Time (where the same instant is 14:00 May 8). This matches how a trip planner expects to think about events: "the Paris dinner is on May 8."

The Day and Week views show the event-local time band ("1:00 PM CEST") inside each block so you can read off the wall-clock time directly.

## Filter integration

The same filter bar used in Table view also filters the Calendar. Filter Activities to a single Trip, and the calendar plots only that trip's activities. Filters persist across mode switches.

## What's not here yet

- **Drag-to-create** new records by dragging on a day or hour block.
- **Drag-to-reschedule** existing events.
- **Multi-month scrolling** in Month view (the prev/next chevrons step one month at a time).
- **Per-database calendar default** — the Calendar mode and anchor reset whenever you switch databases. A future version will remember per-database calendar preferences.

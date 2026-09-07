# Timeline

A native macOS app that opens a Google Maps Timeline JSON export and lets you browse it as dates, places, and paths on a map.

Requires macOS 14 or later. Open `Timeline.xcodeproj` in Xcode and run the Timeline scheme.

## Open an export

- **⌘O**, or the folder button in the toolbar
- On first launch, if `~/Downloads/Timeline.json` exists, it is opened automatically

Exports from Google Maps Timeline (Settings → Location history / Timeline → export) are supported as a JSON array of semantic segments (`visit`, `activity`, `timelinePath`). Older Takeout files that wrap `timelineObjects` are also accepted.

The export stores coordinates, Google place IDs, and labels such as Home or Work — not street or business names.

Opened exports are merged into a local SQLite library (`Application Support/Timeline/library.sqlite`). Later backups from the same device upsert by stable visit, activity, and path keys. Road traces from Apple Directions are stored there too, so they are not requested again.

## Using the app

The sidebar has **Dates** and **Places**.

- **Dates** lists every day in the file, grouped by month. Selecting a day draws that day’s route and stay pins, and the overlay lists each stay with time and duration. Hover a row to highlight it on the map.
- **Places** lists unique locations by visit count. Selecting a place focuses the map there; click a visit in the overlay to jump to that day.

The window subtitle (next to the title) shows the selected day or place.

## Project layout

| Path | Role |
| --- | --- |
| `Timeline/` | SwiftUI app sources |
| `project.yml` | XcodeGen spec; regenerate the project with `xcodegen generate` if you change it |
| `Timeline.xcodeproj` | Xcode project used to build and run |

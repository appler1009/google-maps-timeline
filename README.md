# Timeline

A native macOS and iOS app that opens a Google Maps Timeline export and lets you browse it as dates, places, and routes on a map.

Requires macOS 14 or iOS 17. Open `Timeline.xcodeproj` in Xcode and run the **Timeline_macOS** or **Timeline_iOS** scheme.

## Tests

Unit and map tests (`xcodegen generate` after changing `project.yml`):

```
xcodebuild test -scheme Timeline_iOS -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -scheme Timeline_macOS -destination 'platform=macOS'
```

Apple Maps directions are replaced with `ScriptedMapDirectionsClient` in those tests. Marker placement is checked against the published WGS84 coordinate of the Eiffel Tower (`48.858370, 2.294481`).

XCUITest covers the empty library and the Eiffel Tower marker/route flow on iOS and macOS (`TimelineUITests`). UI tests launch with an isolated store and the bundled Paris fixture.

## Open an export

On Mac, **⌘O** or the folder button in the toolbar.

Export from Google Maps Timeline (location history). Current semantic-segment JSON and older Takeout `timelineObjects` files both work. The file has coordinates and labels such as Home or Work, not street names.

Exports merge into a local library on the device. Later backups upsert. Routes are snapped to roads with Apple Maps and cached so they are not requested again.

## Using the app

The sidebar has **Dates** and **Places**.

- **Dates** lists days by month. Selecting a day draws that day’s route and stays.
- **Places** lists unique locations by visit count.

## Project layout

| Path | Role |
| --- | --- |
| `Timeline/` | SwiftUI app sources |
| `TimelineTests/` | Unit and MapKit tests |
| `TimelineUITests/` | XCUITest marker and route flow |
| `project.yml` | XcodeGen spec (`xcodegen generate` if you change it) |
| `Config/Version.xcconfig` | Marketing version `0.1.0` and local build number |
| `Timeline.xcodeproj` | Xcode project used to build and run |

## Versioning

The user-facing version is **0.1.0** (`MARKETING_VERSION` in `Config/Version.xcconfig`). Bump that file when you cut a release.

The build number (`CURRENT_PROJECT_VERSION` / `CFBundleVersion`) stays `1` for local Xcode builds. GitHub Actions sets it to the workflow run number.

Tag a release as `v0.1.0` (or run the **Release** workflow) to build an unsigned macOS `Timeline.app` zip and, on a tag, attach it to a GitHub Release.

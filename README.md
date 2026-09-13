# Timeline

Where you have been, kept on your own devices.

The phone records the places you stop and the journeys between them; the Mac is
where you sit and put it right. Google Maps Timeline exports import alongside
that, which is how the years before you installed this get in.

Nothing goes to a server. The two devices share a library through your own
iCloud account, and the model that guesses what a new place is runs on the
phone.

Requires macOS 14 or iOS 17. Open `Timeline.xcodeproj` and run the
**Timeline_macOS** or **Timeline_iOS** scheme. Place-name guessing additionally
needs Apple Intelligence on iOS 26 or macOS 26; agent access is macOS only.

## How it fits together

A place is a row with a name and a location, and stays point at one — so
renaming, merging or correcting a place moves every stay at it, and a merge can
be undone. Nothing an edit replaces is discarded: superseded versions of a stay
are kept in order and any can be restored, deletes included.

Stays come from Core Location, which reports a visit on arrival and again on
leaving. The one you are currently inside is shown from the first report,
running up to now. Journeys come from Core Motion, which types a drive as a
drive without needing location.

Where an export and your own recording cover the same stop, the recording wins;
where the export covers something the phone never saw, it stays.

Photos taken during a stay are shown beneath it when Lux is reachable on the
local network.

## Agents

macOS can serve the library to an MCP client — nineteen tools for browsing,
diagnosing and repairing. Every repair goes through the same methods the app's
own buttons call, so it is logged, syncs, and can be undone.

The server listens on `127.0.0.1:8787` and is off until turned on. An agent
asks, the Mac shows a six-digit code, and it is let in only if it repeats the
code back; what is stored is a hash of the token, never the token. That stops a
casual local client getting first-class tools — it is not a defence against
something already running as you, which could read the library file directly.

Development only, and off by default:

```
defaults write com.appler.Timeline mcpLogsPairingCode -bool YES
```

That puts the pairing code in the log so an agent can pair unattended, which
defeats the point of having a code.

## Tests

`xcodegen generate` after changing `project.yml`, then:

```
xcodebuild test -scheme Timeline_iOS -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test -scheme Timeline_macOS -destination 'platform=macOS'
```

Apple Maps directions are replaced with `ScriptedMapDirectionsClient`. Marker
placement is checked against the published WGS84 coordinate of the Eiffel Tower
(`48.858370, 2.294481`). XCUITest covers the empty library and the marker and
route flow on both platforms.

Tests needing the on-device model are opt-in:

```
defaults write com.appler.Timeline.tests runModelTests -bool YES
```

Those include a measurement printing call latency and what the model picks
against what the arithmetic picks — the honest way to decide whether it is
earning its place.

### The importer, against your own exports

The bundled fixture checks the parser against what this app believes Google's
format to be, which is not the same as what Google produces. The format has
changed before, and once the phone is recording for itself an export might only
be opened once a year — by which time a renamed field that stopped most segments
being read looks like a year that simply had less in it.

```
cp ~/Downloads/location-history.json LocalExports/
xcodebuild test -scheme Timeline_macOS -destination 'platform=macOS' \
  -only-testing:TimelineMacTests/LocalExportTests
```

Any number of `*.json`; with the directory empty the tests skip. `LocalExports/`
is in `.gitignore` and must stay there — an export is years of precise location
history.

They check that every segment is understood (failing if more than a tenth was
not, which is the partial import that otherwise looks like success), that what
comes out is coherent, and that importing twice changes nothing. If the first
fails, Google has changed something, and the message says how many segments were
missed out of how many.

## Project layout

| Path | Role |
| --- | --- |
| `Timeline/Capture/` | Recording: stays, motion, naming, notifications |
| `Timeline/Models/` | Parser, store, shared shapes |
| `Timeline/Services/` | Database, iCloud sync, routing, photos |
| `Timeline/Services/MCP/` | The agent-facing server |
| `Timeline/Views/` | SwiftUI, shared between both platforms |
| `TimelineTests/` | Unit and MapKit tests |
| `TimelineUITests/` | XCUITest marker and route flow |
| `LocalExports/` | Your own Google exports, never committed |
| `project.yml` | XcodeGen spec |
| `Config/Version.xcconfig` | Marketing version and local build number |

## Versioning

The user-facing version is **0.1.0** (`MARKETING_VERSION` in
`Config/Version.xcconfig`). Bump it when you cut a release.

The build number stays `1` for local builds; GitHub Actions sets it to the
workflow run number. Tag `v0.1.0` (or run the **Release** workflow) to build an
unsigned macOS `Timeline.app` zip and attach it to a GitHub Release.

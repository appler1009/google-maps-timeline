# Agent notes — Timeline

## macOS: rebuild, reinstall, restart

After **any** change that affects the macOS app (including shared `Timeline/**/*.swift` that ships in the Mac target), **rebuild, reinstall, and restart** before you finish. Do not wait for the user to ask.

Skip this for test-only edits (`TimelineTests/`, `TimelineUITests/`, `TimelineMacTests/`, `TimelineMacUITests/`).

iOS still needs a separate Xcode rebuild/run on device or simulator.

### Commands

```bash
xcodebuild -project Timeline.xcodeproj -scheme Timeline_macOS -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /Users/appler/Library/Developer/Xcode/DerivedData/Timeline-diksfrbjlcplmdezraoyfzhqpqro \
  build

osascript -e 'tell application "Timeline" to quit' 2>/dev/null || true
killall Timeline 2>/dev/null || true
sleep 0.5
APP="/Users/appler/Library/Developer/Xcode/DerivedData/Timeline-diksfrbjlcplmdezraoyfzhqpqro/Build/Products/Release/Timeline.app"
rm -rf /Applications/Timeline.app
ditto "$APP" /Applications/Timeline.app
open -a /Applications/Timeline.app
```

Do **not** ad-hoc resign. Confirm a new `Timeline` process is running. If the build fails, fix it and retry; do not leave the installed app stale.

(Same workflow lives in `.cursor/rules/macos-rebuild.mdc`.)

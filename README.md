# MicPatch

Hides the microphone-in-use pill that macOS shows in the menu bar. While an app is recording from the mic, MicPatch covers the pill with a patch of the menu bar background.

Built on macOS 27 (MacBook Air, 1710×1107-point screen).

## How it works

- Watches Core Audio for any process recording from a physical input device (`kAudioProcessPropertyIsRunningInput`, macOS 14.2+). Input from virtual devices such as BlackHole or Loopback is ignored, since macOS shows no pill for it.
- Reads the pill's exact frame through Accessibility. On macOS 27 the pill is the menu bar item `com.apple.menuextra.audiovideo` ("Audio and Video Controls"), drawn by MenuBarAgent.
- Draws a borderless, click-through window over the pill, filled with a clean image of the menu bar background (`menubar-bg.png`) with feathered edges.

MicPatch needs Accessibility permission (System Settings → Privacy & Security → Accessibility) and asks for it on launch. Without it, it covers nothing. The build is ad-hoc signed, so macOS treats every rebuild as a new app: after rebuilding, switch MicPatch off and on again in that list.

MicPatch doesn't change any privacy settings or use the mic. It only draws over the pill.

## Limits

- The dot after the clock stays. macOS draws it above every app window.
- `menubar-bg.png` comes from a screenshot of one screen and wallpaper. If you change the wallpaper, appearance or display, recalibrate (below). The screen size is `calibratedSize` in `MicPatch.swift`; on any other screen size the patch stays off.
- In full-screen apps the menu bar is hidden, so the patch is off.

## Install

```bash
./install.sh
```

Builds the app, copies it to /Applications, registers it to open at login, and starts it. It appears in System Settings → General → Login Items & Extensions, where you can turn it off. To remove it:

```bash
/Applications/MicPatch.app/Contents/MacOS/MicPatch --unregister-login
pkill -x MicPatch; rm -r /Applications/MicPatch.app
```

## Build and run without installing

```bash
./build.sh
open MicPatch.app
```

Quit with `pkill -x MicPatch`. It logs to `~/Library/Logs/MicPatch.log`.

To see what MicPatch can find, run `MicPatch.app/Contents/MacOS/MicPatch --list-items` from a terminal that has Accessibility permission. While the mic is in use, the pill is marked `PILL`. If it's missing (for example after a macOS update renames it), the list shows what to look for, and `pillIdentifier` in `MicPatch.swift` is the value to change.

## Recalibrate

Take a full-screen screenshot (⇧⌘3) with the menu bar visible, then:

```bash
swiftc -O -o calibrate calibrate.swift
./calibrate ~/Desktop/Screenshot.png menubar-bg.png 1710   # last argument: screen width in points
./build.sh
```

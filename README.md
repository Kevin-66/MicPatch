# MicPatch

Hides the microphone-in-use pill that macOS shows in the menu bar. While an app is recording from the mic, MicPatch covers the pill with a patch of the menu bar background.

Built on macOS 27 (MacBook Air, 1710×1107-point screen).

## How it works

- Watches Core Audio for any process recording from an input device (`kAudioProcessPropertyIsRunningInput`, macOS 14.2+).
- Keeps an invisible 1-point status item as an anchor. When the mic turns on, macOS adds the pill next to it and shifts the menu bar items, so the anchor's movement tells MicPatch where the pill is.
- Draws a borderless, click-through window over the pill, filled with a clean image of the menu bar background (`menubar-bg.png`) with feathered edges.

MicPatch doesn't change any privacy settings or use the mic. It only draws over the pill.

## Limits

- The dot after the clock stays. macOS draws it above every app window.
- `menubar-bg.png` comes from a screenshot of one screen and wallpaper. If you change the wallpaper, appearance or display, recalibrate (below). The screen size is `calibratedSize` in `MicPatch.swift`; on any other screen size the patch stays off.
- In full-screen apps the menu bar is hidden, so the patch is off.

## Build and run

```bash
./build.sh
open MicPatch.app
```

Quit with `pkill -x MicPatch`. It logs to `~/Library/Logs/MicPatch.log`.

To check placement without the mic, quit MicPatch and run `open MicPatch.app --args --dry-run`. It fakes 3 seconds of mic use with an invisible patch and logs where the patch went.

## Recalibrate

Take a full-screen screenshot (⇧⌘3) with the menu bar visible, then:

```bash
swiftc -O -o calibrate calibrate.swift
./calibrate ~/Desktop/Screenshot.png menubar-bg.png 1710   # last argument: screen width in points
./build.sh
```

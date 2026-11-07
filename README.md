# Livewall

A live wallpaper app for macOS. Play your own videos or built-in animated scenes behind your desktop, right from the menu bar.

## Features

- **Video wallpapers:** add MP4, MOV or M4V files by dragging them in, using the + button, or dropping them on the app icon.
- **Animated scenes:** Aurora, Warp Speed, Deep Blue, Sunset Waves and Lava Lamp, drawn live (no video files needed).
- **Library:** favorites, categories, search, and live previews when you hover a wallpaper.
- **Multiple displays:** one wallpaper everywhere, or a different one per display. Turn displays on or off.
- **Lock screen frame:** scrub through any wallpaper, stop on a frame, and use it as your lock screen picture.
- **Saves energy:** pauses when a window covers the desktop, when the display sleeps, on battery or when the battery is low (your choice).
- **Auto-change:** switch to a new wallpaper every few minutes, hours or days, from all wallpapers or just favorites.
- **Playback options:** sound and volume, speed, and fill / fit / stretch scaling.
- **Menu bar controls:** pause, next wallpaper, sound, quick switch, launch at login.

## Requirements

- macOS 15 or later on an Apple silicon Mac
- Xcode or the Command Line Tools (`xcode-select --install`)

## Build and run

```bash
bash build.sh
open Livewall.app
```

`build.sh` compiles the app with `swiftc` (no Xcode project needed), signs it for local use, and puts `Livewall.app` in this folder. Drag it to Applications to keep it.

If the newest macOS SDK can't build SwiftUI apps with the standalone Command Line Tools, the script falls back to an older SDK automatically.

## How it works

- Each display gets a borderless window at the desktop level, below your desktop icons. Videos play with AVFoundation; scenes are drawn with SwiftUI `Canvas`.
- macOS shows your desktop picture on the lock screen, so Livewall sets a still frame as the macOS wallpaper. Your original wallpaper is remembered and restored when you remove Livewall's.
- Your library and settings live in `~/Library/Application Support/Livewall`. Imported videos are copied there; your original files aren't changed.

## Project layout

| Path | What's in it |
|---|---|
| `Sources/App.swift` | App entry point, menu bar menu, login item |
| `Sources/Store.swift` | Library, settings, saving, video import |
| `Sources/WallpaperManager.swift` | Desktop windows, playback, battery and covered-desktop checks |
| `Sources/Scenes.swift` | The animated scenes |
| `Sources/Views.swift` | Library window, displays page, settings |
| `Sources/LockScreen.swift` | Lock screen frame picker |
| `tools/make_icon.swift` | Draws the app icon |
| `Resources/` | `Info.plist` and the app icon |

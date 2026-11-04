# Mirror

Show your iPhone on your iPad, or your iPad on your iPhone. Live, sharp, with sound.

A native SwiftUI app for iPhone and iPad (iOS / iPadOS 17 or later).

## Features

- **Live screen mirroring** in both directions, up to 60 fps, hardware HEVC.
- **Sound** from the shared screen plays on the other device.
- **Drag and drop** photos and files onto the mirror to send them. They land in the other device's Inbox with a notification.
- **Picture in Picture**: keep watching the other screen in a small floating window.
- **Private**: devices talk directly (peer-to-peer Wi-Fi). Every stream is encrypted with a key made from a 6-digit pairing code.
- **Apple-style details**: real device corner radius, auto-hiding glass controls, haptics, Dynamic Type, VoiceOver labels, dark mode, iPad multitasking, reconnects on its own.

## Install

See **[docs/SETUP.md](docs/SETUP.md)**. One-time setup from Safari on your iPad, then a cloud Mac builds the app and sends it to TestFlight. No Mac needed.

## How it works

```
 Device being shown                         Device showing it
 ──────────────────                         ─────────────────
 ReplayKit broadcast extension              Mirror app
   screen frames ─► rotate/scale              ◄─ Bonjour + peer-to-peer Wi-Fi
   ─► HEVC encoder ─┐                         TLS (key from pairing code)
   app audio ─► PCM ┼─► TLS over TCP ───────► decoder ─► AVSampleBufferDisplayLayer ─► PiP
                    │                         audio ─► AVAudioEngine
   Inbox ◄──────────┴──────────────────────── drag & drop files
```

| Folder | What's inside |
| --- | --- |
| `Mirror/` | The app: SwiftUI screens, receiver, video and audio playback, file sending |
| `Broadcast/` | Broadcast Upload Extension: captures, encodes and streams the screen |
| `Shared/` | Code used by both: wire protocol, encrypted connection, settings |
| `project.yml` | Xcode project definition ([XcodeGen](https://github.com/yonaskolb/XcodeGen)) |
| `.github/workflows/` | `build.yml` compiles every push. `testflight.yml` signs and uploads |

### Build on a Mac (optional)

```sh
brew install xcodegen
xcodegen generate
open Mirror.xcodeproj
```

Set your team in Signing & Capabilities for both targets, then run on a device. (Screen broadcast doesn't work in the Simulator.)

## Limits (set by iOS, not by Mirror)

- **No remote control.** iOS lets no app tap or type on another iPhone or iPad, even through TestFlight. For control, use FaceTime screen sharing (iOS 18+), which can request remote control. A planned add-on uses a small ESP32 board acting as a Bluetooth mouse and keyboard.
- Sharing starts with **Start Broadcast**, and iOS shows a red pill while sharing.
- Sharing pauses when the shared device locks.
- Apps that block recording (streaming video, some banking apps) show black.

## Roadmap

- ESP32 Bluetooth mouse/keyboard bridge for real control of the shared device.
- Send files from the shared device back to the viewer.

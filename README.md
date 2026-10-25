# PiPGlass

See-through, click-through Picture-in-Picture for Firefox on macOS.

PiPGlass mirrors Firefox's Picture-in-Picture video into a translucent overlay that floats above
everything, including full-screen apps. Clicks pass straight through it to the windows underneath,
so you can keep working while the video plays on top. Firefox can't do this itself, so PiPGlass
captures the PiP window and redraws it.

> **Vibe coded.** I built this with an AI coding assistant ([Claude Code](https://claude.com/claude-code))
> for my own use and I'm sharing it as-is. It works on my machine (macOS 26, Apple silicon). Read
> the code before you build it, and expect rough edges.

## Features

- Attaches automatically when a Firefox Picture-in-Picture window opens and detaches when it closes
- Opacity from 20% to 100%, click-through on or off, and drag or resize when click-through is off (the aspect ratio stays locked)
- Shows on all Spaces and over full-screen apps
- Hides Firefox's own PiP window so you don't see two videos (audio keeps playing from Firefox)
- Menu bar app with no Dock icon, plus global hotkeys
- Light on resources: capped at 30 fps and captured at the overlay's size (about 3–4% CPU on an M-series Mac)

## Requirements

- macOS 14 or later. It was only tested on macOS 26.5 on Apple silicon.
- Xcode Command Line Tools (`xcode-select --install`). The full Xcode app isn't needed.
- Firefox

## Build & install

```bash
git clone https://github.com/sm-desai/PiPGlass.git
cd PiPGlass
./build.sh          # compiles, signs locally, installs to /Applications/PiPGlass.app
open -a PiPGlass
```

There's no prebuilt download, and that's deliberate: you build it from source you can read.

On first launch macOS asks for two permissions. Turn both on under **System Settings → Privacy & Security**:

| Permission | Why |
|---|---|
| **Screen & System Audio Recording** | To capture the Firefox PiP window. Audio is never captured. |
| **Accessibility** | To move Firefox's own PiP window out of view, and back when you quit |

If macOS offers **Quit & Reopen** after you grant Screen Recording, accept it.

## Usage

1. Play a video in Firefox and pop it out into Picture-in-Picture. The overlay appears automatically.
2. Use the hotkeys or the menu bar icon to adjust it:

| Hotkey | Action |
|---|---|
| ⌃⌥↑ / ⌃⌥↓ | Opacity up or down by 10% |
| ⌃⌥T | Toggle click-through. When it's off, drag to move and drag an edge or the corner grip to resize. |
| ⌃⌥H | Show or hide the overlay. Capture stops while it's hidden. |

The menu has an opacity slider, the same toggles, **Hide Firefox's PiP Window**, and a **Source**
picker (Automatic, or any open Firefox window). Settings and the overlay's position persist between launches.

## How it works

- **Capture:** ScreenCaptureKit captures one window (Firefox, title `Picture-in-Picture`) at the overlay's pixel size, 30 fps max, no audio.
- **Overlay:** a borderless, non-activating `NSPanel` above floating windows, joined to all Spaces, with `ignoresMouseEvents` for click-through.
- **Hiding Firefox's window:** the Accessibility API moves Firefox's PiP window to the bottom-right screen corner. macOS won't put another app's window fully off-screen, so a small corner would stay visible. PiPGlass covers that spot with a tiny patch showing a live capture of whatever is behind it. Firefox keeps rendering at full speed while parked.
- **Hotkeys:** Carbon `RegisterEventHotKey`, which doesn't need any extra permission.

## Privacy & security

- **No network access.** PiPGlass makes no network requests, has no analytics, and doesn't update itself.
- **Nothing leaves your Mac.** Captured frames are drawn on screen and never saved.
- **Logs stay local and don't include titles.** The log at `~/Library/Logs/PiPGlass/PiPGlass.log` records window sizes and IDs but not window titles (those can contain your browsing history). The only exception is the generic `Picture-in-Picture` title.
- **Local code signing only.** macOS ties permissions to an app's signature. `build.sh` creates a self-signed certificate in a private keychain at `~/Library/Application Support/PiPGlass-Signing/` so rebuilds keep your permissions. That keychain is locked with a random password generated on your Mac and stored in your login keychain. The repository contains no keys or passwords, and the certificate is only used to sign PiPGlass on your own machine.
- **No debug hooks in normal builds.** The signal-driven self-test hooks used during development are compiled out unless you build with `PIPGLASS_DEBUG=1`. They'd let any local process request a screenshot, so leave them off.
- **Not notarized** by Apple. You build and sign it yourself, so Gatekeeper doesn't get involved.

## Known limitations

- You can't control playback through the overlay. Pause and seek in the Firefox tab, or turn off "Hide Firefox's PiP Window" to get the real PiP window back.
- Clicks in a roughly 43×49 pt area in the bottom-right screen corner are blocked while Firefox's window is hidden there.
- DRM-protected streams may capture as black.
- Firefox only. The PiP window is matched by its English title. For other languages:
  `defaults write com.local.PiPGlass pipTitle "<your Firefox's PiP window title>"`
- macOS may sometimes ask you to re-confirm Screen Recording for PiPGlass.

## Uninstall

```bash
pkill -x PiPGlass
rm -rf /Applications/PiPGlass.app
defaults delete com.local.PiPGlass
rm -rf ~/Library/Logs/PiPGlass
rm -rf ~/Library/Application\ Support/PiPGlass-Signing
security delete-generic-password -s "PiPGlass signing keychain"
tccutil reset ScreenCapture com.local.PiPGlass
tccutil reset Accessibility com.local.PiPGlass
```

## License

[MIT](LICENSE)

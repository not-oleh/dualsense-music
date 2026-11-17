# DualSense Music

Turns the audio playing on your Mac into vibration on a PS5 DualSense controller.

- **Left grip:** bass (below ~120 Hz).
- **Right grip:** voice and melody (~300 to 3000 Hz).
- **Taps:** a short click on the matching grip for each new drum hit, note or syllable.

When the controller is ready it plays a short left, right, both pulse.

## Requirements

- macOS 13 or newer
- A DualSense connected over Bluetooth or USB

## Install

Pair the controller (hold **PS** + **Create** until the light flashes, then pick it in System Settings → Bluetooth), then run:

```bash
curl -L https://github.com/not-oleh/dualsense-music/releases/latest/download/dualsense-music.zip -o /tmp/dsm.zip && unzip -o /tmp/dsm.zip -d ~ && chmod +x ~/dualsense-music
```

Run the same command again to update. Then start it:

```bash
~/dualsense-music
```

The first run asks for permission to record system audio. Allow Terminal under **System Settings → Privacy & Security → Screen & System Audio Recording**, restart Terminal and run it again. Audio is only analysed, never saved.

## Menu bar app

```bash
curl -L https://github.com/not-oleh/dualsense-music/releases/latest/download/DualSense-Music-app.zip -o /tmp/dsm-app.zip && unzip -o /tmp/dsm-app.zip -d /Applications && open "/Applications/DualSense Music.app"
```

Or build it with `./make-app.sh` (needs Xcode command line tools). The menu lets you toggle vibration, pick an app to follow, set the strength and choose the mode. Settings are remembered. Allow system audio recording the first time, then reopen the app.

## Usage

| What | Command |
|---|---|
| All system audio | `~/dualsense-music` |
| One app only | `~/dualsense-music --app Spotify` |
| Strength (default 0.7) | `--gain 0.4` or `--gain 1.2` |
| List apps | `--list-apps` |
| Test the controller | `--test` |
| Solo instruments | `--instrumental` |
| Experimental raw waveform | `--raw` |

Stop with Control-C. To keep it running after closing Terminal: `nohup ~/dualsense-music > /dev/null 2>&1 &`, and stop it with `pkill dualsense-music`.

## How it works

1. ScreenCaptureKit captures system audio (or one app's audio).
2. The audio is split into a bass band and a voice/melody band. Hi-hats and cymbals are left out.
3. Each band is measured every 2 ms with a fast attack (~3 ms) and a short decay (~20 to 45 ms). When a band drops below its recent average the vibration stops, so pauses stay still. Automatic gain handles quiet and loud songs.
4. Each band's spectral balance sets the sharpness of its vibration.
5. A band jumping above its quietest level of the last 50 ms fires a click (at most ~11 per second), scaled by how hard the note hit.
6. Core Haptics drives one haptic engine per grip, updated about 30 times a second, plus the click transients.

### Instrumental mode

Standard mode lets held notes keep vibrating, so fast piano runs can blur together. Instrumental mode makes every key press a 40 ms spike followed by near silence. Low notes (below ~300 Hz) go left, high notes right, chords both. It feels choppy on songs with drums and vocals.

### Raw mode (experimental)

Sends an actual waveform over Bluetooth, like a PS5 does, using the packet format found by [SAxense](https://apps.sdore.me/SAxense). Left gets the real bass wave (below ~150 Hz). Right gets a 200 Hz buzz whose strength follows the voice and melody. It needs the faster 7.5 ms Bluetooth rate, so it turns on Game Mode while running (via `gamepolicyctl`, which comes with Xcode) and restores automatic afterwards. Each report carries 20.7 ms of sound in a double-length packet. Tested on one controller (firmware 0x0630). It also turns the light bar yellow, and Core Haptics is off in this mode.

## Notes

- Games using the controller at the same time can override the vibration.
- Build: `swift build -c release`, run `.build/release/dualsense-music`. Tests: `swift test`.

## License

MIT

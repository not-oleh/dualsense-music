# DualSense Music — feel sound through your hands

**DualSense Music turns the sound playing on your Mac into vibrations on a PlayStation 5 DualSense controller, so you can feel music through touch.**

It was made for people who are blind, Deaf, hard of hearing or deafblind, and for anyone who wants to *feel* a song, not only hear it. Hold the controller and the music moves through your hands:

- **Left hand — the bass.** Kick drums, bass lines, the low rumble of a film score.
- **Right hand — the voice and the melody.** Singing, guitars, keys. Every new syllable or note is a pulse, and the pause between words or lines goes still.

There is nothing to look at. The app speaks plain text that works with VoiceOver, and the controller plays a short **left, right, both** pulse when it is ready. The pulse tells you everything is working without needing a screen.

## What you need

- A Mac with macOS 13 Ventura or newer (Apple silicon or Intel).
- A DualSense controller paired by Bluetooth or plugged in by USB.

## Install

1. Pair the controller: hold the **PS** button and the **Create** button (small button left of the touchpad) until the light flashes, then choose *DualSense Wireless Controller* in **System Settings → Bluetooth**.
2. Open **Terminal** (press Command-Space, type *Terminal*, press Return) and paste:

   ```bash
   curl -L https://github.com/not-oleh/dualsense-music/releases/latest/download/dualsense-music.zip -o /tmp/dsm.zip && unzip -o /tmp/dsm.zip -d ~ && chmod +x ~/dualsense-music
   ```

   This puts the program in your home folder.

3. Run it once:

   ```bash
   ~/dualsense-music
   ```

   The first time, macOS asks to let Terminal record the screen and system audio. The program listens only to sound; it never records or saves anything. Allow it in **System Settings → Privacy & Security → Screen & System Audio Recording**, turn on **Terminal**, quit Terminal and open it again, then run the command again.

## Use

| What you want | Type |
|---|---|
| Feel everything your Mac plays | `~/dualsense-music` |
| Feel only one app, e.g. Spotify | `~/dualsense-music --app Spotify` |
| Softer or stronger vibration (default 0.7) | `~/dualsense-music --gain 0.4` or `--gain 1.2` |
| See which apps can be chosen | `~/dualsense-music --list-apps` |
| Check the controller works | `~/dualsense-music --test` |
| Stop | press **Control-C** |

To keep it running after you close Terminal:

```bash
nohup ~/dualsense-music > /dev/null 2>&1 &
```

Stop it later with `pkill dualsense-music`.

## How it works

1. **Listening.** Apple's ScreenCaptureKit gives the program a live copy of the sound your Mac plays, for the whole system or for one app. Your speakers keep working as normal.
2. **Splitting.** The sound is split into a bass band (below about 120 Hz) and a voice/melody band (about 300 to 3000 Hz). Hi-hats and cymbals are left out so they don't blur the voice.
3. **Feeling.** The sound is measured every 2 milliseconds. Each band reacts within 3 ms and fades within about 20 to 45 ms, so a drum hit feels like a hit and not a buzz. Whenever a band gets quieter than its recent average, the vibration stops, so pauses between words and spaces between notes are felt as stillness. Automatic gain keeps quiet songs and loud songs both full, and true silence stays still.
4. **Vibrating.** Apple's own **Core Haptics** (the framework Apple uses for the DualSense) drives a separate haptic engine for each grip, updated 100 times a second.

## Notes

- Over Bluetooth, macOS drives the DualSense's rumble motors. That is strong and expressive, but the controller's fine "HD haptics" are only reachable as a USB audio device, which this version does not use yet.
- Gaming apps that use the controller at the same time can override the vibration.
- Build from source: `swift build -c release`, then run `.build/release/dualsense-music`. Run the tests with `swift test`.

## License

MIT

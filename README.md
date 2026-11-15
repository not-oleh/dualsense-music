# DualSense Music — feel sound through your hands

**DualSense Music turns the sound playing on your Mac into vibrations on a PlayStation 5 DualSense controller, so you can feel music through touch.**

It was made for people who are Deaf, hard of hearing or deafblind, and for anyone who wants to *feel* a song, not only hear it. Hold the controller and the music moves through your hands:

- **Left hand — the bass.** Kick drums, bass lines, the low rumble of a film score. A kick feels crisp and punchy, a deep sub-bass feels round.
- **Right hand — the voice and the melody.** Singing, guitars, keys. A bright, high voice feels crisp; a low, warm one feels dull. The pause between words or lines goes still.
- **Taps.** Every new drum hit, note or syllable is a short, sharp click in the hand it belongs to, so you can count the rhythm and follow the words.

There is nothing to look at, so it works for blind and deafblind users too. The app speaks plain text that works with VoiceOver, and the controller plays a short **left, right, both** pulse when it is ready. The pulse tells you everything is working without needing a screen.

## What you need

- A Mac with macOS 13 Ventura or newer (Apple silicon or Intel).
- A DualSense controller paired by Bluetooth or plugged in by USB.

## Install

1. Pair the controller: hold the **PS** button and the **Create** button (small button left of the touchpad) until the light flashes, then choose *DualSense Wireless Controller* in **System Settings → Bluetooth**.
2. Open **Terminal** (press Command-Space, type *Terminal*, press Return) and paste:

   ```bash
   curl -L https://github.com/not-oleh/dualsense-music/releases/latest/download/dualsense-music.zip -o /tmp/dsm.zip && unzip -o /tmp/dsm.zip -d ~ && chmod +x ~/dualsense-music
   ```

   This puts the program in your home folder. To update later, paste the same command again.

3. Run it once:

   ```bash
   ~/dualsense-music
   ```

   The first time, macOS asks to let Terminal record the screen and system audio. The program listens only to sound; it never records or saves anything. Allow it in **System Settings → Privacy & Security → Screen & System Audio Recording**, turn on **Terminal**, quit Terminal and open it again, then run the command again.

## Menu bar app

If you prefer not to use Terminal every time, there is a menu bar app. Install it by pasting this into Terminal once:

```bash
curl -L https://github.com/not-oleh/dualsense-music/releases/latest/download/DualSense-Music-app.zip -o /tmp/dsm-app.zip && unzip -o /tmp/dsm-app.zip -d /Applications && open "/Applications/DualSense Music.app"
```

To build it from source instead, run `./make-app.sh` (needs Xcode's command line tools). This creates **DualSense Music.app** in the project folder.

When the app is open, a game controller icon appears in the menu bar. Its menu lets you:

- turn the vibration on or off,
- choose which app to feel: everything, or one running app such as Spotify or Music,
- choose the strength: soft, normal or strong,
- choose the mode: standard, instrumental (for solo piano and similar), or the experimental raw waveform,
- quit.

Your choices are remembered. The first time, macOS asks to let *DualSense Music* record system audio; allow it and open the app again. The menu is plain text and works with VoiceOver.

## Use

| What you want | Type |
|---|---|
| Feel everything your Mac plays | `~/dualsense-music` |
| Feel only one app, e.g. Spotify | `~/dualsense-music --app Spotify` |
| Softer or stronger vibration (default 0.7) | `~/dualsense-music --gain 0.4` or `--gain 1.2` |
| See which apps can be chosen | `~/dualsense-music --list-apps` |
| Check the controller works | `~/dualsense-music --test` |
| Solo piano or another solo instrument: every note a sharp hit | `~/dualsense-music --instrumental` |
| Experimental: finer detail, sent as a waveform | `~/dualsense-music --raw` |
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
4. **Texture.** Each band is split once more (bass around 60 Hz, voice around 1000 Hz). The more energy sits in the upper half, the crisper that grip feels.
5. **Taps.** When a band rises well above its quietest point of the last 50 milliseconds, a sharp click fires, at most about 11 per second. This catches a new piano key pressed while earlier notes still ring. The harder the note lands, the stronger the tap. A held note taps once, then stays smooth.
6. **Vibrating.** Apple's own **Core Haptics** (the framework Apple uses for the DualSense) drives a separate haptic engine for each grip: strength and sharpness updated about 30 times a second (as fast as macOS passes them on), each update carrying the strongest moment since the last, plus a transient click for every tap.

## Instrumental mode

Standard mode is made for songs: a held note keeps vibrating, so a fast run of piano notes can blur into one rumble. Instrumental mode (`--instrumental`, or *Instrumental* in the menu) is for a solo instrument with little or nothing behind it. Every key press is a spike: full strength for 40 milliseconds, then straight down to almost nothing until the next note. Low notes (below about 300 Hz) go to the left hand, high notes to the right, and chords to both. On songs with drums and vocals it will feel choppy; use standard mode for those.

## Notes

- Wireless is the point, so everything runs over Bluetooth. The default mode uses Core Haptics with live sharpness and taps.
- **Raw mode (`--raw`, experimental)** drives the DualSense's actuators with a waveform over Bluetooth, the way a PS5 does. The left hand gets the real bass wave (below about 150 Hz), so every bass note has its own pitch and every kick its own shape. The right hand gets a 200 Hz buzz whose strength follows the voice and melody 300 times a second. Skin cannot feel pitches above a few hundred hertz, so playing them directly would only make the controller sound like a small speaker. It builds on the packet format found by [SAxense](https://apps.sdore.me/SAxense). Two things make it work on a Mac:
  - macOS sends the controller one small Bluetooth packet every 15 ms, or every 7.5 ms in Game Mode. Raw mode needs the faster rate, so it turns Game Mode on while it runs and back to automatic when it stops. This uses `gamepolicyctl`, which comes with Xcode.
  - Each report carries 20.7 ms of sound in a double-length packet, so it fits in two Bluetooth packets.
  
  It was tested on one controller with firmware 0x0630; it also turns the light bar yellow. Core Haptics is off in raw mode.
- Gaming apps that use the controller at the same time can override the vibration.
- Build from source: `swift build -c release`, then run `.build/release/dualsense-music`. Run the tests with `swift test`.

## License

MIT

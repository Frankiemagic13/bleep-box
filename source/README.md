# Bleep Box

Bleep Box mutes your microphone and plays a bleep when you push a Stream Deck key. OBS gets the result as its own audio source: **Bleep Box Mic**. You do not need a virtual audio cable.

Bleep Box has three parts:

| Part | What it does |
|---|---|
| OBS plugin | Adds the **Bleep Box Mic** source to OBS. The source records your microphone. When a bleep starts, the source mutes the mic and plays the bleep. |
| Bleep Box app | The settings window. Select the microphone, the bleep sound and the volume. It has a large BLEEP button and the hotkey **Ctrl + Shift + B**. |
| Stream Deck plugin | The **Bleep** action. Hold the key to bleep (or set it to toggle). Each key can have its own sound. |

The parts communicate on this computer only, on `http://127.0.0.1:28196`. No data goes to the internet.

## Requirements

- Windows 10 or Windows 11 (64-bit)
- OBS Studio 30 or later
- Stream Deck software 6.4 or later

## Install

1. Close OBS.
2. Extract the `BleepBox` folder from the zip file.
3. Double-click **Install.bat**. Windows asks for administrator permission. Click **Yes**.
4. The Stream Deck window opens. Click **Install**.

## Set up OBS

1. Open OBS.
2. In **Sources**, click **+**. Select **Bleep Box Mic**. Click **OK**.
3. In the properties, select your microphone. Set the input gain. Click **OK**.
4. Remove or mute your old microphone source (for example "Mic/Aux" or "Audio Input Capture"). If you do not do this, viewers hear your voice when you bleep.
5. To hear the bleep in your headphones: **Edit → Advanced Audio Properties → Bleep Box Mic → Monitor and Output**.

## Set up Stream Deck

1. In the Stream Deck window, find the **Bleep Box** category.
2. Drag **Bleep** onto a key.
3. Set the key:
   - **Mode:** *Hold to bleep*, or *Press to start / stop*.
   - **Sound:** *Use app setting*, or one sound for this key only. *Mute only* mutes the mic with no sound.
   - **Volume:** *Use app volume*, or one volume for this key only.

Key images:

| Key | Meaning |
|---|---|
| Orange **BLEEP** | Ready. The mic is live. |
| Red **BLEEPING** | The bleep is on. The mic is muted. |
| Grey **APP OFF** | OBS is not open, or the OBS plugin is not installed. |

## Use the app

- Open **Bleep Box** from the Start menu or the desktop.
- Hold the large **BLEEP** button, or hold **Ctrl + Shift + B**.
- **My .wav:** click **Choose .wav file…** to use your own sound (16-bit, 24-bit or 32-bit WAV).
- The app and OBS keep the settings when you close them.

## Troubleshooting

| Problem | Do this |
|---|---|
| The app shows "OBS plugin not found". | Open OBS. Make sure that you installed with Install.bat. |
| The app shows "Add the source". | Add **Bleep Box Mic** in OBS (see "Set up OBS"). |
| The app shows "Mic error". | In OBS, open the Bleep Box Mic properties and select a different microphone. |
| Viewers hear my voice during a bleep. | Mute or remove your old microphone source in OBS. Make sure that **Mute mic fully while bleeping** is on. |
| The Stream Deck key shows APP OFF. | Open OBS. |
| Port 28196 is in use. | Close the other program that uses this port. See the OBS log (Help → Log Files). |

## Uninstall

Double-click **Uninstall.bat**. To remove the Stream Deck plugin: **Stream Deck → Preferences → Plugins → Bleep Box → Uninstall**.

---

## For developers: build

GitHub Actions builds everything on a Windows runner (`.github/workflows/build.yml`).

1. Push this folder to a GitHub repository (branch `main`).
2. Open the **Actions** tab. Wait for **Build Bleep Box (Windows)** to finish.
3. Download the **BleepBox-Windows** artifact. It is the folder for "Install".
4. To make a release zip, push a tag, for example `v1.0.0`.

The workflow gets the headers from the latest OBS release and makes `obs.lib` from `obs.dll`.

Project folders:

- `obs-plugin/` — C++ OBS plugin (WASAPI capture, bleep sounds, HTTP control)
- `app/` — C# WPF app (.NET 8)
- `streamdeck/` — Stream Deck plugin (HTML/JS)
- `installer/` — install and uninstall scripts
- `tools/make_icons.py` — makes the key and app images

### Control API (127.0.0.1:28196, HTTP GET)

| Path | Result |
|---|---|
| `/status` | JSON state |
| `/bleep/on?sound=quack&volume=60` | Starts the bleep (sound and volume are optional, for this bleep only) |
| `/bleep/off` | Stops the bleep |
| `/bleep/toggle` | Starts or stops the bleep |
| `/set?sound=&volume=&fullMute=&mode=&custom=&device=&gain=` | Changes and saves settings |
| `/devices` | Lists the microphones |

Sounds: `classic`, `censor`, `dolphin`, `quack`, `horn`, `custom`.

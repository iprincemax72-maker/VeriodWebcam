# VeriodWebcam

Turn your Android phone into a mic (and later, webcam) for your Mac — with **independent mic and camera toggles, both OFF by default**.

## Why this exists

macOS switches Bluetooth earbuds from A2DP stereo to HFP mono the moment anything uses their mic. That wrecks audio quality during Discord / streaming / OBS. Using your phone as a separate mic source keeps the earbuds on A2DP stereo.

```
[Android phone] --UDP--> [Mac app] ---> [BlackHole 2ch] ---> Discord / OBS / anything
                                   \
                                    Bluetooth earbuds stay on A2DP stereo (output only)
```

## Requirements

- Android phone (Android 8.0 / API 26+)
- Mac running macOS 13+
- Phone and Mac on the same Wi-Fi network
- [BlackHole](https://github.com/ExistentialAudio/BlackHole) virtual audio device

## Setup

### 1. Mac side

```bash
brew install blackhole-2ch
cd macos
swift run
```

In the app:
1. Pick **BlackHole 2ch** as the output device
2. Note the port (default `50001`) and one of the listed local IPs
3. Click **Start**

In Discord / OBS / Zoom:
- Input device → **BlackHole 2ch**
- Output device → your Bluetooth earbuds (keeps them on A2DP stereo)

The first time you Start, macOS will ask you to allow incoming connections. Allow it.

### 2. Android side

1. Open `android/` in Android Studio (it will resolve the Gradle wrapper automatically the first time)
2. Run on your phone over USB or Wi-Fi ADB
3. Enter the Mac IP + port
4. Flip the **Microphone** switch on (grant the mic permission when prompted)

Both toggles default OFF. Nothing streams until you flip them.

## Wire format

UDP, one datagram per 20 ms audio frame:

```
byte 0      : packet type (0x01 = audio)
bytes 1..3  : 24-bit big-endian sequence number
bytes 4..N  : PCM-16 LE mono at 48 kHz (1920 bytes per 20 ms frame)
```

No codec in the MVP — raw PCM at 48 kHz mono is ~768 kbps, which is nothing on a LAN.

## Status

MVP:
- [x] Phone mic → UDP → Mac → BlackHole
- [x] Mic ON/OFF + Camera ON/OFF toggles in phone UI (cam toggle is wired in UI only)
- [x] Output-device picker on Mac, defaults to BlackHole if present
- [x] Shows Mac's local IPs so you don't have to guess

Next:
- [ ] Camera stream (H.264 over UDP, OBS captures the Mac window)
- [ ] mDNS (Bonjour) auto-discovery — phone finds the Mac automatically
- [ ] USB transport (ADB reverse tether) for zero Wi-Fi latency
- [ ] Opus encoding (optional — only if LAN bandwidth ever becomes an issue)
- [ ] Packaged `.app` bundle for Mac + signed AAB for Play Store

## Project layout

```
VeriodWebcam/
├── android/                        # Kotlin + Jetpack Compose app
│   └── app/src/main/java/com/veriod/webcam/
│       ├── MainActivity.kt         # Compose UI, permission flow
│       └── AudioStreamer.kt        # AudioRecord → UDP pipeline
└── macos/                          # Swift + SwiftUI app (SPM executable)
    └── Sources/VeriodWebcam/
        ├── VeriodWebcamApp.swift   # @main
        ├── ContentView.swift       # UI
        ├── AudioReceiver.swift     # NWListener → AVAudioEngine
        ├── AudioDeviceManager.swift# CoreAudio device enumeration
        └── NetworkInfo.swift       # Local IPv4 discovery for display
```

# v2s

<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" alt="v2s app icon" width="256" height="256">
</p>

<p align="center">
  <strong>Live bilingual subtitles for meetings, calls, streams, and videos on macOS.</strong>
</p>

<p align="center">
  v2s turns microphone input or app audio into a clean two-line subtitle bar so you can follow speech in one language and read it in another without leaving the screen you are already using.
</p>

<p align="center">
  <a href="https://franklioxygen.github.io/v2s/">Website</a>
  ·
  <a href="README.zh-CN.md">中文文档</a>
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/b65167ee-ae7e-4e37-8316-ebd200ae89a7" alt="Mar-20-2026 11-08-59">
</p>

<p align="center">
  <img src="https://github.com/user-attachments/assets/449039ee-c329-426e-a55b-ab6660c56ca7" alt="Screenshot 2026-03-25 at 1 10 39 PM" width="500">
</p>

## Why v2s

- Follow live conversations with translated subtitles pinned at the top of your screen.
- Capture from your microphone or from a specific macOS app instead of your entire system mix.
- Keep the original speech and the translated line visible together for fast context switching.
- Stay in a lightweight menu bar workflow instead of juggling browser tabs or full-screen caption apps.

## Features

- Menu bar app built for always-available subtitle access.
- Live subtitle overlay with translated text on the first line and source text on the second.
- Audio source selection for microphones and running macOS apps.
- Speech transcription powered by Apple's Speech frameworks, preferring on-device recognition.
- On-device translation powered by Apple Translation.
- Transcript summarization powered by Apple Intelligence, falling back to an on-device extractive summary when Apple Intelligence is unavailable.
- Overlay styling controls so the subtitle bar stays readable on top of real work.

## Input and Subtitle Languages

v2s asks Apple's Speech and Translation frameworks which languages the current Mac supports, so the choices automatically follow OS and model updates. Regional variants are collapsed in the UI, while meaningful script variants such as Simplified and Traditional Chinese remain separate. Apple Translation availability is also checked for each source/destination pair before a session starts.

## Privacy

- No account, cloud backend, analytics, or telemetry.
- v2s has no cloud backend and does not send audio or subtitle text to its own servers.
- Translation uses Apple's on-device Translation framework. Some language packs may need to be downloaded first through System Settings.
- On Apple silicon, v2s uses the modern on-device Speech stack when it is available.
- On Intel Macs, the modern Speech stack is unavailable, so v2s falls back to `SFSpeechRecognizer`. It requires on-device recognition when the selected language supports it; otherwise Apple may process speech on its servers. Server-based recognition requires a network connection, is subject to Apple's service quotas, and sends captured speech to Apple under Apple's privacy terms.

## Getting Started

1. Download the latest `.app.zip` from [Releases](https://github.com/franklioxygen/v2s/releases).
2. Unzip and move `v2s.app` to your Applications folder.
3. Launch v2s — it appears as an icon in your menu bar.
4. Select an input source (a running app or microphone).
5. Choose your input and subtitle languages.
6. Click **Start**.

v2s will ask for permissions on first use:

- **Speech Recognition** — to transcribe audio into text.
- **Microphone** — when using a microphone as the input source.
- **Audio Capture** — when capturing audio from another app.

## Requirements

- Speech transcription and translation require macOS 26 or newer
- Apple silicon and Intel Macs are supported. Speech-language availability and whether recognition is on-device depend on the Mac and selected language.

## Building from Source

```bash
git clone https://github.com/franklioxygen/v2s.git
cd v2s
open v2s.xcodeproj
```

Or from the terminal:

```bash
xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug build
```

To build specifically for an Intel Mac:

```bash
swift build -c release --arch x86_64
```

## License

MIT

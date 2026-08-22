# v2s-ios

[English](README.md) · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-CN.md)

**Private, on-device bilingual captions for iPhone and iPad.**

`v2s-ios` is an iOS-first fork of [franklioxygen/v2s](https://github.com/franklioxygen/v2s). It uses the device microphone, Apple Speech, and Apple Translation to show source speech and a translation together. The fork starts from [upstream pull request #20](https://github.com/franklioxygen/v2s/pull/20) and preserves its expanded runtime language catalog, contributed by [@oToToT](https://github.com/oToToT).

<p align="center">
  <img src="docs/assets/v2s-ios-home.png" alt="v2s-ios showing source and translated captions in equal halves on iPhone">
</p>

## What it does

- Transcribes microphone audio and translates captions on device.
- Gives the source language and target translation equal halves of the screen.
- Stacks the two halves in portrait and places them side by side in landscape.
- Uses the iPhone or iPad microphone only.
- Defaults subtitle output to Traditional Chinese (`zh-Hant`), while keeping both Traditional Chinese (`zh-Hant`) and Simplified Chinese (`zh-Hans`) selectable.
- Provides in-app transcript and settings views.

## iOS and macOS capabilities

| Capability | `v2s-ios` on iPhone/iPad | Upstream `v2s` on macOS |
| --- | --- | --- |
| Live microphone captions | Yes | Yes |
| On-device speech recognition and translation | Yes | Yes |
| Caption presentation | Equal source and translation halves; stacked in portrait, side by side in landscape | Floating two-line subtitle bar |
| Capture audio from another app | No. The iOS app is microphone-only. | Yes |
| Float captions over other apps | No. Captions stay inside `v2s-ios`. | Yes |

The iOS app cannot capture another app's audio and does not provide a cross-app floating overlay.

## Privacy

- No accounts or network client.
- No cloud transcription, analytics, or telemetry.
- No updater in the iOS target.
- `v2s-ios` does not send microphone audio or captions to a server.
- Apple may initially download language assets required by its Speech and Translation frameworks. The app then uses those assets for on-device processing.
- Voice activity detection runs the [Silero VAD](THIRD_PARTY_NOTICES.md) model through Apple's system Core ML framework; `v2s-ios` bundles no third-party inference runtime, and the [conversion is reproducible](scripts/convert_silero_vad_coreml.py).

## Requirements

- iPhone or iPad running iOS or iPadOS 26.0 or later
- Xcode 26 or later
- Microphone and Speech Recognition permissions

## Build and run

Install XcodeGen, generate the iOS project, and open it from the repository root:

```bash
brew install xcodegen
cd ios
xcodegen generate
open v2s-ios.xcodeproj
```

Choose the `v2s-ios` scheme and an iPhone or iPad simulator, then run the app from Xcode.

Build for the iOS Simulator from the command line:

```bash
cd ios
xcodegen generate
xcodebuild \
  -project v2s-ios.xcodeproj \
  -scheme v2s-ios \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath .build/sim \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For a physical device, select your development team locally in Xcode under Signing & Capabilities. The repository does not commit a `DEVELOPMENT_TEAM` value.

## Development gates

Run the shared engine tests from the repository root:

```bash
swift test
```

Build the original macOS target as regression coverage:

```bash
xcodebuild \
  -project v2s.xcodeproj \
  -scheme v2s \
  -configuration Release \
  -derivedDataPath .build/release \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY=- \
  build
```

Generate and build the iOS target for the simulator:

```bash
cd ios
xcodegen generate
xcodebuild \
  -project v2s-ios.xcodeproj \
  -scheme v2s-ios \
  -configuration Release \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath .build/sim \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Upstream and macOS

This fork keeps the original macOS target buildable for shared-engine development and regression coverage. Use [franklioxygen/v2s](https://github.com/franklioxygen/v2s) for the macOS product, releases, and documentation.
## License

The [upstream README](https://github.com/franklioxygen/v2s#license) declares MIT, but the upstream repository currently has no `LICENSE` file. This fork preserves upstream attribution in [NOTICE](NOTICE). Consult upstream before publicly redistributing this fork or its binaries.

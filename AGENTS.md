# Easy2Say — agent notes

## Live caption pipeline (macOS + iOS share `Sources/V2SApp`)
LiveTranscriptionSession forwards raw recognizer results and Silero VAD edges as
`CaptionSessionEvent`s → `CaptionPipeline` / `CaptionCore` (pure reducer:
lane state, sentence rows, dual-lane zh/en routing, sealing, translation
effects) → `CaptionDocument` → `CaptionViewport` (CoreText line breaking,
upward-only scrolling) → `CaptionScreen` drawn verbatim by `CaptionSurface`
(overlay and Audience Display). Rules that keep captions from flickering:
- Never call `SpeechAnalyzer.finalize(through:)` mid-session (measured: it drops
  words). Volatile text is append-only; finals only re-case/re-punctuate.
- Never dedupe or trim recognizer text by string comparison; rows come from the
  recognizer's own punctuation and final boundaries.
- Views never measure or wrap text; content only moves up.

## Verification
- Fast caption gate (no audio, ~1 s):
  `swift test --filter 'CaptionScreenOracleTests|CaptionTraceReplayTests|CaptionComposerTests|CaptionCoreTests|CaptionViewportTests|CaptionPipelineTests'`
- Real-time end-to-end gate (TTS → SpeechAnalyzer → rendered screens, ~2 min;
  skips without voices/assets): `swift test --filter CaptionFlickerEndToEndTests`
- Full: `swift test` (two window sharing-type tests fail on this desk independent
  of captions: `testRecordingVisibilitySyncsSharingType`,
  `testRecordingVisibilityUsesNewPublishedStyleValue`).
- macOS app: `xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug -destination 'platform=macOS' build`
  (new source files must be added to `v2s.xcodeproj/project.pbxproj`).
- iOS: `cd ios && xcodegen generate && xcodebuild -project v2s-ios.xcodeproj -scheme v2s-ios -configuration Debug -destination 'generic/platform=iOS Simulator' build`
- Re-record analyzer traces: `EASY2SAY_PROBE_OUT=<dir> swift test --filter SpeechAnalyzerProbeTests`,
  then copy into `Tests/V2STests/Fixtures/AnalyzerTraces/`.
- `Tests/V2STests/Support/CaptionScreenOracle.swift` is the flicker oracle; change
  it only deliberately, with a self-test in `CaptionScreenOracleTests`.

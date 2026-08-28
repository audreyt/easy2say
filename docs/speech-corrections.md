# Private speech-correction lexicon

Live captions can apply a **user-owned**, language-scoped ASR typo list. This is not the translation glossary (source → target). It maps raw speech-recognizer spellings onto the intended source-language term **inside** an utterance (one pass, longest alias first, no cascades).

## Path

```
~/Library/Application Support/v2s/speech-corrections.json
```

The file is **not bundled**, **not synced**, and **not shipped** with the app. Install it locally on the machine that will caption (short local event lexicons belong in this local Application Support file, not in the git repository or app bundle). If it is missing, corrections are a no-op. If it is malformed, uses an unsupported version, or contains ambiguous duplicate aliases, load fails closed (empty table, visible error) — nothing is applied partially.

Do **not** put full scripts, dialogues, or paragraphs in the lexicon. Keep entries to short terms or short phrases.

## Format

```json
{
  "version": 1,
  "languages": {
    "zh-Hant": {
      "hints": ["HintOnlyTerm"],
      "corrections": [
        { "canonical": "term", "aliases": ["asr-typo"] }
      ]
    },
    "en": {
      "hints": ["Riverton"],
      "corrections": [
        { "canonical": "Riverton", "aliases": ["rivertin"], "status": "safe" },
        { "canonical": "north star", "aliases": ["norths star"] }
      ]
    }
  }
}
```

- `version` must be `1`. Unknown keys on the document, a language section, or an entry are rejected. Language IDs themselves may be any identifier.
- Language keys are scoped. `zh-Hant` also matches `zh-TW`. Generic IDs such as `JA` canonicalize to lowercase `ja`. Corrections never leak across unrelated languages.
- `hints` (optional): canonical terms with no known typo alias, fed directly to speech recognition context (merged with glossary keys, longest first, capped at 100 phrases, each ≤ 40 characters).
- `corrections` (optional): list of typo-to-canonical entries. `canonical` is also added to speech recognition context.
- `aliases` are raw ASR misspellings. A canonical that equals an alias, or that equals an alias after Latin-letter lowercasing (not Unicode casefold; `café` and `cafe` stay distinct), is ignored. The same folded alias mapping to two canonicals is rejected.
- `status` is optional. `safe` (default) is applied. `review` and `unsafe` are kept in the file but never applied or hinted, and are not length-checked at runtime.
- Safe canonicals and aliases longer than 80 characters are rejected (this file is not a script store).

Replacement is deterministic: longest alias first, one pass (replacements are not re-scanned), Han/kana/hangul may match adjacently, Latin/digit edges keep whole-token boundaries, Latin aliases match case-insensitively without stripping diacritics.

## Dry-run validator

```bash
./scripts/validate-speech-corrections.sh
./scripts/validate-speech-corrections.sh /path/to/speech-corrections.json
```

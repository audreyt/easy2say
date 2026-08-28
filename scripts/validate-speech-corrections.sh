#!/bin/sh
# Dry-run validator for a user-owned speech-corrections.json.
# Files are not bundled or synced. Do not store full scripts in the lexicon.
set -eu

FILE="${1:-$HOME/Library/Application Support/v2s/speech-corrections.json}"

if [ ! -f "$FILE" ]; then
  echo "OK: no file at $FILE (empty lexicon)"
  exit 0
fi

python3 - "$FILE" <<'PY'
import json, sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)
except json.JSONDecodeError as error:
    print(f"FAIL: malformed JSON: {error}")
    sys.exit(1)

if not isinstance(document, dict):
    print("FAIL: document must be an object")
    sys.exit(1)

DOCUMENT_KEYS = {"version", "languages"}
SECTION_KEYS = {"hints", "corrections"}
ENTRY_KEYS = {"canonical", "aliases", "status"}


def reject_unknown_keys(obj, allowed, location):
    extra = [key for key in obj.keys() if key not in allowed]
    if extra:
        print(f"FAIL: unknown {location} key {extra[0]!r}")
        sys.exit(1)


reject_unknown_keys(document, DOCUMENT_KEYS, "document")

version = document.get("version")
if version != 1:
    print(f"FAIL: unsupported version {version!r} (expected 1)")
    sys.exit(1)

languages = document.get("languages")
if not isinstance(languages, dict):
    print("FAIL: languages must be an object")
    sys.exit(1)


def canonical_language(raw):
    raw = str(raw).strip()
    if not raw:
        return ""
    normalized = raw.replace("_", "-")
    parts = [p for p in normalized.split("-") if p]
    if not parts:
        return raw
    language = parts[0].lower()
    if language in ("zh", "zho"):
        rest = [p.lower() for p in parts[1:]]
        if any(p in ("hant", "tw", "hk", "mo") for p in rest):
            return "zh-Hant"
        if any(p in ("hans", "cn", "sg") for p in rest):
            return "zh-Hans"
        return "zh-Hant"
    if language == "en":
        return "en"
    return language


def is_latin_letter(ch):
    cp = ord(ch)
    return (
        (0x0041 <= cp <= 0x005A)
        or (0x0061 <= cp <= 0x007A)
        or (0x00C0 <= cp <= 0x024F)
        or (0x1E00 <= cp <= 0x1EFF)
    )


def fold_latin(text):
    # Match SpeechCorrectionService.foldLatin: lowercase Latin letters only.
    # Do not use str.casefold() (ß→ss) or diacritic stripping (café≠cafe).
    out = []
    for ch in text:
        if is_latin_letter(ch):
            out.append(ch.lower())
        else:
            out.append(ch)
    return "".join(out)


canonical_to_raw = {}
for language in languages.keys():
    canon = canonical_language(language)
    if not canon:
        print(f"FAIL: empty language identifier")
        sys.exit(1)
    if canon in canonical_to_raw:
        print(f"FAIL: duplicate canonical language section {canon} ({canonical_to_raw[canon]!r} and {language!r})")
        sys.exit(1)
    canonical_to_raw[canon] = language

conflicts = []
applied = 0
skipped = 0
hints_count = 0

for language, section in languages.items():
    if not isinstance(section, dict):
        print(f"FAIL: section in {language} must be an object")
        sys.exit(1)
    reject_unknown_keys(section, SECTION_KEYS, "section")
    hints = section.get("hints") or []
    entries = section.get("corrections") or []
    if not isinstance(hints, list):
        print(f"FAIL: hints in {language} must be an array")
        sys.exit(1)
    if not isinstance(entries, list):
        print(f"FAIL: corrections in {language} must be an array")
        sys.exit(1)

    for hint in hints:
        hint_str = str(hint).strip()
        if not hint_str:
            print(f"FAIL: empty hint in {language}")
            sys.exit(1)
        if len(hint_str) > 40:
            print(f"FAIL: hint in {language} exceeds 40 characters")
            sys.exit(1)
        hints_count += 1
    alias_to_canonical = {}
    for entry in entries:
        if not isinstance(entry, dict):
            print(f"FAIL: entry in {language} must be an object")
            sys.exit(1)
        reject_unknown_keys(entry, ENTRY_KEYS, "entry")
        status = str(entry.get("status", "safe")).strip().lower() or "safe"
        if status in {"review", "unsafe"}:
            skipped += 1
            continue
        if status != "safe":
            print(f"FAIL: unknown status {status!r} in {language}")
            sys.exit(1)

        canonical = str(entry.get("canonical", "")).strip()
        if not canonical:
            print(f"FAIL: empty canonical in {language}")
            sys.exit(1)
        if len(canonical) > 80:
            print(f"FAIL: canonical in {language} exceeds 80 characters")
            sys.exit(1)

        aliases = entry.get("aliases")
        if aliases is None:
            aliases = []
        if not isinstance(aliases, list):
            print(f"FAIL: aliases in {language} must be an array")
            sys.exit(1)

        for alias in aliases:
            alias_str = str(alias).strip()
            if not alias_str:
                print(f"FAIL: empty alias for {canonical!r} in {language}")
                sys.exit(1)
            if len(alias_str) > 80:
                print(f"FAIL: alias for {canonical!r} in {language} exceeds 80 characters")
                sys.exit(1)
            if alias_str == canonical:
                continue
            key = fold_latin(alias_str)
            if key == fold_latin(canonical):
                continue
            existing = alias_to_canonical.get(key)
            if existing and existing != canonical:
                conflicts.append((language, alias_str, existing, canonical))
            else:
                alias_to_canonical[key] = canonical
                applied += 1

if conflicts:
    for language, alias, first, second in conflicts:
        print(f"FAIL: {language} alias {alias!r} maps to {first!r} and {second!r}")
    sys.exit(1)

print(f"OK: {path} (applied aliases={applied}, hints={hints_count}, skipped={skipped})")
PY

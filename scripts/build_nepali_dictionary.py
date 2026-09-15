#!/usr/bin/env python3
"""Build a MONOLINGUAL Nepali dictionary from the yoshabdakosh JSON dataset.

ne.wiktionary carries only a few hundred usable pages, so the Nepali edition is
built from a digitisation of the *नेपाली बृहत् शब्दकोश* (Nepal Academy) instead —
a real monolingual dictionary: Nepali headwords, Nepali senses, Nepali grammar
labels and Sanskrit/Prakrit etymologies. The intermediate JSON comes from
`Shubhamnpk/yoshabdakosh`, which in turn credits
`bikashpadhikari/nepali-brihat-sabdakosh-json`.

The output schema is byte-for-byte the one `StarDictImporter` produces, so the
app opens the downloaded file with no new reader code:

    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE entries(id INTEGER PRIMARY KEY, word TEXT NOT NULL,
                         word_lower TEXT NOT NULL, definition TEXT NOT NULL);
    CREATE INDEX idx_entries_lower ON entries(word_lower);

Usage:
  uv run python3 scripts/build_nepali_dictionary.py [--data PATH] [--out PATH]
                                                    [--limit N] [--gzip]
"""

import argparse
import gzip
import json
import os
import re
import shutil
import sqlite3
import sys
import time
import unicodedata
import urllib.request

DATA_URL = (
    "https://raw.githubusercontent.com/Shubhamnpk/yoshabdakosh/main/data/"
    "sabdakosh.json"
)
REPO_URL = "https://github.com/Shubhamnpk/yoshabdakosh"

BOOKNAME = "नेपाली बृहत् शब्दकोश"
LANGUAGE = "नेपाली"

# The dataset credits the Nepal Academy dictionary as the content and the JSON
# repository as the transcription. Both are named, and the licence line says
# plainly that MIT covers the repository, not the dictionary text.
SOURCE = (
    "नेपाली बृहत् शब्दकोश (नेपाल प्रज्ञा-प्रतिष्ठान) — "
    "digitised JSON via Shubhamnpk/yoshabdakosh "
    f"({REPO_URL}), which credits "
    "bikashpadhikari/nepali-brihat-sabdakosh-json."
)
LICENSE = (
    "Data via Shubhamnpk/yoshabdakosh (MIT). Content credited to "
    "नेपाली बृहत् शब्दकोश, Nepal Academy (नेपाल प्रज्ञा-प्रतिष्ठान); the terms of "
    "the underlying dictionary text are not established."
)
ATTRIBUTION = (
    "नेपाली बृहत् शब्दकोश — नेपाल प्रज्ञा-प्रतिष्ठान. "
    "Digitised data via Shubhamnpk/yoshabdakosh (MIT)."
)
DESCRIPTION = (
    "नेपाली भाषाको एकभाषिक शब्दकोश: नेपाली शब्दको अर्थ नेपालीमै। "
    "(Monolingual Nepali dictionary — Nepali words defined in Nepali.)"
)

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

DEVANAGARI_DIGITS = "०१२३४५६७८९"

# `१. `, `१०. `, and the ASCII spellings a few rows use.
LEADING_NUMBER_RE = re.compile(r"^\s*[" + DEVANAGARI_DIGITS + r"0-9]+\s*[.)।]\s*")

WS_RE = re.compile(r"[ \t ]+")


def devanagari_number(value):
    """12 -> `१२` — senses are numbered the way the printed dictionary is."""
    return "".join(DEVANAGARI_DIGITS[int(digit)] for digit in str(value))


def is_substantive(text):
    """False for a sense that is only a number, a danda or stray punctuation.

    A handful of rows in the dataset carry senses like `१. .` or `१. !` where
    the OCR lost the text; they would otherwise render as an empty bullet.
    """
    stripped = LEADING_NUMBER_RE.sub("", text or "")
    letters = re.sub(r"[^\wऀ-ॿ]", "", stripped, flags=re.U)
    return len(letters) >= 2


def clean_text(text):
    """Normalise whitespace and Devanagari punctuation spacing."""
    text = WS_RE.sub(" ", (text or "").replace("\n", " "))
    # The printed dictionary sets no space before a danda or a comma.
    text = re.sub(r"\s+([।,;:!?])", r"\1", text)
    text = re.sub(r"\s{2,}", " ", text)
    return text.strip()


def format_definition(definitions):
    """The exact text the app renders, one block per grammatical reading.

    Grammar label (and etymology, when the dictionary gives one) on its own
    line, then the numbered senses — the same shape the Spanish build produces.
    """
    blocks = []
    for entry in definitions:
        senses = [clean_text(s) for s in entry.get("senses") or []]
        senses = [s for s in senses if s and is_substantive(s)]
        if not senses:
            continue

        head_parts = []
        grammar = clean_text(entry.get("grammar"))
        if grammar:
            head_parts.append(grammar)
        etymology = clean_text(entry.get("etymology"))
        if etymology:
            head_parts.append(etymology)

        lines = []
        if head_parts:
            lines.append(" ".join(head_parts))
        for index, sense in enumerate(senses, start=1):
            # The source already numbers multi-sense readings; keep its own
            # numbers rather than renumbering, and only add one where a
            # multi-sense reading is missing it.
            if LEADING_NUMBER_RE.match(sense) or len(senses) == 1:
                lines.append(sense)
            else:
                lines.append(f"{devanagari_number(index)}. {sense}")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


# ---------------------------------------------------------------------------
# Data handling
# ---------------------------------------------------------------------------


def ensure_data(path):
    """Download the dataset unless it is already here — it is 31 MB."""
    if os.path.exists(path) and os.path.getsize(path) > 1_000_000:
        print(f"Using cached dataset: {path} "
              f"({os.path.getsize(path) / 1e6:.1f} MB)")
        return path
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    print(f"Downloading {DATA_URL}")
    partial = path + ".part"
    with urllib.request.urlopen(DATA_URL) as response, open(partial, "wb") as out:
        total = int(response.headers.get("Content-Length") or 0)
        done = 0
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
            done += len(chunk)
            if total:
                print(f"\r  {done / 1e6:6.1f} / {total / 1e6:.1f} MB", end="")
        print()
    os.replace(partial, path)
    return path


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------


def write_database(out_path, rows):
    if os.path.exists(out_path):
        os.remove(out_path)
    db = sqlite3.connect(out_path)
    db.execute("PRAGMA journal_mode=OFF")
    db.execute("PRAGMA synchronous=OFF")
    db.execute("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)")
    db.execute(
        "CREATE TABLE entries(id INTEGER PRIMARY KEY, word TEXT NOT NULL,"
        " word_lower TEXT NOT NULL, definition TEXT NOT NULL)"
    )

    meta = {
        "bookname": BOOKNAME,
        "wordcount": str(len(rows)),
        "language": LANGUAGE,
        "source": SOURCE,
        "description": DESCRIPTION,
        "license": LICENSE,
        "attribution": ATTRIBUTION,
        "date": time.strftime("%Y-%m-%d"),
    }

    db.execute("BEGIN")
    db.executemany("INSERT INTO meta(key, value) VALUES(?, ?)", sorted(meta.items()))
    db.executemany(
        "INSERT INTO entries(word, word_lower, definition) VALUES(?, ?, ?)",
        # Devanagari is unicameral, but the app matches on a casefolded column;
        # casefold() keeps that path working and is a no-op for the script.
        ((word, word.casefold(), definition) for word, definition in rows),
    )
    db.execute("COMMIT")
    db.execute("CREATE INDEX idx_entries_lower ON entries(word_lower)")
    db.execute("VACUUM")
    db.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    default_data = os.path.join("build", "dumps", "sabdakosh.json")
    parser.add_argument("--data", default=default_data,
                        help="path to sabdakosh.json (downloaded if absent)")
    parser.add_argument("--out", default=os.path.join("build", "ne-sabdakosh.sqlite"))
    parser.add_argument("--limit", type=int, default=0,
                        help="stop after N source entries (for a smoke test)")
    parser.add_argument("--gzip", action="store_true",
                        help="also write <out>.gz for shipping")
    args = parser.parse_args()

    data_path = ensure_data(args.data)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)

    started = time.time()
    with open(data_path, encoding="utf-8") as handle:
        source = json.load(handle)
    print(f"Loaded {len(source)} source entries in {time.time() - started:.0f}s")

    rows = []
    scanned = skipped = 0
    for record in source:
        scanned += 1
        if args.limit and scanned > args.limit:
            break
        word = (record.get("word") or "").strip()
        if not word:
            skipped += 1
            continue
        definition = format_definition(record.get("definitions") or [])
        if not definition.strip():
            skipped += 1
            continue
        rows.append((word, definition))

    rows.sort(key=lambda row: (unicodedata.normalize("NFKD", row[0].casefold()),
                               row[0]))
    print(f"Scanned {scanned} entries; {len(rows)} usable, {skipped} skipped")

    write_database(args.out, rows)
    size = os.path.getsize(args.out)
    print(f"Wrote {len(rows)} entries to {args.out} ({size / 1e6:.1f} MB)")

    if args.gzip:
        gz_path = args.out + ".gz"
        with open(args.out, "rb") as src, gzip.open(gz_path, "wb", compresslevel=9) as dst:
            shutil.copyfileobj(src, dst, 1 << 20)
        print(f"Wrote {gz_path} ({os.path.getsize(gz_path) / 1e6:.1f} MB)")

    print(f"Done in {time.time() - started:.0f}s")


if __name__ == "__main__":
    sys.exit(main())

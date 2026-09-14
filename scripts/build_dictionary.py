#!/usr/bin/env python3
"""Build the offline dictionary SQLite database bundled with the iOS app.

Sources:
  - WordNet 3.1 (Princeton University) — definitions, examples, synonyms,
    antonyms, part-of-speech data. Mirrored on GitHub via nltk/nltk_data
    (packages/corpora/wordnet31.zip).
  - CMU Pronouncing Dictionary (cmusphinx/cmudict on GitHub) — pronunciations,
    converted from ARPABET to IPA.

Usage:
  python3 build_dictionary.py <wordnet_dir> <cmudict_file> <output.sqlite>
"""

import json
import re
import sqlite3
import sys
from collections import defaultdict

POS_NAMES = {"n": "noun", "v": "verb", "a": "adjective", "s": "adjective", "r": "adverb"}
DATA_FILES = {"n": "data.noun", "v": "data.verb", "a": "data.adj", "r": "data.adv"}
INDEX_FILES = {"n": "index.noun", "v": "index.verb", "a": "index.adj", "r": "index.adv"}
EXC_FILES = {"n": "noun.exc", "v": "verb.exc", "a": "adj.exc", "r": "adv.exc"}

# ARPABET (without stress digits) -> IPA
ARPABET_IPA = {
    "AA": "ɑ", "AE": "æ", "AH": "ʌ", "AO": "ɔ", "AW": "aʊ", "AY": "aɪ",
    "B": "b", "CH": "tʃ", "D": "d", "DH": "ð", "EH": "ɛ", "ER": "ər",
    "EY": "eɪ", "F": "f", "G": "ɡ", "HH": "h", "IH": "ɪ", "IY": "i",
    "JH": "dʒ", "K": "k", "L": "l", "M": "m", "N": "n", "NG": "ŋ",
    "OW": "oʊ", "OY": "ɔɪ", "P": "p", "R": "r", "S": "s", "SH": "ʃ",
    "T": "t", "TH": "θ", "UH": "ʊ", "UW": "u", "V": "v", "W": "w",
    "Y": "j", "Z": "z", "ZH": "ʒ",
}


def arpabet_to_ipa(phones):
    out = []
    for ph in phones:
        stress = ""
        if ph[-1].isdigit():
            digit = ph[-1]
            ph = ph[:-1]
            if digit == "1":
                stress = "ˈ"
            elif digit == "2":
                stress = "ˌ"
        ipa = ARPABET_IPA.get(ph, "")
        # Unstressed AH is schwa
        if ph == "AH" and stress == "" and ipa == "ʌ":
            ipa = "ə"
        out.append(stress + ipa)
    # Move stress marks before the consonant cluster that starts the syllable
    # is complex; keep the simple convention of marking the vowel.
    return "".join(out)


def load_cmudict(path):
    prons = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.split("#")[0].strip()
            if not line:
                continue
            parts = line.split()
            word = parts[0].lower()
            # Skip alternate pronunciations like word(2)
            if "(" in word:
                continue
            prons[word] = arpabet_to_ipa(parts[1:])
    return prons


def parse_synset_line(line):
    """Parse one line of a WordNet data.* file."""
    head, _, gloss = line.partition("|")
    fields = head.split()
    offset = fields[0]
    ss_type = fields[2]
    w_cnt = int(fields[3], 16)
    words = []
    i = 4
    for _ in range(w_cnt):
        lemma = fields[i]
        # Strip adjective syntactic markers like (a), (p), (ip)
        lemma = re.sub(r"\((a|p|ip)\)$", "", lemma)
        words.append(lemma.replace("_", " "))
        i += 2  # skip lex_id
    p_cnt = int(fields[i])
    i += 1
    pointers = []
    for _ in range(p_cnt):
        symbol = fields[i]
        target_offset = fields[i + 1]
        target_pos = fields[i + 2]
        source_target = fields[i + 3]
        pointers.append((symbol, target_offset, target_pos, source_target))
        i += 4

    gloss = gloss.strip()
    definition = gloss
    examples = []
    if '"' in gloss:
        # Definition is text before the first quoted example
        first_quote = gloss.index('"')
        definition = gloss[:first_quote].rstrip("; ").strip()
        examples = re.findall(r'"([^"]+)"', gloss)
    return {
        "offset": offset,
        "ss_type": ss_type,
        "words": words,
        "pointers": pointers,
        "definition": definition,
        "examples": examples,
    }


def main(wordnet_dir, cmudict_path, out_path):
    prons = load_cmudict(cmudict_path)
    print(f"Loaded {len(prons)} pronunciations")

    # pos -> offset -> synset
    synsets = {}
    for pos, fname in DATA_FILES.items():
        table = {}
        with open(f"{wordnet_dir}/{fname}", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("  "):
                    continue
                syn = parse_synset_line(line.rstrip("\n"))
                table[syn["offset"]] = syn
        synsets[pos] = table
        print(f"Parsed {len(table)} {POS_NAMES[pos]} synsets")

    # index files give, per lemma+pos, synset offsets in sense order
    # entries: word_lower -> list of (pos, [offsets])
    index_entries = defaultdict(list)
    display_case = {}
    for pos, fname in INDEX_FILES.items():
        with open(f"{wordnet_dir}/{fname}", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("  "):
                    continue
                fields = line.split()
                lemma = fields[0].replace("_", " ")
                p_cnt = int(fields[3])
                synset_cnt = int(fields[2])
                offsets = fields[4 + p_cnt + 2:]
                assert len(offsets) == synset_cnt, line
                index_entries[lemma].append((pos, offsets))

    # Prefer the casing that appears in the synset word lists (data files keep
    # original case; index files are lowercased).
    for pos, table in synsets.items():
        for syn in table.values():
            for w in syn["words"]:
                lw = w.lower()
                if lw not in display_case or (display_case[lw] != w and w[0].isupper()):
                    display_case.setdefault(lw, w)
                    if w[0].isupper() and display_case[lw][0].islower() and lw not in index_entries:
                        display_case[lw] = w

    db = sqlite3.connect(out_path)
    db.executescript(
        """
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        CREATE TABLE words (
            id INTEGER PRIMARY KEY,
            word TEXT NOT NULL,
            word_lower TEXT NOT NULL UNIQUE,
            pronunciation TEXT
        );
        CREATE TABLE senses (
            id INTEGER PRIMARY KEY,
            word_id INTEGER NOT NULL REFERENCES words(id),
            pos TEXT NOT NULL,
            sense_number INTEGER NOT NULL,
            definition TEXT NOT NULL,
            examples TEXT NOT NULL,   -- JSON array
            synonyms TEXT NOT NULL,   -- JSON array
            antonyms TEXT NOT NULL    -- JSON array
        );
        CREATE TABLE forms (
            form TEXT NOT NULL,
            base TEXT NOT NULL,
            PRIMARY KEY (form, base)
        ) WITHOUT ROWID;
        """
    )

    word_ids = {}

    def word_id(lemma_lower):
        if lemma_lower in word_ids:
            return word_ids[lemma_lower]
        display = display_case.get(lemma_lower, lemma_lower)
        cur = db.execute(
            "INSERT INTO words (word, word_lower, pronunciation) VALUES (?,?,?)",
            (display, lemma_lower, prons.get(lemma_lower)),
        )
        word_ids[lemma_lower] = cur.lastrowid
        return cur.lastrowid

    n_senses = 0
    for lemma, entries in sorted(index_entries.items()):
        wid = word_id(lemma)
        for pos, offsets in entries:
            for sense_num, off in enumerate(offsets, start=1):
                syn = synsets[pos].get(off)
                if syn is None:
                    continue
                synonyms = [w for w in syn["words"] if w.lower() != lemma]
                # Antonyms: '!' pointers. Lexical ones encode word positions in
                # source_target, but antonyms of any word in the synset are a
                # good thesaurus signal; prefer lexical matches for this lemma.
                antonyms = []
                for symbol, t_off, t_pos, st in syn["pointers"]:
                    if symbol != "!":
                        continue
                    src = int(st[:2], 16)
                    if src != 0:
                        src_word = syn["words"][src - 1].lower()
                        if src_word != lemma:
                            continue
                    target = synsets.get(t_pos if t_pos != "s" else "a", {}).get(t_off)
                    if target:
                        tgt = int(st[2:], 16)
                        if tgt != 0:
                            antonyms.append(target["words"][tgt - 1])
                        else:
                            antonyms.extend(target["words"])
                # de-dup, preserve order
                antonyms = list(dict.fromkeys(antonyms))
                db.execute(
                    "INSERT INTO senses (word_id, pos, sense_number, definition,"
                    " examples, synonyms, antonyms) VALUES (?,?,?,?,?,?,?)",
                    (
                        wid,
                        POS_NAMES[syn["ss_type"]],
                        sense_num,
                        syn["definition"],
                        json.dumps(syn["examples"], ensure_ascii=False),
                        json.dumps(synonyms, ensure_ascii=False),
                        json.dumps(antonyms, ensure_ascii=False),
                    ),
                )
                n_senses += 1
    print(f"Inserted {len(word_ids)} words, {n_senses} senses")

    # Irregular inflected forms (exception lists) for lookup fallback
    n_forms = 0
    for pos, fname in EXC_FILES.items():
        with open(f"{wordnet_dir}/{fname}", encoding="utf-8", errors="replace") as f:
            for line in f:
                fields = line.split()
                if len(fields) < 2:
                    continue
                form = fields[0].replace("_", " ")
                for base in fields[1:]:
                    base = base.replace("_", " ")
                    if form != base and base in index_entries:
                        db.execute(
                            "INSERT OR IGNORE INTO forms (form, base) VALUES (?,?)",
                            (form, base),
                        )
                        n_forms += 1
    print(f"Inserted {n_forms} inflected forms")

    db.executescript(
        """
        CREATE INDEX idx_senses_word ON senses(word_id, pos, sense_number);
        PRAGMA optimize;
        VACUUM;
        """
    )
    db.commit()
    db.close()
    print(f"Done: {out_path}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])

#!/usr/bin/env python3
"""Build a MONOLINGUAL German dictionary from the German Wiktionary dump.

de.wiktionary carries entries for hundreds of languages, all *explained in
German*. Only the `== Wort ({{Sprache|Deutsch}}) ==` section of a page is a
German word defined in German, so everything else is discarded — the result is
the German-speaker's equivalent of the bundled WordNet, not a translation
dictionary.

The output schema is byte-for-byte the one `StarDictImporter` produces, so the
app opens the downloaded file with no new reader code:

    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE entries(id INTEGER PRIMARY KEY, word TEXT NOT NULL,
                         word_lower TEXT NOT NULL, definition TEXT NOT NULL);
    CREATE INDEX idx_entries_lower ON entries(word_lower);

Usage:
  uv run python3 scripts/build_wiktionary_de.py [--dump PATH] [--out PATH]
                                                [--limit N] [--gzip]
                                                [--no-forms]
"""

import argparse
import bz2
import gzip
import html
import os
import re
import shutil
import sqlite3
import sys
import time
import unicodedata
import urllib.request
import xml.etree.ElementTree as ET

DUMP_URL = "https://dumps.wikimedia.org/dewiktionary/latest/dewiktionary-latest-pages-articles.xml.bz2"

BOOKNAME = "Wiktionary (Deutsch)"
LANGUAGE = "Deutsch"

# ---------------------------------------------------------------------------
# Section / heading recognition
# ---------------------------------------------------------------------------

# `== Haus ({{Sprache|Deutsch}}) ==`. The parenthesised language marker is the
# only reliable signal: the lemma before it is free text and may contain
# anything except a heading `=`.
LANG_DE_HEADING = re.compile(
    r"^==\s*[^\n=]*?\{\{\s*Sprache\s*\|\s*Deutsch\s*\}\}[^\n=]*==\s*$", re.M
)
LEVEL2_HEADING = re.compile(r"^==(?!=)\s*.+?\s*==\s*$", re.M)
ANY_HEADING = re.compile(r"^(={2,6})\s*(.+?)\s*\1\s*$", re.M)

# `=== {{Wortart|Substantiv|Deutsch}}, {{n}} ===` — a heading is a part-of-speech
# heading exactly when it carries at least one `{{Wortart|…}}`.
WORTART_RE = re.compile(r"\{\{\s*Wortart\s*\|\s*([^|}]*?)\s*(?:\|\s*([^|}]*?)\s*)?\}\}")
GENDER_RE = re.compile(r"\{\{\s*(m|f|n|mf|fm|mn|nm|fn|nf|mfn|pl|u|x)\s*\}\}")

# `:[1] Definition`, `:[2a] …`, `:[1, 3] …` inside a `{{Bedeutungen}}` block.
SENSE_LINE = re.compile(r"^:+\s*(?:\[\s*([^\]]{0,24}?)\s*\])?\s*(.*)$")
# A run of templates opening a definition is its usage/domain marker; the same
# template further along the line is ordinary inline text and stays put.
LEADING_MARKERS = re.compile(
    r"^\s*(?:\{\{[^{}]*(?:\{\{[^{}]*\}\}[^{}]*)*\}\}[\s,;]*)+"
)

GENDER_NAMES = {
    "m": "m", "f": "f", "n": "n", "mf": "mf", "fm": "fm", "mn": "mn",
    "nm": "nm", "fn": "fn", "nf": "nf", "mfn": "mfn", "pl": "Plural",
    "u": "u", "x": "x",
}

# Word classes the bots generate mechanically from a lemma page; the user may
# want a smaller download without them (`--no-forms`).
FORM_WORTARTEN = {
    "deklinierte form", "konjugierte form", "erweiterter infinitiv",
    "partizip i", "partizip ii", "komparativ", "superlativ",
}

# ---------------------------------------------------------------------------
# Wikitext cleaning
# ---------------------------------------------------------------------------

COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
REF_PAIR_RE = re.compile(r"<ref\b[^>]*>.*?</ref>", re.S | re.I)
REF_SELF_RE = re.compile(r"<ref\b[^>]*/\s*>", re.I)
# `Straße <sup>[1]</sup>` is a cross-reference to sense 1; in plain text the
# bracketed digit reads as noise, so a bare numeric super/subscript goes.
SENSE_MARK_RE = re.compile(r"<su[pb]>\s*\[\s*[\d,\s–-]+\s*\]\s*</su[pb]>", re.I)
TAG_RE = re.compile(r"</?[a-zA-Z][a-zA-Z0-9]*\b[^>]*/?>")
FILE_LINK_RE = re.compile(
    r"\[\[\s*(?:Datei|Bild|Image|File|Kategorie|Category)\s*:[^\[\]]*"
    r"(?:\[\[[^\[\]]*\]\][^\[\]]*)*\]\]",
    re.I,
)
WIKILINK_RE = re.compile(r"\[\[([^\[\]]*)\]\]")
EXTLINK_RE = re.compile(r"\[(?:https?:|//)\S+?(?:\s+([^\]]*))?\]")
INNER_TEMPLATE_RE = re.compile(r"\{\{([^{}]*)\}\}")
QUOTES_RE = re.compile(r"'{2,5}")
LOOSE_MARKUP_RE = re.compile(r"\{\{|\}\}|\[\[|\]\]")
WS_RE = re.compile(r"[ \t ]+")

# Reference, source and maintenance templates: they render as a footnote marker
# or a coloured box, never as part of the definition.
DROP_TEMPLATE_PREFIXES = (
    "ref-", "lit-", "qs ", "qs_", "#isbn", "#invoke", "#if", "#switch",
    "internetquelle", "literatur", "wikiquote", "wikisource", "wikinews",
    "wikibooks", "wikispecies", "commons", "wikivoyage", "navigationsleiste",
)
DROP_TEMPLATE_NAMES = {
    "ipa", "lautschrift fehlt", "audio", "hörbeispiele", "reim", "reime",
    "beispiele fehlen", "erweitern", "überarbeiten", "löschantrag", "gbs",
    "dwds", "clear", "anker", "pos", "dokumentation", "siehe auch",
    "wort der woche", "quellen", "referenzen prüfen", "bibel",
    "lautschrift?", "keine belege", "belege fehlen", "üxx4", "üxx5",
    "ü-tabelle", "ü-liste", "ähnlichkeiten", "grundformverweis",
    "grundformverweis dekl", "grundformverweis konj", "lemmaverweis",
}

# Abbreviation table and connective list, transcribed from Vorlage:K/Abk.
K_ABBREV = {
    'AE': 'US-amerikanisch',
    'Abl.': 'mit Ablativ',
    'Ablativ': 'mit Ablativ',
    'Akkusativ': 'mit Akkusativ',
    'AmE': 'US-amerikanisch',
    'BE': 'britisch',
    'Bedva.': 'veraltete Bedeutung',
    'Bedvatd.': 'veraltende Bedeutung',
    'BrE': 'britisch',
    'CJK': 'für chinesische, japanische und koreanische Schriften',
    'Dativ': 'mit Dativ',
    'Dim.': 'Diminutiv',
    'Dimin.': 'Diminutiv',
    'Genitiv': 'mit Genitiv',
    'Geographie': 'Geografie',
    'Instrumental': 'mit Instrumental',
    'Ling.': 'Linguistik',
    'Med.': 'Medizin',
    'Plural': 'im Plural',
    'PmD': 'Präposition mit Dativ',
    'PmG': 'Präposition mit Genitiv',
    'PräpmD': 'Präposition mit Dativ',
    'PräpmG': 'Präposition mit Genitiv',
    'Wpräp': 'Wechselpräposition',
    'abw.': 'abwertend',
    'adv.': 'adverbial',
    'alemann.': 'alemannisch',
    'allg.': 'allgemein',
    'alltagsspr.': 'alltagssprachlich',
    'altlat.': 'altlateinisch',
    'amtsspr.': 'amtssprachlich',
    'aran.': 'aranesisch',
    'attr.': 'attributiv',
    'bair.': 'bairisch',
    'bar.': 'bairisch',
    'bes.': 'besonders',
    'bildungsspr.': 'bildungssprachlich',
    'bzw.': 'beziehungsweise',
    'dichter.': 'dichterisch',
    'erzg.': 'erzgebirgisch',
    'erzgeb.': 'erzgebirgisch',
    'euph.': 'euphemistisch',
    'fachspr.': 'fachsprachlich',
    'fam.': 'familiär',
    'fig': 'figürlich',
    'fig.': 'figurativ',
    'geh.': 'gehoben',
    'gsm': 'schweizerdeutsch',
    'haben': 'Hilfsverb haben',
    'hebben': 'Hilfsverb »hebben«',
    'hist.': 'historisch',
    'i. e. S.': 'im engeren Sinne',
    'i. w. S.': 'im weiteren Sinne',
    'i.e.S.': 'im engeren Sinne',
    'i.w.S.': 'im weiteren Sinne',
    'iPl': 'im Plural',
    'ieS': 'im engeren Sinne',
    'indekl.': 'indeklinabel',
    'intrans.': 'intransitiv',
    'iron.': 'ironisch',
    'iwS': 'im weiteren Sinne',
    'jugendspr.': 'jugendsprachlich',
    'kPl.': 'kein Plural',
    'kSg.': 'kein Singular',
    'kSt.': 'keine Steigerung',
    'kStg.': 'keine Steigerung',
    'kinderspr.': 'kindersprachlich',
    'klasslat.': 'klassischlateinisch',
    'landsch.': 'landschaftlich',
    'lautm.': 'lautmalerisch',
    'mA': 'mit Akkusativ',
    'mD': 'mit Dativ',
    'mG': 'mit Genitiv',
    'md.': 'mitteldeutsch',
    'mdal.': 'mundartlich',
    'metaphor.': 'metaphorisch',
    'meton.': 'metonymisch',
    'mitteld.': 'mitteldeutsch',
    'mlat.': 'mittellateinisch',
    'mundartl.': 'mundartlich',
    'nDu.': 'nur Dual',
    'nPl.': 'nur Plural',
    'nachklassischlateinisch': 'Nachklassisches Latein',
    'nigr.': 'nigrisch',
    'nkLat.': 'Nachklassisches Latein',
    'nlat.': 'neulateinisch',
    'nordd.': 'norddeutsch',
    'nordwestd.': 'nordwestdeutsch',
    'pej.': 'pejorativ',
    'poet.': 'poetisch',
    'prov.': 'provenzalisch',
    'provenz.': 'provenzalisch',
    'refl.': 'reflexiv',
    'reg.': 'regional',
    'sal.': 'salopp',
    'scherzh.': 'scherzhaft',
    'schriftspr.': 'schriftsprachlich',
    'schweiz.': 'schweizerisch',
    'schwäb.': 'schwäbisch',
    'schülerspr.': 'schülersprachlich',
    'seemannsspr.': 'seemannssprachlich',
    'sein': 'Hilfsverb sein',
    'soldatenspr.': 'soldatensprachlich',
    'sonderspr.': 'sondersprachlich',
    'spätlat.': 'spätlateinisch',
    'südd.': 'süddeutsch',
    'süddt.': 'süddeutsch',
    'techn.': 'technisch',
    'tlwva.': 'veraltete Bedeutung',
    'tlwvatd.': 'veraltende Bedeutung',
    'trans.': 'transitiv',
    'ugs.': 'umgangssprachlich',
    'ungebr.': 'ungebräuchlich',
    'unpers.': 'unpersönlich',
    'va.': 'veraltet',
    'vatd.': 'veraltend',
    'verh.': 'verhüllend',
    'vlat.': 'vulgärlateinisch',
    'volkst.': 'volkstümlich',
    'vul.': 'vulgär',
    'vulg.': 'vulgär',
    'vulgärlat.': 'vulgärlateinisch',
    'wien.': 'wienerisch',
    'z. B.': 'zum Beispiel',
    'z. T.': 'zum Teil',
    'Österr.': 'Österreich',
    'österr.': 'österreichisch',
    'übertr.': 'übertragen',
}

K_CONNECTORS = {
    'allg.',
    'allgemein',
    'ansonsten',
    'auch',
    'bei',
    'bes.',
    'besonders',
    'beziehungsweise',
    'bis',
    'bisweilen',
    'bzw.',
    'das',
    'der',
    'die',
    'eher',
    'früher',
    'hauptsächlich',
    'häufig',
    'im',
    'in',
    'insbes.',
    'insbesondere',
    'leicht',
    'meist',
    'meistens',
    'mit',
    'mitunter',
    'noch',
    'noch in',
    'nur',
    'nur noch',
    'oder',
    'oft',
    'oftmals',
    'ohne',
    'respektive',
    'sehr',
    'seltener',
    'seltener auch',
    'sonst',
    'sowie',
    'speziell',
    'später',
    'teils',
    'teilweise',
    'und',
    'ursprünglich',
    'von',
    'vor allem',
    'vor allem in',
    'z. B.',
    'z. T.',
    'zum Beispiel',
    'zum Teil',
    'zumeist',
    'über',
    'überwiegend',
}


def _split_template(body):
    """Split a template body into (name, positional args, named args)."""
    parts = body.split("|")
    name = parts[0].strip().lower().lstrip(":")
    positional, named = [], {}
    for part in parts[1:]:
        key, sep, value = part.partition("=")
        if sep and re.fullmatch(r"[^\W\d_][\w .-]*", key.strip(), re.U):
            named[key.strip().lower()] = value.strip()
        else:
            positional.append(part.strip())
    return name, positional, named


def render_kontext(body):
    """Render `{{K|…}}`, the marker template that opens most definitions.

    Reproduces Vorlage:K: each positional argument is expanded through the
    Vorlage:K/Abk abbreviation table, arguments are joined with a comma unless
    the previous one is a connective ("auch", "meist", …) or the next one is a
    conjunction, and `ft=` appends free text.
    """
    parts = body.split("|")[1:]
    items, named = [], {}
    for part in parts:
        key, sep, value = part.partition("=")
        key = key.strip()
        if sep and re.fullmatch(r"[A-Za-zÄÖÜäöü][\w.]*", key):
            named[key.lower()] = value.strip()
        else:
            items.append(part.strip())
    items = [item for item in items if item]

    out = ""
    for index, raw in enumerate(items):
        shown = K_ABBREV.get(raw, raw)
        if index == 0:
            out = shown
            continue
        custom = named.get(f"t{index}")
        if custom is not None:
            separator = {":": ":", ";": ";", "_": ""}.get(custom, custom)
        elif items[index - 1] in K_CONNECTORS:
            separator = ""
        elif raw in ("beziehungsweise", "oder", "respektive", "sowie", "und"):
            separator = ""
        else:
            separator = ","
        out += separator + " " + shown

    free = named.get("ft")
    if free:
        if out:
            custom = named.get("t7")
            separator = {":": ":", ";": ";", "_": ""}.get(custom, custom) \
                if custom is not None else ","
            out += separator + " "
        out += free
    return out


def render_template(body, title, labels):
    """Render one innermost template to plain text.

    Only templates the wiki renders as prose are expanded; everything else is
    dropped, because a raw `{{…}}` inside a definition is worse than a small
    gap. `labels` collects the usage/domain markers so the caller can show them
    as a parenthetical prefix.
    """
    name, positional, named = _split_template(body)
    if not name:
        return ""

    if name == "k":
        text = render_kontext(body)
        if not text:
            return ""
        if labels is None:
            return text
        labels.append(text)
        return ""

    # Stand-alone marker templates: `{{ugs.}}`, `{{trans.}}`, `{{va.}}`, …
    # They render as the expanded word plus whatever punctuation is passed in.
    expansion = K_ABBREV.get(name) or K_ABBREV.get(body.split("|")[0].strip())
    if expansion and (name.endswith(".") or name in STANDALONE_MARKERS):
        if labels is None:
            return expansion
        labels.append(expansion)
        return ""

    if name in ("wikipedia", "w", "wp", "wikt", "wikitionary"):
        target = named.get("1") or (positional[0] if positional else "")
        return target.split(":")[-1].split("#")[0]

    if name in ("l", "link", "wikilink"):
        return positional[-1] if positional else ""

    if name in ("ü", "üt", "ük", "ü?"):
        # `{{Ü|en|dog}}` — language code first, the word second.
        return positional[1] if len(positional) > 1 else ""

    if name == "lautschrift":
        return f"[{positional[0]}]" if positional else ""

    if name in ("vgl.", "vergleiche", "siehe"):
        return "vergleiche"

    if name in ("pl.", "plural"):
        return "Plural"
    if name in ("sg.", "singular"):
        return "Singular"

    if name in GENDER_NAMES:
        return ""

    if name in DROP_TEMPLATE_NAMES or name.startswith(DROP_TEMPLATE_PREFIXES):
        return ""

    return ""


# Marker templates whose name does not end in a period.
STANDALONE_MARKERS = {
    "sein", "haben", "hebben", "plural", "ieS", "iwS", "gsm", "ae", "be",
    "amer", "brit", "ce", "cjk", "ddr", "wpräp",
}


def clean_wikitext(text, title, labels=None):
    """Turn a fragment of wikitext into readable plain prose.

    Pass a list as `labels` to hoist marker templates (`{{K|…}}`, `{{ugs.}}`)
    out of the text; with `labels=None` they render where they stand.
    """
    text = COMMENT_RE.sub("", text)
    text = REF_PAIR_RE.sub("", text)
    text = REF_SELF_RE.sub("", text)
    text = SENSE_MARK_RE.sub("", text)
    text = FILE_LINK_RE.sub("", text)

    # Links first: resolving them before templates keeps a `[[a|b]]` pipe from
    # being mistaken for a template argument separator.
    def link(match):
        inner = match.group(1)
        target, _, shown = inner.partition("|")
        if shown:
            return shown
        # `[[w:Fuß (Einheit)|…]]` without display text: use the tail.
        return target.split(":")[-1] if ":" in target else target

    for _ in range(4):
        new = WIKILINK_RE.sub(link, text)
        if new == text:
            break
        text = new
    text = EXTLINK_RE.sub(lambda m: m.group(1) or "", text)

    # Templates innermost-first, so nested ones resolve bottom-up.
    for _ in range(12):
        new = INNER_TEMPLATE_RE.sub(
            lambda m: render_template(m.group(1), title, labels), text
        )
        if new == text:
            break
        text = new
    # Anything still unbalanced would render as literal braces.
    text = re.sub(r"\{\{[^}]*\}?\}?", "", text)

    # A hand-edited page sometimes opens a comment or a <ref> and never closes
    # it; without this the raw tag trails into the definition.
    text = re.sub(r"<!-{0,2}.*$", "", text, flags=re.S)
    text = re.sub(r"<ref\b.*$", "", text, flags=re.S | re.I)
    text = TAG_RE.sub("", text)
    text = html.unescape(text)
    text = QUOTES_RE.sub("", text)
    text = text.replace("&nbsp;", " ")
    # A page that opens a template or a link on one line and closes it on the
    # next leaves an orphaned delimiter behind; never show it to a reader.
    text = LOOSE_MARKUP_RE.sub("", text)

    text = WS_RE.sub(" ", text)
    text = re.sub(r"\s+([,;.:!?])", r"\1", text)
    text = re.sub(r"\(\s*\)", "", text)
    # A dropped template between two sentences leaves `. .` behind.
    text = re.sub(r"(?<!\.)\.\s*\.(?!\.)", ".", text)
    text = re.sub(r"\s{2,}", " ", text)
    return text.strip(" \t.,;:·—–-").strip()


# ---------------------------------------------------------------------------
# Page parsing
# ---------------------------------------------------------------------------


def german_section(text):
    """The `{{Sprache|Deutsch}}` section body, or None."""
    match = LANG_DE_HEADING.search(text)
    if not match:
        return None
    start = match.end()
    following = LEVEL2_HEADING.search(text, start)
    return text[start:following.start()] if following else text[start:]


def heading_pos_name(heading):
    """(display name, is_inflected_form) for a POS heading, else None."""
    kinds = WORTART_RE.findall(heading)
    if not kinds:
        return None
    names = []
    for kind, language in kinds:
        # A stray non-German word-class box inside the German section means the
        # page is mis-tagged; ignore it rather than importing another language.
        if language and language != "Deutsch":
            return None
        if kind and kind not in names:
            names.append(kind)
    if not names:
        return None
    genders = [GENDER_NAMES[g] for g in GENDER_RE.findall(heading)]
    is_form = all(name.lower() in FORM_WORTARTEN for name in names)
    return ", ".join(names + genders), is_form


def block_lines(body, marker):
    """The lines of the `{{marker}}` block inside one POS section."""
    match = re.search(r"^\{\{\s*" + marker + r"\s*\}\}\s*$", body, re.M)
    if not match:
        return []
    lines = []
    for line in body[match.end():].split("\n"):
        stripped = line.strip()
        if stripped.startswith(("{{", "=", "----", "</")):
            break
        lines.append(line)
    return lines


def senses_from_bedeutungen(title, lines):
    """[(number, definition)] from the `:[1] …` lines of a Bedeutungen block."""
    senses = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if line.startswith("*"):
            # `*{{K|sein}}` groups the senses that follow by auxiliary verb; it
            # is a sub-heading, not a sense.
            continue
        if not line.startswith(":"):
            # A wrapped continuation of the previous sense.
            if senses:
                extra = clean_wikitext(line, title)
                if extra:
                    number, definition = senses[-1]
                    senses[-1] = (number, definition + " " + extra)
            continue
        match = SENSE_LINE.match(line)
        if not match:
            continue
        number, source = match.groups()
        labels = []
        marker = LEADING_MARKERS.match(source)
        head = ""
        if marker:
            # Most opening templates are markers and render as nothing; one
            # that does render is part of the definition, so keep the text.
            head = clean_wikitext(marker.group(0), title, labels)
            source = source[marker.end():]
        definition = clean_wikitext(source, title)
        if head:
            definition = f"{head} {definition}".strip() if definition else head
        if not definition:
            continue
        if labels:
            seen, unique = set(), []
            for item in labels:
                item = html.unescape(QUOTES_RE.sub("", item)).strip()
                key = item.lower()
                if item and key not in seen:
                    seen.add(key)
                    unique.append(item)
            definition = f"({', '.join(unique)}) {definition}"
        if not definition.endswith((".", "!", "?", "…")):
            definition += "."
        senses.append(((number or "").strip(), definition))
    return senses


def senses_from_merkmale(title, lines):
    """[(number, definition)] from a `{{Grammatische Merkmale}}` block.

    Inflected-form pages carry no `{{Bedeutungen}}`; their whole content is
    lines like `*Nominativ Plural des Substantivs '''[[Haus]]'''`, which already
    read as German prose.
    """
    senses = []
    for line in lines:
        line = line.strip()
        if not line.startswith(("*", ":")):
            continue
        definition = clean_wikitext(line.lstrip("*: "), title)
        if not definition:
            continue
        if not definition.endswith((".", "!", "?", "…")):
            definition += "."
        senses.append(("", definition))
    return senses


def parse_page(title, text, keep_forms=True):
    """([(pos_name, [(number, definition)])], saw_form) for the German section."""
    section = german_section(text)
    if section is None:
        return [], False

    # Flat walk over every sub-heading: word-class boxes sit at level 3 on a
    # plain page and at level 4 under `=== Wortart 1 ===`, so depth is
    # unreliable.
    blocks = []
    current = None
    last = 0
    for match in ANY_HEADING.finditer(section):
        if current is not None:
            blocks.append((current, section[last:match.start()]))
        current = heading_pos_name(match.group(2))
        last = match.end()
    if current is not None:
        blocks.append((current, section[last:]))

    result = []
    saw_form = False
    for (pos, is_form), body in blocks:
        if is_form:
            saw_form = True
            if not keep_forms:
                continue
        senses = senses_from_bedeutungen(title, block_lines(body, "Bedeutungen"))
        if not senses:
            senses = senses_from_merkmale(
                title, block_lines(body, "Grammatische Merkmale")
            )
        # Distinct wikitext can clean down to the same sentence.
        seen, unique = set(), []
        for number, definition in senses:
            if definition.lower() not in seen:
                seen.add(definition.lower())
                unique.append((number, definition))
        if unique:
            result.append((pos, unique))
    return result, saw_form


def format_definition(blocks):
    """The exact text the app renders: POS on its own line, senses numbered."""
    chunks = []
    for pos, senses in blocks:
        lines = [pos]
        for index, (number, definition) in enumerate(senses, start=1):
            lines.append(f"{number or index}. {definition}")
        chunks.append("\n".join(lines))
    return "\n\n".join(chunks)


# ---------------------------------------------------------------------------
# Dump handling
# ---------------------------------------------------------------------------


def ensure_dump(path):
    """Download the dump unless it is already here — it is 256 MB."""
    if os.path.exists(path) and os.path.getsize(path) > 1_000_000:
        print(f"Using cached dump: {path} "
              f"({os.path.getsize(path) / 1e6:.1f} MB)")
        return path
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    print(f"Downloading {DUMP_URL}")
    partial = path + ".part"
    with urllib.request.urlopen(DUMP_URL) as response, open(partial, "wb") as out:
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


def iter_pages(dump_path):
    """Stream (title, text) for main-namespace, non-redirect pages."""
    with bz2.open(dump_path, "rb") as stream:
        context = ET.iterparse(stream, events=("start", "end"))
        _, root = next(context)
        namespace = root.tag[: root.tag.index("}") + 1] if "}" in root.tag else ""
        page_tag = namespace + "page"

        for event, element in context:
            if event != "end" or element.tag != page_tag:
                continue
            ns = element.findtext(namespace + "ns")
            redirect = element.find(namespace + "redirect")
            title = element.findtext(namespace + "title") or ""
            revision = element.find(namespace + "revision")
            text = revision.findtext(namespace + "text") if revision is not None else None
            if ns == "0" and redirect is None and text:
                yield title, text
            # iterparse keeps every finished element alive under root; without
            # this the whole decompressed XML accumulates in memory.
            element.clear()
            root.clear()


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
        "source": "dewiktionary",
        "description": "Einsprachiges deutsches Wörterbuch, aus dem "
                       "deutschsprachigen Wiktionary extrahiert.",
        "license": "CC BY-SA 4.0",
        "date": time.strftime("%Y-%m-%d"),
    }

    db.execute("BEGIN")
    db.executemany("INSERT INTO meta(key, value) VALUES(?, ?)", sorted(meta.items()))
    db.executemany(
        "INSERT INTO entries(word, word_lower, definition) VALUES(?, ?, ?)",
        ((word, word.lower(), definition) for word, definition in rows),
    )
    db.execute("COMMIT")
    db.execute("CREATE INDEX idx_entries_lower ON entries(word_lower)")
    db.execute("VACUUM")
    db.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    default_dump = os.path.join("build", "dumps",
                                "dewiktionary-latest-pages-articles.xml.bz2")
    parser.add_argument("--dump", default=default_dump,
                        help="path to the bz2 dump (downloaded if absent)")
    parser.add_argument("--out", default=os.path.join("build", "de-wiktionary.sqlite"))
    parser.add_argument("--limit", type=int, default=0,
                        help="stop after N pages (for a quick smoke test)")
    parser.add_argument("--gzip", action="store_true",
                        help="also write <out>.gz for shipping")
    parser.add_argument("--no-forms", action="store_true",
                        help="drop bot-generated inflected-form entries "
                             "(Deklinierte/Konjugierte Form) to shrink the file")
    args = parser.parse_args()

    dump = ensure_dump(args.dump)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)

    started = time.time()
    scanned = german = forms = 0
    rows = []
    for title, text in iter_pages(dump):
        scanned += 1
        if scanned % 50_000 == 0:
            elapsed = time.time() - started
            print(f"  {scanned:>7} pages, {len(rows):>6} entries, {elapsed:5.0f}s")
        if "Sprache|Deutsch" not in text:
            continue
        blocks, saw_form = parse_page(title, text, keep_forms=not args.no_forms)
        if saw_form:
            forms += 1
        if not blocks:
            continue
        german += 1
        definition = format_definition(blocks)
        if definition.strip():
            rows.append((title, definition))
        if args.limit and scanned >= args.limit:
            break

    rows.sort(key=lambda row: (unicodedata.normalize("NFKD", row[0].lower()),
                               0 if row[0].islower() else 1, row[0]))
    print(f"Scanned {scanned} pages; {german} had a German section with senses "
          f"({forms} pages are inflected forms)")

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

#!/usr/bin/env python3
"""Build a MONOLINGUAL Hindi dictionary from the Hindi Wiktionary dump.

hi.wiktionary is dominated by a bot import of the *हिन्दी शब्दसागर* (Nagari
Pracharini Sabha, 1929) — a real monolingual Hindi dictionary — which sits on
about 164,000 pages under `== प्रकाशितकोशों से अर्थ == / === शब्दसागर ===`.
That import, plus the much smaller set of hand-written entries, is what this
script keeps. Pages for other languages (hi.wiktionary also documents Kannada,
Marathi, English, ... words) are discarded, so the result is the Hindi
speaker's equivalent of the bundled WordNet, not a translation dictionary.

The markup is far less regular than the European editions: the language marker
may be `{{-hi-}}`, `{{-हिन्दी-}}`, `== हिन्दी ==` or `= {{हिन्दी}} =`, or absent
altogether, and part-of-speech markers appear both as headings and as inline
`{{-संज्ञा-}}` templates. Heading depth is meaningless, so the parser walks
markers flatly, exactly as the Spanish build does.

The output schema is byte-for-byte the one `StarDictImporter` produces, so the
app opens the downloaded file with no new reader code:

    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE entries(id INTEGER PRIMARY KEY, word TEXT NOT NULL,
                         word_lower TEXT NOT NULL, definition TEXT NOT NULL);
    CREATE INDEX idx_entries_lower ON entries(word_lower);

Usage:
  uv run python3 scripts/build_wiktionary_hi.py [--dump PATH] [--out PATH]
                                                [--limit N] [--gzip]
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

DUMP_URL = "https://dumps.wikimedia.org/hiwiktionary/latest/hiwiktionary-latest-pages-articles.xml.bz2"

BOOKNAME = "हिन्दी विक्षनरी"
LANGUAGE = "हिन्दी"

SOURCE = (
    "hiwiktionary (hi.wiktionary.org), including its bot import of the "
    "हिन्दी शब्दसागर (नागरी प्रचारिणी सभा)."
)
LICENSE = "CC BY-SA 4.0"
ATTRIBUTION = (
    "हिन्दी विक्षनरी (hi.wiktionary.org), CC BY-SA 4.0. "
    "अधिकांश अर्थ हिन्दी शब्दसागर (नागरी प्रचारिणी सभा) से।"
)
DESCRIPTION = (
    "हिन्दी का एकभाषी शब्दकोश: हिन्दी शब्दों के अर्थ हिन्दी में। "
    "(Monolingual Hindi dictionary — Hindi words defined in Hindi.)"
)

DEVANAGARI_DIGITS = "०१२३४५६७८९"

# ---------------------------------------------------------------------------
# Language sectioning
# ---------------------------------------------------------------------------

# A heading at any depth, or an inline `{{-hi-}}` / `{{-संज्ञा-}}` marker. The
# two are interchangeable on this wiki, so one pass has to see both.
MARKER_RE = re.compile(
    r"^\s*(?:={1,6})\s*(?P<heading>.+?)\s*(?:={1,6})\s*$"
    r"|\{\{\s*-\s*(?P<code>[^\-{}|\n]{1,24}?)\s*-\s*\}\}",
    re.M,
)

HINDI_NAMES = {
    "हिन्दी", "हिंदी", "हिन्दि", "हिन्‍दी", "hi", "hindi", "हिन्दुस्तानी",
}

# Language names as hi.wiktionary spells them. Anything under one of these is a
# foreign word explained in Hindi, which is not what a Hindi speaker looks up.
FOREIGN_NAMES = {
    "अंग्रेज़ी", "अंग्रेजी", "अङ्ग्रेजी", "अंग्रे", "en", "english",
    "उर्दू", "फ़ारसी", "फारसी", "फ़ार्सी", "अरबी", "तुर्की", "हिब्रू",
    "संस्कृत", "पालि", "प्राकृत", "मराठी", "नेपाली", "भोजपुरी", "मैथिली",
    "अवधी", "बज्जिका", "मगही", "राजस्थानी", "हरियाणवी", "डोगरी", "कोंकणी",
    "कोङ्कणी", "गुजराती", "पंजाबी", "पञ्जाबी", "बंगाली", "बांग्ला", "बाङ्ला",
    "असमिया", "ओड़िया", "उड़िया", "सिंधी", "सिन्धी", "कश्मीरी", "संथाली",
    "कन्नड़", "कन्नड", "तमिल", "तेलुगु", "तेलेगु", "मलयालम", "सिंहली",
    "नेवारी", "नेपाल भाषा", "तिब्बती", "बर्मी", "थाई", "वियतनामी", "खमेर",
    "चीनी", "मंदारिन", "जापानी", "कोरियाई", "मंगोलियाई", "इंडोनेशियाई",
    "मलय", "तागालोग", "रूसी", "यूक्रेनी", "पोलिश", "चेक", "स्लोवाक",
    "सर्बियाई", "क्रोएशियाई", "बुल्गारियाई", "सायरेबियन", "serbian",
    "जर्मन", "डच", "डेनिश", "स्वीडिश", "नॉर्वेजियाई", "आइसलैंडी",
    "फ़्रान्सीसी", "फ़्रांसीसी", "फ्रांसीसी", "फ्रेंच", "फ़्रेंच",
    "स्पेनी", "स्पैनिश", "स्पेनिश", "पुर्तगाली", "इतालवी", "इटालियन",
    "रोमानियाई", "ग्रीक", "यूनानी", "लातिनी", "लैटिन", "अल्बानियाई",
    "आर्मीनियाई", "जॉर्जियाई", "फ़िनिश", "फिनिश", "एस्टोनियाई", "हंगेरियाई",
    "मालागासी", "स्वाहिली", "अफ़्रीकान्स", "अफ्रीकांस", "यिद्दिश",
    "एस्पेरांतो", "क्लिंगन", "वोलापुक", "लोजबान", "इंटरलिंगुआ",
}

# ISO codes that appear as `{{-xx-}}`; `hi` is the one we keep. Codes that are
# really part-of-speech or section markers on this wiki are excluded below.
FOREIGN_CODES = {
    "en", "de", "fr", "es", "it", "nl", "pt", "ru", "uk", "pl", "cs", "sk",
    "sr", "hr", "bg", "el", "la", "sq", "hy", "ka", "fi", "et", "hu", "sv",
    "da", "no", "is", "tr", "ar", "fa", "he", "ur", "ps", "ku", "yi",
    "sa", "pa", "bn", "as", "or", "gu", "mr", "ne", "si", "ta", "te", "kn",
    "ml", "kok", "sd", "ks", "mai", "bho", "dv", "my", "th", "vi", "km",
    "lo", "zh", "ja", "ko", "mn", "bo", "id", "ms", "tl", "jv", "sw", "af",
    "am", "ha", "yo", "zu", "xh", "eo", "io", "ia", "tlh", "jbo", "vo",
    "mg", "eu", "ca", "gl", "cy", "ga", "gd", "br", "lb", "mt", "lv", "lt",
    "be", "mk", "sl", "bs", "az", "kk", "ky", "uz", "tg", "tk", "tt", "ba",
    "ceb", "haw", "mi", "sm", "to", "fj", "qu", "ay", "gn", "nv", "chr",
    "avk", "grc", "ang", "non", "got", "sco", "fro", "pro",
}

# `{{-noun-}}`, `{{-संज्ञा-}}` and friends look exactly like a language marker
# but name a part of speech.
POS_HEADINGS = {
    "संज्ञा", "सञ्ज्ञा", "सज्ञा", "संज्ञा पुल्लिंग", "संज्ञा स्त्रीलिंग",
    "संज्ञा पुँल्लिंग", "व्यक्तिवाचक संज्ञा", "नामवाचक संज्ञा",
    "नामवाचक सङ्ज्ञा", "जातिवाचक संज्ञा", "भाववाचक संज्ञा",
    "समूहवाचक संज्ञा", "द्रव्यवाचक संज्ञा", "स्थान वाचक संज्ञा",
    "स्थानवाचक संज्ञा", "वस्तु वाचक संज्ञा", "वस्तुवाचक संज्ञा",
    "क्रिया", "सकर्मक क्रिया", "अकर्मक क्रिया", "विशेषण", "क्रिया विशेषण",
    "क्रियाविशेषण", "सर्वनाम", "अव्यय", "संबंधबोधक", "सम्बन्धबोधक",
    "समुच्चयबोधक", "विस्मयादिबोधक", "उपसर्ग", "प्रत्यय", "संख्या", "संख्यावाचक",
    "अर्थ", "सरल अर्थ", "अन्य अर्थ", "परिभाषा", "मानी और परिभाषा",
    "noun", "verb", "adj", "adjective", "adv", "adverb", "pronoun",
    "prep", "conj", "interj", "num", "prefix", "suffix", "proper noun",
}

POS_DISPLAY = {
    "noun": "संज्ञा", "proper noun": "व्यक्तिवाचक संज्ञा", "verb": "क्रिया",
    "adj": "विशेषण", "adjective": "विशेषण", "adv": "क्रियाविशेषण",
    "adverb": "क्रियाविशेषण", "pronoun": "सर्वनाम", "prep": "संबंधबोधक",
    "conj": "समुच्चयबोधक", "interj": "विस्मयादिबोधक", "num": "संख्यावाचक",
    "prefix": "उपसर्ग", "suffix": "प्रत्यय",
}

SHABDASAGAR_HEADINGS = {"शब्दसागर", "शब्द सागर", "शब्दसागर कोश"}

# Headings that never hold a definition. Listed so that a stray one is never
# mistaken for a part of speech by the fuzzy matcher below.
NON_POS_HEADINGS = {
    "अनुवाद", "उच्चारण", "उच्चरण", "यह भी देखें", "यह भी देखिए",
    "इन्हें भी देखें", "इसे भी देखें", "पर्यायवाची", "पर्यायवाची शब्द",
    "पर्याय", "समानार्थी", "समानार्थी शब्द", "समान अर्थ वाले शब्द",
    "विलोम", "विलोम शब्द", "विरुद्धार्थ", "संबंधित शब्द", "सम्बन्धित शब्द",
    "संबन्धित शब्द", "अन्य शब्द", "व्युत्पत्ति", "निरुक्ति", "मूल",
    "मूल शब्द", "उदाहरण", "उदाहरण वाक्य", "प्रयोग", "श्रेणी", "श्रेणियाँ",
    "संदर्भ", "सन्दर्भ", "हवाला", "उद्धरण स्रोत", "बाहरी कड़ियाँ",
    "बाहरी कडियाँ", "संबंधित कड़ियाँ", "अन्य भाषा में", "अन्य भाषाओं में",
    "अन्य भाषाओं में अनुवाद", "तर्जुमा", "लिंग", "व्याकरणिक परिचय",
    "शब्दसफ़र", "वैकल्पिक नाम", "वैकल्पिक रूप", "वैकल्पिक वर्तनी",
    "अन्य रूप", "रूपान्तर", "मुहावरे", "मुहावरे/लोकोक्तियाँ",
    "संबंधित मुहावरे", "व्युत्पन्न शब्द", "संधि", "विश्लेषण", "टिप्पणी",
    "वर्णक्रम सहचर", "कल्पित शब्द", "अक्षर", "प्रकाशितकोशों से अर्थ",
    "प्रकाशित कोशों से अर्थ", "trans", "phon", "rom", "ref", "etym",
}


def normalise_marker(name):
    """Reduce a heading or `{{-x-}}` code to a bare comparable name."""
    name = name.strip()
    name = re.sub(r"^\{\{\s*|\s*\}\}$", "", name).strip()
    name = re.sub(r"^\[\[\s*|\s*\]\]$", "", name).strip()
    name = name.replace("'''", "").replace("''", "").strip()
    name = name.split("|")[0].strip()
    return name.strip(" :=").strip()


def marker_language(name):
    """'hi', 'foreign', or None when the marker does not name a language."""
    name = normalise_marker(name)
    lowered = name.lower()
    if lowered in POS_HEADINGS or name in POS_HEADINGS:
        return None
    if lowered in NON_POS_HEADINGS or name in NON_POS_HEADINGS:
        return None
    # `रूसी भाषा`, `गुजराती भाषा`, `हिंदी में`
    bare = re.sub(r"\s*(?:भाषा|में)$", "", name).strip()
    if name in HINDI_NAMES or bare in HINDI_NAMES or lowered in HINDI_NAMES:
        return "hi"
    if name in FOREIGN_NAMES or bare in FOREIGN_NAMES or lowered in FOREIGN_NAMES:
        return "foreign"
    if lowered in FOREIGN_CODES:
        return "foreign"
    return None


def marker_blocks(text):
    """[(marker_name_or_None, body)] in document order."""
    blocks = []
    current = None
    last = 0
    for match in MARKER_RE.finditer(text):
        blocks.append((current, text[last:match.start()]))
        current = (match.group("heading") or match.group("code") or "").strip()
        last = match.end()
    blocks.append((current, text[last:]))
    return blocks


def hindi_blocks(text):
    """Only the blocks belonging to the Hindi part of the page.

    A page starts in Hindi: the caller has already required a Devanagari title,
    and the overwhelming majority of pages carry no language marker at all.
    A recognised foreign marker switches the parser off until Hindi resumes.
    """
    result = []
    active = "hi"
    for name, body in marker_blocks(text):
        if name is not None:
            language = marker_language(name)
            if language is not None:
                active = language
                name = None  # a language marker is not a part of speech
        if active == "hi":
            result.append((name, body))
    return result


# ---------------------------------------------------------------------------
# Wikitext cleaning
# ---------------------------------------------------------------------------

COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
REF_PAIR_RE = re.compile(r"<ref\b[^>]*>.*?</ref>", re.S | re.I)
REF_SELF_RE = re.compile(r"<ref\b[^>]*/\s*>", re.I)
BR_RUN_RE = re.compile(r"(?:\s*<\s*br\s*/?\s*>\s*)+", re.I)
TAG_RE = re.compile(r"</?[a-zA-Z][a-zA-Z0-9]*\b[^>]*/?>")
FILE_LINK_RE = re.compile(
    r"\[\[\s*(?:चित्र|छवि|फ़ाइल|फाइल|श्रेणी|संवर्ग|File|Image|Category|category)"
    r"\s*:[^\[\]]*(?:\[\[[^\[\]]*\]\][^\[\]]*)*\]\]",
    re.I,
)
# `[[:en:time]]`, `[[w:पानी|पानी]]` — an interwiki or project link, not a gloss.
INTERWIKI_RE = re.compile(r"\[\[\s*:?(?:[a-z]{2,3}|w|wikt|s|q|commons):[^\[\]]*\]\]", re.I)
WIKILINK_RE = re.compile(r"\[\[([^\[\]]*)\]\]")
EXTLINK_RE = re.compile(r"\[(?:https?:|//)\S+?(?:\s+([^\]]*))?\]")
INNER_TEMPLATE_RE = re.compile(r"\{\{[^{}]*\}\}")
QUOTES_RE = re.compile(r"'{2,5}")
WS_RE = re.compile(r"[ \t ]+")


def clean_wikitext(text):
    """Turn a fragment of hi.wiktionary wikitext into readable Hindi prose.

    Unlike the Spanish edition, no template here renders as prose a reader
    needs: they are translation tables, inflection boxes, audio players and
    stub notices. Dropping every template outright is both simpler and safer
    than leaving a raw `{{...}}` in the middle of a definition.
    """
    text = COMMENT_RE.sub("", text)
    text = REF_PAIR_RE.sub("", text)
    text = REF_SELF_RE.sub("", text)
    text = FILE_LINK_RE.sub("", text)
    text = INTERWIKI_RE.sub("", text)

    # Links before templates, so a `[[a|b]]` pipe is never mistaken for a
    # template argument separator.
    def link(match):
        inner = match.group(1)
        target, _, shown = inner.partition("|")
        if shown:
            return shown
        return target.split(":")[-1] if ":" in target else target

    for _ in range(4):
        new = WIKILINK_RE.sub(link, text)
        if new == text:
            break
        text = new
    text = EXTLINK_RE.sub(lambda m: m.group(1) or "", text)

    for _ in range(8):
        new = INNER_TEMPLATE_RE.sub("", text)
        if new == text:
            break
        text = new
    text = re.sub(r"\{\{[^}]*\}?\}?", "", text)

    # A hand-edited page sometimes opens a comment or a <ref> and never closes
    # it; without this the raw tag trails into the definition.
    text = re.sub(r"<!-{0,2}.*$", "", text, flags=re.S)
    text = re.sub(r"<ref\b.*$", "", text, flags=re.S | re.I)
    text = TAG_RE.sub("", text)
    text = html.unescape(text)
    text = QUOTES_RE.sub("", text)
    text = text.replace("&nbsp;", " ").replace(" ", " ")

    text = WS_RE.sub(" ", text.replace("\n", " "))
    # Hindi typography sets no space before a danda or a comma.
    text = re.sub(r"\s+([।,;:!?॥])", r"\1", text)
    # Whatever brackets survive are unbalanced — a template or an image link
    # that a hand edit spread over several lines, split before it was resolved.
    text = re.sub(r"\[\[|\]\]|\{\{|\}\}", "", text)
    text = re.sub(r"\(\s*\)", "", text)
    text = re.sub(r"\[\s*\]", "", text)
    text = re.sub(r"\s{2,}", " ", text)
    return text.strip(" \t।॥.,;:·—–-").strip()


def is_substantive(text):
    """False for a fragment that is only punctuation, a stub mark or a number.

    The wiki is full of `#…` placeholders, and the शब्दसागर OCR occasionally
    breaks a page reference across a `<br><br>` and leaves `२३. ।` behind.
    """
    if not text:
        return False
    letters = re.sub(r"[^ऀ-ॣॲ-ॿ\w]", "", text, flags=re.U)
    letters = re.sub(r"[" + DEVANAGARI_DIGITS + r"0-9_]", "", letters)
    return len(letters) >= 2


# ---------------------------------------------------------------------------
# शब्दसागर parsing
# ---------------------------------------------------------------------------

# `संज्ञा पुं॰`, `क्रि॰ अ॰`, `वि॰`, `पु † संज्ञा स्त्री॰` — a short, closed
# vocabulary of grammar abbreviations, plus the OCR variants the import carries.
POS_TOKENS = {
    "संज्ञा", "सज्ञा", "सञ्ज्ञा", "सग्ंया", "सज्ञां", "संज्ञां",
    "क्रि", "क्रिं", "वि", "विं", "बि", "व्रि", "अव्य", "अब्य", "सर्व",
    "प्रत्य", "उप", "पुं", "पुँ", "पृं", "पु", "स्त्री", "स्री", "स्त्रा",
    "नपुं", "अ", "स", "सं", "ना", "व्य", "यौ", "हिं", "मि",
}
# A phrase is only accepted as a part of speech if it contains one of these,
# so that a definition starting with a short common word is never eaten.
STRONG_POS_TOKENS = {
    "संज्ञा", "सज्ञा", "सञ्ज्ञा", "सग्ंया", "सज्ञां", "संज्ञां",
    "क्रि", "क्रिं", "वि", "विं", "बि", "व्रि", "अव्य", "अब्य", "सर्व",
    "प्रत्य", "उप", "व्य",
}
TOKEN_RE = re.compile(r"\s*(\S+)")
ABBREV_STRIP = " ॰.,;:†*"

SENSE_NUMBER_RE = re.compile(r"^\s*([" + DEVANAGARI_DIGITS + r"]+|\d+)\s*[.।)]\s*")
# `अंकुर ^१`, `लाल पु † ^४`
HOMOGRAPH_RE = re.compile(r"\^\s*([" + DEVANAGARI_DIGITS + r"\d]+)")


def take_pos(text):
    """Split a leading grammar-abbreviation phrase off the header."""
    taken, index, strong = [], 0, False
    for _ in range(6):
        match = TOKEN_RE.match(text, index)
        if not match:
            break
        token = match.group(1)
        bare = token.strip(ABBREV_STRIP)
        if not bare:
            # A bare `†` (the import's "archaic" mark) sits between two real
            # abbreviations; stepping over it keeps the phrase together.
            taken.append(token)
            index = match.end()
            continue
        if bare in POS_TOKENS:
            taken.append(token)
            index = match.end()
            if bare in STRONG_POS_TOKENS:
                strong = True
        else:
            break
    if not strong:
        return "", text
    return " ".join(taken), text[index:]


def take_brackets(text):
    """Peel the `[सं॰ हस्त, प्रा॰ हत्थ]` etymology groups off the header."""
    groups, index = [], 0
    while True:
        match = re.compile(r"\s*\[([^\[\]]*)\]").match(text, index)
        if not match:
            break
        inner = match.group(1).strip()
        if inner:
            groups.append(f"[{inner}]")
        index = match.end()
    return groups, text[index:]


def parse_shabdasagar_header(header, title):
    """(pos_line, inline_definition) for one homograph paragraph's first chunk."""
    text = header.strip()
    if title and text.startswith(title):
        text = text[len(title):]

    homograph = ""
    match = HOMOGRAPH_RE.search(text[:40])
    if match:
        homograph = match.group(1)
        text = text[:match.start()] + " " + text[match.end():]
    text = text.lstrip(" †*·-—")

    pos, rest = take_pos(text)
    if not pos:
        # The headword sometimes differs from the page title (a spelling
        # variant); drop one leading token and try again.
        first = TOKEN_RE.match(text)
        if first:
            retry_pos, retry_rest = take_pos(text[first.end():])
            if retry_pos:
                pos, rest = retry_pos, retry_rest
    if not pos:
        rest = text

    brackets, rest = take_brackets(rest)

    head = []
    if homograph:
        head.append(f"({homograph})")
    if pos:
        head.append(pos)
    head.extend(brackets)
    return " ".join(head), rest


def parse_shabdasagar(body, title):
    """[(pos_line, [(number, definition)])] for one शब्दसागर section."""
    body = FILE_LINK_RE.sub("", body)
    blocks = []
    for paragraph in re.split(r"\n\s*\n", body):
        paragraph = paragraph.strip()
        if not paragraph:
            continue
        # Split on the `<br><br>` sense separator *before* cleaning, because
        # generic tag stripping would erase it.
        chunks = BR_RUN_RE.split(paragraph)
        pos_line, inline = parse_shabdasagar_header(chunks[0], title)
        pos_line = clean_wikitext(pos_line)

        senses = []
        inline = clean_wikitext(inline)
        if is_substantive(inline):
            senses.append(("", inline))

        for chunk in chunks[1:]:
            match = SENSE_NUMBER_RE.match(chunk)
            number = match.group(1) if match else ""
            text = clean_wikitext(chunk[match.end():] if match else chunk)
            if not is_substantive(text):
                continue
            if not number and senses:
                # A `<br><br>` that fell inside a sentence; rejoin it.
                senses[-1] = (senses[-1][0], f"{senses[-1][1]} {text}")
            else:
                senses.append((number, text))

        if senses:
            blocks.append((pos_line, senses))
    return blocks


# ---------------------------------------------------------------------------
# Hand-written (non-शब्दसागर) sections
# ---------------------------------------------------------------------------

DEFINITION_LABEL_RE = re.compile(
    r"^(?:'{2,3})?\s*(?:परिभाषा|अर्थ|मतलब|मानी)\s*(?:'{2,3})?\s*[:：]\s*(.*)$"
)
EXAMPLE_LABEL_RE = re.compile(
    r"^(?:'{2,3})?\s*(?:उदाहरण|प्रयोग|वाक्य\s*प्रयोग)\s*(?:'{2,3})?\s*[:：]"
)
LIST_LINE_RE = re.compile(r"^#+\s*(.*)$")
DEVANAGARI_LETTER_RE = re.compile(r"[ऀ-ॣॲ-ॿ]")


def is_grammar_only(text):
    """True for `पु॰`, `स्त्री॰`, `संज्ञा पुं॰` — a label, never a definition."""
    tokens = [token.strip(ABBREV_STRIP) for token in text.split()]
    tokens = [token for token in tokens if token]
    return bool(tokens) and all(token in POS_TOKENS for token in tokens)


def is_definition_text(text, require_prose=False):
    if not is_substantive(text) or is_grammar_only(text):
        return False
    # `[ सदन निकेतन आलय ]` — a bracketed run is always a synonym list here.
    if text.startswith("[") and text.endswith("]"):
        return False
    if require_prose and len(DEVANAGARI_LETTER_RE.findall(text)) < 4:
        return False
    return True


def parse_modern_block(name, body):
    """(pos_name, [definitions]) for a hand-written part-of-speech section."""
    definitions = []
    # A `;पर्यायवाची` / `;अनुवाद` mini-heading opens a synonym or translation
    # list that runs to the next mini-heading; nothing in it is a definition.
    suppressed = False
    for line in body.split("\n"):
        line = line.strip()
        if not line:
            continue

        if line.startswith(";"):
            labelled = DEFINITION_LABEL_RE.match(line[1:])
            if labelled:
                suppressed = False
                candidate = labelled.group(1)
            else:
                suppressed = True
                continue
        elif EXAMPLE_LABEL_RE.match(line):
            suppressed = True
            continue
        elif DEFINITION_LABEL_RE.match(line):
            suppressed = False
            candidate = DEFINITION_LABEL_RE.match(line).group(1)
        elif suppressed:
            continue
        elif LIST_LINE_RE.match(line):
            candidate = LIST_LINE_RE.match(line).group(1)
        elif line[0] in "*:|!=" or line.startswith("{{") or line.startswith("[["):
            continue
        else:
            # A bare prose line is the weakest signal on the page, so it has to
            # look like a sentence rather than a stray gender marker.
            candidate = line
            text = clean_wikitext(candidate)
            if is_definition_text(text, require_prose=True) and text not in definitions:
                definitions.append(text)
            continue

        text = clean_wikitext(candidate)
        if is_definition_text(text) and text not in definitions:
            definitions.append(text)

    if not definitions:
        return None
    pos = normalise_marker(name) if name else ""
    if pos.lower() in NON_POS_HEADINGS:
        return None
    # A few thousand pages still mark the part of speech with the English
    # `{{-noun-}}` family; a Hindi dictionary should say it in Hindi.
    return POS_DISPLAY.get(pos.lower(), pos), definitions


def is_pos_heading(name):
    if name is None:
        return False
    normalised = normalise_marker(name)
    return (normalised in POS_HEADINGS
            or normalised.lower() in POS_HEADINGS)


def parse_page(title, text):
    """[(pos_line, [(number, definition)])] for the Hindi part of a page."""
    # Image and category links are stripped page-wide rather than per fragment:
    # they routinely wrap across several lines, and the block walk below splits
    # on lines, which would otherwise leave a caption behind as a definition.
    text = COMMENT_RE.sub("", text)
    text = FILE_LINK_RE.sub("", text)

    result = []
    for name, body in hindi_blocks(text):
        normalised = normalise_marker(name) if name else ""
        if normalised in SHABDASAGAR_HEADINGS:
            result.extend(parse_shabdasagar(body, title))
        elif name is None or is_pos_heading(name):
            parsed = parse_modern_block(name, body)
            if parsed:
                pos, definitions = parsed
                result.append((pos, [("", d) for d in definitions]))

    # Two sections can clean down to the same sentence (a hand-written gloss
    # that simply repeats the शब्दसागर one).
    seen, unique = set(), []
    for pos, senses in result:
        deduped = []
        for number, definition in senses:
            key = definition.casefold()
            if key not in seen:
                seen.add(key)
                deduped.append((number, definition))
        if deduped:
            unique.append((pos, deduped))
    return unique


def format_definition(blocks):
    """The exact text the app renders: POS on its own line, senses numbered."""
    chunks = []
    for pos, senses in blocks:
        lines = [pos] if pos else []
        single = len(senses) == 1 and not senses[0][0]
        for index, (number, definition) in enumerate(senses, start=1):
            # Cleaning strips the trailing danda along with stray separators;
            # put the sentence terminator back.
            if not definition.endswith(("।", "॥", "?", "!", "…")):
                definition += "।"
            if single:
                lines.append(definition)
            else:
                lines.append(f"{number or devanagari_number(index)}. {definition}")
        chunks.append("\n".join(lines))
    return "\n\n".join(chunks)


def devanagari_number(value):
    return "".join(DEVANAGARI_DIGITS[int(digit)] for digit in str(value))


# ---------------------------------------------------------------------------
# Dump handling
# ---------------------------------------------------------------------------

# A Hindi headword is written in Devanagari. hi.wiktionary also documents
# Kannada, English, Bengali, ... words under their own scripts; rejecting a
# title that carries letters from another script removes them in one step.
DEVANAGARI_RE = re.compile(r"[ऀ-ॿ]")
OTHER_SCRIPT_RE = re.compile(
    r"[A-Za-zঀ-࿿က-῿Ⰰ-퟿豈-﫿"
    r"Ѐ-ԯ԰-׿؀-ࣿ　-鿿]"
)


def is_hindi_title(title):
    if not DEVANAGARI_RE.search(title):
        return False
    return not OTHER_SCRIPT_RE.search(title)


def ensure_dump(path):
    """Download the dump unless it is already here — it is 55 MB."""
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
    default_dump = os.path.join("build", "dumps",
                                "hiwiktionary-latest-pages-articles.xml.bz2")
    parser.add_argument("--dump", default=default_dump,
                        help="path to the bz2 dump (downloaded if absent)")
    parser.add_argument("--out", default=os.path.join("build", "hi-wiktionary.sqlite"))
    parser.add_argument("--limit", type=int, default=0,
                        help="stop after N pages (for a quick smoke test)")
    parser.add_argument("--gzip", action="store_true",
                        help="also write <out>.gz for shipping")
    args = parser.parse_args()

    dump = ensure_dump(args.dump)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)

    started = time.time()
    scanned = devanagari = empty = 0
    rows = []
    for title, text in iter_pages(dump):
        scanned += 1
        if scanned % 25_000 == 0:
            elapsed = time.time() - started
            print(f"  {scanned:>7} pages, {len(rows):>6} entries, {elapsed:5.0f}s")
        if not is_hindi_title(title):
            continue
        devanagari += 1
        blocks = parse_page(title, text)
        if not blocks:
            empty += 1
            continue
        definition = format_definition(blocks)
        if definition.strip():
            rows.append((title, definition))
        else:
            empty += 1
        if args.limit and scanned >= args.limit:
            break

    rows.sort(key=lambda row: (unicodedata.normalize("NFKD", row[0].casefold()),
                               row[0]))
    print(f"Scanned {scanned} pages; {devanagari} had a Devanagari headword; "
          f"{len(rows)} produced a Hindi entry; {empty} had no usable Hindi "
          f"definition")

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

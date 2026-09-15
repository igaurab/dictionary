#!/usr/bin/env python3
"""Build a MONOLINGUAL French dictionary from the French Wiktionary dump.

fr.wiktionary carries entries for well over a thousand languages, all
*explained in French*. Only the `== {{langue|fr}} ==` section of a page is a
French word defined in French, so everything else is discarded — the result is
the French-speaker's equivalent of the bundled WordNet, not a translation
dictionary.

The output schema is byte-for-byte the one `StarDictImporter` produces, so the
app opens the downloaded file with no new reader code:

    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE entries(id INTEGER PRIMARY KEY, word TEXT NOT NULL,
                         word_lower TEXT NOT NULL, definition TEXT NOT NULL);
    CREATE INDEX idx_entries_lower ON entries(word_lower);

Usage:
  uv run python3 scripts/build_wiktionary_fr.py [--dump PATH] [--out PATH]
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

DUMP_URL = "https://dumps.wikimedia.org/frwiktionary/latest/frwiktionary-latest-pages-articles.xml.bz2"

BOOKNAME = "Wiktionnaire (Français)"
LANGUAGE = "Français"

# ---------------------------------------------------------------------------
# Section / heading recognition
# ---------------------------------------------------------------------------

LANG_FR_HEADING = re.compile(r"^==\s*\{\{\s*langue\s*\|\s*fr\s*\}\}\s*==\s*$", re.M)
LEVEL2_HEADING = re.compile(r"^==(?!=)\s*.+?\s*==\s*$", re.M)
ANY_HEADING = re.compile(r"^(={2,6})\s*(.+?)\s*\1\s*$", re.M)

# `=== {{S|nom|fr}} ===`, `=== {{S|verbe|fr|flexion}} ===`. Every section on a
# page is one of these; only the ones naming a word class are definitions.
S_HEADING = re.compile(r"^\{\{\s*S\s*\|([^{}]*)\}\}$")

# `# définition`, `## sous-sens`. `#*` is an example, `#:` a note — both out.
# `#` must be in the negative lookahead too, or the regex backtracks and reads
# `##* citation` as a top-level sense whose text starts with `#*`.
DEF_LINE = re.compile(r"^(#+)(?![#*:;])\s*(.*)$")

# Word-class names and their abbreviations, from Module:types de mots/data.
POS_NAMES = {
    'adj': 'adjectif',
    'adj-dém': 'adjectif démonstratif',
    'adj-excl': 'adjectif exclamatif',
    'adj-indéf': 'adjectif indéfini',
    'adj-int': 'adjectif interrogatif',
    'adj-num': 'adjectif numéral',
    'adj-pos': 'adjectif possessif',
    'adj-rel': 'adjectif relatif',
    'adjectif': 'adjectif',
    'adjectif dém': 'adjectif démonstratif',
    'adjectif démonstratif': 'adjectif démonstratif',
    'adjectif exc': 'adjectif exclamatif',
    'adjectif exclamatif': 'adjectif exclamatif',
    'adjectif ind': 'adjectif indéfini',
    'adjectif indéfini': 'adjectif indéfini',
    'adjectif int': 'adjectif interrogatif',
    'adjectif interrogatif': 'adjectif interrogatif',
    'adjectif num': 'adjectif numéral',
    'adjectif numéral': 'adjectif numéral',
    'adjectif pos': 'adjectif possessif',
    'adjectif possessif': 'adjectif possessif',
    'adjectif qualificatif': 'adjectif',
    'adjectif rel': 'adjectif relatif',
    'adjectif relatif': 'adjectif relatif',
    'adv': 'adverbe',
    'adv-ind': 'adverbe indéfini',
    'adv-int': 'adverbe interrogatif',
    'adv-pron': 'adverbe pronominal',
    'adv-rel': 'adverbe relatif',
    'adverbe': 'adverbe',
    'adverbe ind': 'adverbe indéfini',
    'adverbe indéfini': 'adverbe indéfini',
    'adverbe int': 'adverbe interrogatif',
    'adverbe interrogatif': 'adverbe interrogatif',
    'adverbe pro': 'adverbe pronominal',
    'adverbe pronominal': 'adverbe pronominal',
    'adverbe rel': 'adverbe relatif',
    'adverbe relatif': 'adverbe relatif',
    'aff': 'affixe',
    'affixe': 'affixe',
    'art': 'article',
    'art-déf': 'article défini',
    'art-indéf': 'article indéfini',
    'art-part': 'article partitif',
    'article': 'article',
    'article déf': 'article défini',
    'article défini': 'article défini',
    'article ind': 'article indéfini',
    'article indéfini': 'article indéfini',
    'article par': 'article partitif',
    'article partitif': 'article partitif',
    'circon': 'circonfixe',
    'circonf': 'circonfixe',
    'circonfixe': 'circonfixe',
    'class': 'classificateur',
    'classif': 'classificateur',
    'classificateur': 'classificateur',
    'conj': 'conjonction',
    'conj-coord': 'conjonction de coordination',
    'conjonction': 'conjonction',
    'conjonction coo': 'conjonction de coordination',
    'conjonction de coordination': 'conjonction de coordination',
    'copule': 'copule',
    'dét': 'déterminant',
    'dét pos': 'déterminant possessif',
    'dét-dem': 'déterminant démonstratif',
    'dét-dém': 'déterminant démonstratif',
    'déterminant': 'déterminant',
    'déterminant dém': 'déterminant démonstratif',
    'déterminant démonstratif': 'déterminant démonstratif',
    'déterminant pos': 'déterminant possessif',
    'déterminant possessif': 'déterminant possessif',
    'encl': 'enclitique',
    'enclitique': 'enclitique',
    'gismu': 'gismu',
    'idéophone': 'idéophone',
    'inf': 'infixe',
    'infixe': 'infixe',
    'interf': 'interfixe',
    'interfixe': 'interfixe',
    'interj': 'interjection',
    'interjection': 'interjection',
    'lettre': 'lettre',
    'loc': 'locution',
    'loc-phr': 'locution-phrase',
    'locution': 'locution',
    'locution phrase': 'locution-phrase',
    'locution-phrase': 'locution-phrase',
    'nom': 'nom commun',
    'nom commun': 'nom commun',
    'nom de famille': 'nom de famille',
    'nom propre': 'nom propre',
    'nom science': 'nom scientifique',
    'nom scient': 'nom scientifique',
    'nom scientifique': 'nom scientifique',
    'nom-fam': 'nom de famille',
    'nom-pr': 'nom propre',
    'nom-sciences': 'nom scientifique',
    'num': 'numéral',
    'numér': 'numéral',
    'numéral': 'numéral',
    'onom': 'onomatopée',
    'onoma': 'onomatopée',
    'onomatopée': 'onomatopée',
    'part': 'particule',
    'part-num': 'particule numérale',
    'particule': 'particule',
    'particule num': 'particule numérale',
    'particule numérale': 'particule numérale',
    'patronyme': 'patronyme',
    'phrase': 'locution-phrase',
    'post': 'postposition',
    'postpos': 'postposition',
    'postposition': 'postposition',
    'procl': 'proclitique',
    'proclitique': 'proclitique',
    'pronom': 'pronom',
    'pronom dém': 'pronom démonstratif',
    'pronom démonstratif': 'pronom démonstratif',
    'pronom ind': 'pronom indéfini',
    'pronom indéfini': 'pronom indéfini',
    'pronom int': 'pronom interrogatif',
    'pronom interrogatif': 'pronom interrogatif',
    'pronom personnel': 'pronom personnel',
    'pronom pos': 'pronom possessif',
    'pronom possessif': 'pronom possessif',
    'pronom rel': 'pronom relatif',
    'pronom relatif': 'pronom relatif',
    'pronom réf': 'pronom personnel',
    'pronom réfléchi': 'pronom personnel',
    'pronom-adjectif': 'pronom-adjectif',
    'pronom-dém': 'pronom démonstratif',
    'pronom-indéf': 'pronom indéfini',
    'pronom-int': 'pronom interrogatif',
    'pronom-per': 'pronom personnel',
    'pronom-pers': 'pronom personnel',
    'pronom-pos': 'pronom possessif',
    'pronom-rel': 'pronom relatif',
    'pronom-réfl': 'pronom personnel',
    'prov': 'proverbe',
    'proverbe': 'proverbe',
    'pré-nom': 'pré-nom',
    'pré-verbe': 'pré-verbe',
    'préf': 'préfixe',
    'préfixe': 'préfixe',
    'prénom': 'prénom',
    'prép': 'préposition',
    'préposition': 'préposition',
    'quantif': 'quantificateur',
    'quantificateur': 'quantificateur',
    'racine': 'racine',
    'rad': 'radical',
    'radical': 'radical',
    'rafsi': 'rafsi',
    'rasm': 'squelette',
    'schème': 'transfixe',
    'sino': 'sinogramme',
    'sinog': 'sinogramme',
    'sinogramme': 'sinogramme',
    'skel': 'squelette',
    'squel': 'squelette',
    'squelette': 'squelette',
    'substantif': 'nom commun',
    'suf': 'suffixe',
    'suff': 'suffixe',
    'suffixe': 'suffixe',
    'symb': 'symbole',
    'symbole': 'symbole',
    'transf': 'transfixe',
    'transfixe': 'transfixe',
    'var-typo': 'variante par contrainte typographique',
    'variante par contrainte typographique': 'variante par contrainte typographique',
    'variante typo': 'variante par contrainte typographique',
    'variante typographique': 'variante par contrainte typographique',
    'verb': 'verbe',
    'verb-pr': 'verbe',
    'verbe': 'verbe',
    'verbe pr': 'verbe',
    'verbe pronominal': 'verbe',
}


# Word classes that a bot generates mechanically from a lemma page. The
# `flexion` marker in the heading is the wiki's own label for them.
FORM_MARKER = "flexion"

# ---------------------------------------------------------------------------
# Wikitext cleaning
# ---------------------------------------------------------------------------

COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
REF_PAIR_RE = re.compile(r"<ref\b[^>]*>.*?</ref>", re.S | re.I)
REF_SELF_RE = re.compile(r"<ref\b[^>]*/\s*>", re.I)
TAG_RE = re.compile(r"</?[a-zA-Z][a-zA-Z0-9]*\b[^>]*/?>")
FILE_LINK_RE = re.compile(
    r"\[\[\s*(?:Fichier|Image|File|Catégorie|Category)\s*:[^\[\]]*"
    r"(?:\[\[[^\[\]]*\]\][^\[\]]*)*\]\]",
    re.I,
)
WIKILINK_RE = re.compile(r"\[\[([^\[\]]*)\]\]")
EXTLINK_RE = re.compile(r"\[(?:https?:|//)\S+?(?:\s+([^\]]*))?\]")
INNER_TEMPLATE_RE = re.compile(r"\{\{([^{}]*)\}\}")
QUOTES_RE = re.compile(r"'{2,5}")
LOOSE_MARKUP_RE = re.compile(r"\{\{|\}\}|\[\[|\]\]")
WS_RE = re.compile(r"[ \t ]+")

# A run of templates opening a definition is its usage/domain marker; the same
# template further along the line is ordinary inline text and stays put.
LEADING_MARKERS = re.compile(
    r"^\s*(?:\{\{[^{}]*(?:\{\{[^{}]*\}\}[^{}]*)*\}\}[\s,]*)+"
)

LANG_CODE_RE = re.compile(r"[a-z]{2,3}(?:-[a-zA-Z0-9-]+)?")

# Templates that render as prose but are *not* usage markers, plus the
# reference / maintenance / typographic ones that render as nothing useful.
DROP_TEMPLATE_NAMES = {
    "réf", "réf?", "référence nécessaire", "réf nécessaire", "r", "rp",
    "source", "sources", "exemple", "ébauche-déf", "ébauche-exe",
    "ébauche-étym", "ébauche-pron", "ébauche-trad", "ébauche",
    "pron", "phon", "pron-recons", "prononciation", "écouter", "audio",
    "couleur", "colore", "clé de tri", "clé", "wikipédia", "wikispecies",
    "wikisource", "wikiquote", "commons", "voir", "voir aussi", "vers",
    "import:cfc", "import:daf8", "import:cfc/1", "cfc", "daf8",
    "lien web", "ouvrage", "article", "périodique", "citation", "ws",
    "date", "siècle", "recons", "étyl", "polytonique", "nobr", "smcp",
    "term-cat", "graphie", "gr", "petites capitales", "nom w pc",
    "modèle inexistant", "attention", "note-fr-féminin", "cit_ref",
}

# Templates that spell out a relation to another word; rendering them as prose
# keeps thousands of one-line entries readable instead of blank.
RELATION_TEMPLATES = {
    "variante de": "Variante de",
    "variante orthographique de": "Variante orthographique de",
    "variante ortho de": "Variante orthographique de",
    "var-ortho-de": "Variante orthographique de",
    "ancienne orthographe de": "Ancienne orthographe de",
    "orthographe rectifiée de": "Orthographe rectifiée de",
    "graphie ancienne de": "Graphie ancienne de",
    "abréviation de": "Abréviation de",
    "diminutif de": "Diminutif de",
    "augmentatif de": "Augmentatif de",
    "féminin de": "Féminin de",
    "masculin de": "Masculin de",
    "pluriel de": "Pluriel de",
    "singulier de": "Singulier de",
    "surnom de": "Surnom de",
    "nom de famille de": "Nom de famille de",
    "apocope de": "Apocope de",
    "aphérèse de": "Aphérèse de",
    "syncope de": "Syncope de",
    "contraction de": "Contraction de",
    "acronyme de": "Acronyme de",
    "sigle de": "Sigle de",
    "verlan de": "Verlan de",
    "erreur pour": "Erreur pour",
    "faute de": "Faute d’orthographe de",
    "désuet de": "Forme désuète de",
}

# Thematic shortcuts that stand for a different domain label than their name.
LABEL_ALIASES = {
    "plantes": "botanique",
    "arbres": "botanique",
    "fruits": "botanique",
    "fleurs": "botanique",
    "champignons": "mycologie",
    "oiseaux": "ornithologie",
    "poissons": "ichtyologie",
    "insectes": "entomologie",
    "papillons": "lépidoptérologie",
    "mammifères": "zoologie",
    "reptiles": "herpétologie",
    "amphibiens": "herpétologie",
    "mollusques": "malacologie",
    "crustacés": "carcinologie",
    "animaux": "zoologie",
    "minéraux": "minéralogie",
    "maladies": "médecine",
    "anatomie animale": "anatomie",
}

# Named parameters a marker template may carry without ceasing to be a marker.
MARKER_NAMED_OK = {
    "lang", "nocat", "clé", "clé2", "clé3", "clé4", "clé5", "spéc", "cat",
    "cat2", "cat3", "cat4", "cat5", "catfin", "ancre", "id", "sous-cat",
    "libellé", "tri", "m", "num", "dif", "sens", "genre",
}

ROMAN_RE = re.compile(r"^[IVXLCDM]+$")


def _split_template(body):
    """Split a template body into (name, positional args, named args)."""
    parts = body.split("|")
    name = parts[0].strip().lower().lstrip(":")
    positional, named = [], {}
    for part in parts[1:]:
        key, sep, value = part.partition("=")
        if sep and re.fullmatch(r"[^\W\d_][\w .'’-]*", key.strip(), re.U):
            named[key.strip().lower()] = value.strip()
        else:
            positional.append(part.strip())
    return name, positional, named


def _capitalize(text):
    """Upper-case the first letter only — what {{term}} and {{lexique}} do."""
    for index, char in enumerate(text):
        if char.isalpha():
            return text[:index] + char.upper() + text[index + 1:]
    return text


def _drop_lang_codes(positional):
    """Everything but the trailing language code(s) of a marker template."""
    kept = [p for p in positional if p and not LANG_CODE_RE.fullmatch(p)]
    return kept


def _is_marker(name, positional, named):
    """Whether an unrecognised template is one of the usage/domain markers.

    Wiktionnaire has several hundred of them (`{{figuré|fr}}`, `{{Québec|fr}}`,
    `{{par extension|fr}}`, …), all rendered as an italic parenthetical. They
    share a shape: a wordy name and no arguments beyond a language code.
    """
    if len(name) < 3 or any(char.isdigit() for char in name):
        return False
    if not re.fullmatch(r"[^\W\d_][\w '’.-]*", name, re.U):
        return False
    if any(key not in MARKER_NAMED_OK for key in named):
        return False
    return all(LANG_CODE_RE.fullmatch(p) for p in positional if p)


def render_template(body, title, labels):
    """Render one innermost template to plain text.

    Templates the wiki renders as prose are expanded by hand; anything else is
    dropped, because a raw `{{…}}` in the middle of a definition is worse than
    a small gap. `labels` collects the usage/domain markers so the caller can
    show them as a parenthetical prefix; with `labels=None` a marker renders in
    place instead.
    """
    name, positional, named = _split_template(body)
    if not name:
        return ""

    if name in ("lien", "l", "lien-ancre-étym", "lnom", "lgt"):
        text = named.get("dif") or named.get("sens") or ""
        if not text:
            text = positional[0] if positional else ""
        return text

    if name in ("w", "wd", "wsp", "wikipedia"):
        target = named.get("dif") or (positional[0] if positional else "")
        if len(positional) > 1 and not LANG_CODE_RE.fullmatch(positional[1]):
            target = positional[1]
        return target.split(":")[-1].split("#")[0]

    if name in ("cf", "voir-conj", "vers-conj"):
        words = [p for p in positional if p]
        return "→ voir " + ", ".join(words) if words else ""

    if name in ("e", "er", "ère", "re", "es", "ers", "èmes", "ème"):
        return positional[0] if positional else \
            {"er": "er", "ère": "ère", "re": "re"}.get(name, "e")

    if name in ("1er", "1re", "1ère", "2e", "3e", "4e"):
        return name

    if name in ("siècle2", "siecle2"):
        number = positional[0] if positional else ""
        return f"{number}e" if number else ""

    if name.startswith(("formatnum:", "#expr:", "unité:")):
        return body.split(":", 1)[1].strip()

    if name in ("nombre", "unité", "unite"):
        return " ".join(p for p in positional if p)

    if name == "fchim":
        return "".join(p for p in positional if p)

    if name in ("note", "usage", "note-usage"):
        return "Note :"

    if name in ("équiv-pour", "equiv-pour"):
        if len(positional) > 1:
            return f"(pour {positional[0]}, on dit : {positional[1]})"
        return ""

    if name in RELATION_TEMPLATES:
        target = named.get("dif") or (positional[0] if positional else "")
        return f"{RELATION_TEMPLATES[name]} {target}" if target else ""

    if name in ("lexique", "info lex", "term", "term-cat"):
        if name == "term":
            words = [named.get("libellé") or (positional[0] if positional else "")]
        else:
            words = _drop_lang_codes(positional)
        words = [w for w in words if w]
        if not words:
            return ""
        text = ", ".join(_capitalize(w) for w in words)
        if labels is None:
            return f"({text})"
        labels.append(text)
        return ""

    if name in DROP_TEMPLATE_NAMES:
        return ""

    if _is_marker(name, positional, named):
        text = _capitalize(LABEL_ALIASES.get(name) or name)
        if labels is None:
            return f"({text})"
        labels.append(text)
        return ""

    return ""


def clean_wikitext(text, title, labels=None):
    """Turn a fragment of wikitext into readable plain prose.

    Pass a list as `labels` to hoist marker templates out of the text; with
    `labels=None` they render where they stand.
    """
    text = COMMENT_RE.sub("", text)
    text = REF_PAIR_RE.sub("", text)
    text = REF_SELF_RE.sub("", text)
    text = FILE_LINK_RE.sub("", text)

    # Links first: resolving them before templates keeps a `[[a|b]]` pipe from
    # being mistaken for a template argument separator.
    def link(match):
        inner = match.group(1)
        target, _, shown = inner.partition("|")
        if shown:
            return shown
        # `[[ménage#fr]]` — the anchor is a language marker, not part of the
        # word; `[[w:Gif animé]]` has no display text either.
        target = target.split("#")[0]
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
    text = re.sub(r"\s+([,;.!?])", r"\1", text)
    text = re.sub(r"\(\s*\)", "", text)
    # A dropped template between two sentences leaves `. .` behind.
    text = re.sub(r"(?<!\.)\.\s*\.(?!\.)", ".", text)
    text = re.sub(r"\s{2,}", " ", text)
    return text.strip(" \t.,;:·—–-").strip()


# ---------------------------------------------------------------------------
# Page parsing
# ---------------------------------------------------------------------------


def french_section(text):
    """The `{{langue|fr}}` section body, or None."""
    match = LANG_FR_HEADING.search(text)
    if not match:
        return None
    start = match.end()
    following = LEVEL2_HEADING.search(text, start)
    return text[start:following.start()] if following else text[start:]


def heading_pos_name(heading):
    """(display name, is_inflected_form) for a POS heading, else None."""
    match = S_HEADING.fullmatch(heading.strip())
    if not match:
        return None
    parts = [p.strip() for p in match.group(1).split("|")]
    kind = parts[0].lower()
    display = POS_NAMES.get(kind)
    if display is None:
        return None
    rest = [p for p in parts[1:] if p and "=" not in p]
    # A `{{S|nom|en}}` box inside the French section means the page is
    # mis-tagged; ignore it rather than importing another language.
    if not rest or rest[0] != "fr":
        return None
    is_form = FORM_MARKER in rest[1:]
    if is_form:
        display += " (flexion)"
    return display, is_form


def parse_page(title, text, keep_forms=True):
    """([(pos_name, [(number, definition)])], saw_form) for the French section."""
    section = french_section(text)
    if section is None:
        return [], False

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
        senses = []
        top = 0
        for line in body.split("\n"):
            line = line.strip()
            if not line.startswith("#"):
                continue
            match = DEF_LINE.match(line)
            if not match:
                continue
            depth = len(match.group(1))
            source = match.group(2)
            labels = []
            marker = LEADING_MARKERS.match(source)
            head = ""
            if marker:
                # Most opening templates are markers and render as nothing; one
                # that does render (`{{variante de|…}}`) *is* the definition, so
                # keep whatever text comes back.
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
            if depth <= 1 or not senses:
                top += 1
                senses.append((str(top), definition))
            else:
                # `##` is a sub-sense of the `#` above it.
                sub = sum(1 for number, _ in senses
                          if number.startswith(f"{top}.")) + 1
                senses.append((f"{top}.{sub}", definition))
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
    """Download the dump unless it is already here — it is 840 MB."""
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
            # this the whole 9 GB of decompressed XML accumulates in memory.
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
        "source": "frwiktionary",
        "description": "Dictionnaire monolingue du français, extrait du "
                       "Wiktionnaire francophone.",
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
                                "frwiktionary-latest-pages-articles.xml.bz2")
    parser.add_argument("--dump", default=default_dump,
                        help="path to the bz2 dump (downloaded if absent)")
    parser.add_argument("--out", default=os.path.join("build", "fr-wiktionary.sqlite"))
    parser.add_argument("--limit", type=int, default=0,
                        help="stop after N pages (for a quick smoke test)")
    parser.add_argument("--gzip", action="store_true",
                        help="also write <out>.gz for shipping")
    parser.add_argument("--no-forms", action="store_true",
                        help="drop bot-generated inflected-form entries "
                             "({{S|…|fr|flexion}}) to shrink the file")
    args = parser.parse_args()

    dump = ensure_dump(args.dump)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)

    started = time.time()
    scanned = french = forms = 0
    rows = []
    for title, text in iter_pages(dump):
        scanned += 1
        if scanned % 100_000 == 0:
            elapsed = time.time() - started
            print(f"  {scanned:>7} pages, {len(rows):>7} entries, {elapsed:5.0f}s",
                  flush=True)
        if "langue|fr}}" not in text:
            continue
        blocks, saw_form = parse_page(title, text, keep_forms=not args.no_forms)
        if saw_form:
            forms += 1
        if not blocks:
            continue
        french += 1
        definition = format_definition(blocks)
        if definition.strip():
            rows.append((title, definition))
        if args.limit and scanned >= args.limit:
            break

    rows.sort(key=lambda row: (unicodedata.normalize("NFKD", row[0].lower()),
                               0 if row[0].islower() else 1, row[0]))
    print(f"Scanned {scanned} pages; {french} had a French section with senses "
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

#!/usr/bin/env python3
"""Build a MONOLINGUAL Spanish dictionary from the Spanish Wiktionary dump.

es.wiktionary carries entries for hundreds of languages, all *explained in
Spanish*. Only the `== {{lengua|es}} ==` section of a page is a Spanish word
defined in Spanish, so everything else is discarded — the result is the
Spanish-speaker's equivalent of the bundled WordNet, not a translation
dictionary.

The output schema is byte-for-byte the one `StarDictImporter` produces, so the
app opens the downloaded file with no new reader code:

    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE entries(id INTEGER PRIMARY KEY, word TEXT NOT NULL,
                         word_lower TEXT NOT NULL, definition TEXT NOT NULL);
    CREATE INDEX idx_entries_lower ON entries(word_lower);

Usage:
  uv run python3 scripts/build_wiktionary_es.py [--dump PATH] [--out PATH]
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

DUMP_URL = "https://dumps.wikimedia.org/eswiktionary/latest/eswiktionary-latest-pages-articles.xml.bz2"

BOOKNAME = "Wikcionario (Español)"
LANGUAGE = "Español"

# ---------------------------------------------------------------------------
# Section / heading recognition
# ---------------------------------------------------------------------------

# `== {{lengua|es}} ==`, tolerating missing spaces. The older `{{ES}}` marker is
# still on a long tail of untouched pages.
LANG_ES_HEADING = re.compile(
    r"^==\s*\{\{\s*(?:lengua\s*\|\s*es|ES)\s*(?:\|[^}]*)?\}\}\s*==\s*$", re.M
)
LEVEL2_HEADING = re.compile(r"^==(?!=)\s*.+?\s*==\s*$", re.M)
ANY_HEADING = re.compile(r"^(={2,6})\s*(.+?)\s*\1\s*$", re.M)

# A sense: `;1: definición`, `;1 {{csem|países}}: definición`, `;2a: ...`
SENSE_LINE = re.compile(r"^;\s*([0-9]+[a-zé]?)\s*(.*?):\s*(.*)$")

# Heading templates that name a part of speech. The first positional parameter
# is the language code, the rest are qualifiers (`{{sustantivo|es|propio}}`).
POS_TEMPLATE_ROOTS = (
    "sustantivo", "verbo", "adjetivo", "adverbio", "pronombre", "preposición",
    "conjunción", "interjección", "artículo", "determinante", "locución",
    "expresión", "onomatopeya", "prefijo", "sufijo", "infijo", "interfijo",
    "afijo", "partícula", "numeral", "cardinal", "ordinal", "sigla", "acrónimo",
    "abreviatura", "símbolo", "letra", "carácter", "refrán", "modismo", "forma",
    "contracción", "postposición", "clasificador", "cuantificador", "apellido",
    "nombre", "antropónimo", "topónimo", "gentilicio",
)

# Old-style plain-text POS headings, still common on unconverted pages.
PLAIN_POS_HEADING = re.compile(
    r"^(?:" + "|".join(POS_TEMPLATE_ROOTS) + r")\b", re.I
)

# Headings that are never definitions, even though they can start with a word
# in the list above (`Formas alternativas`, `Locuciones`, ...).
NON_POS_HEADINGS = {
    "locuciones", "expresiones", "refranes", "modismos", "formas alternativas",
    "formas y grafías alternativas", "forma alternativa", "conjugación",
    "declinación", "etimología", "traducciones", "véase también", "referencias",
    "referencias y notas", "información adicional", "compuestos", "derivados",
    "descendientes", "sinónimos", "antónimos", "hiperónimos", "hipónimos",
    "merónimos", "holónimos", "cognados", "pronunciación", "notas",
    "nombres propios", "apellidos", "topónimos", "gentilicios",
}

# ---------------------------------------------------------------------------
# Wikitext cleaning
# ---------------------------------------------------------------------------

COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
REF_PAIR_RE = re.compile(r"<ref\b[^>]*>.*?</ref>", re.S | re.I)
REF_SELF_RE = re.compile(r"<ref\b[^>]*/\s*>", re.I)
# `agua<sub>1</sub>` is a cross-reference to sense 1, not a chemical formula;
# in plain text the digit reads as a typo, so a bare numeric subscript goes.
SENSE_SUBSCRIPT_RE = re.compile(r"<sub>\s*\d+\s*</sub>", re.I)
TAG_RE = re.compile(r"</?[a-zA-Z][a-zA-Z0-9]*\b[^>]*/?>")
FILE_LINK_RE = re.compile(
    r"\[\[\s*(?:Archivo|Imagen|Image|File|Categoría|Category)\s*:[^\[\]]*"
    r"(?:\[\[[^\[\]]*\]\][^\[\]]*)*\]\]",
    re.I,
)
WIKILINK_RE = re.compile(r"\[\[([^\[\]]*)\]\]")
EXTLINK_RE = re.compile(r"\[(?:https?:|//)\S+?(?:\s+([^\]]*))?\]")
INNER_TEMPLATE_RE = re.compile(r"\{\{([^{}]*)\}\}")
QUOTES_RE = re.compile(r"'{2,5}")
WS_RE = re.compile(r"[ \t ]+")

# Reference/maintenance templates: they render as a footnote marker at most.
DROP_TEMPLATE_PREFIXES = (
    "drae", "dle", "dlc", "drag", "dpd", "dme", "ddgm", "dcech", "dcvb",
    "damer", "labernia", "aulete", "unam", "lunfa", "moliner", "clave",
    "vox", "larousse", "wikipedia", "wikcionario", "commons", "wikisource",
    "wikiquote", "wikinoticias", "wikiviajes", "wikispecies", "trad",
)
DROP_TEMPLATE_NAMES = {
    "cita requerida", "definición imprecisa", "referencia", "referencias",
    "referencia incompleta", "mostrar-han", "mostrar", "pron-graf",
    "etimología", "etimología2", "etim", "clear", "column", "columna",
    "desambiguación", "inflect.es.sust.reg", "sinónimo", "antónimo",
    "hiperónimo", "hipónimo", "relacionado", "ejemplo", "uso", "anotación",
}


def _capitalize(text):
    """Upper-case the first letter only — what {{plm}}/{{ucf}} do."""
    for index, char in enumerate(text):
        if char.isalpha():
            return text[:index] + char.upper() + text[index + 1:]
    return text


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


def _strip_lang_code(positional):
    """Drop a leading positional language code.

    Only the `{{l|es|casa}}` family and the POS headings put the language code
    in a positional slot; every other template names it `leng=`. Stripping it
    unconditionally would eat the lemma of `{{f.v|dar|1s|pres|ind}}`.
    """
    if positional and re.fullmatch(r"[a-z]{2,3}(?:-[a-z0-9-]+)?", positional[0]):
        return positional[1:]
    return positional


# `{{f.v|dar|1s|pres|ind}}` and its named-parameter spelling `p=1s|t=pres|m=ind`.
VERB_PERSON = {
    "1s": "Primera persona del singular",
    "2s": "Segunda persona del singular",
    "3s": "Tercera persona del singular",
    "1p": "Primera persona del plural",
    "2p": "Segunda persona del plural",
    "3p": "Tercera persona del plural",
    "yo": "Primera persona del singular",
    "tú": "Segunda persona del singular",
    "tu": "Segunda persona del singular",
    "vos": "Segunda persona del singular (voseo)",
    "2sv": "Segunda persona del singular (voseo)",
    "2stv": "Segunda persona del singular (tú/vos)",
    "2su": "Segunda persona del singular (usted)",
    "2pu": "Segunda persona del plural (ustedes)",
    "él": "Tercera persona del singular",
    "usted": "Tercera persona del singular (usted)",
    "nosotros": "Primera persona del plural",
    "vosotros": "Segunda persona del plural",
    "ellos": "Tercera persona del plural",
    "ustedes": "Tercera persona del plural (ustedes)",
}
VERB_TENSE = {
    "pres": "presente", "presente": "presente",
    "pret": "pretérito", "pretérito": "pretérito", "preterito": "pretérito",
    "perf": "pretérito perfecto simple",
    "indefinido": "pretérito indefinido",
    "imperf": "pretérito imperfecto", "imperfecto": "pretérito imperfecto",
    "copret": "copretérito", "copretérito": "copretérito",
    "pospret": "pospretérito", "pospretérito": "pospretérito",
    "fut": "futuro", "futuro": "futuro",
    "cond": "condicional", "condicional": "condicional",
    # How the conjugation bot spells the two simple past tenses.
    "pret ind": "pretérito indefinido",
    "pret imp": "pretérito imperfecto",
    "pretérito indefinido": "pretérito indefinido",
    "imperativo": "imperativo", "imper": "imperativo", "imp": "imperativo",
    "infinitivo": "infinitivo", "gerundio": "gerundio",
    "participio": "participio",
}
VERB_MOOD = {
    "ind": "indicativo", "indicativo": "indicativo",
    "sub": "subjuntivo", "subj": "subjuntivo", "subjuntivo": "subjuntivo",
    "imp": "imperativo", "imperativo": "imperativo",
}


def _conjugation(lemma, positional, named):
    """A readable gloss for a verb form, e.g. `{{f.v|dar|1s|pres|ind}}`."""
    person = named.get("p", "")
    tense = named.get("t", "")
    mood = named.get("m", "")
    for arg in positional:
        key = arg.strip().lower()
        if not person and key in VERB_PERSON:
            person = key
        elif not tense and key in VERB_TENSE:
            tense = key
        elif not mood and key in VERB_MOOD:
            mood = key

    tense_text = VERB_TENSE.get(tense.lower(), tense) if tense else ""
    mood_text = VERB_MOOD.get(mood.lower(), mood) if mood else ""
    # `t=imperativo|m=imperativo` is common; say it once.
    if mood_text and mood_text == tense_text:
        mood_text = ""

    parts = []
    if person:
        parts.append(VERB_PERSON.get(person.lower(), ""))
    if tense_text:
        parts.append(("del " if parts else "") + tense_text)
    if mood_text:
        parts.append("de " + mood_text)
    head = " ".join(p for p in parts if p)
    head = _capitalize(head)
    if not head:
        return f"Forma conjugada de {lemma}"
    return f"{head} de {lemma}"


def render_template(body, title, labels):
    """Render one innermost template to plain text.

    Templates the wiki renders as prose are expanded by hand; anything else is
    dropped, because a raw `{{...}}` in the middle of a definition is worse
    than a small gap. `labels` collects usage/domain markers so the caller can
    show them as a parenthetical prefix.
    """
    name, positional, named = _split_template(body)
    if not name:
        return ""

    if name in ("plm", "ucf", "plm2"):
        return _capitalize(positional[0]) if positional and positional[0] \
            else _capitalize(title)

    if name in ("l", "l+", "e", "enlace", "link"):
        args = _strip_lang_code(positional)
        text = named.get("alt") or named.get("texto") or (args[0] if args else "")
        # `{{l|es|casa|casas}}` — second positional is the display text.
        if len(args) > 1 and not named.get("alt") and not args[1].isdigit():
            text = args[1]
        return text

    if name in ("csem", "ámbito", "ambito", "uso", "jerga", "registro",
                "campo semántico"):
        for arg in _strip_lang_code(positional):
            if arg and not arg.isdigit():
                labels.append(arg)
        return ""

    if name in ("-sub", "subíndice", "subindice"):
        # Always a sense cross-reference in this wiki ("agua{{-sub|1}}"), and a
        # bare digit glued to the word reads as a typo in plain text.
        return ""

    if name in ("-sup", "superíndice", "superindice"):
        return positional[0] if positional else ""

    if name in ("impropia", "impropio", "no flexión", "definición impropia"):
        return positional[0] if positional else ""

    if name in ("gentilicio", "gentilicio1", "gentilicio2", "gentilicio3"):
        place = positional[0] if positional else title
        if name in ("gentilicio", "gentilicio1"):
            return f"Originario, relativo a, o propio de {place}"
        return f"Persona originaria de {place}"

    if name in ("variante", "variante anticuada", "variante obsoleta",
                "grafía", "grafia", "grafía obsoleta", "grafía alternativa",
                "grafía rara", "grafía informal"):
        target = positional[0] if positional else title
        word = {
            "variante": "Variante de",
            "variante anticuada": "Variante anticuada de",
            "variante obsoleta": "Variante obsoleta de",
            "grafía": "Grafía alternativa de",
            "grafia": "Grafía alternativa de",
            "grafía obsoleta": "Grafía obsoleta de",
            "grafía alternativa": "Grafía alternativa de",
            "grafía rara": "Grafía poco usada de",
            "grafía informal": "Grafía informal de",
        }[name]
        return f"{word} {target}"

    if name in ("participio", "participio activo", "participio pasivo"):
        return f"Participio de {positional[0]}" if positional else ""

    if name == "sustantivo de verbo":
        return f"Acción o efecto de {positional[0]}" if positional else ""

    if name in ("adjetivo de sustantivo", "adjetivo de padecimiento"):
        return f"Perteneciente o relativo a {positional[0]}" if positional else ""

    if name == "sustantivo de adjetivo":
        return f"Cualidad de {positional[0]}" if positional else ""

    if name in ("forma verbo", "f.v"):
        lemma = named.get("v") or (positional[0] if positional else "")
        return _conjugation(lemma, positional[1:], named) if lemma else ""

    if name in ("forma participio", "forma gerundio"):
        return f"Forma de {positional[0]}" if positional else ""

    if name.startswith("forma ") or name in ("f.adj", "f.adj2", "f.sust", "f.s"):
        lemma = positional[0] if positional else ""
        kind = name[len("forma "):].strip() if name.startswith("forma ") else ""
        if not lemma:
            return ""
        if kind.startswith("sustantivo"):
            return f"Forma del sustantivo {lemma}"
        if kind.startswith("adjetivo"):
            return f"Forma del adjetivo {lemma}"
        if kind.startswith("pronombre"):
            return f"Forma del pronombre {lemma}"
        return f"Forma de {lemma}"

    if name in ("antropónimo femenino", "nombre propio femenino"):
        extra = f", equivalente a {positional[0]}" if positional else ""
        return f"Nombre propio de mujer{extra}"

    if name in ("antropónimo masculino", "nombre propio masculino"):
        extra = f", equivalente a {positional[0]}" if positional else ""
        return f"Nombre propio de hombre{extra}"

    if name == "apellido":
        return "Apellido"

    if name in ("marca", "marca registrada"):
        return "Marca registrada"

    if name in DROP_TEMPLATE_NAMES or name.startswith(DROP_TEMPLATE_PREFIXES):
        return ""

    # `{{es.sust}}`, `{{inflect.*}}` and friends are inflection boxes.
    if "." in name or name.startswith(("t+", "t-", "trad")):
        return ""

    return ""


def clean_wikitext(text, title, labels=None):
    """Turn a fragment of wikitext into readable plain prose."""
    if labels is None:
        labels = []

    text = COMMENT_RE.sub("", text)
    text = REF_PAIR_RE.sub("", text)
    text = REF_SELF_RE.sub("", text)
    text = SENSE_SUBSCRIPT_RE.sub("", text)
    text = FILE_LINK_RE.sub("", text)

    # Links first: resolving them before templates keeps a `[[a|b]]` pipe from
    # being mistaken for a template argument separator.
    def link(match):
        inner = match.group(1)
        target, _, shown = inner.partition("|")
        if shown:
            return shown
        # `[[Wikipedia:es:Mar del Japón]]` has no display text; use the tail.
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

    text = WS_RE.sub(" ", text)
    text = re.sub(r"\s+([,;.:!?])", r"\1", text)
    text = re.sub(r"\(\s*\)", "", text)
    text = re.sub(r"\s{2,}", " ", text)
    return text.strip(" \t.,;:·—–-").strip()


# ---------------------------------------------------------------------------
# Page parsing
# ---------------------------------------------------------------------------


def spanish_section(text):
    """The `{{lengua|es}}` section body, or None."""
    match = LANG_ES_HEADING.search(text)
    if not match:
        return None
    start = match.end()
    following = LEVEL2_HEADING.search(text, start)
    return text[start:following.start()] if following else text[start:]


def heading_pos_name(heading):
    """The display name for a POS heading, or None if it is not one."""
    heading = heading.strip()

    template = re.fullmatch(r"\{\{\s*([^{}]*)\}\}", heading)
    if template:
        name, positional, named = _split_template(template.group(1))
        lang = named.get("leng") or (positional[0] if positional else "")
        # Inside the Spanish section a stray non-es POS box means the page is
        # mis-tagged; ignore it rather than importing another language.
        if lang and lang != "es":
            return None
        if not name.startswith(POS_TEMPLATE_ROOTS):
            return None
        extras = [p for p in _strip_lang_code(positional)
                  if p and not p.isdigit()]
        return " ".join([name] + extras)

    plain = heading.lower().strip()
    if plain in NON_POS_HEADINGS:
        return None
    if re.match(r"^etimología\b|^pronunciación\b", plain):
        return None
    if PLAIN_POS_HEADING.match(plain):
        return heading[0].lower() + heading[1:]
    return None


def parse_page(title, text):
    """[(pos_name, [(sense_number, definition)])] for the Spanish section."""
    section = spanish_section(text)
    if section is None:
        return []

    # Flat walk over every sub-heading: POS boxes sit at level 3 under a plain
    # page and at level 4 under `=== Etimología 1 ===`, so depth is unreliable.
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
    for pos, body in blocks:
        senses = []
        for line in body.split("\n"):
            line = line.strip()
            if not line.startswith(";"):
                continue
            match = SENSE_LINE.match(line)
            if match:
                number, label_src, definition_src = match.groups()
            else:
                number, label_src, definition_src = "", "", line[1:]

            labels = []
            clean_wikitext(label_src, title, labels)
            definition = clean_wikitext(definition_src, title, labels)
            if not definition:
                continue
            if labels:
                seen, unique = set(), []
                for item in labels:
                    key = item.lower()
                    if key not in seen:
                        seen.add(key)
                        unique.append(item)
                definition = f"({', '.join(unique)}) {definition}"
            if not definition.endswith((".", "!", "?", "…")):
                definition += "."
            senses.append((number, definition))
        # Distinct wikitext can clean down to the same sentence (two verb forms
        # that differ only in a parameter we do not render).
        seen_defs, unique_senses = set(), []
        for number, definition in senses:
            if definition.lower() not in seen_defs:
                seen_defs.add(definition.lower())
                unique_senses.append((number, definition))
        senses = unique_senses
        if senses:
            result.append((pos, senses))
    return result


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
    """Download the dump unless it is already here — it is 84 MB."""
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
            # this the whole 1 GB of decompressed XML accumulates in memory.
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
        "source": "eswiktionary",
        "description": "Diccionario monolingüe del español, extraído del "
                       "Wikcionario en español.",
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
                                "eswiktionary-latest-pages-articles.xml.bz2")
    parser.add_argument("--dump", default=default_dump,
                        help="path to the bz2 dump (downloaded if absent)")
    parser.add_argument("--out", default=os.path.join("build", "es-wiktionary.sqlite"))
    parser.add_argument("--limit", type=int, default=0,
                        help="stop after N pages (for a quick smoke test)")
    parser.add_argument("--gzip", action="store_true",
                        help="also write <out>.gz for shipping")
    args = parser.parse_args()

    dump = ensure_dump(args.dump)
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)

    started = time.time()
    scanned = spanish = 0
    rows = []
    for title, text in iter_pages(dump):
        scanned += 1
        if scanned % 50_000 == 0:
            elapsed = time.time() - started
            print(f"  {scanned:>7} pages, {len(rows):>6} entries, {elapsed:5.0f}s")
        if "lengua|es" not in text and "{{ES" not in text:
            continue
        blocks = parse_page(title, text)
        if not blocks:
            continue
        spanish += 1
        definition = format_definition(blocks)
        if definition.strip():
            rows.append((title, definition))
        if args.limit and scanned >= args.limit:
            break

    rows.sort(key=lambda row: (unicodedata.normalize("NFKD", row[0].lower()),
                               0 if row[0].islower() else 1, row[0]))
    print(f"Scanned {scanned} pages; {spanish} had a Spanish section with senses")

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

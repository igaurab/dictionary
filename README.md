# Dictionary for iOS

A native SwiftUI dictionary app for iPhone and iPad, designed to feel like a
mobile version of the Dictionary app that ships with macOS — and it works
**completely offline**. No network access, no accounts, no tracking: the entire
dictionary ships inside the app bundle.

## Data sources

- **WordNet 3.1** (Princeton University) — the most widely used open English
  lexical database, mirrored on GitHub via
  [nltk/nltk_data](https://github.com/nltk/nltk_data). Provides definitions,
  usage examples, parts of speech, synonyms, and antonyms for **147,478 words
  / 207,235 senses**.
- **CMU Pronouncing Dictionary**
  ([cmusphinx/cmudict](https://github.com/cmusphinx/cmudict)) — pronunciations
  for 126,000+ words, converted from ARPABET to IPA at build time.

Both are compiled into a single 38 MB SQLite database
(`Dictionary/Resources/WordNet.sqlite`) that ships in the app bundle, so every
feature works in airplane mode.

## Features (matching the macOS Dictionary app)

- **Live search sidebar** — results appear as you type, prefix matches first,
  then substring matches, just like the macOS results list.
- **Apple-style entries** — large serif headword, IPA pronunciation between
  vertical bars (`| ˈæpəl |`), italic part-of-speech labels, numbered senses,
  and italic usage examples introduced with a colon.
- **All / Dictionary / Thesaurus source bar** — the segmented source switcher
  from the top of macOS entries. The Thesaurus view shows synonyms and
  antonyms grouped by sense.
- **Tap any word to look it up** — every word inside a definition, example,
  or synonym list is tappable, mirroring double-click-to-look-up on macOS.
- **Back / Forward navigation** — the Go ▸ Back / Forward history controls,
  as chevrons in the entry toolbar.
- **Smart lookup fallbacks** — irregular forms redirect to their base word
  ("went" → *go*, "children" → *child*), regular inflections are stemmed
  ("running" → *run*), and misspellings get "did you mean" suggestions.
- **Recent searches** — a persistent history list with swipe-to-delete.
- **Text size control** — the equivalent of ⌘+/⌘− zoom on macOS.
- **Random word** — for browsing and discovery.
- **iPad support** — a two-column split view that mirrors the macOS
  sidebar-plus-entry layout; on iPhone it collapses to a stack.

> The macOS app's Wikipedia source is intentionally omitted: it requires an
> internet connection, and this app is fully offline by design.

## Building

1. Open `Dictionary.xcodeproj` in Xcode 16 or later.
2. Select the `Dictionary` scheme and an iOS 17+ simulator or device.
3. Build and run. No dependencies, no packages — just SwiftUI and the
   system SQLite3 library.

## Regenerating the database

The bundled database is reproducible from public sources:

```sh
# WordNet 3.1 (NLTK mirror) and CMUdict
curl -L -o wordnet31.zip https://raw.githubusercontent.com/nltk/nltk_data/gh-pages/packages/corpora/wordnet31.zip
unzip wordnet31.zip
curl -L -o cmudict.dict https://raw.githubusercontent.com/cmusphinx/cmudict/master/cmudict.dict

python3 scripts/build_dictionary.py wordnet31 cmudict.dict Dictionary/Resources/WordNet.sqlite
```

## Project layout

```
Dictionary.xcodeproj/          Xcode project (Xcode 16 synchronized groups)
Dictionary/
  DictionaryApp.swift          App entry point
  Models/WordEntry.swift       Entry, sense, and lookup-result models
  Database/DictionaryStore.swift  Read-only SQLite access (C API, no deps)
  ViewModels/DictionaryViewModel.swift  Search, history, and settings state
  Views/                       ContentView, entry rendering, history, settings
  Resources/WordNet.sqlite     The offline dictionary database
scripts/build_dictionary.py    Rebuilds the database from WordNet + CMUdict
LICENSES/                      WordNet and CMUdict license texts
```

## Licenses

Application code is provided under the MIT license. Dictionary content is
© Princeton University (WordNet license) and © Carnegie Mellon University
(BSD-style license); see the `LICENSES/` directory.

import SwiftUI

/// The entry on screen with its toolbar: save, and the Go ▸ Back / Forward
/// chevrons. Shown in the main window's detail column and pushed from Browse.
struct EntryPage: View {
    @EnvironmentObject private var model: DictionaryViewModel

    var body: some View {
        if let lookup = model.currentLookup, let term = model.currentTerm {
            LookupResultView(term: term, result: lookup)
                .id(term)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        FavoriteButton(word: term)

                        Button {
                            model.goBack()
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .disabled(!model.canGoBack)

                        Button {
                            model.goForward()
                        } label: {
                            Label("Forward", systemImage: "chevron.forward")
                        }
                        .disabled(!model.canGoForward)
                    }
                }
        } else {
            EmptyPage(prompt: "Type a word to look up in\u{2026}")
        }
    }
}

extension View {
    /// Routes taps on words inside an entry to a lookup. Sheets don't inherit
    /// this from the window, so each one that shows an entry applies it again.
    func handlesLookupLinks(_ model: DictionaryViewModel) -> some View {
        environment(\.openURL, OpenURLAction { url in
            if let word = LookupLink.word(from: url) {
                model.lookUp(word)
                return .handled
            }
            return .systemAction
        })
    }
}

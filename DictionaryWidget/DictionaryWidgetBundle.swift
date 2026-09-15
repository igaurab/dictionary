import WidgetKit
import SwiftUI

@main
struct DictionaryWidgetBundle: WidgetBundle {
    init() {
        // Registering here as well as lazily in `Font.roboto` covers the
        // timeline-only launches where no view has been built yet.
        _ = WidgetFonts.registered
    }

    var body: some Widget {
        WordOfTheDayWidget()
        SearchWidget()
    }
}

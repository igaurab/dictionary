import SwiftUI

@main
struct DictionaryApp: App {
    @StateObject private var model = DictionaryViewModel()

    init() {
        AppFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}

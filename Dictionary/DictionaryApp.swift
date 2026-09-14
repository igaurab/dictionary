import SwiftUI

@main
struct DictionaryApp: App {
    @StateObject private var model = DictionaryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}

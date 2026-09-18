import SwiftUI
import SwiftData

@main
struct JiZiApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [SourceBook.self, CharacterEntry.self])
    }
}

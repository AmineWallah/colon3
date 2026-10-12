import SwiftUI

@main
struct Colon3App: App {
    @StateObject private var library: Library
    @StateObject private var model: AppModel
    @StateObject private var player = Player()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = Library()
        _library = StateObject(wrappedValue: library)
        _model = StateObject(wrappedValue: AppModel(library: library))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(library)
                .environmentObject(player)
                .onAppear { model.start() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                model.reconnectIfNeeded()
                library.rescan()
            }
        }
    }
}

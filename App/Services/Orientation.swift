import SwiftUI
import UIKit

/// Portrait everywhere, except the full-screen player, which also turns to landscape.
/// Info.plist lists landscape so iOS allows it at all; this narrows it down per screen.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var orientations: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { Self.orientations }
    }
}

@MainActor
enum OrientationLock {
    /// Lets the screen turn to landscape (while the player is up), or turns it back to portrait.
    static func allowLandscape(_ allowed: Bool) {
        AppDelegate.orientations = allowed ? .allButUpsideDown : .portrait
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            if !allowed {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
        }
    }
}

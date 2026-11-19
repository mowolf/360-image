import UIKit

/// Keeps the screen awake and at a steady brightness during capture / stitching.
///
/// - Auto-lock: `isIdleTimerDisabled` is (re)asserted whenever we become active; iOS can
///   ignore a value set before the scene is active, so it is toggled to force an update.
/// - Auto-brightness: while capturing, the phone points at lamps and windows, and the ambient
///   light sensor dims the screen. The brightness is pinned while capturing and restored after.
@MainActor
enum ScreenKeeper {
    private static var savedBrightness: CGFloat?
    private static var holders = 0

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.screen
    }

    /// Prevent auto-lock (balanced with `release()`).
    static func hold() {
        holders += 1
        reassert()
    }

    static func release() {
        holders = max(0, holders - 1)
        if holders == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// Re-apply after returning to the foreground.
    static func reassert() {
        guard holders > 0 else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Pin the brightness (at least the current level, minimum 60%) until `unpinBrightness()`.
    static func pinBrightness() {
        guard let screen else { return }
        if savedBrightness == nil { savedBrightness = screen.brightness }
        screen.brightness = max(savedBrightness ?? screen.brightness, 0.6)
    }

    static func unpinBrightness() {
        guard let saved = savedBrightness else { return }
        screen?.brightness = saved
        savedBrightness = nil
    }
}

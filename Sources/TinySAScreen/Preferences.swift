import Foundation

/// The app's settings, kept in its user defaults (the Settings window binds to the same keys).
enum Preferences {
  enum Key {
    static let controlEnabled = "controlEnabled"
    static let keepRecent = "keepRecent"
    static let keepRecentSeconds = "keepRecentSeconds"
    static let gifShowsDate = "gifShowsDate"
    static let gifShowsTime = "gifShowsTime"
    static let gifScale = "gifScale"
  }

  static let defaults = UserDefaults.standard

  static func register() {
    defaults.register(defaults: [
      Key.controlEnabled: true,
      Key.keepRecent: true,
      Key.keepRecentSeconds: 60,
      Key.gifShowsDate: true,
      Key.gifShowsTime: true,
      Key.gifScale: 2,
    ])
  }

  /// Clicks on the picture tap the analyzer's screen.
  static var controlEnabled: Bool {
    get { defaults.bool(forKey: Key.controlEnabled) }
    set { defaults.set(newValue, forKey: Key.controlEnabled) }
  }

  /// The latest seconds kept for Capture: 0 when off.
  static var keptSeconds: Int {
    defaults.bool(forKey: Key.keepRecent) ? min(max(defaults.integer(forKey: Key.keepRecentSeconds), 5), 120) : 0
  }

  static var gifShowsDate: Bool { defaults.bool(forKey: Key.gifShowsDate) }
  static var gifShowsTime: Bool { defaults.bool(forKey: Key.gifShowsTime) }
  static var gifScale: Int { defaults.integer(forKey: Key.gifScale) == 1 ? 1 : 2 }
}

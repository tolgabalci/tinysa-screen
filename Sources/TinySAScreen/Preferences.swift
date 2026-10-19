import Foundation
import TinySAKit

/// The app's settings, kept in its user defaults (the Settings window binds to the same keys).
enum Preferences {
  enum Key {
    static let controlEnabled = "controlEnabled"
    static let keepRecent = "keepRecent"
    static let keepRecentSeconds = "keepRecentSeconds"
    static let gifShowsDate = "gifShowsDate"
    static let gifShowsTime = "gifShowsTime"
    static let gifScale = "gifScale"
    static let savedBands = "savedBands"
    static let inkSeconds = "inkSeconds"
    static let floatOnTop = "floatOnTop"
    static let peakHold = "peakHold"
    static let peakWindow = "peakWindow"
    static let peakCount = "peakCount"
    static let saveFolderBookmark = "saveFolderBookmark"
    static let saveFolderPath = "saveFolderPath"
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
      Key.inkSeconds: 3,
      Key.floatOnTop: false,
      Key.peakHold: false,
      Key.peakWindow: 0,
      Key.peakCount: 5,
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

  /// Seconds a pen stroke stays before it fades.
  static var inkSeconds: Int { min(max(defaults.integer(forKey: Key.inkSeconds), 1), 30) }

  /// The peak hold drawn over the picture.
  static var peakHold: Bool {
    get { defaults.bool(forKey: Key.peakHold) }
    set { defaults.set(newValue, forKey: Key.peakHold) }
  }

  /// Seconds the peak hold keeps a level, or nil for until it is cleared.
  static var peakWindow: TimeInterval? {
    let seconds = defaults.integer(forKey: Key.peakWindow)
    return seconds > 0 ? TimeInterval(seconds) : nil
  }

  static var peakCount: Int { min(max(defaults.integer(forKey: Key.peakCount), 0), 9) }

  /// The window stays above other apps' windows.
  static var floatOnTop: Bool {
    get { defaults.bool(forKey: Key.floatOnTop) }
    set { defaults.set(newValue, forKey: Key.floatOnTop) }
  }

  /// Where GIFs and screenshots are saved (Settings › Save to): the Desktop unless another folder was chosen.
  static var saveFolder: SaveFolder {
    get {
      let bookmark = defaults.data(forKey: Key.saveFolderBookmark)
      let path = defaults.string(forKey: Key.saveFolderPath)
      return SaveFolder(
        bookmark: bookmark?.isEmpty == false ? bookmark : nil, path: path?.isEmpty == false ? path : nil)
    }
    set {
      defaults.set(newValue.bookmark ?? Data(), forKey: Key.saveFolderBookmark)
      defaults.set(newValue.path ?? "", forKey: Key.saveFolderPath)
    }
  }

  /// The name of the folder files go to now, as Finder shows it ("Desktop" while a chosen folder can't be found).
  static var saveFolderName: String { saveFolder.place().name }

  /// The bands the user saved (Band › Save Current Span as a Band), at the top of the Band menu.
  static var savedBands: [BandPreset] {
    get {
      guard let data = defaults.data(forKey: Key.savedBands) else { return [] }
      return (try? JSONDecoder().decode([BandPreset].self, from: data)) ?? []
    }
    set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.savedBands) }
  }
}

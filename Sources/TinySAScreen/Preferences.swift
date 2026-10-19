import AppKit
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
    static let peakColor = "peakColor"
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
      Key.peakWindow: 60,  // the latest minute, as a monitor holds peaks; 0 keeps them until cleared
      Key.peakColor: PeakColor.cyan.rawValue,
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

  /// How long the peak hold can keep a level, in seconds (0: until cleared), for the menu and Settings.
  static let peakWindows = [0, 10, 30, 60, 300]

  /// The peak hold's colour.
  static var peakColor: PeakColor { PeakColor(rawValue: defaults.string(forKey: Key.peakColor) ?? "") ?? .cyan }

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

/// The peak hold's colours. The analyzer draws its own traces yellow, green, red and magenta (traces 1 to 4 on a
/// tinySA Ultra, 3 and 4 the other way round on the original), so the default is cyan, which none of them is: the held
/// line never passes for one of the analyzer's (a green max hold, say). Yellow isn't offered: the held line runs along
/// the yellow live trace.
enum PeakColor: String, CaseIterable, Identifiable {
  case cyan, green, magenta, orange, red, white

  var id: String { rawValue }
  var name: String { rawValue.capitalized }

  var color: NSColor {
    switch self {
    case .cyan: return NSColor(srgbRed: 0.15, green: 0.9, blue: 1, alpha: 1)
    case .green: return NSColor(srgbRed: 0.25, green: 1, blue: 0.25, alpha: 1)
    case .magenta: return NSColor(srgbRed: 1, green: 0.25, blue: 1, alpha: 1)
    case .orange: return NSColor(srgbRed: 1, green: 0.6, blue: 0.1, alpha: 1)
    case .red: return NSColor(srgbRed: 1, green: 0.3, blue: 0.3, alpha: 1)
    case .white: return NSColor(white: 0.95, alpha: 1)
    }
  }

  /// A dot of the colour, for menus.
  var swatch: NSImage {
    let color = color
    let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
      color.setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
      NSColor.black.withAlphaComponent(0.35).setStroke()
      NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
      return true
    }
    image.isTemplate = false
    return image
  }
}

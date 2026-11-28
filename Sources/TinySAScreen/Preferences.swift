import AppKit
import TinySAKit

/// The app's settings, kept in its user defaults (the Settings window binds to the same keys).
enum Preferences {
  enum Key {
    static let controlEnabled = "controlEnabled"
    static let keepRecent = "keepRecent"
    static let keepRecentSeconds = "keepRecentSeconds"
    static let recordLeadIn = "recordLeadIn"
    static let recordLongest = "recordLongest"
    static let gifShowsDate = "gifShowsDate"
    static let gifShowsTime = "gifShowsTime"
    static let gifShowsElapsed = "gifShowsElapsed"
    static let gifShowsProgress = "gifShowsProgress"
    static let gifLoops = "gifLoops"
    static let gifPauseAtEnd = "gifPauseAtEnd"
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
    static let editorWidth = "editorWidth"
    static let editorHeight = "editorHeight"
  }

  static let defaults = UserDefaults.standard

  static func register() {
    defaults.register(defaults: [
      Key.controlEnabled: true,
      Key.keepRecent: true,
      Key.keepRecentSeconds: 60,
      Key.recordLeadIn: 5,
      Key.recordLongest: 120,
      Key.gifShowsDate: true,
      Key.gifShowsTime: true,
      Key.gifShowsElapsed: true,
      Key.gifShowsProgress: true,
      Key.gifLoops: true,
      Key.gifPauseAtEnd: 3,
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

  /// The latest seconds kept in memory, for Record to start before it's pressed (and for the command line's capture):
  /// 0 when off, five minutes at most.
  static var keptSeconds: Int {
    defaults.bool(forKey: Key.keepRecent)
      ? min(max(defaults.integer(forKey: Key.keepRecentSeconds), 5), Int(FrameRecorder.longestAllowed)) : 0
  }

  /// The seconds a recording starts before Record is pressed, as far back as the seconds kept go.
  static var recordLeadIn: Int { min(max(defaults.integer(forKey: Key.recordLeadIn), 0), keptSeconds) }

  /// The longest a recording runs after Record is pressed, from one minute to five.
  static var recordLongest: Int {
    min(max(defaults.integer(forKey: Key.recordLongest), 60), Int(FrameRecorder.longestAllowed))
  }

  static var gifShowsDate: Bool { defaults.bool(forKey: Key.gifShowsDate) }
  static var gifShowsTime: Bool { defaults.bool(forKey: Key.gifShowsTime) }
  static var gifShowsElapsed: Bool { defaults.bool(forKey: Key.gifShowsElapsed) }
  static var gifShowsProgress: Bool { defaults.bool(forKey: Key.gifShowsProgress) }
  static var gifScale: Int { defaults.integer(forKey: Key.gifScale) == 1 ? 1 : 2 }
  static var gifLoops: Bool { defaults.bool(forKey: Key.gifLoops) }
  /// Seconds the last frame is held, 0 to 10.
  static var gifPauseAtEnd: Int { min(max(defaults.integer(forKey: Key.gifPauseAtEnd), 0), 10) }

  /// How GIFs look and play, as Settings and the editor last left them: at their own speed, every frame.
  static var gifOptions: GIFOptions {
    GIFOptions(
      scale: gifScale, showsDate: gifShowsDate, showsTime: gifShowsTime, showsElapsed: gifShowsElapsed,
      showsProgress: gifShowsProgress, loops: gifLoops, pauseAtEnd: TimeInterval(gifPauseAtEnd))
  }

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

  /// Where GIFs and screenshots are saved: the Desktop, or the folder the editor last saved a GIF to (its Save to).
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

  /// The size the editor's window was last left at: the next one's.
  static var editorSize: NSSize? {
    get {
      let width = defaults.double(forKey: Key.editorWidth)
      let height = defaults.double(forKey: Key.editorHeight)
      return width > 0 && height > 0 ? NSSize(width: width, height: height) : nil
    }
    set {
      defaults.set(newValue?.width ?? 0, forKey: Key.editorWidth)
      defaults.set(newValue?.height ?? 0, forKey: Key.editorHeight)
    }
  }

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

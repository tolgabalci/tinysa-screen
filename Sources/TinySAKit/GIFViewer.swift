import Foundation

/// Where a GIF the window saved opens to be watched: in the app the Mac opens GIFs with, unless that app shows a GIF
/// still, and then in the browser, which plays it.
public enum GIFViewer {
  /// Apps a GIF may open in that don't play it: Preview shows its frames as pages, Photos takes it into the library,
  /// ColorSync Utility shows the first frame, and the image editors open the frames as layers.
  static let stillApps: Set<String> = [
    "com.apple.preview", "com.apple.photos", "com.apple.colorsyncutility",
    "com.pixelmatorteam.pixelmator.x", "com.pixelmatorteam.pixelmator", "com.adobe.photoshop",
    "com.seriflabs.affinityphoto", "com.seriflabs.affinityphoto2", "org.krita",
  ]
  /// The same, by the start of their identifiers, which change with the version (GIMP 2.10's is org.gimp.gimp-2.10,
  /// Acorn 7's com.flyingmeat.Acorn7).
  static let stillAppPrefixes = ["org.gimp.gimp", "com.flyingmeat.acorn"]

  /// Whether a GIF opens in the browser rather than in the app the Mac opens GIFs with (its bundle identifier, or nil
  /// when no app opens them).
  public static func usesBrowser(insteadOf app: String?) -> Bool {
    guard let app = app?.lowercased() else { return true }
    return stillApps.contains(app) || stillAppPrefixes.contains { app.hasPrefix($0) }
  }
}

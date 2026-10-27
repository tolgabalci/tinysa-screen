/// What the window's title bar says: the app's name and version, both from its Info.plist (the build writes the
/// repository's VERSION there), and under them the tagline, or while other programs record the screen, who they are.
/// Where the picture comes from is in `tinysa-screen status` and in a GIF's comment (`Status.source`).
public enum TitleBar {
  public static let tagline = "The big screen your tinySA deserves"

  /// "tinySA Screen v1.3.2", from the app's Info.plist (`Bundle.main.infoDictionary`); just the name when it has no
  /// version, as when run from source without a bundle.
  public static func title(_ info: [String: Any]?) -> String {
    let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? "tinySA Screen"
    guard let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty else { return name }
    return "\(name) v\(version)"
  }

  /// The tagline, or "Recording for …" while other programs record the screen.
  public static func subtitle(recordingFor names: [String]) -> String {
    names.isEmpty ? tagline : "Recording for \(names.joined(separator: ", "))"
  }
}

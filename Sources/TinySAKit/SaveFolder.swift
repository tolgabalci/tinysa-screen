import Foundation

/// Where the app saves GIFs and screenshots: the Desktop, or a folder chosen in Settings. A chosen folder is kept as a
/// bookmark as well as a path, so it is found again after it is moved or renamed. While it can't be found (on a drive
/// that is unplugged, say) or can't be written to, files go to the Desktop instead, and the app says so: a recording is
/// never lost for want of its folder.
public struct SaveFolder: Equatable, Sendable {
  /// A bookmark to the chosen folder, and its path when chosen; both nil for the Desktop.
  public let bookmark: Data?
  public let path: String?

  public init(bookmark: Data? = nil, path: String? = nil) {
    self.bookmark = bookmark
    self.path = path
  }

  /// The Desktop, where files go unless another folder is chosen.
  public static let desktop = SaveFolder()

  public static var desktopURL: URL { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] }

  /// `url` as the chosen folder (the Desktop itself is the default).
  public static func chosen(_ url: URL, desktop: URL = desktopURL) throws -> SaveFolder {
    let url = url.standardizedFileURL
    if url.resolvingSymlinksInPath().path == desktop.resolvingSymlinksInPath().path { return .desktop }
    return SaveFolder(bookmark: try url.bookmarkData(), path: url.path)
  }

  public var isDesktop: Bool { path == nil }

  /// Where files go now.
  public struct Place: Equatable, Sendable {
    public let url: URL
    /// The chosen folder's name while it can't be found: files go to the Desktop meanwhile.
    public let missing: String?
    /// The chosen folder again, when it was moved or renamed since: to keep in its place.
    public let moved: SaveFolder?

    /// The folder's name as Finder shows it.
    public var name: String { FileManager.default.displayName(atPath: url.path) }
  }

  /// The folder files go to now: the chosen one where its bookmark (or else its path) finds it, else the Desktop.
  public func place(desktop: URL = desktopURL) -> Place {
    guard let path else { return Place(url: desktop, missing: nil, moved: nil) }
    let chosenURL = URL(fileURLWithPath: path, isDirectory: true)
    if let bookmark {
      var stale = false
      // Never mounting a volume or asking anything: a drive that isn't there is missing for now.
      if let url = try? URL(
        resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
        bookmarkDataIsStale: &stale),
        Self.isFolder(url)
      {
        let same = url.resolvingSymlinksInPath().path == chosenURL.resolvingSymlinksInPath().path
        return Place(url: url, missing: nil, moved: stale || !same ? try? Self.chosen(url, desktop: desktop) : nil)
      }
    }
    if Self.isFolder(chosenURL) { return Place(url: chosenURL, missing: nil, moved: nil) }
    return Place(url: desktop, missing: chosenURL.lastPathComponent, moved: nil)
  }

  /// What `save` did.
  public struct Saved: Equatable, Sendable {
    /// The file written.
    public let url: URL
    /// Why it isn't in the chosen folder, when it went to the Desktop instead.
    public let instead: String?
    /// The chosen folder again, when it was moved or renamed since: to keep in its place.
    public let moved: SaveFolder?

    /// Its folder's name as Finder shows it.
    public var folder: String { FileManager.default.displayName(atPath: url.deletingLastPathComponent().path) }
  }

  /// Writes a new file named after `start` (`fileName`, never over another file) in the folder, with `write`; on the
  /// Desktop when the folder can't be found, or writing in it fails.
  public func save(
    for start: Date, extension kind: String, desktop: URL = desktopURL, _ write: (URL) throws -> Void
  ) throws -> Saved {
    let place = place(desktop: desktop)
    let url = Self.newFile(in: place.url, for: start, extension: kind)
    do {
      try write(url)
      return Saved(url: url, instead: place.missing.map { "\($0) isn't there" }, moved: place.moved)
    } catch where place.missing == nil && !isDesktop {
      let fallback = Self.newFile(in: desktop, for: start, extension: kind)
      try write(fallback)
      return Saved(url: fallback, instead: "\(place.name) couldn't be written to", moved: place.moved)
    }
  }

  /// "tinySA 2026-10-17 at 10.15.32.gif", named after `start` like the Mac's own screen recordings (whatever the Mac's
  /// calendar and digits), "(2)" and on after it when that name is taken.
  public static func fileName(for start: Date, number: Int = 1, extension kind: String = "gif") -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return "tinySA \(formatter.string(from: start))" + (number > 1 ? " (\(number))" : "") + ".\(kind)"
  }

  /// A new file in `folder` named after `start`, never one already there.
  public static func newFile(in folder: URL, for start: Date, extension kind: String = "gif") -> URL {
    var number = 1
    while true {
      let url = folder.appendingPathComponent(fileName(for: start, number: number, extension: kind))
      if !FileManager.default.fileExists(atPath: url.path) { return url }
      number += 1
    }
  }

  /// A folder that is there, and not in the Trash: a bookmark follows a folder that is thrown away.
  static func isFolder(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      return false
    }
    return !url.resolvingSymlinksInPath().pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
  }
}

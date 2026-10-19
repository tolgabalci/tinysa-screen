import XCTest

@testable import TinySAKit

final class SaveFolderTests: XCTestCase {
  private var root: URL!
  /// Stands in for the Desktop, so no test writes on the real one.
  private var desktop: URL!
  private let start = Date(timeIntervalSince1970: 1_792_000_000)

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("tinysa-screen-save-\(UUID().uuidString)")
    desktop = root.appendingPathComponent("Desktop", isDirectory: true)
    try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func folder(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func same(_ a: URL, _ b: URL, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.resolvingSymlinksInPath().path, b.resolvingSymlinksInPath().path, file: file, line: line)
  }

  func testTheDesktopIsTheDefault() {
    let place = SaveFolder.desktop.place(desktop: desktop)
    same(place.url, desktop)
    XCTAssertNil(place.missing)
    XCTAssertNil(place.moved)
  }

  func testChoosingTheDesktopIsTheDefault() throws {
    XCTAssertEqual(try SaveFolder.chosen(desktop, desktop: desktop), .desktop)
  }

  func testFilesGoToTheChosenFolder() throws {
    let recordings = try folder("Recordings")
    let chosen = try SaveFolder.chosen(recordings, desktop: desktop)
    XCTAssertFalse(chosen.isDesktop)
    let saved = try chosen.save(for: start, extension: "gif", desktop: desktop) { try Data("gif".utf8).write(to: $0) }
    same(saved.url.deletingLastPathComponent(), recordings)
    XCTAssertEqual(saved.url.lastPathComponent, SaveFolder.fileName(for: start))
    XCTAssertEqual(saved.folder, "Recordings")
    XCTAssertNil(saved.instead)
  }

  func testAFolderMovedOrRenamedIsFollowed() throws {
    let chosen = try SaveFolder.chosen(try folder("Recordings"), desktop: desktop)
    let renamed = root.appendingPathComponent("Band recordings", isDirectory: true)
    try FileManager.default.moveItem(at: root.appendingPathComponent("Recordings"), to: renamed)
    let place = chosen.place(desktop: desktop)
    same(place.url, renamed)
    XCTAssertNil(place.missing)
    let moved = try XCTUnwrap(place.moved, "the bookmark to keep from now on")
    same(URL(fileURLWithPath: try XCTUnwrap(moved.path)), renamed)
    XCTAssertNil(moved.place(desktop: desktop).moved)
  }

  func testAFolderThatIsGoneMeansTheDesktopAndSaysSo() throws {
    let recordings = try folder("Recordings")
    let chosen = try SaveFolder.chosen(recordings, desktop: desktop)
    try FileManager.default.removeItem(at: recordings)
    let place = chosen.place(desktop: desktop)
    same(place.url, desktop)
    XCTAssertEqual(place.missing, "Recordings")
    let saved = try chosen.save(for: start, extension: "png", desktop: desktop) { try Data("png".utf8).write(to: $0) }
    same(saved.url.deletingLastPathComponent(), desktop)
    XCTAssertEqual(saved.instead, "Recordings isn't there")
  }

  func testAFolderThrownAwayIsGoneThoughItsBookmarkFindsIt() throws {
    let chosen = try SaveFolder.chosen(try folder("Recordings"), desktop: desktop)
    let trash = try folder(".Trash")
    try FileManager.default.moveItem(
      at: root.appendingPathComponent("Recordings"), to: trash.appendingPathComponent("Recordings"))
    let place = chosen.place(desktop: desktop)
    same(place.url, desktop)
    XCTAssertEqual(place.missing, "Recordings")
  }

  func testAFolderThatCantBeWrittenToMeansTheDesktop() throws {
    let recordings = try folder("Recordings")
    let chosen = try SaveFolder.chosen(recordings, desktop: desktop)
    let saved = try chosen.save(for: start, extension: "gif", desktop: desktop) { url in
      if url.deletingLastPathComponent().lastPathComponent == "Recordings" { throw CocoaError(.fileWriteNoPermission) }
      try Data("gif".utf8).write(to: url)
    }
    same(saved.url.deletingLastPathComponent(), desktop)
    XCTAssertEqual(saved.instead, "Recordings couldn't be written to")
    XCTAssertTrue(FileManager.default.fileExists(atPath: saved.url.path))
  }

  func testWritingOnTheDesktopFailingIsAnError() {
    XCTAssertThrowsError(
      try SaveFolder.desktop.save(for: start, extension: "gif", desktop: desktop) { _ in
        throw CocoaError(.fileWriteOutOfSpace)
      })
  }

  func testANewFileNeverReplacesOne() throws {
    let recordings = try folder("Recordings")
    let first = SaveFolder.newFile(in: recordings, for: start)
    try Data().write(to: first)
    let second = SaveFolder.newFile(in: recordings, for: start)
    XCTAssertNotEqual(first, second)
    XCTAssertTrue(second.lastPathComponent.hasSuffix(" (2).gif"), second.lastPathComponent)
  }

  func testFileNamesAreTheMacsScreenRecordingStyleWhateverItsCalendar() {
    let name = SaveFolder.fileName(for: start, extension: "png")
    XCTAssertTrue(name.hasPrefix("tinySA 20"), name)
    let pattern = #"^tinySA \d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2}\.png$"#
    XCTAssertNotNil(name.range(of: pattern, options: .regularExpression), name)
  }
}

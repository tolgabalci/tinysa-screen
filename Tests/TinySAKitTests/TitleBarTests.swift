import Foundation
import XCTest

@testable import TinySAKit

final class TitleBarTests: XCTestCase {
  /// The title names the version the build writes in the app's Info.plist: the repository's VERSION, put in the
  /// template's @VERSION@ (scripts/build-app.sh).
  func testTheTitleNamesTheVersionTheBuildWrites() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let version = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let template = try String(contentsOf: root.appendingPathComponent("Resources/Info.plist"), encoding: .utf8)
    let plist = template.replacingOccurrences(of: "@VERSION@", with: version)
      .replacingOccurrences(of: "@BUILD@", with: "1")
    let info = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any])
    XCTAssertEqual(TitleBar.title(info), "tinySA Screen v\(version)")
  }

  /// Run from source, without a bundle, the app has no Info.plist: just its name.
  func testWithoutAVersionJustTheName() {
    XCTAssertEqual(TitleBar.title(nil), "tinySA Screen")
    XCTAssertEqual(TitleBar.title([:]), "tinySA Screen")
    XCTAssertEqual(TitleBar.title(["CFBundleName": "tinySA Screen", "CFBundleShortVersionString": ""]), "tinySA Screen")
  }

  func testTheSubtitleIsTheTaglineUnlessAProgramRecords() {
    XCTAssertEqual(TitleBar.subtitle(recordingFor: []), "The big screen your tinySA deserves")
    XCTAssertEqual(
      TitleBar.subtitle(recordingFor: ["sweep-logger.py", "an agent"]), "Recording for sweep-logger.py, an agent")
  }
}

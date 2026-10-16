import XCTest

@testable import TinySAKit

final class IntegrationTests: XCTestCase {
  private var home: URL!
  private var saved: URL!

  override func setUpWithError() throws {
    saved = Integration.home
    home = FileManager.default.temporaryDirectory.appendingPathComponent("tinysa-screen-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    Integration.home = home
  }

  override func tearDownWithError() throws {
    Integration.home = saved
    try? FileManager.default.removeItem(at: home)
  }

  /// A process that runs while the test does, other than the test's own.
  private func otherProcess() throws -> Process {
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try sleeper.run()
    addTeardownBlock { sleeper.terminate() }
    return sleeper
  }

  func testBorrowRequest() throws {
    XCTAssertNil(BorrowRequest.current(), "No file, no request")
    let other = try otherProcess()
    try "\(other.processIdentifier) record.py\n".write(to: Integration.borrowFile, atomically: true, encoding: .utf8)
    XCTAssertEqual(BorrowRequest.current(), BorrowRequest(pid: other.processIdentifier, name: "record.py"))
    try "\(getpid()) myself".write(to: Integration.borrowFile, atomically: true, encoding: .utf8)
    XCTAssertNil(BorrowRequest.current(), "This process's own request")
    other.terminate()
    other.waitUntilExit()
    try "\(other.processIdentifier) gone".write(to: Integration.borrowFile, atomically: true, encoding: .utf8)
    XCTAssertNil(BorrowRequest.current(), "A process that has ended")
  }

  func testFeeder() throws {
    XCTAssertNil(FeedState.current(), "No state, no feeder")
    try FileManager.default.createDirectory(at: Integration.feedFolder, withIntermediateDirectories: true)
    let other = try otherProcess()
    func state(_ json: String) throws { try json.write(to: Integration.stateFile, atomically: true, encoding: .utf8) }
    try state(#"{"state": "holding", "pid": \#(other.processIdentifier), "name": "Monitor"}"#)
    XCTAssertEqual(FeedState.current()?.name, "Monitor")
    try state(#"{"state": "lent", "program": "record.py", "pid": \#(other.processIdentifier)}"#)
    XCTAssertEqual(FeedState.current()?.program, "record.py")
    try state(#"{"state": "stopped", "pid": \#(other.processIdentifier)}"#)
    XCTAssertNil(FeedState.current(), "A feeder that stopped")
    try state(#"{"state": "holding"}"#)
    XCTAssertNil(FeedState.current(), "No process to check")
  }

  func testWatching() throws {
    FeedState.touchWatching()
    let first = try FileManager.default.attributesOfItem(atPath: Integration.watchingFile.path)[.modificationDate]
    XCTAssertNotNil(first)
    FeedState.stopWatching()
    XCTAssertFalse(FileManager.default.fileExists(atPath: Integration.watchingFile.path))
  }

  func testVersionNames() {
    XCTAssertEqual(Session.shortVersion("tinySA4_v1.4-252-g2b4aa51-dirty"), "v1.4-252")
    XCTAssertEqual(Session.shortVersion("tinySA_v1.4-199-gdeadbee"), "v1.4-199")
    XCTAssertEqual(ScreenSize.of(version: "tinySA4_v1.4-252"), .ultra)
    XCTAssertEqual(ScreenSize.of(version: "tinySA_v1.4-199"), .basic)
  }
}

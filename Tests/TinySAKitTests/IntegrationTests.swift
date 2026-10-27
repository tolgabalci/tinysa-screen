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

  func testFeederThatPassesTapsOn() throws {
    try FileManager.default.createDirectory(at: Integration.feedFolder, withIntermediateDirectories: true)
    let other = try otherProcess()
    let pid = other.processIdentifier
    try #"{"state": "holding", "pid": \#(pid), "name": "Monitor", "taps": true}"#
      .write(to: Integration.stateFile, atomically: true, encoding: .utf8)
    XCTAssertEqual(FeedState.current()?.taps, true)
    try #"{"state": "holding", "pid": \#(pid), "name": "Monitor"}"#
      .write(to: Integration.stateFile, atomically: true, encoding: .utf8)
    XCTAssertNil(FeedState.current()?.taps, "A feeder from before taps")
  }

  /// The taps file: a line for each click, the command and when, and a new file in one step (another inode, which a
  /// feeder reads from its start) when the app starts and when it has grown large.
  func testTapsLog() throws {
    FeedTaps.startOver()
    func inode() throws -> Int {
      try XCTUnwrap(FileManager.default.attributesOfItem(atPath: Integration.tapsFile.path)[.systemFileNumber] as? Int)
    }
    let first = try inode()
    XCTAssertEqual(try String(contentsOf: Integration.tapsFile, encoding: .utf8), "")
    FeedTaps.add("touch 240 160", at: Date(timeIntervalSince1970: 1_792_452_000.125))
    FeedTaps.add("release 240 160", at: Date(timeIntervalSince1970: 1_792_452_000.5))
    XCTAssertEqual(
      try String(contentsOf: Integration.tapsFile, encoding: .utf8),
      "touch 240 160 1792452000.125\nrelease 240 160 1792452000.500\n")
    XCTAssertEqual(try inode(), first, "Added to, not replaced")
    FeedTaps.startOver()
    XCTAssertNotEqual(try inode(), first)
    XCTAssertEqual(try String(contentsOf: Integration.tapsFile, encoding: .utf8), "")
    // Past the limit, the next click starts a new file.
    try String(repeating: "x", count: FeedTaps.limit + 1)
      .write(to: Integration.tapsFile, atomically: false, encoding: .utf8)
    let large = try inode()
    FeedTaps.add("touch 1 2")
    XCTAssertNotEqual(try inode(), large)
    XCTAssertTrue(try String(contentsOf: Integration.tapsFile, encoding: .utf8).hasPrefix("touch 1 2 "))
  }

  /// While a feeder that passes taps on has the analyzer, the window's clicks go to it, and a touch it was given is
  /// released when they stop going there; a feeder that doesn't pass taps on gets none, and its pictures take no
  /// clicks. (The feeder is there before the session starts, so the session never opens a USB port.)
  func testClicksGoToAFeederThatPassesTapsOn() throws {
    try FileManager.default.createDirectory(at: Integration.feedFolder, withIntermediateDirectories: true)
    let other = try otherProcess()
    func feeder(taps: Bool) throws {
      try #"{"state": "holding", "pid": \#(other.processIdentifier), "name": "Monitor", "taps": \#(taps)}"#
        .write(to: Integration.stateFile, atomically: true, encoding: .utf8)
    }
    func lines() throws -> [String] {
      try String(contentsOf: Integration.tapsFile, encoding: .utf8).split(separator: "\n")
        .map { $0.split(separator: " ").prefix(3).joined(separator: " ") }
    }
    func wait(for condition: () -> Bool) {
      let deadline = Date() + 5
      while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    }
    try feeder(taps: true)
    let session = Session()
    session.start()
    defer { session.stop() }
    wait { session.status.controllable }
    XCTAssertTrue(session.status.controllable)
    XCTAssertEqual(session.status.feeder, "Monitor")
    session.touch(x: 100, y: 50)
    session.touch(x: 110, y: 50)
    session.release(x: 110, y: 50)
    XCTAssertEqual(try lines(), ["touch 100 50", "touch 110 50", "release 110 50"])

    session.touch(x: 5, y: 6)
    try feeder(taps: false)
    wait { !session.status.controllable }
    XCTAssertFalse(session.status.controllable)
    XCTAssertEqual(try lines().last, "release 5 6", "The touch it was given, released")
    session.touch(x: 7, y: 8)
    session.release(x: 7, y: 8)
    XCTAssertEqual(try lines().last, "release 5 6", "Nothing for a feeder that doesn't pass taps on")
  }

  /// A feeder's picture of the analyzer's keypad never goes stale: the analyzer doesn't sweep while its keypad is open
  /// and draws nothing until a key is pressed, so no picture comes after it. A graph's picture does go stale.
  func testAKeypadPictureNeverGoesStale() throws {
    try FileManager.default.createDirectory(at: Integration.feedFolder, withIntermediateDirectories: true)
    let other = try otherProcess()
    try #"{"state": "holding", "pid": \#(other.processIdentifier), "name": "Monitor"}"#
      .write(to: Integration.stateFile, atomically: true, encoding: .utf8)
    /// A fixture as the feeder's picture, put 3 s ago (live when the session sees it: under the 6 s a picture stays
    /// new); returns when it is 7 s old.
    func picture(_ name: String) throws -> Date {
      let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
      try? FileManager.default.removeItem(at: Integration.pictureFile)
      try FileManager.default.copyItem(at: url, to: Integration.pictureFile)
      let put = Date() - 3
      try FileManager.default.setAttributes([.modificationDate: put], ofItemAtPath: Integration.pictureFile.path)
      return put + 7
    }
    let keypadStale = try picture("screen-keypad.png")
    let session = Session()
    session.start()
    defer { session.stop() }
    Thread.sleep(until: keypadStale)
    XCTAssertEqual(session.status.feeder, "Monitor")
    XCTAssertNil(session.status.note, "The keypad, still what the analyzer shows")

    Thread.sleep(until: try picture("screen-915.png"))
    let note = try XCTUnwrap(session.status.note, "A graph with no picture after it for 7 s")
    XCTAssertTrue(note.hasPrefix("No new picture from Monitor since"), note)
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

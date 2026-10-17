import XCTest

@testable import TinySAKit

final class ControlTests: XCTestCase {
  var folder: URL!

  override func setUpWithError() throws {
    // A short path: a Unix socket's path holds at most 103 bytes.
    folder = URL(fileURLWithPath: "/tmp/tsa-\(getpid())-\(Int.random(in: 0..<1_000_000))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
  }

  /// A request goes to the server and its reply comes back; with no server, the client says so (nil).
  func testRequestAndReply() throws {
    let path = folder.appendingPathComponent("control.sock")
    XCTAssertNil(try ControlClient.send(ControlRequest(command: "status"), path: path, timeout: 2))
    let server = ControlServer(path: path) { request, _ in
      var reply = ControlReply(ok: true)
      reply.source = "\(request.command) \(request.seconds ?? 0) \(request.output ?? "")"
      return reply
    }
    try server.start()
    defer { server.stop() }
    let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
    XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077, 0, "this user only")
    let reply = try XCTUnwrap(
      try ControlClient.send(ControlRequest(command: "record", seconds: 5, output: "/x/y z.gif"), path: path, timeout: 5))
    XCTAssertEqual(reply.source, "record 5.0 /x/y z.gif")
    // A second copy of the app doesn't take the socket from the first.
    XCTAssertThrowsError(try ControlServer(path: path) { _, _ in ControlReply(ok: true) }.start()) {
      XCTAssertEqual($0 as? ControlServer.Failure, .taken)
    }
    server.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    XCTAssertNil(try ControlClient.send(ControlRequest(command: "status"), path: path, timeout: 2))
  }

  /// A long request sees the asker go away.
  func testServerSeesTheAskerLeave() throws {
    let path = folder.appendingPathComponent("control.sock")
    let left = expectation(description: "the asker left")
    let server = ControlServer(path: path) { _, isOpen in
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline {
        if !isOpen() {
          left.fulfill()
          break
        }
        Thread.sleep(forTimeInterval: 0.05)
      }
      return ControlReply(ok: true)
    }
    try server.start()
    defer { server.stop() }
    let fd = try ControlClient.connect(path)
    ControlClient.write(#"{"command":"record","seconds":30}"# + "\n", to: fd)
    Thread.sleep(forTimeInterval: 0.3)
    close(fd)
    wait(for: [left], timeout: 3)
  }

  /// Something that isn't a request gets an error, not silence.
  func testGarbageGetsAnError() throws {
    let path = folder.appendingPathComponent("control.sock")
    let server = ControlServer(path: path) { _, _ in ControlReply(ok: true) }
    try server.start()
    defer { server.stop() }
    let fd = try ControlClient.connect(path)
    defer { close(fd) }
    ControlClient.write("hello\n", to: fd)
    let line = try XCTUnwrap(ControlClient.readLine(fd, timeout: 3))
    let reply = try JSONDecoder().decode(ControlReply.self, from: Data(line.utf8))
    XCTAssertFalse(reply.ok)
    XCTAssertNotNil(reply.error)
  }

  /// Requests are checked before anything is recorded, and a recording waits for a live picture.
  func testAutomationChecksRequests() throws {
    let automation = Automation(session: Session(), isApp: false, version: "test")
    automation.pictureWait = 0.3
    func error(_ request: ControlRequest) -> String? { automation.handle(request).error }
    XCTAssertEqual(error(ControlRequest(command: "dance")), "Unknown command \"dance\": record, capture, screenshot, sweep, peaks or status")
    XCTAssertEqual(error(ControlRequest(command: "record", output: "/tmp/x.gif")), "How long to record: 1 to 120 seconds")
    XCTAssertEqual(error(ControlRequest(command: "record", seconds: 121, output: "/tmp/x.gif")), "How long to record: 1 to 120 seconds")
    XCTAssertEqual(error(ControlRequest(command: "record", seconds: 5)), "Where to save it: an output path")
    XCTAssertEqual(error(ControlRequest(command: "record", seconds: 5, output: "x.gif")), "The output path must be absolute: x.gif")
    XCTAssertEqual(error(ControlRequest(command: "record", seconds: 5, output: "/nope/x.gif")), "No folder /nope")
    XCTAssertEqual(error(ControlRequest(command: "record", seconds: 5, output: "/tmp")), "/tmp is a folder: give a file name")
    // The session isn't started: no picture comes.
    XCTAssertEqual(error(ControlRequest(command: "record", seconds: 5, output: folder.path + "/x.gif")), "No picture: Starting…")
    XCTAssertTrue(error(ControlRequest(command: "capture", output: folder.path + "/x.gif"))?.hasPrefix("tinySA Screen isn't open") == true)
    let status = automation.handle(ControlRequest(command: "status"))
    XCTAssertTrue(status.ok)
    XCTAssertEqual(status.app, false)
    XCTAssertEqual(status.version, "test")
  }

  /// A span needs both ends, in order; and without the analyzer on USB, sweep says why.
  func testSpanRequests() throws {
    XCTAssertEqual(try Automation.span(ControlRequest(command: "sweep")).get(), nil)
    XCTAssertEqual(
      try Automation.span(ControlRequest(command: "sweep", start: 902_000_000, stop: 928_000_000)).get(),
      SweepRange(start: 902_000_000, stop: 928_000_000))
    XCTAssertThrowsError(try Automation.span(ControlRequest(command: "sweep", start: 902_000_000)).get())
    XCTAssertThrowsError(try Automation.span(ControlRequest(command: "sweep", start: 928_000_000, stop: 902_000_000)).get())
    let automation = Automation(session: Session(), isApp: false, version: "test")
    automation.pictureWait = 0.2
    XCTAssertEqual(
      automation.handle(ControlRequest(command: "sweep", start: 5, stop: 1)).error, "The span's start must be below its stop")
    XCTAssertEqual(automation.handle(ControlRequest(command: "sweep")).error, "No picture: Starting…")
  }

  /// Replies are one line of JSON that reads back the same.
  func testReplyLine() throws {
    var reply = ControlReply(ok: true)
    reply.file = "/Users/me/a b.gif"
    reply.notes = ["one", "two"]
    let line = reply.line()
    XCTAssertFalse(line.contains("\n"))
    XCTAssertTrue(line.contains(#""file":"/Users/me/a b.gif""#))
    XCTAssertEqual(try JSONDecoder().decode(ControlReply.self, from: Data(line.utf8)), reply)
  }
}

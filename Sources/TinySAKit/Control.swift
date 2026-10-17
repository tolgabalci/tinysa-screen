import Foundation

/// A request to tinySA Screen: a JSON object on one line, sent to the open app's control socket
/// (`Integration.controlSocket`) or carried out by the command line itself when the app isn't open.
public struct ControlRequest: Codable, Equatable, Sendable {
  /// "record", "capture", "screenshot" or "status".
  public var command: String
  /// How long to record; for capture, how many of the kept seconds (all of them when nil).
  public var seconds: Double?
  /// Where to write the GIF or PNG: an absolute path.
  public var output: String?
  /// GIF pixels to each pixel of the screen: 1 or 2 (the default).
  public var scale: Int?
  /// The date and the time under the screen (both by default).
  public var date: Bool?
  public var time: Bool?
  /// Who asks, shown in the window while it records ("Recording 30 s for my-script").
  public var name: String?

  public init(
    command: String, seconds: Double? = nil, output: String? = nil, scale: Int? = nil, date: Bool? = nil,
    time: Bool? = nil, name: String? = nil
  ) {
    self.command = command
    self.seconds = seconds
    self.output = output
    self.scale = scale
    self.date = date
    self.time = time
    self.name = name
  }
}

/// The reply: one JSON object on one line. `ok` says whether it worked, `error` why not.
public struct ControlReply: Codable, Equatable, Sendable {
  public var ok: Bool
  public var error: String?
  /// The file written, its size, what it holds.
  public var file: String?
  public var bytes: Int?
  public var width: Int?
  public var height: Int?
  public var seconds: Double?
  /// Frames of the screen in a GIF (one a sweep), and images in it (frames, and the time ticking on).
  public var frames: Int?
  public var images: Int?
  /// When the GIF starts and ends, or when the screenshot's picture came (ISO 8601).
  public var start: String?
  public var end: String?
  /// Where the picture comes from: the analyzer and its firmware, or the program feeding pictures.
  public var source: String?
  /// What happened meanwhile that a viewer should know: the picture stopping, say.
  public var notes: [String]?

  // Status
  /// Whether the open app answered (or the command line alone).
  public var app: Bool?
  public var version: String?
  /// Whether a picture is coming, and from the analyzer itself over USB (clicks reach it).
  public var picture: Bool?
  public var usb: Bool?
  /// Why no picture comes, as the window says it.
  public var note: String?
  /// Seconds the app keeps for capture, and how many it has.
  public var keptSeconds: Double?
  public var availableSeconds: Double?
  public var recordings: Int?
  /// The tinySAs on USB, a program that feeds pictures, and one that borrowed the analyzer.
  public var devices: [String]?
  public var feeder: String?
  public var borrower: String?

  public init(ok: Bool, error: String? = nil) {
    self.ok = ok
    self.error = error
  }

  public static func failure(_ message: String) -> ControlReply { ControlReply(ok: false, error: message) }

  /// One line of JSON.
  public func line() -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(self)) ?? Data(#"{"ok":false}"#.utf8), as: UTF8.self)
  }
}

/// The open app's end of the control socket: a Unix-domain socket in the feed folder that only this user can open.
/// Each connection carries one request and gets one reply; the connection stays open while a recording runs, and
/// closing it cancels the recording.
public final class ControlServer: @unchecked Sendable {
  public enum Failure: Error, Equatable {
    case pathTooLong
    /// Another copy of the app answers there.
    case taken
    case system(String)
  }

  /// Answers a request; `isOpen` says whether the asking program still waits.
  public typealias Handler = (_ request: ControlRequest, _ isOpen: @escaping () -> Bool) -> ControlReply

  private let path: URL
  private let handler: Handler
  private var listener: Int32 = -1

  public init(path: URL = Integration.controlSocket, handler: @escaping Handler) {
    self.path = path
    self.handler = handler
  }

  /// Starts answering. Writing to an asker that has gone would stop the process with SIGPIPE: the process ignores that
  /// signal from now on (the write fails instead), as servers do.
  public func start() throws {
    signal(SIGPIPE, SIG_IGN)
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    if (try? ControlClient.connect(path)).map({ fd -> Bool in
      close(fd)
      return true
    }) == true {
      throw Failure.taken
    }
    unlink(path.path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure.system(String(cString: strerror(errno))) }
    var address = try ControlClient.address(path)
    let previous = umask(0o077)  // the socket file: this user only
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    umask(previous)
    guard bound == 0, listen(fd, 8) == 0 else {
      let message = String(cString: strerror(errno))
      close(fd)
      throw Failure.system(message)
    }
    listener = fd
    let thread = Thread { [weak self] in self?.accepting(fd) }
    thread.name = "tinySA Screen control"
    thread.start()
  }

  /// Stops answering and removes the socket.
  public func stop() {
    guard listener >= 0 else { return }
    let fd = listener
    listener = -1
    shutdown(fd, SHUT_RDWR)
    close(fd)
    unlink(path.path)
  }

  private func accepting(_ fd: Int32) {
    while true {
      let client = accept(fd, nil, nil)
      if client < 0 {
        if errno == EINTR { continue }
        return  // stopped
      }
      var uid: uid_t = 0
      var gid: gid_t = 0
      var on: Int32 = 1
      guard getpeereid(client, &uid, &gid) == 0, uid == getuid(),
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
      else {
        close(client)  // another user's program, or one that has gone already
        continue
      }
      let thread = Thread { [handler] in
        defer { close(client) }
        let reply: ControlReply
        if let line = ControlClient.readLine(client, timeout: 5),
          let request = try? JSONDecoder().decode(ControlRequest.self, from: Data(line.utf8))
        {
          reply = handler(request) { ControlClient.isOpen(client) }
        } else {
          reply = .failure("Not a request: send one line of JSON, such as {\"command\": \"status\"}")
        }
        ControlClient.write(reply.line() + "\n", to: client)
      }
      thread.name = "tinySA Screen request"
      thread.start()
    }
  }
}

/// The asking end: sends a request to the open app and waits for its reply.
public enum ControlClient {
  /// The app's reply, or nil when the app isn't open (nothing answers at the socket). Ignores SIGPIPE from now on, like
  /// the server: an app that quits mid-request makes the write fail instead of stopping this process.
  public static func send(_ request: ControlRequest, path: URL = Integration.controlSocket, timeout: TimeInterval)
    throws -> ControlReply?
  {
    signal(SIGPIPE, SIG_IGN)
    let fd: Int32
    do {
      fd = try connect(path)
    } catch {
      return nil
    }
    defer { close(fd) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let body = String(decoding: try encoder.encode(request), as: UTF8.self)
    write(body + "\n", to: fd)
    let started = Date()
    guard let line = readLine(fd, timeout: timeout) else {
      if Date().timeIntervalSince(started) < timeout - 1 { return .failure("tinySA Screen closed before answering") }
      return .failure("tinySA Screen didn't answer within \(Int(timeout)) seconds")
    }
    return try JSONDecoder().decode(ControlReply.self, from: Data(line.utf8))
  }

  static func address(_ path: URL) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { throw ControlServer.Failure.pathTooLong }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: bytes)
      buffer[bytes.count] = 0
    }
    return address
  }

  /// A connection to the socket, or an error when nothing answers there.
  static func connect(_ path: URL) throws -> Int32 {
    var address = try address(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ControlServer.Failure.system(String(cString: strerror(errno))) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      let message = String(cString: strerror(errno))
      close(fd)
      throw ControlServer.Failure.system(message)
    }
    return fd
  }

  static func write(_ text: String, to fd: Int32) {
    var bytes = Array(text.utf8)[...]
    while !bytes.isEmpty {
      let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      if n < 0, errno == EINTR { continue }
      guard n > 0 else { return }
      bytes = bytes.dropFirst(n)
    }
  }

  /// A line, up to its newline, or nil when none comes within `timeout` seconds or the other end closes first.
  static func readLine(_ fd: Int32, timeout: TimeInterval) -> String? {
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) {
        return String(decoding: bytes[..<newline], as: UTF8.self)
      }
      let left = deadline.timeIntervalSinceNow
      guard left > 0, bytes.count < 1 << 20 else { return nil }
      var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&poller, 1, Int32(min(left, 1) * 1000))
      if ready < 0, errno != EINTR { return nil }
      guard ready > 0 else { continue }
      let n = read(fd, &buffer, buffer.count)
      if n < 0, errno == EINTR { continue }
      guard n > 0 else { return nil }
      bytes += buffer[0..<n]
    }
  }

  /// Whether the other end is still there: not closed (a read would return nothing).
  static func isOpen(_ fd: Int32) -> Bool {
    var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&poller, 1, 0) > 0 else { return true }
    if poller.revents & Int16(POLLHUP | POLLERR) != 0 { return false }
    var byte: UInt8 = 0
    return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) != 0
  }
}

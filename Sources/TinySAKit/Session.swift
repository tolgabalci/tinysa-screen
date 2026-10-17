import CoreGraphics
import Foundation

/// What the window shows besides the picture.
public struct Status: Equatable, Sendable {
  /// Where the picture comes from, for the window's subtitle: the analyzer and its firmware, or the feeding program.
  public var source: String
  /// Why no live picture comes, shown over the picture; nil while it is live.
  public var note: String?
  /// Whether clicks reach the analyzer as taps (live over USB).
  public var controllable: Bool
  /// Whether the analyzer's span can be set from here (live over USB, a tinySA Ultra: the original tinySA has two
  /// inputs for different bands, which a span alone can't choose).
  public var tunable: Bool
  /// The instrument on USB (nil for a feeding program's pictures, or none): only a tinySA's screen is a spectrum.
  public var instrument: Instrument?

  public init(source: String, note: String?, controllable: Bool, tunable: Bool = false, instrument: Instrument? = nil) {
    self.source = source
    self.note = note
    self.controllable = controllable
    self.tunable = tunable
    self.instrument = instrument
  }
}

/// Told on the main thread.
@MainActor
public protocol SessionDelegate: AnyObject {
  func session(_ session: Session, show image: CGImage)
  func session(_ session: Session, status: Status)
}

/// Keeps the window's picture coming: from a tinySA on USB (its live screen after `refresh on`, or on firmware without
/// it a capture after every sweep), or from a program that feeds pictures; and lets go of the analyzer while another
/// program borrows it. Runs on a thread of its own and tells its delegate on the main thread.
public final class Session {
  public weak var delegate: SessionDelegate?
  /// Frames of the screen for GIFs: one after each sweep is drawn (or each picture fed).
  public let recorder = FrameRecorder()

  /// Calls `handler` with each frame (the screen after a sweep, or a fed picture), on the session's thread, until the
  /// returned token is passed to `removeFrameHandler`.
  public func onFrame(_ handler: @escaping @Sendable (Snapshot, Date) -> Void) -> UUID {
    let token = UUID()
    lock.locked { frameHandlers[token] = handler }
    return token
  }

  public func removeFrameHandler(_ token: UUID) {
    lock.locked { frameHandlers[token] = nil }
  }

  public init() {}

  /// What the window would show besides the picture, now: readable from any thread.
  public var status: Status {
    lock.locked { currentStatus } ?? Status(source: "", note: "Starting…", controllable: false)
  }

  // MARK: The main thread's side

  public func start() {
    let thread = Thread { [weak self] in self?.run() }
    thread.name = "tinySA session"
    thread.qualityOfService = .userInitiated
    thread.start()
  }

  /// Lets go of the analyzer properly (its live screen turned off), waiting at most `timeout` seconds.
  public func stop(timeout: TimeInterval = 2) {
    lock.locked { stopping = true }
    _ = finished.wait(timeout: .now() + timeout)
  }

  /// A tap on the analyzer's screen, at a pixel of it: `touch` while the button is down (again as it moves),
  /// `release` when it comes up.
  public func touch(x: Int, y: Int) { lock.locked { taps.append("touch \(x) \(y)") } }
  public func release(x: Int, y: Int) { lock.locked { taps.append("release \(x) \(y)") } }

  /// The span the analyzer sweeps, and with a `target` the span it is set to: the span before and after. Done on the
  /// session's thread with the live screen paused for a moment; `done` is called there. Fails without the analyzer on
  /// USB (a feeding program has it, say), with the reason.
  public func sweep(_ target: SweepRange?, done: @escaping @Sendable (Result<SweepChange, AnalyzerError>) -> Void) {
    lock.locked { jobs.append((UUID(), .sweep(target, done))) }
  }

  /// `sweep`, waiting for the result (not on the main thread: its delegate calls would wait too). A change that hasn't
  /// started within `timeout` (the analyzer busy with a long sweep, say) is taken back, so it never happens later
  /// unasked; one that has started is waited for.
  public func sweep(_ target: SweepRange?, timeout: TimeInterval = 15) -> Result<SweepChange, AnalyzerError> {
    let finished = DispatchSemaphore(value: 0)
    let result = ResultBox()
    let id = UUID()
    lock.locked {
      jobs.append(
        (
          id,
          .sweep(target) { outcome in
            result.set(outcome)
            finished.signal()
          }
        ))
    }
    if finished.wait(timeout: .now() + timeout) == .success, let outcome = result.get() { return outcome }
    let takenBack = lock.locked { () -> Bool in
      guard let i = jobs.firstIndex(where: { $0.id == id }) else { return false }
      jobs.remove(at: i)
      return true
    }
    if takenBack { return .failure(.failed("The tinySA was busy for \(Int(timeout)) seconds: try again")) }
    _ = finished.wait(timeout: .now() + 30)
    return result.get() ?? .failure(.failed("The tinySA didn't answer in time"))
  }

  private let lock = NSLock()
  private var jobs: [(id: UUID, job: Job)] = []
  private var frameHandlers: [UUID: @Sendable (Snapshot, Date) -> Void] = [:]
  private var currentStatus: Status?
  private var stopping = false
  private var taps: [String] = []
  private let finished = DispatchSemaphore(value: 0)

  // MARK: The session thread's side

  private enum Failure: Error {
    case noAnswer
    case unexpected(String)
    /// The app is quitting, or another program asked for the analyzer: let go now.
    case interrupted
  }

  /// Work for the analyzer itself, done between regions of the live screen.
  private enum Job {
    case sweep(SweepRange?, @Sendable (Result<SweepChange, AnalyzerError>) -> Void)

    func fail(_ reason: String) {
      switch self {
      case let .sweep(_, done): done(.failure(.unavailable(reason)))
      }
    }
  }

  private enum Mode {
    /// The firmware's live screen (`refresh on`): every region as it is drawn.
    case stream
    /// A capture after every sweep (`waitscan 1`, `capture rle`), for firmware without the live screen.
    case poll
  }

  private static let prompt = Array("ch> ".utf8)
  private var port: SerialPort?
  private var instrument = Instrument.tinySA
  private var screen: Framebuffer?
  private var stream: ScreenStream?
  private var mode = Mode.stream
  /// Bytes read and not yet used (replies before the live screen starts).
  private var pending: [UInt8] = []
  private var dirty = false
  private var lastFrame = Date.distantPast
  private var lastChecks = Date.distantPast
  private var lastWatching = Date.distantPast
  private var feedPicture: Date?
  /// The usual time between a feeder's pictures: a picture is stale after three of them (and at least 6 s), so a feeder
  /// with slow sweeps isn't shown as stopped between pictures.
  private var feedInterval: TimeInterval = 0
  private var deviceSource = ""
  private var lastStatus: Status?
  /// Regions of the live screen skipped so far (damaged by a command's echo), and when that was last looked at.
  private var skippedSeen = 0
  private var lastSkipCheck = Date.distantPast
  private var lastTap = Date.distantPast
  /// Where a touch went down that hasn't been released yet: the analyzer waits for the release, with its sweep stopped,
  /// so it is always sent before letting go.
  private var touchHeld: (x: Int, y: Int)?
  /// When the live screen last brought bytes: a stream that has gone quiet is checked (a Mac that slept turns it off).
  private var lastData = Date.distantPast
  /// The last feeder seen, and when: a moment's unreadable state.json doesn't end its turn.
  private var lastFeeder: (state: FeedState, seen: Date)?
  private var lastYieldCheck = Date.distantPast
  private var yieldAsked = false
  /// When `refresh on` went out to a quiet stream, until its echo comes back; and the latest text between regions.
  private var probeSent: Date?
  private var recentText = ""
  /// The screen changed and isn't in a frame yet: since when, and when last. A sweep is drawn in a burst of regions a
  /// few milliseconds apart, then nothing until the next sweep, so a frame is taken once the regions pause.
  private var frameDue: Date?
  private var lastChange = Date.distantPast

  private var isStopping: Bool { lock.locked { stopping } }

  private func run() {
    while !isStopping {
      let now = Date()
      if now.timeIntervalSince(lastWatching) >= 1 {
        FeedState.touchWatching()
        lastWatching = now
      }
      // A feeding program comes first, then one that asked to borrow the analyzer.
      if port == nil || now.timeIntervalSince(lastChecks) >= 0.25 {
        lastChecks = now
        let current = FeedState.current()
        if let current { lastFeeder = (current, now) }
        if let feed = current ?? recentFeeder(now) {
          letGo()
          failJobs("\(feed.name ?? "Another program") has the tinySA and feeds its pictures: change it there")
          showFeed(feed)
          pause(0.25)
          continue
        }
        lastFeeder = nil
        feedPicture = nil
        feedInterval = 0
        if let request = BorrowRequest.current() {
          letGo()
          failJobs("The tinySA is lent to \(request.name)")
          publish(
            Status(
              source: deviceSource, note: "The tinySA is lent to \(request.name). Its screen comes back when it's done.",
              controllable: false))
          pause(0.5)
          continue
        }
      }
      if port == nil {
        failJobs(lastStatus?.note ?? "No tinySA on USB")
        connect()
      } else {
        pump()
      }
    }
    failJobs("tinySA Screen is quitting")
    letGo()
    FeedState.stopWatching()
    finished.signal()
  }

  /// The feeder seen within the last 1.5 s, while its state.json can't be read (a feeder writing it in place).
  private func recentFeeder(_ now: Date) -> FeedState? {
    guard let lastFeeder, now.timeIntervalSince(lastFeeder.seen) < 1.5,
      FileManager.default.fileExists(atPath: Integration.stateFile.path)
    else { return nil }
    return lastFeeder.state
  }

  private func connect() {
    guard let device = DeviceFinder.instruments().first else {
      publish(Status(source: "", note: "Connect a tinySA by USB and switch it on.", controllable: false))
      pause(1)
      return
    }
    let users = PortUsers.of(device.path)
    if !users.isEmpty {
      publish(inUse(by: users.joined(separator: ", ")))
      pause(2)
      return
    }
    do {
      port = try SerialPort(path: device.path)
      instrument = device.instrument
      yieldAsked = false
      try greet()
      let version = try command("version").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
      var model = try command("info").split(whereSeparator: \.isNewline).first.map(String.init) ?? device.product
      if model.hasPrefix("Board: ") { model = String(model.dropFirst("Board: ".count)) }  // a NanoVNA's info
      let size = instrument == .tinySA ? ScreenSize.of(version: version) : ScreenSize.of(nanoVNA: device.product)
      let screen = Framebuffer(size: size)
      try Capture.apply(capture(size), to: screen)
      self.screen = screen
      deviceSource = [model, Self.shortVersion(version)].filter { !$0.isEmpty }.joined(separator: " · ")
      mode = try startStream() ? .stream : .poll
      publishFrame()
      recordFrame()
      publish(
        Status(
          source: deviceSource, note: nil, controllable: true, tunable: instrument == .tinySA && size == .ultra,
          instrument: instrument))
    } catch Failure.interrupted {
      letGo()
    } catch SerialPort.Failure.busy {
      dropPort()
      publish(inUse(by: nil))
      pause(2)
    } catch {
      dropPort()
      publish(
        Status(
          source: device.product,
          note: "The tinySA doesn't answer over USB. Switch it off and on, or plug its cable in again.",
          controllable: false))
      pause(2)
    }
  }

  private func inUse(by names: String?) -> Status {
    let who = names.map { "another program (\($0))" } ?? "another program"
    return Status(
      source: "", note: "The tinySA is in use by \(who). Its screen shows here once that program lets go of it.",
      controllable: false)
  }

  /// "v1.4-252" from "tinySA4_v1.4-252-g2b4aa51"; "v1.2.52" from a NanoVNA's "1.2.52".
  static func shortVersion(_ version: String) -> String {
    if let first = version.first, first.isNumber { return "v" + version }
    guard let v = version.range(of: "_v") else { return version }
    let rest = version[v.upperBound...]
    let parts = rest.split(separator: "-")
    return "v" + parts.prefix(2).joined(separator: "-")
  }

  /// The live screen and the taps, or a sweep and a capture, until something goes wrong.
  private func pump() {
    guard let port, let screen else { return }
    do {
      try sendTaps()
      if touchHeld == nil { try runJobs() }
      switch mode {
      case .stream:
        let bytes = try port.read(timeout: 0.03)
        if !bytes.isEmpty {
          lastData = Date()
          draw(bytes)
        }
        try checkStream()
      case .poll:
        if instrument == .tinySA, touchHeld == nil {
          _ = try command("waitscan 1", timeout: 30)
        } else {
          // A NanoVNA has no waitscan, and a tinySA doesn't sweep while a touch is down: a picture every half second.
          try waitWithoutReading(0.5)
        }
        try Capture.apply(capture(screen.size), to: screen)
        dirty = true
        recordFrame()
      }
      if dirty, Date().timeIntervalSince(lastFrame) >= 1.0 / 25 { publishFrame() }
      recordFrameWhenDrawn()
    } catch Failure.interrupted {
      letGo()
    } catch {
      dropPort()
      publish(Status(source: "", note: "The tinySA went away. Plug it in again, or switch it on.", controllable: false))
      pause(1)
    }
  }

  private func draw<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
    guard let screen else { return }
    stream?.feed(bytes) { event in
      if case let .text(text) = event {
        // The echo of a `refresh on` sent to a quiet stream: the console answers.
        recentText = String((recentText + text).suffix(64))
        if probeSent != nil, recentText.contains("refresh on") {
          probeSent = nil
          recentText = ""
        }
        return
      }
      screen.apply(event)
      changed()
    }
  }

  /// The screen changed: the window shows it soon, and a frame is taken once the sweep is drawn.
  private func changed() {
    dirty = true
    lastChange = Date()
    if frameDue == nil { frameDue = lastChange }
  }

  /// A frame once the regions pause for 100 ms, a sweep drawn (within one they come a few milliseconds apart, with a
  /// pause of tens of milliseconds while a big waterfall scrolls; between sweeps the analyzer measures, about half a
  /// second at its usual speed), or every half second while they keep coming.
  private func recordFrameWhenDrawn() {
    guard let frameDue else { return }
    let now = Date()
    if now.timeIntervalSince(lastChange) >= 0.1 || now.timeIntervalSince(frameDue) >= 0.5 { recordFrame() }
  }

  private func recordFrame() {
    frameDue = nil
    guard let screen else { return }
    took(screen.snapshot(), at: Date())
  }

  /// A frame: to the recorder, and whoever else wants frames.
  private func took(_ snapshot: Snapshot, at time: Date) {
    recorder.add(snapshot, at: time)
    for handler in lock.locked({ Array(frameHandlers.values) }) { handler(snapshot, time) }
  }

  private func sendTaps() throws {
    let lines = lock.locked { () -> [String] in
      defer { taps.removeAll() }
      return taps
    }
    if !lines.isEmpty { lastTap = Date() }
    for line in lines {
      let parts = line.split(separator: " ")
      if parts.count == 3, let x = Int(parts[1]), let y = Int(parts[2]) {
        touchHeld = parts[0] == "touch" ? (x, y) : nil
      }
      if mode == .poll {
        _ = try command(line)
      } else {
        try port?.write(line + "\r")  // its echo comes back between regions, as text
      }
    }
  }

  // MARK: The console

  /// A clean console: a live screen left on by a program that ended is turned off first, then a prompt.
  private func greet() throws {
    guard let port else { return }
    try port.write("refresh off\r")
    _ = try readFor(0.3)
    port.discardInput()
    pending.removeAll()
    try port.write("\r")
    _ = try readUntil(Self.prompt, timeout: 2)
    // A touch left down by a program that ended mid-tap keeps the analyzer waiting, its sweep stopped: a release frees
    // it, and does nothing when no touch is down.
    _ = try command("release")
    pending.removeAll()
  }

  /// Looks after the live screen every second (not in the middle of a tap). A region skipped (a command's echo landed
  /// inside it) leaves that part of the copy stale until the analyzer happens to draw it again: a whole capture puts it
  /// right. A stream quiet for 3 s may be a paused analyzer or a slow sweep, but also one whose live screen went off (it
  /// turns it off when the Mac sleeps): `refresh on` turns it back on, runs beside the sweep without cutting it short,
  /// and its echo shows the console still answers; without one the analyzer is connected again.
  private func checkStream() throws {
    let now = Date()
    guard now.timeIntervalSince(lastSkipCheck) >= 1, now.timeIntervalSince(lastTap) >= 0.5, touchHeld == nil,
      let stream, let port
    else { return }
    lastSkipCheck = now
    if let probeSent {
      if now.timeIntervalSince(probeSent) > 2 { throw Failure.noAnswer }
      return
    }
    if stream.skipped > skippedSeen {
      try resync()
    } else if now.timeIntervalSince(lastData) >= 3 {
      try port.write("refresh on\r")
      probeSent = now
      lastData = now
    }
  }

  /// A whole capture onto the copy, between the live screen off and on again.
  private func resync() throws {
    try pauseStream()
    try resumeStream()
  }

  /// The live screen off, and whatever was still on its way drawn, up to the echo of `refresh off`: a clean console for
  /// commands.
  private func pauseStream() throws {
    guard let port, let screen else { return }
    try port.write("refresh off\r")
    let deadline = Date() + 1
    var seen = ""
    // Up to the prompt after the echo: a prompt read later would be taken for the next command's reply.
    while Date() < deadline {
      if let echo = seen.range(of: "refresh off"), seen[echo.upperBound...].contains("ch> ") { break }
      self.stream?.feed(try port.read(timeout: 0.05)) { event in
        if case let .text(text) = event { seen += text } else { screen.apply(event) }
      }
    }
    pending.removeAll()
  }

  /// A whole capture onto the copy (the analyzer drew meanwhile), then the live screen on again.
  private func resumeStream() throws {
    guard let screen else { return }
    try Capture.apply(capture(screen.size), to: screen)
    changed()
    if try !startStream() { mode = .poll }
  }

  // MARK: Jobs

  private func runJobs() throws {
    let waiting = lock.locked { () -> [Job] in
      defer { jobs.removeAll() }
      return jobs.map(\.job)
    }
    for (i, job) in waiting.enumerated() {
      do {
        switch job {
        case let .sweep(target, done): done(.success(try changeSweep(target)))
        }
      } catch {
        job.fail(error is Failure ? "The tinySA didn't answer" : "\(error)")
        for later in waiting.dropFirst(i + 1) { later.fail("The tinySA didn't answer") }
        throw error
      }
    }
  }

  private func failJobs(_ reason: String) {
    let waiting = lock.locked { () -> [Job] in
      defer { jobs.removeAll() }
      return jobs.map(\.job)
    }
    for job in waiting { job.fail(reason) }
  }

  /// The span before, then set to `target` and read back.
  private func changeSweep(_ target: SweepRange?) throws -> SweepChange {
    if mode == .stream { try pauseStream() }
    let before = try readSweep()
    var after = before
    if let target, !target.matches(before) {
      for line in target.commands(from: before) { _ = try command(line) }
      after = try readSweep()
    }
    if mode == .stream {
      try resumeStream()
    } else {
      changed()
    }
    return SweepChange(before: before, after: after)
  }

  private func readSweep() throws -> SweepRange {
    let reply = try command("sweep")
    guard let range = SweepRange(reply: reply) else { throw Failure.unexpected("sweep: \(reply)") }
    return range
  }

  /// Turns the live screen on: false on firmware without it ("refresh?").
  private func startStream() throws -> Bool {
    guard let port, let screen else { return false }
    pending.removeAll()
    try port.write("refresh on\r")
    let reply = try readFor(0.3)
    if String(decoding: reply, as: UTF8.self).contains("refresh?") {
      pending.removeAll()
      return false
    }
    stream = ScreenStream(size: screen.size)
    skippedSeen = 0
    lastData = Date()
    probeSent = nil
    recentText = ""
    let early = pending
    pending.removeAll()
    draw(early)  // regions may have come with the reply
    return true
  }

  /// A command's reply: the text after its echo, up to the prompt.
  private func command(_ line: String, timeout: TimeInterval = 3) throws -> String {
    guard let port else { throw Failure.noAnswer }
    pending.removeAll()
    try port.write(line + "\r")
    let end = try readUntil(Self.prompt, timeout: timeout)
    var reply = String(decoding: pending[0..<(end - Self.prompt.count)], as: UTF8.self)
    pending.removeFirst(end)
    if reply.hasPrefix(line) { reply = String(reply.dropFirst(line.count)) }
    return reply.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The screen (`capture rle`): its bytes read by their length, since the prompt's bytes can occur inside them.
  private func capture(_ size: ScreenSize) throws -> Data {
    guard let port else { throw Failure.noAnswer }
    let echo = Array("capture rle\r\n".utf8)
    pending.removeAll()
    try port.write("capture rle\r")
    let deadline = Date() + 10
    var length: Int?
    while true {
      if pending.count >= echo.count {
        guard pending.starts(with: echo) else { throw Failure.unexpected("capture") }
        let body = pending[echo.count...]
        if length == nil { length = Capture.length(of: body, size: size) }
        if let length, body.count >= length + Self.prompt.count { break }
      }
      guard Date() < deadline else { throw Failure.noAnswer }
      try checkYield()
      pending += try port.read(timeout: 0.1)
    }
    let data = Data(pending[echo.count..<(echo.count + length!)])
    pending.removeAll()
    return data
  }

  /// Reads into `pending` until it holds `marker`: the index just past it.
  private func readUntil(_ marker: [UInt8], timeout: TimeInterval) throws -> Int {
    guard let port else { throw Failure.noAnswer }
    let deadline = Date() + timeout
    while true {
      if let found = pending.firstRange(of: marker) { return found.upperBound }
      guard Date() < deadline else { throw Failure.noAnswer }
      try checkYield()
      pending += try port.read(timeout: 0.05)
    }
  }

  /// Throws `interrupted` when the app is quitting or another program asked for the analyzer (looked at every quarter
  /// second), so a long wait (a slow sweep, a capture) doesn't hold the analyzer from it.
  private func checkYield() throws {
    if isStopping { throw Failure.interrupted }
    let now = Date()
    if !yieldAsked, now.timeIntervalSince(lastYieldCheck) >= 0.25 {
      lastYieldCheck = now
      yieldAsked = BorrowRequest.current() != nil || FeedState.current() != nil
    }
    if yieldAsked { throw Failure.interrupted }
  }

  /// Waits, ready to let go if asked meanwhile.
  private func waitWithoutReading(_ seconds: TimeInterval) throws {
    let deadline = Date() + seconds
    while Date() < deadline {
      try checkYield()
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  /// Everything that comes within `seconds` (also kept in `pending`).
  private func readFor(_ seconds: TimeInterval) throws -> [UInt8] {
    guard let port else { throw Failure.noAnswer }
    let deadline = Date() + seconds
    var got: [UInt8] = []
    while Date() < deadline {
      let bytes = try port.read(timeout: 0.05)
      got += bytes
      pending += bytes
    }
    return got
  }

  /// Lets go of the analyzer as it should: its live screen off (or its own sweeping back on, after polling), then the
  /// port closed.
  private func letGo() {
    guard let port else { return }
    publishControllable(false)
    if let held = touchHeld {
      try? port.write("release \(held.x) \(held.y)\r")
      touchHeld = nil
    }
    switch mode {
    case .stream:
      if stream != nil, (try? port.write("refresh off\r")) != nil {
        // Regions still on their way, then the echo: wait for it so nothing is cut off mid-region.
        let deadline = Date() + 1
        var seen = ""
        while Date() < deadline, !seen.contains("refresh off") {
          guard let bytes = try? port.read(timeout: 0.05) else { break }
          stream?.feed(bytes) { event in
            if case let .text(text) = event { seen += text }
          }
        }
      }
    case .poll:
      if instrument == .tinySA {  // its sweeping, paused by waitscan, back on
        try? port.write("resume\r")
        _ = try? readFor(0.3)
      }
    }
    dropPort()
  }

  private func dropPort() {
    port?.close()
    port = nil
    stream = nil
    screen = nil
    pending.removeAll()
    dirty = false
    frameDue = nil
    touchHeld = nil
    lock.locked { taps.removeAll() }  // clicks made while letting go aren't replayed on the next connection
  }

  // MARK: Feeding

  private func showFeed(_ feed: FeedState) {
    if let (image, date) = FeedState.picture(newerThan: feedPicture) {
      if let previous = feedPicture, date > previous, date.timeIntervalSince(previous) < 60 {
        let interval = date.timeIntervalSince(previous)
        feedInterval = feedInterval == 0 ? interval : 0.7 * feedInterval + 0.3 * interval
      }
      feedPicture = date
      // A picture older than a live one can be (left on the disk by an earlier run) is shown, as the window does with
      // its note, but not recorded as if it were live.
      if Date().timeIntervalSince(date) < max(6, 3 * feedInterval), let snapshot = Snapshot(image) {
        took(snapshot, at: date)
      }
      if delegate != nil {
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.delegate?.session(self, show: image)
        }
      }
    }
    let name = feed.name ?? "another program"
    let note: String?
    switch feed.state {
    case "lent":
      note = "The tinySA is lent to \(feed.program ?? "another program"). Its screen comes back when it's done."
    case "waiting":
      note = "Waiting for the tinySA: switched off, or its USB cable out."
    default:
      if let feedPicture, Date().timeIntervalSince(feedPicture) < max(6, 3 * feedInterval) {
        note = nil
      } else if let feedPicture {
        note = "No new picture from \(name) since \(feedPicture.formatted(date: .omitted, time: .standard))."
      } else {
        note = "Waiting for a picture from \(name)…"
      }
    }
    publish(Status(source: "Pictures from \(name)", note: note, controllable: false))
  }

  // MARK: Telling the window

  private func publish(_ status: Status) {
    guard status != lastStatus else { return }
    lastStatus = status
    lock.locked { currentStatus = status }
    guard delegate != nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.delegate?.session(self, status: status)
    }
  }

  /// Clicks stop reaching the analyzer at once (the full status follows).
  private func publishControllable(_ controllable: Bool) {
    guard var status = lastStatus, status.controllable != controllable else { return }
    status.controllable = controllable
    status.tunable = status.tunable && controllable
    publish(status)
  }

  private func publishFrame() {
    dirty = false
    lastFrame = Date()
    guard delegate != nil, let image = screen?.image() else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.delegate?.session(self, show: image)
    }
  }

  private func pause(_ seconds: TimeInterval) {
    let deadline = Date() + seconds
    while Date() < deadline, !isStopping { Thread.sleep(forTimeInterval: 0.05) }
  }
}

extension NSLock {
  /// `body` with the lock held (NSLock's own `withLock` needs macOS 14).
  func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

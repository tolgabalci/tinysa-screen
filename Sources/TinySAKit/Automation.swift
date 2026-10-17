import Foundation

/// What other programs can ask of tinySA Screen (the command line, AI agents, scripts): record a GIF for some seconds,
/// capture the seconds the app keeps, save a screenshot, or say what it sees. The same for the open app (asked through
/// its control socket) and for the command line on its own (its own session, without a window).
///
/// A recording or screenshot starts only from a live picture: one that stopped coming (the analyzer unplugged, a feeder
/// gone quiet) is waited for, then refused with the reason, never recorded stale. Whatever happens while it records is
/// in the reply's notes.
public final class Automation: @unchecked Sendable {
  public let session: Session
  /// Whether this is the open app (with its window), or the command line alone.
  public let isApp: Bool
  public let version: String
  /// Says something in the window: a recording starting or saved.
  public var announce: ((String) -> Void)?
  /// The names of the programs recording now, for the window's title.
  public var onRecordingsChange: (([String]) -> Void)?
  /// How long to wait for a live picture before giving up.
  public var pictureWait: TimeInterval = 15

  private let lock = NSLock()
  private var recordingNames: [UUID: String] = [:]

  public init(session: Session, isApp: Bool, version: String) {
    self.session = session
    self.isApp = isApp
    self.version = version
  }

  /// Carries out a request; `cancelled` is asked while it waits (the asking program went away, Control-C).
  public func handle(_ request: ControlRequest, cancelled: () -> Bool = { false }) -> ControlReply {
    switch request.command {
    case "record": return record(request, cancelled: cancelled)
    case "capture": return capture(request)
    case "screenshot": return screenshot(request, cancelled: cancelled)
    case "status": return status()
    default:
      return .failure("Unknown command \"\(request.command)\": record, capture, screenshot or status")
    }
  }

  // MARK: Commands

  private func record(_ request: ControlRequest, cancelled: () -> Bool) -> ControlReply {
    guard let seconds = request.seconds, seconds >= 1, seconds <= FrameRecorder.longest else {
      return .failure("How long to record: 1 to \(Int(FrameRecorder.longest)) seconds")
    }
    let output: URL
    switch Self.output(request.output) {
    case .success(let url): output = url
    case .failure(let message): return message
    }
    if let failure = waitForPicture(cancelled: cancelled) { return failure }
    let recorder = session.recorder
    let id = recorder.begin()
    let name = request.name ?? "another program"
    changeRecordings { $0[id] = name }
    announce?("Recording \(Int(seconds)) s for \(name)…")
    var notes: [String] = []
    var lastNote: String?
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if cancelled() {
        _ = recorder.end(id)
        changeRecordings { $0[id] = nil }
        announce?("Recording for \(name) cancelled")
        return .failure("Cancelled")
      }
      let note = session.status.note
      if note != lastNote {
        if let note { notes.append("\(Self.clock(Date())): \(note)") }
        else if lastNote != nil { notes.append("\(Self.clock(Date())): the picture came back") }
        lastNote = note
      }
      Thread.sleep(forTimeInterval: min(0.1, max(0, end.timeIntervalSinceNow)))
    }
    let clip = recorder.end(id)
    changeRecordings { $0[id] = nil }
    guard let clip else { return .failure("Nothing was recorded: no picture came") }
    var reply = save(clip, request: request, to: output)
    if reply.ok {
      if !notes.isEmpty { reply.notes = notes }
      announce?("Saved \(output.lastPathComponent) for \(name)")
    }
    return reply
  }

  private func capture(_ request: ControlRequest) -> ControlReply {
    guard isApp else {
      return .failure(
        "tinySA Screen isn't open: capture saves the seconds its window keeps. Open the app, or use record.")
    }
    let output: URL
    switch Self.output(request.output) {
    case .success(let url): output = url
    case .failure(let message): return message
    }
    let recorder = session.recorder
    guard recorder.keepRecent > 0 else {
      return .failure("tinySA Screen keeps no seconds: turn on \"Keep the latest seconds\" in its Settings")
    }
    if let seconds = request.seconds, seconds < 1 { return .failure("How many seconds: at least 1") }
    guard let clip = recorder.recent(request.seconds), clip.duration >= 1 else {
      return .failure("Nothing to capture yet: no picture has come")
    }
    var reply = save(clip, request: request, to: output)
    if reply.ok {
      if let seconds = request.seconds, seconds > clip.duration + 0.5 {
        reply.notes = ["Only \(Int(clip.duration)) seconds were kept"]
      }
      announce?("Saved \(output.lastPathComponent) for \(request.name ?? "another program")")
    }
    return reply
  }

  private func screenshot(_ request: ControlRequest, cancelled: () -> Bool) -> ControlReply {
    let output: URL
    switch Self.output(request.output) {
    case .success(let url): output = url
    case .failure(let message): return message
    }
    if let failure = waitForPicture(cancelled: cancelled) { return failure }
    guard let (snapshot, time) = session.recorder.latestSnapshot() else { return .failure("No picture yet") }
    let scale = request.scale == 2 ? 2 : 1
    let picture = scale == 1 ? snapshot : GIF.still(snapshot, at: time, options: GIFOptions(scale: 2, showsDate: false, showsTime: false))
    guard let png = picture.png() else { return .failure("The picture couldn't be made") }
    do {
      try png.write(to: output, options: .atomic)
    } catch {
      return .failure("Couldn't write \(output.path): \(error.localizedDescription)")
    }
    var reply = ControlReply(ok: true)
    reply.file = output.path
    reply.bytes = png.count
    reply.width = picture.width
    reply.height = picture.height
    reply.start = Self.iso(time)
    reply.source = session.status.source
    return reply
  }

  private func status() -> ControlReply {
    let status = session.status
    var reply = ControlReply(ok: true)
    reply.app = isApp
    reply.version = version
    reply.devices = DeviceFinder.tinySAs().map { "\($0.product) at \($0.path)" }
    if let feed = FeedState.current() { reply.feeder = "\(feed.name ?? "a program") (\(feed.state))" }
    if let borrow = BorrowRequest.current() { reply.borrower = "\(borrow.name) (process \(borrow.pid))" }
    guard isApp else { return reply }
    reply.source = status.source
    reply.picture = status.note == nil
    reply.usb = status.controllable
    reply.note = status.note
    reply.keptSeconds = session.recorder.keepRecent
    reply.availableSeconds = (session.recorder.recentSeconds() * 10).rounded() / 10
    reply.recordings = session.recorder.recordingCount
    return reply
  }

  // MARK: Helpers

  /// Waits for a live picture: nil when there is one, else why there isn't.
  private func waitForPicture(cancelled: () -> Bool) -> ControlReply? {
    let deadline = Date().addingTimeInterval(pictureWait)
    while true {
      if session.status.note == nil, session.recorder.hasSnapshot { return nil }
      if cancelled() { return .failure("Cancelled") }
      if Date() > deadline {
        return .failure("No picture: \(session.status.note ?? "nothing came from the tinySA")")
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
  }

  private func save(_ clip: Clip, request: ControlRequest, to output: URL) -> ControlReply {
    var options = GIFOptions(
      scale: request.scale == 1 ? 1 : 2, showsDate: request.date ?? true, showsTime: request.time ?? true)
    let source = session.status.source
    options.comment = [source.isEmpty ? nil : source, "\(Self.iso(clip.start)) to \(Self.iso(clip.end))", "tinySA Screen \(version)"]
      .compactMap { $0 }.joined(separator: " · ")
    guard let gif = GIF.make(clip, options: options) else { return .failure("The GIF couldn't be made") }
    do {
      try gif.data.write(to: output, options: .atomic)
    } catch {
      return .failure("Couldn't write \(output.path): \(error.localizedDescription)")
    }
    var reply = ControlReply(ok: true)
    reply.file = output.path
    reply.bytes = gif.data.count
    reply.width = gif.width
    reply.height = gif.height
    reply.seconds = (gif.duration * 100).rounded() / 100
    reply.frames = clip.frames.count
    reply.images = gif.images
    reply.start = Self.iso(clip.start)
    reply.end = Self.iso(clip.end)
    reply.source = source
    return reply
  }

  private func changeRecordings(_ change: (inout [UUID: String]) -> Void) {
    let names = lock.locked { () -> [String] in
      change(&recordingNames)
      return recordingNames.values.sorted()
    }
    onRecordingsChange?(names)
  }

  /// The output path: absolute, in a folder that exists, not a folder itself.
  static func output(_ path: String?) -> Result<URL, ControlReply> {
    guard let path, !path.isEmpty else { return .failure(.failure("Where to save it: an output path")) }
    let expanded = (path as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else { return .failure(.failure("The output path must be absolute: \(path)")) }
    let url = URL(fileURLWithPath: expanded).standardizedFileURL
    var isFolder: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
      return .failure(.failure("\(url.path) is a folder: give a file name"))
    }
    let folder = url.deletingLastPathComponent().path
    guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
      return .failure(.failure("No folder \(folder)"))
    }
    return .success(url)
  }

  static func iso(_ date: Date) -> String {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    format.timeZone = .current
    return format.string(from: date)
  }

  static func clock(_ date: Date) -> String {
    let format = DateFormatter()
    format.dateFormat = "HH:mm:ss"
    return format.string(from: date)
  }
}

extension ControlReply: Error {}

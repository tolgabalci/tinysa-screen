import Foundation

/// A frame of a recording: the screen at a moment, packed (LZFSE) to a few tens of kilobytes.
public struct RecordedFrame: Sendable {
  public let time: Date
  public let width: Int
  public let height: Int
  private let packed: Data

  init(_ snapshot: Snapshot, at time: Date) {
    self.time = time
    width = snapshot.width
    height = snapshot.height
    let bytes = snapshot.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
    packed = (try? (bytes as NSData).compressed(using: .lzfse) as Data) ?? bytes
  }

  public func snapshot() -> Snapshot? {
    let count = width * height
    var bytes = packed
    if bytes.count != count * 4 {
      guard let unpacked = try? (packed as NSData).decompressed(using: .lzfse) as Data else { return nil }
      bytes = unpacked
    }
    guard bytes.count == count * 4 else { return nil }
    let pixels = bytes.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    return Snapshot(width: width, height: height, pixels: pixels)
  }

  /// Bytes it takes in memory.
  public var size: Int { packed.count }
}

/// A stretch of the screen, recorded: its frames in order, the first being the screen as it was at `start`.
public struct Clip: Sendable {
  public let frames: [RecordedFrame]
  public let start: Date
  public let end: Date

  /// The frames from the screen as it was at `start` to `end`; `start` moves up to the first frame when there is none
  /// before it. Nil without a frame.
  public init?(frames all: [RecordedFrame], from start: Date, to end: Date) {
    let from = all.lastIndex { $0.time <= start } ?? all.firstIndex { $0.time > start } ?? all.endIndex
    let frames = all[from...].prefix { $0.time <= end }
    guard let first = frames.first else { return nil }
    self.frames = Array(frames)
    self.start = max(start, first.time)
    self.end = max(end, self.start)
  }

  public var duration: TimeInterval { end.timeIntervalSince(start) }

  /// Its last `seconds`.
  public func last(_ seconds: TimeInterval) -> Clip {
    Clip(frames: frames, from: max(start, end.addingTimeInterval(-seconds)), to: end) ?? self
  }

  /// The frame on the screen at a moment of it.
  public func frame(at moment: Date) -> RecordedFrame? {
    frames.last { $0.time <= moment } ?? frames.first
  }
}

/// Keeps frames of the screen for GIFs: those of a recording from when it begins until it ends (at most `longest`
/// seconds, or as long as it asks, up to `longestAllowed`), and with `keepRecent` on, the latest seconds all the time,
/// so a moment just seen can still be saved, and a recording can start before it began. Frames come from the
/// session's thread, after each sweep is drawn or each picture fed; a frame like the one before isn't kept twice. Safe
/// to use from any thread.
public final class FrameRecorder: @unchecked Sendable {
  /// The longest a recording runs unless it asks for longer: what the command line's recordings are held to.
  public static let longest: TimeInterval = 120
  /// The longest a recording may ask to run, and the most seconds kept.
  public static let longestAllowed: TimeInterval = 300
  /// A frame within this of the one before replaces it: a new frame every 50 ms is more than a GIF can show.
  static let closest: TimeInterval = 0.05

  private let lock = NSLock()
  private var frames: [RecordedFrame] = []
  /// The screen as it is now, kept as it is even when nothing records: a recording begins with it.
  private var latest: (snapshot: Snapshot, time: Date, stored: Bool)?
  private var keepSeconds: TimeInterval = 0
  private struct Recording {
    /// Where its clip starts: when it began, or before, as far back as the seconds kept then went.
    var from: Date
    var began: Date
    var longest: TimeInterval
  }
  private var recordings: [UUID: Recording] = [:]

  public init() {}

  /// How many of the latest seconds are kept, for capturing later and for a recording to start before it began: 0 for
  /// none, at most `longestAllowed`.
  public var keepRecent: TimeInterval {
    get { lock.locked { keepSeconds } }
    set {
      lock.locked {
        keepSeconds = min(max(newValue, 0), Self.longestAllowed)
        if keepSeconds > 0 { storeLatest() }
        prune(now: Date())
      }
    }
  }

  /// The screen at a moment. Moments only go forward: a frame older than the latest (an old picture a feeding program
  /// left on the disk, say) is left out, so it can't take the place of newer ones.
  public func add(_ snapshot: Snapshot, at time: Date) {
    lock.locked {
      if let latest, time < latest.time { return }
      if let latest, latest.snapshot == snapshot { return }
      if let size = frames.last.map({ ($0.width, $0.height) }), size != (snapshot.width, snapshot.height) {
        frames.removeAll()  // another screen: frames of two sizes don't make one GIF
      }
      latest = (snapshot, time, false)
      if keepSeconds > 0 || !recordings.isEmpty { storeLatest() }
      prune(now: time)
    }
  }

  /// Whether there is a picture to record.
  public var hasSnapshot: Bool { lock.locked { latest != nil } }

  /// The screen as it is now, and since when.
  public func latestSnapshot() -> (snapshot: Snapshot, time: Date)? {
    lock.locked { latest.map { ($0.snapshot, $0.time) } }
  }

  /// Recordings running now.
  public var recordingCount: Int { lock.locked { recordings.count } }

  /// Begins a recording: its frames are kept, from the screen as it is now, until it ends, `longest` seconds on at
  /// most (up to `longestAllowed`). Its clip starts `before` seconds earlier, as far back as the latest seconds kept
  /// go: the window's Record takes them all, to trim later.
  public func begin(at time: Date = Date(), before: TimeInterval = 0, longest: TimeInterval = FrameRecorder.longest)
    -> UUID
  {
    lock.locked {
      let id = UUID()
      let back = min(max(before, 0), keepSeconds)
      recordings[id] = Recording(
        from: time.addingTimeInterval(-back), began: time, longest: min(max(longest, 1), Self.longestAllowed))
      storeLatest()
      return id
    }
  }

  /// When a recording began.
  public func started(_ id: UUID) -> Date? { lock.locked { recordings[id]?.began } }

  /// Where a recording's clip starts so far: as far before it began as it asked, or at the first frame kept, if that
  /// came later (the seconds kept hadn't been coming that long).
  public func clipStart(_ id: UUID) -> Date? {
    lock.locked {
      guard let recording = recordings[id] else { return nil }
      return max(recording.from, min(frames.first?.time ?? recording.began, recording.began))
    }
  }

  /// Ends a recording: its clip, from as far before it began as it asked (and the frames went) to now, at most its
  /// `longest` seconds after it began; nil if no frame came.
  public func end(_ id: UUID, at time: Date = Date()) -> Clip? {
    lock.locked {
      guard let recording = recordings.removeValue(forKey: id) else { return nil }
      let end = min(time, recording.began.addingTimeInterval(recording.longest))
      let clip = Clip(frames: frames, from: recording.from, to: end)
      prune(now: time)
      return clip
    }
  }

  /// The latest seconds kept (`keepRecent`), or the last `seconds` of them; nil when none are kept.
  public func recent(_ seconds: TimeInterval? = nil, at time: Date = Date()) -> Clip? {
    lock.locked {
      guard keepSeconds > 0 else { return nil }
      let span = min(seconds ?? keepSeconds, keepSeconds)
      return Clip(frames: frames, from: time.addingTimeInterval(-span), to: time)
    }
  }

  /// How many seconds `recent` gives now: `keepRecent`, or less while the frames haven't been coming that long.
  public func recentSeconds(at time: Date = Date()) -> TimeInterval {
    lock.locked {
      guard keepSeconds > 0, let first = frames.first else { return 0 }
      return max(0, min(keepSeconds, time.timeIntervalSince(first.time)))
    }
  }

  /// Bytes the kept frames take.
  public var memory: Int { lock.locked { frames.reduce(0) { $0 + $1.size } } }

  private func storeLatest() {
    guard let current = latest, !current.stored else { return }
    let frame = RecordedFrame(current.snapshot, at: current.time)
    if let previous = frames.last, frames.count > 1,
      (0..<Self.closest).contains(current.time.timeIntervalSince(previous.time))
    {
      frames[frames.count - 1] = frame
    } else {
      frames.append(frame)
    }
    latest?.stored = true
  }

  /// Drops frames no longer needed: those before the oldest recording's start and the seconds kept, except the one
  /// on the screen at that moment.
  private func prune(now: Date) {
    var from = recordings.values.map(\.from).min()
    if keepSeconds > 0 {
      let cut = now.addingTimeInterval(-keepSeconds)
      from = from.map { min($0, cut) } ?? cut
    }
    guard let from else {
      frames.removeAll()
      latest?.stored = false
      return
    }
    if let i = frames.lastIndex(where: { $0.time <= from }), i > 0 { frames.removeFirst(i) }
  }
}

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
/// seconds), and with `keepRecent` on, the latest seconds all the time, so a moment just seen can still be saved.
/// Frames come from the session's thread, after each sweep is drawn or each picture fed; a frame like the one before
/// isn't kept twice. Safe to use from any thread.
public final class FrameRecorder: @unchecked Sendable {
  /// The longest a GIF runs.
  public static let longest: TimeInterval = 120
  /// A frame within this of the one before replaces it: a new frame every 50 ms is more than a GIF can show.
  static let closest: TimeInterval = 0.05

  private let lock = NSLock()
  private var frames: [RecordedFrame] = []
  /// The screen as it is now, kept as it is even when nothing records: a recording begins with it.
  private var latest: (snapshot: Snapshot, time: Date, stored: Bool)?
  private var keepSeconds: TimeInterval = 0
  private var recordings: [UUID: Date] = [:]

  public init() {}

  /// How many of the latest seconds are kept for capturing later: 0 for none, at most `longest`.
  public var keepRecent: TimeInterval {
    get { lock.locked { keepSeconds } }
    set {
      lock.locked {
        keepSeconds = min(max(newValue, 0), Self.longest)
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

  /// Begins a recording: its frames are kept, from the screen as it is now, until it ends.
  public func begin(at time: Date = Date()) -> UUID {
    lock.locked {
      let id = UUID()
      recordings[id] = time
      storeLatest()
      return id
    }
  }

  /// When a recording began.
  public func started(_ id: UUID) -> Date? { lock.locked { recordings[id] } }

  /// Ends a recording: its clip, at most `longest` seconds from when it began, or nil if no frame came.
  public func end(_ id: UUID, at time: Date = Date()) -> Clip? {
    lock.locked {
      guard let start = recordings.removeValue(forKey: id) else { return nil }
      let clip = Clip(frames: frames, from: start, to: min(time, start.addingTimeInterval(Self.longest)))
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
    var from = recordings.values.min()
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

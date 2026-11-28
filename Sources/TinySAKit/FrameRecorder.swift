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

/// The peak hold from a moment on, until the next: nil while it was off.
public struct PeakMoment: Sendable {
  public let time: Date
  public let state: PeakHold.State?

  public init(time: Date, state: PeakHold.State?) {
    self.time = time
    self.state = state
  }
}

/// A stretch of the screen, recorded: its frames in order, the first being the screen as it was at `start`.
public struct Clip: Sendable {
  public let frames: [RecordedFrame]
  public let start: Date
  public let end: Date
  /// When pictures came, in order, a frame's or one the same as the frame before (which isn't kept twice): the
  /// seconds none came show in a GIF. From a little before the start, so its first second has the picture before.
  public let arrivals: [Date]
  /// The peak hold over it: as it was at the start, then each change.
  public let peaks: [PeakMoment]

  /// How long before the start the arrivals go back: further than a GIF's moments look back.
  static let arrivalsBefore: TimeInterval = 30

  /// The frames from the screen as it was at `start` to `end`; `start` moves up to the first frame when there is none
  /// before it. Nil without a frame. Without `arrivals`, pictures came with the frames only.
  public init?(
    frames all: [RecordedFrame], from start: Date, to end: Date, arrivals: [Date]? = nil, peaks: [PeakMoment] = []
  ) {
    let from = all.lastIndex { $0.time <= start } ?? all.firstIndex { $0.time > start } ?? all.endIndex
    let frames = all[from...].prefix { $0.time <= end }
    guard let first = frames.first else { return nil }
    self.frames = Array(frames)
    self.start = max(start, first.time)
    self.end = max(end, self.start)
    let earliest = self.start.addingTimeInterval(-Self.arrivalsBefore)
    let latest = self.end
    self.arrivals = (arrivals ?? all.map(\.time)).filter { $0 >= earliest && $0 <= latest }
    let clipStart = self.start
    let held = peaks.lastIndex { $0.time <= clipStart } ?? peaks.startIndex
    self.peaks = Array(peaks[held...].prefix { $0.time <= latest })
  }

  public var duration: TimeInterval { end.timeIntervalSince(start) }

  /// Its last `seconds`.
  public func last(_ seconds: TimeInterval) -> Clip {
    Clip(
      frames: frames, from: max(start, end.addingTimeInterval(-seconds)), to: end, arrivals: arrivals, peaks: peaks)
      ?? self
  }

  /// The peak hold at a moment of it: nil while it was off.
  public func peaks(at moment: Date) -> PeakHold.State? {
    var low = 0
    var high = peaks.count
    while low < high {
      let middle = (low + high) / 2
      if peaks[middle].time <= moment { low = middle + 1 } else { high = middle }
    }
    return low == 0 ? nil : peaks[low - 1].state
  }

  /// The peak hold was on at some time of it, for a GIF to draw.
  public var hasPeaks: Bool { peaks.contains { $0.state != nil } }

  /// The clip with its peak hold captured afresh from `start` (its own start unless given), as if Clear Peaks had been
  /// pressed there: none before it, then the frames from the one on the screen there added to a new hold as they came
  /// (holding each level as long as the recording's hold did, its `count` highest peaks), until the recording's own
  /// hold starts over (Clear Peaks, turned off, another period), from where it's the recording's own again. Each
  /// frame's frequencies and levels are its labels as the recording's hold had read them then (not read again); a span
  /// it read only after a moment is known from its first frame. Where the hold was off at `start`, or had just been
  /// cleared, it's the clip as it is.
  public func peaksCapturedAfresh(from start: Date? = nil, count: Int) -> Clip {
    let from = max(start ?? self.start, self.start)
    guard let then = peaks(at: from) else { return self }
    let restart = peaks.firstIndex { $0.time > from && $0.state == nil } ?? peaks.endIndex
    let until = restart < peaks.endIndex ? peaks[restart].time : .distantFuture
    let hold = PeakHold(readsLabels: false)
    hold.window = then.window
    hold.peakCount = count
    // Each span as the recording's hold first had it read, with the labels on the screen then: known from the start.
    var before: GraphScale?
    for moment in peaks[..<restart] {
      let scale = moment.state?.scale
      defer { before = scale }
      guard let scale, scale != before, let screen = frame(at: moment.time)?.snapshot() else { continue }
      hold.know(scale, for: screen)
    }
    var moments = [PeakMoment(time: self.start, state: nil)]
    let first = frames.lastIndex { $0.time <= from } ?? frames.startIndex
    var after = peaks.startIndex  // past the recording's hold as it was just after the frame
    for i in first..<frames.endIndex where frames[i].time < until {
      guard let screen = frames[i].snapshot() else { continue }
      let next = min(i + 1 < frames.endIndex ? frames[i + 1].time : .distantFuture, until)
      while after < restart, peaks[after].time < next { after += 1 }
      let time = max(frames[i].time, from)
      hold.add(screen, at: time, labels: after > peaks.startIndex ? peaks[after - 1].state?.scale : nil)
      let state = hold.state
      if moments.last?.state != state { moments.append(PeakMoment(time: time, state: state)) }
    }
    moments += peaks[restart...]
    return Clip(frames: frames, from: self.start, to: end, arrivals: arrivals, peaks: moments) ?? self
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
  /// When pictures came, the same as the one before or not, while frames are kept: for a GIF to show the seconds
  /// none came in.
  private var arrivals: [Date] = []
  /// The peak hold's changes while frames are kept, and always the latest, so a recording knows it from its start.
  private var peakMoments: [PeakMoment] = []
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
      if keepSeconds > 0 || !recordings.isEmpty { arrivals.append(time) }
      if let latest, latest.snapshot == snapshot { return }
      if let size = frames.last.map({ ($0.width, $0.height) }), size != (snapshot.width, snapshot.height) {
        frames.removeAll()  // another screen: frames of two sizes don't make one GIF
      }
      latest = (snapshot, time, false)
      if keepSeconds > 0 || !recordings.isEmpty { storeLatest() }
      prune(now: time)
    }
  }

  /// The peak hold as it is from `time` on (nil: off), for GIFs to draw it as the window does.
  public func notePeaks(_ state: PeakHold.State?, at time: Date) {
    lock.locked {
      if let last = peakMoments.last, last.state == state { return }
      peakMoments.append(PeakMoment(time: max(time, peakMoments.last?.time ?? time), state: state))
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
      let clip = Clip(frames: frames, from: recording.from, to: end, arrivals: arrivals, peaks: peakMoments)
      prune(now: time)
      return clip
    }
  }

  /// The latest seconds kept (`keepRecent`), or the last `seconds` of them; nil when none are kept.
  public func recent(_ seconds: TimeInterval? = nil, at time: Date = Date()) -> Clip? {
    lock.locked {
      guard keepSeconds > 0 else { return nil }
      let span = min(seconds ?? keepSeconds, keepSeconds)
      return Clip(
        frames: frames, from: time.addingTimeInterval(-span), to: time, arrivals: arrivals, peaks: peakMoments)
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
      arrivals.removeAll()
      if peakMoments.count > 1 { peakMoments.removeFirst(peakMoments.count - 1) }
      latest?.stored = false
      return
    }
    if let i = frames.lastIndex(where: { $0.time <= from }), i > 0 { frames.removeFirst(i) }
    let earliest = from.addingTimeInterval(-Clip.arrivalsBefore)
    if let i = arrivals.firstIndex(where: { $0 >= earliest }), i > 0 { arrivals.removeFirst(i) }
    if let i = peakMoments.lastIndex(where: { $0.time <= from }), i > 0 { peakMoments.removeFirst(i) }
  }
}

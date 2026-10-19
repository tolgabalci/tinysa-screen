import Foundation

/// The highest level the analyzer's live trace has reached at each point of the graph, held on the Mac: from the
/// screen's pixels after each sweep, so the analyzer's own traces, markers and settings are left as they are, and fed
/// pictures work as well as the analyzer on USB. Its highest peaks are found and, once the screen's labels are read,
/// given their frequency and level. The hold starts over when the span or the levels change, and can keep only the
/// latest seconds. Frames come from the session's thread; `onChange` is called there.
public final class PeakHold: @unchecked Sendable {
  public struct Peak: Equatable, Sendable {
    /// Where on the screen (its own pixels).
    public var column: Int
    public var row: Int
    /// Read from the screen's labels; nil until they are.
    public var frequency: Int64?
    public var level: Double?
  }

  public struct State: Equatable, Sendable {
    public var graph: Graph
    /// The highest row reached in each column (the top is row 0), nil where nothing has been seen.
    public var rows: [Int?]
    public var scale: GraphScale?
    /// The highest peaks, highest first.
    public var peaks: [Peak]
    /// When the hold started (over).
    public var since: Date
    /// How long it keeps a level: nil for until it starts over.
    public var window: TimeInterval?
    /// The emptiest place in the graph for a box of readouts (the analyzer writes its own markers' readouts at the
    /// top): its top left corner, in the screen's pixels.
    public var quietSpot = (x: 0, y: 0)

    public static func == (a: State, b: State) -> Bool {
      a.graph == b.graph && a.rows == b.rows && a.scale == b.scale && a.peaks == b.peaks && a.since == b.since
        && a.window == b.window && a.quietSpot == b.quietSpot
    }
  }

  /// The size of the readouts' box, in the screen's pixels, for `peakCount` peaks.
  public static func readoutSize(peaks: Int) -> (width: Int, height: Int) { (128, 10 + 8 * (peaks + 1)) }

  /// Called with each new state (or nil when reset), on the thread that added the frame or read the labels.
  public var onChange: ((State?) -> Void)?

  private let lock = NSLock()
  private var holdWindow: TimeInterval?
  private var count = 5
  private var current: State?
  /// The highest rows of each second (or one bucket for the whole hold), under the labels `rowsScale` was read from.
  private var buckets: [(second: Int, rows: [Int?])] = []
  /// The rows since the labels changed to ones not read yet, kept apart (and shown alone) until they are read: then
  /// they join the held rows under the same span and levels (a menu covered the labels for a while), or replace them
  /// under others (another span), so neither the old span's levels show over the new one nor the new one's first
  /// sweeps are lost.
  private var apart: [(second: Int, rows: [Int?])] = []
  /// When the held rows began, and the ones kept apart.
  private var heldSince: Date?
  private var apartSince: Date?
  /// The labels' fingerprint now, the spans and levels read for each fingerprint seen (a menu over the labels changes it
  /// for a while), and the ones the held rows belong to.
  private var labels: Int?
  private var scales: [Int: GraphScale] = [:]
  private var rowsScale: GraphScale?
  private var reading = false
  private var unread: (Snapshot, Graph, Int)?
  /// When labels that couldn't be read (a trace across them, say) are read again from a later frame, and the wait
  /// before the next try, doubling up to 30 s while they still can't.
  private var retry = (at: Date.distantPast, after: 2.0)
  private let readingQueue = DispatchQueue(label: "Reading the screen's labels", qos: .utility)

  public init() {}

  /// How long a level is held: nil (the default) until the hold starts over, or the latest seconds.
  public var window: TimeInterval? {
    get { lock.locked { holdWindow } }
    set {
      lock.locked {
        holdWindow = newValue.map { max(1, $0) }
        startOver()
      }
      onChange?(nil)
    }
  }

  /// How many of the highest peaks to find.
  public var peakCount: Int {
    get { lock.locked { count } }
    set { lock.locked { count = max(0, min(newValue, 9)) } }
  }

  public var state: State? { lock.locked { current } }

  /// Starts the hold over.
  public func reset() {
    lock.locked { startOver() }
    onChange?(nil)
  }

  /// Nothing held; the labels read again from the next frame (their fingerprint forgotten, the spans read kept).
  private func startOver() {
    buckets.removeAll()
    apart.removeAll()
    heldSince = nil
    apartSince = nil
    current = nil
    labels = nil
    rowsScale = nil
  }

  /// Labels read, now or before: the rows kept apart join the held ones under the same span and levels, and replace
  /// them under others.
  private func settle(_ scale: GraphScale, at time: Date) {
    defer {
      rowsScale = scale
      apart.removeAll()
      apartSince = nil
    }
    guard let rowsScale, rowsScale != scale else {
      buckets += apart
      return
    }
    buckets = apart
    heldSince = apartSince ?? time
  }

  /// `rows` into the bucket for `second` (one bucket for the whole hold without a window).
  private static func add(_ rows: [Int?], at second: Int, window: TimeInterval?, to set: inout [(second: Int, rows: [Int?])]) {
    let key = window == nil ? 0 : second
    if set.last?.second != key || set.last?.rows.count != rows.count {
      set.append((key, Array(repeating: nil, count: rows.count)))
    }
    var last = set[set.count - 1].rows
    for i in rows.indices {
      if let row = rows[i] { last[i] = min(last[i] ?? row, row) }
    }
    set[set.count - 1].rows = last
  }

  /// The highest row of each column over some buckets.
  private static func highest(_ set: [(second: Int, rows: [Int?])], count: Int) -> [Int?] {
    var held = [Int?](repeating: nil, count: count)
    for bucket in set where bucket.rows.count == count {
      for i in held.indices {
        if let row = bucket.rows[i] { held[i] = min(held[i] ?? row, row) }
      }
    }
    return held
  }

  /// The screen after a sweep.
  public func add(_ screen: Snapshot, at time: Date) {
    guard let graph = Graph.find(on: screen) else { return }
    let rows = graph.traceRows(on: screen)
    let print = graph.labelPrint(on: screen)
    let state = lock.locked { () -> State? in
      if let current, current.graph != graph { startOver() }  // another layout (the waterfall's size changed)
      // The labels: read before for this fingerprint, or to be read now (nil meanwhile, so no readouts from labels
      // that have changed, and what comes meanwhile is kept apart from what was held).
      let changed = print != labels && labels != nil
      if print != labels {
        labels = print
        retry = (time.addingTimeInterval(2), 2)
        if scales[print] == nil { unread = (screen, graph, print) }
      } else if scales[print] == nil, !reading, unread == nil, time >= retry.at {
        retry = (time.addingTimeInterval(min(2 * retry.after, 30)), min(2 * retry.after, 30))
        unread = (screen, graph, print)
      }
      let scale = scales[print]
      if let scale {
        settle(scale, at: time)
      } else if changed, apartSince == nil, !buckets.isEmpty {
        apartSince = time
      }
      if heldSince == nil { heldSince = time }
      let second = Int(time.timeIntervalSinceReferenceDate.rounded(.down))
      if apartSince == nil {
        Self.add(rows, at: second, window: holdWindow, to: &buckets)
      } else {
        Self.add(rows, at: second, window: holdWindow, to: &apart)
      }
      if let holdWindow {
        buckets.removeAll { Double(second - $0.second) >= holdWindow }
        apart.removeAll { Double(second - $0.second) >= holdWindow }
      }
      var state = State(
        graph: graph, rows: Self.highest(apartSince == nil ? buckets : apart, count: rows.count), scale: scale,
        peaks: [], since: apartSince ?? heldSince ?? time, window: holdWindow,
        quietSpot: Self.quietSpot(
          screen, graph: graph, size: Self.readoutSize(peaks: count),
          staying: current?.graph == graph ? current?.quietSpot : nil))
      state.peaks = Self.peaks(in: state, count: count)
      current = state
      return state
    }
    onChange?(state)
    readLabelsIfNeeded()
  }

  private func readLabelsIfNeeded() {
    let job = lock.locked { () -> (Snapshot, Graph, Int)? in
      guard !reading, let unread else { return nil }
      reading = true
      self.unread = nil
      return unread
    }
    guard let (screen, graph, print) = job else { return }
    readingQueue.async { [weak self] in
      let scale = GraphScale.read(graph, on: screen)
      guard let self else { return }
      let changed = self.lock.locked { () -> State? in
        self.reading = false
        guard let scale else { return nil }  // unreadable (a menu over the labels): no readouts until they're back
        if self.scales.count > 32 { self.scales.removeAll() }
        self.scales[print] = scale
        // Labels that changed again meanwhile are read next.
        guard var state = self.current, state.graph == graph, print == self.labels else { return nil }
        self.settle(scale, at: Date())
        state.rows = Self.highest(self.buckets, count: state.rows.count)
        state.since = self.heldSince ?? state.since
        state.scale = scale
        state.peaks = Self.peaks(in: state, count: self.count)
        self.current = state
        return state
      }
      if let changed { self.onChange?(changed) }
      self.readLabelsIfNeeded()
    }
  }

  /// The place in the graph, at its left or right side (clear of the level labels), where a box of `size` covers
  /// the least the analyzer has drawn (grid aside); the highest of equals. The box stays where it was (`staying`)
  /// unless the new place is clearly emptier, so it doesn't jump about from sweep to sweep.
  static func quietSpot(
    _ screen: Snapshot, graph: Graph, size: (width: Int, height: Int), staying: (x: Int, y: Int)? = nil
  ) -> (x: Int, y: Int) {
    func ink(_ x: Int, _ y: Int, under limit: Int = .max) -> Int {
      var ink = 0
      for row in y..<min(y + size.height, screen.height) {
        for column in x..<min(x + size.width, screen.width) {
          let pixel = screen.pixels[row * screen.width + column]
          let (r, g, b) = Snapshot.rgb(pixel)
          if r | g | b > 0x20, !Graph.isGrid(pixel) { ink += 1 }
        }
        if ink >= limit { break }
      }
      return ink
    }
    let xs = [graph.left + 4, graph.right - 36 - size.width]
    var best = (x: xs[1], y: graph.top + 2)
    var least = Int.max
    for y in stride(from: graph.top + 2, through: max(graph.top + 2, graph.bottom - size.height - 2), by: 4) {
      for x in xs where x >= 0 && x + size.width <= screen.width {
        let covered = ink(x, y, under: least)
        if covered < least {
          least = covered
          best = (x, y)
        }
      }
    }
    guard least != .max else {
      return (max(0, min(xs[0], screen.width - 1)), max(0, min(graph.top + 2, screen.height - 1)))  // no room
    }
    if let staying, staying.x >= 0, staying.x + size.width <= screen.width, ink(staying.x, staying.y) <= least * 3 / 2 + 20 {
      return staying
    }
    return best
  }

  /// The highest peaks of the held trace: each the highest point between the higher ground on either side, standing at
  /// least 6 dB above the lower of the two valleys around it and above the held noise (the trace's median), highest
  /// first. Before the labels are read, 6 dB is taken as six tenths of a grid division (10 dB a division, the usual).
  static func peaks(in state: State, count: Int) -> [Peak] {
    let rows = state.rows
    guard count > 0, !rows.isEmpty else { return [] }
    let minimum: Int
    if let scale = state.scale, scale.perRow != 0 {
      minimum = max(2, Int((6 / abs(scale.perRow)).rounded()))
    } else {
      let division = state.graph.gridRows.count > 1 ? state.graph.gridRows[1] - state.graph.gridRows[0] : 10
      minimum = max(2, Int((0.6 * Double(division)).rounded()))
    }
    let seen = rows.compactMap { $0 }.sorted()
    guard !seen.isEmpty else { return [] }
    let noise = seen[seen.count / 2]
    var found: [Peak] = []
    for i in rows.indices {
      guard let row = rows[i] else { continue }
      // The first of a flat top only, and only a top: no higher (smaller) row next to it.
      if i > 0, let left = rows[i - 1], left <= row { continue }
      if i + 1 < rows.count, let right = rows[i + 1], right < row { continue }
      // The valleys: the lowest point on each side before higher ground. A side that reaches the graph's edge without
      // higher ground doesn't hold the peak down (a peak at the edge has nothing on that side).
      var leftValley = row
      var leftOpen = true
      var j = i - 1
      while j >= 0 {
        if let r = rows[j] {
          if r < row {
            leftOpen = false
            break
          }
          leftValley = max(leftValley, r)
        }
        j -= 1
      }
      var rightValley = row
      var rightOpen = true
      j = i + 1
      while j < rows.count {
        if let r = rows[j] {
          if r < row {
            rightOpen = false
            break
          }
          rightValley = max(rightValley, r)
        }
        j += 1
      }
      let base =
        leftOpen && rightOpen
        ? max(leftValley, rightValley) : leftOpen ? rightValley : rightOpen ? leftValley : min(leftValley, rightValley)
      guard base - row >= minimum, noise - row >= minimum else { continue }
      let column = state.graph.left + i
      var peak = Peak(column: column, row: row)
      if let scale = state.scale {
        peak.frequency = scale.frequency(column: column, of: state.graph)
        peak.level = scale.level(atRow: Double(row))
      }
      found.append(peak)
    }
    return Array(found.sorted { $0.row < $1.row }.prefix(count))
  }
}

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
  /// The highest rows of each second (or one bucket for the whole hold).
  private var buckets: [(second: Int, rows: [Int?])] = []
  private var labels: Int?
  private var reading = false
  private var unread: (Snapshot, Graph, Int)?
  private let readingQueue = DispatchQueue(label: "Reading the screen's labels", qos: .utility)

  public init() {}

  /// How long a level is held: nil (the default) until the hold starts over, or the latest seconds.
  public var window: TimeInterval? {
    get { lock.locked { holdWindow } }
    set {
      lock.locked {
        holdWindow = newValue.map { max(1, $0) }
        buckets.removeAll()
        current = nil
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
    lock.locked {
      buckets.removeAll()
      current = nil
    }
    onChange?(nil)
  }

  /// The screen after a sweep.
  public func add(_ screen: Snapshot, at time: Date) {
    guard let graph = Graph.find(on: screen) else { return }
    let rows = graph.traceRows(on: screen)
    let print = graph.labelPrint(on: screen)
    let state = lock.locked { () -> State? in
      if let current, current.graph != graph {
        buckets.removeAll()  // another layout (the waterfall's size changed): start over
        self.current = nil
      }
      let second = Int(time.timeIntervalSinceReferenceDate.rounded(.down))
      let key = holdWindow == nil ? 0 : second
      if buckets.last?.second != key || buckets.last?.rows.count != rows.count {
        buckets.append((key, Array(repeating: nil, count: rows.count)))
      }
      var last = buckets[buckets.count - 1].rows
      for i in rows.indices {
        if let row = rows[i] { last[i] = min(last[i] ?? row, row) }
      }
      buckets[buckets.count - 1].rows = last
      if let holdWindow { buckets.removeAll { Double(second - $0.second) >= holdWindow } }
      var held = [Int?](repeating: nil, count: rows.count)
      for bucket in buckets where bucket.rows.count == held.count {
        for i in held.indices {
          if let row = bucket.rows[i] { held[i] = min(held[i] ?? row, row) }
        }
      }
      let scale = current?.scale
      var state = State(
        graph: graph, rows: held, scale: scale, peaks: [], since: current?.since ?? time, window: holdWindow,
        quietSpot: Self.quietSpot(
          screen, graph: graph, size: Self.readoutSize(peaks: count),
          staying: current?.graph == graph ? current?.quietSpot : nil))
      state.peaks = Self.peaks(in: state, count: count)
      current = state
      // The labels changed (or were never read): read them again, away from this thread.
      if print != labels {
        labels = print
        unread = (screen, graph, print)
      }
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
        // Labels that changed again meanwhile are read next; unreadable ones (a menu over them) change nothing.
        guard var state = self.current, state.graph == graph, print == self.labels, let scale, scale != state.scale
        else { return nil }
        if state.scale != nil {
          // Another span or other levels: what was held belongs to the old ones.
          self.buckets.removeAll()
          state.rows = Array(repeating: nil, count: state.rows.count)
          state.since = Date()
        }
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
    if let staying, ink(staying.x, staying.y) <= least * 3 / 2 + 20 { return staying }
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
      // The valleys: the lowest point on each side before higher ground.
      var leftValley = row
      var j = i - 1
      while j >= 0 {
        if let r = rows[j] {
          if r < row { break }
          leftValley = max(leftValley, r)
        }
        j -= 1
      }
      var rightValley = row
      j = i + 1
      while j < rows.count {
        if let r = rows[j] {
          if r < row { break }
          rightValley = max(rightValley, r)
        }
        j += 1
      }
      guard min(leftValley, rightValley) - row >= minimum, noise - row >= minimum else { continue }
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

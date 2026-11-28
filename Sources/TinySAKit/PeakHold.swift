import Foundation
import os

/// The highest level the analyzer's live trace has reached at each point of the graph, held on the Mac: from the
/// screen's pixels after each sweep, so the analyzer's own traces, markers and settings are left as they are, and fed
/// pictures work as well as the analyzer on USB. Its highest peaks are found and, once the screen's labels are read,
/// given their frequency and level. The hold starts over when the span changes; when the levels change (the reference
/// level, by hand or by the analyzer's automatic reference level, the decibels a division, the waterfall's size), what
/// it holds moves to where those levels are now. It can keep only the latest seconds. Frames come from the session's
/// thread; `onChange` is called there. What changes the hold wholesale is logged (subsystem
/// io.github.tolgabalci.tinysa-screen, category "peak hold").
public final class PeakHold: @unchecked Sendable {
  public struct Peak: Equatable, Sendable {
    /// Its number on the screen, as an analyzer's marker stays on its peak: kept while the hold holds the peak (moved
    /// a few columns at most), the lowest free one for a new peak.
    public var number = 0
    /// Where on the screen (its own pixels).
    public var column: Int
    public var row: Int
    /// Read from the screen's labels; nil until they are.
    public var frequency: Int64?
    public var level: Double?
    /// When its level came in: the sweep that first reached it, held since.
    public var time: Date?
  }

  public struct State: Equatable, Sendable {
    public var graph: Graph
    /// The highest row reached in each column (the top is row 0), nil where nothing has been seen.
    public var rows: [Int?]
    /// When each column's highest row came in: the sweep that first reached it.
    public var times: [Date?]
    public var scale: GraphScale?
    /// The highest peaks, highest first, each with its number.
    public var peaks: [Peak]
    /// When the hold started (over).
    public var since: Date
    /// How long it keeps a level: nil for until it starts over.
    public var window: TimeInterval?
    /// The emptiest place in the graph for a box of readouts (the analyzer writes its own markers' readouts at the
    /// top): its top left corner, in the screen's pixels.
    public var quietSpot = (x: 0, y: 0)

    public init(
      graph: Graph, rows: [Int?], times: [Date?]? = nil, scale: GraphScale?, peaks: [Peak], since: Date,
      window: TimeInterval?, quietSpot: (x: Int, y: Int) = (0, 0)
    ) {
      self.graph = graph
      self.rows = rows
      self.times = times ?? Array(repeating: nil, count: rows.count)
      self.scale = scale
      self.peaks = peaks
      self.since = since
      self.window = window
      self.quietSpot = quietSpot
    }

    public static func == (a: State, b: State) -> Bool {
      a.graph == b.graph && a.rows == b.rows && a.times == b.times && a.scale == b.scale && a.peaks == b.peaks
        && a.since == b.since && a.window == b.window && a.quietSpot == b.quietSpot
    }
  }

  /// A second's highest rows (or the whole hold's), and when each came in.
  private struct Bucket {
    var second: Int
    var rows: [Int?]
    var times: [Date?]
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
  private var buckets: [Bucket] = []
  /// The rows since the labels changed to ones not read yet, kept apart (and shown alone) until they are read: then
  /// they join the held rows under the same span and levels (a menu covered the labels for a while), or replace them
  /// under others (another span), so neither the old span's levels show over the new one nor the new one's first
  /// sweeps are lost.
  private var apart: [Bucket] = []
  /// When the held rows began, and the ones kept apart.
  private var heldSince: Date?
  private var apartSince: Date?
  /// The peaks last numbered, whose numbers the next ones keep; none when what's shown starts over.
  private var numbered: [Peak] = []
  /// The labels' fingerprint now, the spans and levels read for each fingerprint seen (a menu over the labels changes it
  /// for a while), and the ones the held rows belong to.
  private var labels: Int?
  private var scales: [Int: GraphScale] = [:]
  private var rowsScale: GraphScale?
  private var reading = false
  private var unread: Frame?
  /// The latest frame, and the number of the latest one a read has had: `labelsRead(by:)` reads the latest once more
  /// when no read has had it.
  private var latest: Frame?
  private var frames = 0
  private var tried = 0
  /// When labels that couldn't be read (a trace across them, say) are read again from a later frame, and the wait
  /// before the next try, doubling up to 30 s while they still can't.
  private var retry = (at: Date.distantPast, after: 2.0)
  private let readingQueue = DispatchQueue(label: "Reading the screen's labels", qos: .utility)

  /// A frame whose labels may be read: its number counts the frames added.
  private struct Frame {
    var screen: Snapshot
    var graph: Graph
    var print: Int
    var number: Int
  }

  /// Whether it reads the screen's labels itself, with the Mac's text recognition: a hold replayed from a recording
  /// is told them (`know(_:for:)`) instead.
  private let readsLabels: Bool

  public init(readsLabels: Bool = true) {
    self.readsLabels = readsLabels
  }

  private static let log = Logger(subsystem: "io.github.tolgabalci.tinysa-screen", category: "peak hold")

  /// What changes the hold wholesale, for the Mac's log (`/usr/bin/log show --predicate 'subsystem ==
  /// "io.github.tolgabalci.tinysa-screen"' --last 1h`; zsh's own `log` is another command): the live hold's, not a
  /// replay's.
  private func note(_ message: @autoclosure () -> String) {
    guard readsLabels else { return }
    let message = message()
    Self.log.notice("\(message, privacy: .public)")
  }

  /// The peaks numbered before what's shown was kept apart (the labels changed to ones not read yet), numbered again
  /// when the labels turn out to be the same span's.
  private var numberedBefore: [Peak]?

  /// The span and levels the labels of `screen` say, read before (by the recording's own hold): not read again.
  public func know(_ scale: GraphScale, for screen: Snapshot) {
    guard let graph = Graph.find(on: screen) else { return }
    let print = graph.labelPrint(on: screen)
    lock.locked { scales[print] = scale }
  }

  /// How long a level is held: nil (the default) until the hold starts over, or the latest seconds.
  public var window: TimeInterval? {
    get { lock.locked { holdWindow } }
    set {
      lock.locked {
        holdWindow = newValue.map { max(1, $0) }
        startOver()
      }
      note("Hold period now \(newValue.map { "\(Int($0)) s" } ?? "until cleared"): starting over")
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
    note("Cleared (Clear Peaks, or the hold turned off): starting over")
    onChange?(nil)
  }

  /// Nothing held; the labels read again from the next frame (their fingerprint forgotten, the spans read kept).
  private func startOver() {
    buckets.removeAll()
    apart.removeAll()
    heldSince = nil
    apartSince = nil
    numbered.removeAll()
    numberedBefore = nil
    current = nil
    labels = nil
    rowsScale = nil
    latest = nil
  }

  /// Labels read, now or before, on `graph`: the rows kept apart join the held ones under the same span and levels. At
  /// other levels of the same span (the reference level changed, by hand or by the analyzer's automatic reference
  /// level, the decibels a division, the waterfall's size), the held ones move first to where their levels are now;
  /// under another span the ones kept apart replace them.
  private func settle(_ scale: GraphScale, at time: Date, graph: Graph) {
    defer {
      rowsScale = scale
      apart.removeAll()
      apartSince = nil
      numberedBefore = nil
    }
    guard let rowsScale, rowsScale != scale else {
      buckets += apart
      if let numberedBefore { numbered = numberedBefore }
      return
    }
    guard rowsScale.start == scale.start, rowsScale.stop == scale.stop else {
      note(
        "Another span, \(Self.span(scale)) (was \(Self.span(rowsScale))): starting over"
          + (apartSince.map { ", from \(Self.clock($0))" } ?? ""))
      buckets = apart
      heldSince = apartSince ?? time
      numbered.removeAll()  // another span's peaks aren't the ones before
      return
    }
    note(
      "Other levels, \(Self.levels(scale)) (were \(Self.levels(rowsScale))): what's held moved to them, "
        + "\(Self.span(scale)) as before")
    buckets = buckets.map { Self.move($0, from: rowsScale, to: scale, on: graph) } + apart
    if let numberedBefore { numbered = numberedBefore }
  }

  /// A bucket's rows at other levels: each where its level is now, at the graph's top or bottom when it's beyond them
  /// (as the analyzer draws a trace beyond them).
  private static func move(_ bucket: Bucket, from old: GraphScale, to new: GraphScale, on graph: Graph) -> Bucket {
    var bucket = bucket
    bucket.rows = bucket.rows.map { row in
      row.map { row in
        let level = old.level(atRow: Double(row))
        let moved = ((level - new.level0) / new.perRow).rounded()
        return Int(min(max(moved, Double(graph.top)), Double(graph.bottom)))
      }
    }
    return bucket
  }

  /// For the log: "902.000–928.000 MHz".
  private static func span(_ scale: GraphScale) -> String {
    String(format: "%.3f–%.3f MHz", Double(scale.start) / 1e6, Double(scale.stop) / 1e6)
  }

  /// For the log: "+10.0 dBm at row 0, -0.417 dB a row".
  private static func levels(_ scale: GraphScale) -> String {
    String(format: "%+.1f dBm at row 0, %.3f dB a row", scale.level0, scale.perRow)
  }

  /// For the log: "rows 0–240, 24 a division".
  private static func rows(_ graph: Graph) -> String {
    let step = graph.gridRows.count > 1 ? graph.gridRows[1] - graph.gridRows[0] : 0
    return "rows \(graph.top)–\(graph.bottom), \(step) a division"
  }

  private static func clock(_ time: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: time)
  }

  /// Numbers for the peaks found (highest first), as an analyzer's markers stay on their peaks: a peak within 2 % of
  /// the graph's width of one numbered before keeps its number (the nearest, each number once; half a megahertz of a
  /// 26 MHz span, as the bench's monitor has it), a new one takes the lowest number free, the higher new peak first.
  private func number(_ found: [Peak], width: Int) -> [Peak] {
    let near = max(3, width / 50)
    var numbers = [Int?](repeating: nil, count: found.count)
    for old in numbered.sorted(by: { $0.number < $1.number }) {
      let candidates = found.indices.filter { numbers[$0] == nil && abs(found[$0].column - old.column) <= near }
      if let k = candidates.min(by: { abs(found[$0].column - old.column) < abs(found[$1].column - old.column) }) {
        numbers[k] = old.number
      }
    }
    var taken = Set(numbers.compactMap { $0 })
    for k in found.indices where numbers[k] == nil {
      let free = (1...).first { !taken.contains($0) } ?? 1
      numbers[k] = free
      taken.insert(free)
    }
    let peaks = found.indices.map { k -> Peak in
      var peak = found[k]
      peak.number = numbers[k] ?? 0
      return peak
    }
    numbered = peaks
    return peaks
  }

  /// `rows`, which came in at `time`, into the bucket for its second (one bucket for the whole hold without a window).
  private static func add(_ rows: [Int?], at time: Date, window: TimeInterval?, to set: inout [Bucket]) {
    let key = window == nil ? 0 : Int(time.timeIntervalSinceReferenceDate.rounded(.down))
    if set.last?.second != key || set.last?.rows.count != rows.count {
      let none = [Int?](repeating: nil, count: rows.count)
      set.append(Bucket(second: key, rows: none, times: Array(repeating: nil, count: rows.count)))
    }
    var last = set[set.count - 1]
    for i in rows.indices {
      if let row = rows[i], row < last.rows[i] ?? .max {
        last.rows[i] = row
        last.times[i] = time
      }
    }
    set[set.count - 1] = last
  }

  /// The highest row of each column over some buckets, and when it first came in.
  private static func highest(_ set: [Bucket], count: Int) -> (rows: [Int?], times: [Date?]) {
    var held = [Int?](repeating: nil, count: count)
    var times = [Date?](repeating: nil, count: count)
    for bucket in set where bucket.rows.count == count {
      for i in held.indices {
        if let row = bucket.rows[i], row < held[i] ?? .max {
          held[i] = row
          times[i] = bucket.times[i]
        }
      }
    }
    return (held, times)
  }

  /// The screen after a sweep. What covers the graph isn't the trace: with a keypad over it nothing is read (the
  /// analyzer doesn't sweep while one is open), and with a menu down its right side nothing from under the menu (its
  /// buttons and their edges read as levels at the top of the graph, held there as peaks), the graph the one held
  /// (found with the menu over it, it's narrower, and the hold would start over). `labels`: what its labels say, as
  /// read before (a hold replayed from a recording, as the recording's own hold had read them then), not read again.
  public func add(_ screen: Snapshot, at time: Date, labels known: GraphScale? = nil) {
    let covered = ScreenState.of(screen)
    guard !covered.isKeypad else { return }
    let held = covered == .menu ? lock.locked { current?.graph } : nil
    guard let graph = held ?? Graph.find(on: screen) else { return }
    var rows = graph.traceRows(on: screen)
    if covered == .menu {
      let menu = Self.menuLeft(screen)
      for i in rows.indices where graph.left + i >= menu { rows[i] = nil }
    }
    let print = graph.labelPrint(on: screen)
    let state = lock.locked { () -> State? in
      if let known { scales[print] = known }
      // Another layout: the grid's rows elsewhere with the same columns (the waterfall's size changed) keeps what's
      // held, moved to the levels there, when both layouts' labels have been read; else it starts over.
      if let current, current.graph != graph {
        let sameColumns = current.graph.left == graph.left && current.graph.right == graph.right
        if sameColumns, rowsScale != nil, scales[print] != nil {
          note(
            "The graph's rows changed (\(Self.rows(current.graph)), now \(Self.rows(graph)): the waterfall's size): "
              + "what's held moves with the levels")
        } else {
          note(
            "The graph changed (columns \(current.graph.left)–\(current.graph.right), \(Self.rows(current.graph)); "
              + "now \(graph.left)–\(graph.right), \(Self.rows(graph))): starting over")
          startOver()
        }
      }
      frames += 1
      let frame = Frame(screen: screen, graph: graph, print: print, number: frames)
      latest = frame
      // The labels: read before for this fingerprint, or to be read now (nil meanwhile, so no readouts from labels
      // that have changed, and what comes meanwhile is kept apart from what was held).
      let changed = print != labels && labels != nil
      if print != labels {
        labels = print
        retry = (time.addingTimeInterval(2), 2)
        if scales[print] == nil { unread = frame }
      } else if scales[print] == nil, !reading, unread == nil, time >= retry.at {
        retry = (time.addingTimeInterval(min(2 * retry.after, 30)), min(2 * retry.after, 30))
        unread = frame
      }
      let scale = scales[print]
      if changed { note(scale == nil ? "The labels changed: reading them" : "The labels changed to ones read before") }
      if let scale {
        settle(scale, at: time, graph: graph)
      } else if changed, apartSince == nil, !buckets.isEmpty {
        note("Meanwhile only what comes in shows, the rest held apart")
        apartSince = time
        numberedBefore = numbered
        numbered.removeAll()  // what's shown now may be another span: its peaks aren't the ones before
      }
      if heldSince == nil { heldSince = time }
      let second = Int(time.timeIntervalSinceReferenceDate.rounded(.down))
      if apartSince == nil {
        Self.add(rows, at: time, window: holdWindow, to: &buckets)
      } else {
        Self.add(rows, at: time, window: holdWindow, to: &apart)
      }
      if let holdWindow {
        buckets.removeAll { Double(second - $0.second) >= holdWindow }
        apart.removeAll { Double(second - $0.second) >= holdWindow }
      }
      let held = Self.highest(apartSince == nil ? buckets : apart, count: rows.count)
      var state = State(
        graph: graph, rows: held.rows, times: held.times, scale: scale,
        peaks: [], since: apartSince ?? heldSince ?? time, window: holdWindow,
        quietSpot: Self.quietSpot(
          screen, graph: graph, size: Self.readoutSize(peaks: count),
          staying: current?.graph == graph ? current?.quietSpot : nil))
      state.peaks = number(Self.peaks(in: state, count: count), width: graph.right - graph.left)
      current = state
      return state
    }
    onChange?(state)
    readLabelsIfNeeded()
  }

  /// Where the analyzer's menu begins, its buttons down the screen's right side (80 pixels of the tinySA Ultra's 480),
  /// a little to the left for their edges.
  static func menuLeft(_ screen: Snapshot) -> Int { screen.width - screen.width / 6 - 6 }

  private func readLabelsIfNeeded() {
    guard readsLabels else { return }
    guard let job = lock.locked({ takeJob(orLatest: false) }) else { return }
    readingQueue.async { [weak self] in
      let scale = GraphScale.read(job.graph, on: job.screen)
      guard let self else { return }
      if let changed = self.lock.locked({ self.finishRead(job, scale) }) { self.onChange?(changed) }
      self.readLabelsIfNeeded()
    }
  }

  /// The state with the screen's labels read, for an answer that can't wait for more frames (`tinysa-screen peaks`,
  /// its seconds up): a read under way is waited for, until `deadline` at most, and labels still unread are read once
  /// more, here, from the latest frame, when no read has had it. The first read by a program after a macOS update
  /// takes most of a minute (the Mac's text recognition prepares itself for the program, once), and a program that
  /// quits meanwhile leaves that to the next. Also whether a read was still under way when it gave up.
  public func labelsRead(by deadline: Date, cancelled: () -> Bool = { false }) -> (state: State?, stillReading: Bool) {
    while true {
      let (state, job, waiting) = lock.locked { () -> (State?, Frame?, Bool) in
        guard let current, current.scale == nil else { return (current, nil, false) }
        let job = Date() < deadline ? takeJob(orLatest: true) : nil
        return (current, job, reading)
      }
      if let job {
        let scale = GraphScale.read(job.graph, on: job.screen)
        if let changed = lock.locked({ finishRead(job, scale) }) { onChange?(changed) }
        continue
      }
      guard waiting else { return (state, false) }
      if Date() >= deadline || cancelled() { return (state, true) }
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  /// The frame whose labels to read next, taken (one read at a time): the one waiting for it, or with `orLatest` the
  /// latest frame when no read has had it. Under the lock.
  private func takeJob(orLatest: Bool) -> Frame? {
    guard !reading, let job = unread ?? (orLatest && (latest?.number ?? 0) > tried ? latest : nil) else { return nil }
    reading = true
    unread = nil
    tried = max(tried, job.number)
    return job
  }

  /// A read done: its span and levels kept for its labels, and given to what's held when they're still the labels
  /// shown (the new state, to tell). Under the lock.
  private func finishRead(_ job: Frame, _ scale: GraphScale?) -> State? {
    reading = false
    guard let scale else {
      note("The labels couldn't be read (a menu over them, say): read again later")
      return nil  // unreadable: no readouts until they're back
    }
    if scales.count > 32 { scales.removeAll() }
    scales[job.print] = scale
    // Labels that changed again meanwhile are read next.
    guard var state = current, state.graph == job.graph, job.print == labels else { return nil }
    settle(scale, at: Date(), graph: job.graph)
    (state.rows, state.times) = Self.highest(buckets, count: state.rows.count)
    state.since = heldSince ?? state.since
    state.scale = scale
    state.peaks = number(Self.peaks(in: state, count: count), width: job.graph.right - job.graph.left)
    current = state
    return state
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
  public static func peaks(in state: State, count: Int) -> [Peak] {
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
      var peak = Peak(column: column, row: row, time: i < state.times.count ? state.times[i] : nil)
      if let scale = state.scale {
        peak.frequency = scale.frequency(column: column, of: state.graph)
        peak.level = scale.level(atRow: Double(row))
      }
      found.append(peak)
    }
    return Array(found.sorted { $0.row < $1.row }.prefix(count))
  }
}

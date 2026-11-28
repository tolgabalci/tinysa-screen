import Foundation

/// Every peak the hold has had since the app started, for the window's list beside the screen: a row a peak, kept
/// after the peak has gone from the hold (never taken out), its level and time brought up to date while it's held
/// (the same number, at most 2 % of the graph's width away), a new row for a peak that comes again after it went.
public struct PeakLog: Sendable {
  public struct Entry: Identifiable, Equatable, Sendable {
    public let id: Int
    public var number: Int
    /// Where on the screen (its own pixels).
    public var column: Int
    /// When its level came in.
    public var time: Date
    public var frequency: Int64
    /// Megahertz with as many decimals as a column of the graph resolved: "915.200".
    public var megahertz: String
    public var level: Double
    /// Its level as finely as a row of the graph resolved: "−45", "−45.5".
    public var dBm: String
    /// Still in the hold, so on the screen.
    public var held: Bool
  }

  public private(set) var entries: [Entry] = []
  /// The hold's period, as its box says it: "Peak hold, last 1:00".
  public private(set) var title = ""

  public init() {}

  /// The hold as it is now (nil when it's off or starting over) into the list; whether the list changed.
  @discardableResult
  public mutating func update(with state: PeakHold.State?) -> Bool {
    let (before, beforeTitle) = (entries, title)
    if let state { title = state.title }
    guard let state, let scale = state.scale else {
      for i in entries.indices { entries[i].held = false }
      return entries != before || title != beforeTitle
    }
    let width = state.graph.right - state.graph.left
    let perColumn = Double(scale.stop - scale.start) / Double(max(width - 1, 1))
    let near = max(3, width / 50)
    var seen = Set<Int>()
    let inOrder = state.peaks.sorted { ($0.time ?? .distantPast, $0.number) < ($1.time ?? .distantPast, $1.number) }
    for peak in inOrder {
      guard let frequency = peak.frequency, let level = peak.level, let time = peak.time else { continue }
      let megahertz = PeakHold.frequency(frequency, resolution: perColumn).replacingOccurrences(of: " MHz", with: "")
      let dBm = PeakHold.level(level, resolution: abs(scale.perRow)).replacingOccurrences(of: " dBm", with: "")
      let same = entries.indices.last {
        entries[$0].held && !seen.contains($0) && entries[$0].number == peak.number
          && abs(entries[$0].column - peak.column) <= near
      }
      if let i = same {
        entries[i].column = peak.column
        entries[i].time = time
        entries[i].frequency = frequency
        entries[i].megahertz = megahertz
        entries[i].level = level
        entries[i].dBm = dBm
        seen.insert(i)
      } else {
        entries.append(
          Entry(
            id: entries.count, number: peak.number, column: peak.column, time: time, frequency: frequency,
            megahertz: megahertz, level: level, dBm: dBm, held: true))
        seen.insert(entries.count - 1)
      }
    }
    for i in entries.indices where entries[i].held && !seen.contains(i) { entries[i].held = false }
    return entries != before || title != beforeTitle
  }

  /// The list as a CSV file for a spreadsheet: a row a peak, its number, the date and time its level came in, to the
  /// second ("2026-11-28 12:05:31 AM"), its frequency in megahertz and its level in dBm, as the list shows them (with
  /// a plain minus).
  public func csv(timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd hh:mm:ss a"
    var lines = ["Peak,Time,Frequency (MHz),Level (dBm)"]
    for entry in entries {
      let level = entry.dBm.replacingOccurrences(of: "\u{2212}", with: "-")
      lines.append("\(entry.number),\(formatter.string(from: entry.time)),\(entry.megahertz),\(level)")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

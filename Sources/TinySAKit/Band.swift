import Foundation

/// The span the analyzer sweeps: its start and stop frequencies in hertz (and its sweep points, when read from it).
public struct SweepRange: Equatable, Codable, Sendable {
  public var start: Int64
  public var stop: Int64
  public var points: Int?

  public init(start: Int64, stop: Int64, points: Int? = nil) {
    self.start = start
    self.stop = stop
    self.points = points
  }

  /// The reply to `sweep`: "902000000 928000000 450" (start, stop, points).
  public init?(reply: String) {
    let numbers = reply.split(whereSeparator: { $0 == " " || $0.isNewline }).compactMap { Int64($0) }
    guard numbers.count >= 2, numbers[0] <= numbers[1] else { return nil }
    self.init(start: numbers[0], stop: numbers[1], points: numbers.count > 2 ? Int(numbers[2]) : nil)
  }

  /// "902–928 MHz", "2400–2483.5 MHz", "87.5–108 MHz".
  public var label: String { Frequency.range(start, stop) }

  /// Whether two spans are the same, to within a hertz per megahertz (the analyzer rounds to its step).
  public func matches(_ other: SweepRange) -> Bool {
    let tolerance = max(1, max(stop, other.stop) / 1_000_000)
    return abs(start - other.start) <= tolerance && abs(stop - other.stop) <= tolerance
  }

  /// The commands that take the analyzer from `current` to this span. Start and stop go one at a time, in the order
  /// that never makes start pass stop: the analyzer would take the moment they meet for a zero span and reset its
  /// sweep time.
  public func commands(from current: SweepRange?) -> [String] {
    let startFirst = current.map { start < $0.stop } ?? true
    let start = "sweep start \(self.start)"
    let stop = "sweep stop \(self.stop)"
    return startFirst ? [start, stop] : [stop, start]
  }
}

/// Frequencies as people write them.
public enum Frequency {
  /// Hertz from "902M", "2.4G", "433.92 MHz", "100k", "915000000", "1.2e9"; nil if it isn't one.
  public static func parse(_ text: String) -> Int64? {
    var body = text.trimmingCharacters(in: .whitespaces).lowercased()
    if body.hasSuffix("hz") { body.removeLast(2) }
    body = body.trimmingCharacters(in: .whitespaces)
    var factor = 1.0
    if let last = body.last, let multiple = ["k": 1e3, "m": 1e6, "g": 1e9][String(last)] {
      factor = multiple
      body.removeLast()
    }
    guard let value = Double(body.trimmingCharacters(in: .whitespaces)), value.isFinite, value >= 0 else { return nil }
    let hertz = (value * factor).rounded()
    guard hertz < 1e12 else { return nil }
    return Int64(hertz)
  }

  /// "902 MHz", "2483.5 MHz", "100 kHz": megahertz from 1 MHz up (as bands are written, below 10 GHz), without trailing
  /// zeros.
  public static func format(_ hertz: Int64) -> String {
    let (value, unit) = scaled(hertz, unit(for: hertz))
    return "\(value) \(unit)"
  }

  /// "902–928 MHz": one unit for both ends, the stop's.
  public static func range(_ start: Int64, _ stop: Int64) -> String {
    let unit = unit(for: stop)
    return "\(scaled(start, unit).value)–\(scaled(stop, unit).value) \(unit)"
  }

  private static func unit(for hertz: Int64) -> String {
    hertz >= 10_000_000_000 ? "GHz" : hertz >= 1_000_000 ? "MHz" : hertz >= 1_000 ? "kHz" : "Hz"
  }

  private static func scaled(_ hertz: Int64, _ unit: String) -> (value: String, unit: String) {
    let divisor: Double = ["GHz": 1e9, "MHz": 1e6, "kHz": 1e3][unit] ?? 1
    var text = String(format: "%.6f", Double(hertz) / divisor)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return (text, unit)
  }
}

/// A band to sweep in one click: a name and its span.
public struct BandPreset: Equatable, Codable, Sendable, Identifiable {
  public var name: String
  public var range: SweepRange
  public var id: String { name }

  public init(name: String, start: Int64, stop: Int64) {
    self.name = name
    range = SweepRange(start: start, stop: stop)
  }

  /// The bands the menu starts with, in groups: common bands to look at with a tinySA Ultra, by where they are used.
  public static let builtIn: [[BandPreset]] = [
    [
      BandPreset(name: "FM radio", start: 87_500_000, stop: 108_000_000),
      BandPreset(name: "Airband", start: 118_000_000, stop: 137_000_000),
      BandPreset(name: "Marine VHF", start: 156_000_000, stop: 162_025_000),
    ],
    [
      BandPreset(name: "2 m amateur", start: 144_000_000, stop: 148_000_000),
      BandPreset(name: "70 cm amateur", start: 420_000_000, stop: 450_000_000),
    ],
    [
      BandPreset(name: "433 MHz ISM", start: 433_050_000, stop: 434_790_000),
      BandPreset(name: "868 MHz (Europe): LoRa, RFID", start: 863_000_000, stop: 870_000_000),
      BandPreset(name: "915 MHz (Americas): LoRa, RFID", start: 902_000_000, stop: 928_000_000),
      BandPreset(name: "2.4 GHz: Wi-Fi, Bluetooth", start: 2_400_000_000, stop: 2_483_500_000),
      BandPreset(name: "5 GHz Wi-Fi", start: 5_150_000_000, stop: 5_850_000_000),
    ],
    [
      BandPreset(name: "Cellular 700–900 MHz", start: 698_000_000, stop: 960_000_000),
      BandPreset(name: "ADS-B 1090 MHz", start: 1_085_000_000, stop: 1_095_000_000),
      BandPreset(name: "GPS L1", start: 1_565_000_000, stop: 1_586_000_000),
    ],
  ]
}

/// A span changed: what it was, and what the analyzer took (it rounds to its own steps, and keeps within its range).
public struct SweepChange: Equatable, Sendable {
  public let before: SweepRange
  public let after: SweepRange
}

/// Why the analyzer couldn't be asked.
public enum AnalyzerError: Error, Equatable, CustomStringConvertible, Sendable {
  /// Not on USB here: a feeding program has it, it is lent, unplugged.
  case unavailable(String)
  case failed(String)

  public var description: String {
    switch self {
    case let .unavailable(reason), let .failed(reason): return reason
    }
  }
}

/// A result handed from one thread to another.
final class ResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<SweepChange, AnalyzerError>?
  func set(_ result: Result<SweepChange, AnalyzerError>) { lock.locked { value = result } }
  func get() -> Result<SweepChange, AnalyzerError>? { lock.locked { value } }
}

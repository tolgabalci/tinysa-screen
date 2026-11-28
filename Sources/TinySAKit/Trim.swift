import Foundation

/// The part of a recording a GIF keeps, as the editor's two handles set it: a start and an end within the clip, at
/// least `shortest` apart (the whole clip, when it is shorter).
public struct Trim: Equatable, Sendable {
  /// The shortest GIF the handles make.
  public static let shortest: TimeInterval = 1

  public let bounds: ClosedRange<Date>
  public private(set) var start: Date
  public private(set) var end: Date

  /// The part from `leadIn` seconds before the recording `began` (as far back as the clip goes) to its end: the GIF
  /// that Stop and Save makes, and where the editor's handles start.
  public init(_ clip: Clip, began: Date, leadIn: TimeInterval) {
    bounds = clip.start...clip.end
    start = clip.start
    end = clip.end
    moveStart(to: began.addingTimeInterval(-max(leadIn, 0)))
  }

  public var duration: TimeInterval { end.timeIntervalSince(start) }

  private var least: TimeInterval { min(Self.shortest, bounds.upperBound.timeIntervalSince(bounds.lowerBound)) }

  /// The start moved to `moment`, as far as the clip's start and the end allow.
  public mutating func moveStart(to moment: Date) {
    start = min(max(moment, bounds.lowerBound), end.addingTimeInterval(-least))
  }

  /// The end moved to `moment`, as far as the start and the clip's end allow.
  public mutating func moveEnd(to moment: Date) {
    end = max(min(moment, bounds.upperBound), start.addingTimeInterval(least))
  }
}

extension Clip {
  /// When the next frame after `moment` came; the clip's end when none did.
  public func frameTime(after moment: Date) -> Date {
    frames.first { $0.time > moment }.map { min($0.time, end) } ?? end
  }

  /// When the frame before `moment` came: the one on the screen then, or, at the moment it came, the one before it;
  /// the clip's start at the earliest.
  public func frameTime(before moment: Date) -> Date {
    max(frames.last { $0.time < moment }?.time ?? start, start)
  }

  /// Its part from `start` to `end`: the GIF a trim keeps.
  public func part(_ trim: Trim) -> Clip {
    Clip(frames: frames, from: trim.start, to: trim.end, arrivals: arrivals, peaks: peaks) ?? self
  }
}

import Foundation
import TinySAKit

/// Escape's way back to the analyzer's graph, by its own touches: where `ScreenState` says (the number keypad's erase
/// key, a character a press, until the keypad has gone; the graph beside a menu), each once the screen shows what the
/// touch before did, until the graph shows. A picture counts once the part touched has changed (the keypad, which
/// stays still while open; a menu's column, while the graph behind it sweeps on): through a feeder the next picture
/// may still be a sweep's from before the touch was typed. After `patience` without a change, it looks again. At
/// most `touches` touches in `limit` seconds, so a screen it doesn't know is never tapped on and on.
@MainActor
final class EscapeRun {
  static let touches = 24
  static let limit: TimeInterval = 15
  /// How long a touch's picture may take: through a feeder it comes with the next one, up to a second or so.
  static let patience: TimeInterval = 2.5

  private let session: Session
  private let done: (String?) -> Void
  private let latest = LatestFrame()
  private var frames: UUID?
  private var timer: Timer?
  /// The touch before: what the screen showed, the part of it the touch should change, and when.
  private var touched: (state: ScreenState, part: [UInt32], at: Date)?
  private var count = 0
  private let started = Date()

  /// Starts from `current`, the picture in the window; `done` is told how it ended: nil back on the graph, else why
  /// not, for a moment's note.
  init(session: Session, current: Snapshot?, done: @escaping (String?) -> Void) {
    self.session = session
    self.done = done
    if let current { latest.set(current, at: Date.distantPast) }
    let box = latest
    frames = session.onFrame { snapshot, time in box.set(snapshot, at: time) }
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.step() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    step()
  }

  /// Stops where it is: a click, or the pointer or the pen, takes the mouse back.
  func stop() {
    timer?.invalidate()
    timer = nil
    if let frames { session.removeFrameHandler(frames) }
    frames = nil
  }

  private func step() {
    guard timer != nil else { return }
    if count >= Self.touches || Date().timeIntervalSince(started) > Self.limit {
      finish("The tinySA's screen didn't come back to its graph: tap it there.")
      return
    }
    guard session.status.controllable, let (screen, _) = latest.get() else { return }
    if let touched, Date().timeIntervalSince(touched.at) < Self.patience,
      Self.part(of: screen, for: touched.state) == touched.part
    {
      return  // not shown yet
    }
    let state = ScreenState.of(screen)
    switch state {
    case .graph:
      finish(count == 0 ? "Nothing is open on the tinySA's screen." : nil)
    case .keypad:
      finish("A keypad for a name is open on the tinySA: its own keys close it.")
    case .numberKeypad, .menu:
      guard let (x, y) = state.escapeTap(on: screen) else { return }
      session.touch(x: x, y: y)
      session.release(x: x, y: y)
      touched = (state, Self.part(of: screen, for: state), Date())
      count += 1
    }
  }

  /// The part of the screen a touch changes: a menu's column, else all of it.
  private static func part(of screen: Snapshot, for state: ScreenState) -> [UInt32] {
    guard state == .menu else { return screen.pixels }
    let left = screen.width - screen.width / 6
    return (0..<screen.height).flatMap { y in screen.pixels[(y * screen.width + left)..<((y + 1) * screen.width)] }
  }

  private func finish(_ message: String?) {
    stop()
    done(message)
  }
}

/// The latest picture and when it was drawn, from the session's thread to the main one.
private final class LatestFrame: @unchecked Sendable {
  private let lock = NSLock()
  private var frame: (Snapshot, Date)?

  func set(_ snapshot: Snapshot, at time: Date) {
    lock.lock()
    frame = (snapshot, time)
    lock.unlock()
  }

  func get() -> (Snapshot, Date)? {
    lock.lock()
    defer { lock.unlock() }
    return frame
  }
}

import SwiftUI
import TinySAKit

/// The Capture sheet: how many of the latest seconds to save (all of them, or drag for fewer), with a picture of the
/// GIF's first frame as it will look, the date and time under it, and its size, measured as the choices change.
struct CaptureSheet: View {
  enum Action { case save, copy }
  struct Choice {
    let seconds: TimeInterval
    let action: Action
  }

  let clip: Clip
  let done: (Choice?) -> Void

  @AppStorage(Preferences.Key.gifShowsDate) private var showsDate = true
  @AppStorage(Preferences.Key.gifShowsTime) private var showsTime = true
  @AppStorage(Preferences.Key.gifScale) private var scale = 2
  @State private var seconds: Double
  @StateObject private var frames = FrameCache()
  @StateObject private var estimate = SizeEstimate()

  init(clip: Clip, done: @escaping (Choice?) -> Void) {
    self.clip = clip
    self.done = done
    _seconds = State(initialValue: max(1, clip.duration.rounded(.down)))
  }

  private var longest: Double { max(1, clip.duration.rounded(.down)) }
  private var start: Date { clip.end.addingTimeInterval(-seconds) }
  private var screen: (width: Int, height: Int) { (clip.frames.last?.width ?? 480, clip.frames.last?.height ?? 320) }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Save the last \(Self.duration(seconds)) as a GIF")
        .font(.headline)
      preview
      VStack(alignment: .leading, spacing: 4) {
        if longest > 1 {
          // Whole seconds, without a tick mark for each.
          Slider(value: Binding(get: { seconds }, set: { seconds = $0.rounded() }), in: 1...longest) {
            Text("Length")
          } minimumValueLabel: {
            Text("0:01").monospacedDigit()
          } maximumValueLabel: {
            Text(Self.duration(longest)).monospacedDigit()
          }
          .accessibilityValue("\(Int(seconds)) seconds")
        }
        Text(summary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      HStack(spacing: 18) {
        Text("Under the screen:")
        Toggle("Date", isOn: $showsDate)
        Toggle("Time", isOn: $showsTime)
      }
      HStack(spacing: 12) {
        Picker("Size:", selection: $scale) {
          Text(size(1)).tag(1)
          Text(size(2)).tag(2)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        if let bytes = estimate.bytes {
          Text(GIFController.size(bytes))
            .foregroundStyle(.secondary)
            .accessibilityLabel("The GIF will take \(GIFController.size(bytes))")
        } else {
          ProgressView().controlSize(.small)
        }
      }
      HStack {
        Spacer()
        Button("Cancel") { done(nil) }
          .keyboardShortcut(.cancelAction)
        Button("Copy") { done(Choice(seconds: seconds, action: .copy)) }
          .keyboardShortcut("c")
          .help("Copy the GIF to paste into a chat or an email (⌘C)")
        Button("Save to Desktop") { done(Choice(seconds: seconds, action: .save)) }
          .keyboardShortcut(.defaultAction)
        // ⌘S saves too, as the screenshot's does outside the sheet.
        Button("") { done(Choice(seconds: seconds, action: .save)) }
          .keyboardShortcut("s")
          .frame(width: 0, height: 0)
          .opacity(0)
          .accessibilityHidden(true)
      }
    }
    .padding(20)
    .frame(width: 520)
    .task(id: "\(seconds) \(scale) \(showsDate) \(showsTime)") {
      estimate.update(clip.last(seconds), options: GIFOptions(scale: scale, showsDate: showsDate, showsTime: showsTime))
    }
    .onDisappear { estimate.cancel() }
  }

  /// The GIF's first frame as it will look, strip and all: drawn twice the screen's size, shown at half that, so a
  /// Retina display shows each pixel of it.
  private var preview: some View {
    let options = GIFOptions(scale: 2, showsDate: showsDate, showsTime: showsTime)
    let still = frames.snapshot(of: clip.frame(at: start)).map { GIF.still($0, at: start, options: options) }
    let image = still?.image()
    let width = CGFloat(min(screen.width, 480))  // a wider fed picture is shown smaller, to fit the sheet
    let height = image.map { width * CGFloat($0.height) / CGFloat($0.width) } ?? width * CGFloat(screen.height) / CGFloat(screen.width)
    return Group {
      if let image {
        Image(decorative: image, scale: 2)
          .resizable()
          .interpolation(.high)
          .frame(width: width, height: height)
          .accessibilityLabel("The GIF's first frame, at \(Self.clock(start))")
      } else {
        Color.black.frame(width: width, height: height)
      }
    }
  }

  private var summary: String {
    let shown = clip.frames.filter { $0.time > start }.count + 1
    return "From \(Self.clock(start)) to \(Self.clock(clip.end)), \(shown) frame\(shown == 1 ? "" : "s")"
  }

  static func clock(_ moment: Date) -> String {
    moment.formatted(date: .omitted, time: .standard)
  }

  private func size(_ scale: Int) -> String {
    let strip = showsDate || showsTime ? 16 * scale : 0
    let name = scale == 1 ? "Small" : "Sharp"
    return "\(name), \(screen.width * scale) × \(screen.height * scale + strip)"
  }

  /// "0:15", "1:00".
  static func duration(_ seconds: Double) -> String {
    let whole = Int(seconds.rounded())
    return String(format: "%d:%02d", whole / 60, whole % 60)
  }
}

/// Frames unpacked for the preview, one at a time.
@MainActor
final class FrameCache: ObservableObject {
  private var time: Date?
  private var snapshot: Snapshot?

  func snapshot(of frame: RecordedFrame?) -> Snapshot? {
    guard let frame else { return nil }
    if frame.time != time {
      time = frame.time
      snapshot = frame.snapshot()
    }
    return snapshot
  }
}

/// The size of the GIF the sheet would make, measured by making it in the background a moment after the choices stop
/// changing.
@MainActor
final class SizeEstimate: ObservableObject {
  @Published private(set) var bytes: Int?
  private var generation = 0
  private var pending: DispatchWorkItem?
  private static let queue = DispatchQueue(label: "GIF size", qos: .userInitiated)

  func update(_ clip: Clip, options: GIFOptions) {
    generation += 1
    let current = generation
    bytes = nil
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      let bytes = GIF.make(clip, options: options)?.data.count
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, self.generation == current else { return }
          self.bytes = bytes
        }
      }
    }
    pending = work
    Self.queue.asyncAfter(deadline: .now() + 0.25, execute: work)
  }

  /// No more measuring (the sheet closed).
  func cancel() {
    generation += 1
    pending?.cancel()
    pending = nil
  }
}

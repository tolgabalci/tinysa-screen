import AppKit
import SwiftUI
import TinySAKit

/// Record and Capture: GIFs of the analyzer's screen. Record runs from ⌘R until it is stopped (or for two minutes, the
/// longest a GIF runs) and saves to the Desktop; Capture saves the latest seconds kept, as many of them as wanted.
@MainActor
final class GIFController {
  private let recorder: FrameRecorder
  private weak var window: NSWindow?
  private let view: ScreenView
  /// Where the picture comes from (the window's subtitle), kept in the GIF's comment.
  var source = ""
  /// Recording began, ticked or ended: for the toolbar and the menus.
  var onChange: (() -> Void)?

  private var recording: UUID?
  private var timer: Timer?
  private var sheet: NSWindow?
  private static let queue = DispatchQueue(label: "GIFs", qos: .userInitiated)

  init(recorder: FrameRecorder, window: NSWindow, view: ScreenView) {
    self.recorder = recorder
    self.window = window
    self.view = view
    Self.removeOldCopies()
  }

  var isRecording: Bool { recording != nil }

  /// How long the recording has been running.
  var elapsed: TimeInterval {
    guard let recording, let started = recorder.started(recording) else { return 0 }
    return Date().timeIntervalSince(started)
  }

  var canCapture: Bool { sheet == nil && recorder.recentSeconds() >= 1 }

  // MARK: Record

  func toggleRecording() {
    if isRecording { stopRecording() } else { startRecording() }
  }

  func startRecording() {
    guard recording == nil else { return }
    guard recorder.hasSnapshot else {
      view.flash("Nothing to record yet: no picture from the tinySA.")
      return
    }
    recording = recorder.begin()
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    onChange?()
  }

  private func tick() {
    if elapsed >= FrameRecorder.longest {
      stopRecording(reachedLimit: true)
    } else {
      onChange?()
    }
  }

  func stopRecording(reachedLimit: Bool = false) {
    guard let id = recording else { return }
    recording = nil
    timer?.invalidate()
    timer = nil
    onChange?()
    guard let clip = recorder.end(id) else {
      view.flash("Nothing was recorded: no picture came.")
      return
    }
    let note = reachedLimit ? "Recording stopped at 2:00, the longest a GIF runs. " : ""
    save(clip, options: options(), note: note)
  }

  // MARK: Capture

  /// Opens the Capture sheet with the seconds kept up to now.
  func capture() {
    guard sheet == nil, let window else { return }
    guard let clip = recorder.recent(), clip.duration >= 1 else {
      view.flash("Nothing to capture yet.")
      return
    }
    let host = NSHostingController(
      rootView: CaptureSheet(clip: clip) { [weak self] choice in self?.finishCapture(clip, choice) })
    let sheet = NSWindow(contentViewController: host)
    sheet.title = "Capture"
    self.sheet = sheet
    onChange?()
    window.beginSheet(sheet)
  }

  private func finishCapture(_ clip: Clip, _ choice: CaptureSheet.Choice?) {
    if let sheet { window?.endSheet(sheet) }
    sheet = nil
    onChange?()
    guard let choice else { return }
    let part = clip.last(choice.seconds)
    switch choice.action {
    case .save: save(part, options: options())
    case .copy: copy(part, options: options())
    }
  }

  // MARK: Making GIFs

  private func options() -> GIFOptions {
    GIFOptions(
      scale: Preferences.gifScale, showsDate: Preferences.gifShowsDate, showsTime: Preferences.gifShowsTime,
      comment: nil)
  }

  /// The GIF's comment: where the picture came from, and when.
  private func comment(_ clip: Clip) -> String {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime]
    format.timeZone = .current
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return [
      source.isEmpty ? nil : source,
      "\(format.string(from: clip.start)) to \(format.string(from: clip.end))",
      "tinySA Screen" + (version.map { " \($0)" } ?? ""),
    ].compactMap { $0 }.joined(separator: " · ")
  }

  private func make(_ clip: Clip, options: GIFOptions, then finish: @escaping @MainActor (GIFResult?) -> Void) {
    var options = options
    options.comment = comment(clip)
    Self.queue.async {
      let result = GIF.make(clip, options: options)
      DispatchQueue.main.async { MainActor.assumeIsolated { finish(result) } }
    }
  }

  private func save(_ clip: Clip, options: GIFOptions, note: String = "") {
    view.flash(note + "Making the GIF…")
    let url = Self.desktopURL(for: clip.start)
    make(clip, options: options) { [weak self] result in
      guard let self else { return }
      do {
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.data.write(to: url, options: .atomic)
        self.view.flash(note + "Saved to the Desktop: \(url.lastPathComponent) (\(Self.size(result.data.count)))")
      } catch {
        self.view.flash("The GIF couldn't be saved: \(error.localizedDescription)")
      }
    }
  }

  /// Copies the GIF as a file, as Finder does, which chats and mail take as an animated GIF; and as GIF data for apps
  /// that take images.
  private func copy(_ clip: Clip, options: GIFOptions) {
    view.flash("Making the GIF…")
    make(clip, options: options) { [weak self] result in
      guard let self else { return }
      do {
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        let folder = Self.copiesFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.name(for: clip.start))
        try result.data.write(to: url, options: .atomic)
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setData(result.data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        self.view.flash("Copied the GIF (\(Self.size(result.data.count)))")
      } catch {
        self.view.flash("The GIF couldn't be copied: \(error.localizedDescription)")
      }
    }
  }

  // MARK: Files

  /// "tinySA 2026-10-17 at 10.15.32.gif", named after the clip's start like the Mac's screen recordings.
  static func name(for start: Date, number: Int = 1) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return "tinySA \(formatter.string(from: start))" + (number > 1 ? " (\(number))" : "") + ".gif"
  }

  /// A new file on the Desktop, never one already there.
  static func desktopURL(for start: Date) -> URL {
    let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    var number = 1
    while true {
      let url = desktop.appendingPathComponent(name(for: start, number: number))
      if !FileManager.default.fileExists(atPath: url.path) { return url }
      number += 1
    }
  }

  static func size(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  /// Where copied GIFs are kept for the apps they're pasted into: a day.
  static var copiesFolder: URL { Integration.feedFolder.appendingPathComponent("Copied GIFs", isDirectory: true) }

  private static func removeOldCopies() {
    let manager = FileManager.default
    guard
      let files = try? manager.contentsOfDirectory(
        at: copiesFolder, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }
    for file in files {
      let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      if let modified, Date().timeIntervalSince(modified) > 86_400 { try? manager.removeItem(at: file) }
    }
  }
}

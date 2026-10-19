import AppKit
import SwiftUI
import TinySAKit

/// Record and Capture: GIFs of the analyzer's screen. Record runs from ⌘R until it is stopped (or for two minutes, the
/// longest a GIF runs) and saves to the folder chosen in Settings (the Desktop at first); Capture saves the latest
/// seconds kept, as many of them as wanted.
@MainActor
final class GIFController {
  private let recorder: FrameRecorder
  private weak var window: NSWindow?
  private let view: ScreenView
  /// Where the picture comes from (the window's subtitle), kept in the GIF's comment.
  var source = ""
  /// Why no live picture comes (the window's note), or nil while it's live; and since when it hasn't come. A GIF never
  /// shows an old picture as if it were live: Record starts only from a live picture, and a GIF ends where it stopped.
  var notLive: (note: String, since: Date)?
  /// Recording began, ticked or ended: for the toolbar and the menus.
  var onChange: (() -> Void)?

  private var recording: UUID?
  private var timer: Timer?
  private var sheet: NSWindow?
  /// GIFs being made and written, and what waits for them (quitting).
  private var saving = 0
  private var whenSaved: [() -> Void] = []
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
    if let notLive {
      view.flash("Nothing to record: \(notLive.note)")
      return
    }
    guard recorder.hasSnapshot else {
      view.flash("Nothing to record yet: no picture from the tinySA.")
      return
    }
    recording = recorder.begin()
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)  // the time and the 2:00 stop go on while a menu is open
    self.timer = timer
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
    guard let clip = recorder.end(id, at: notLive?.since ?? Date()) else {
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
    guard let clip = recorder.recent(at: notLive?.since ?? Date()), clip.duration >= 1 else {
      view.flash(notLive.map { "Nothing to capture: \($0.note)" } ?? "Nothing to capture yet.")
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
    saving += 1
    Self.queue.async {
      let result = GIF.make(clip, options: options)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          finish(result)
          self.saved()
        }
      }
    }
  }

  private func saved() {
    saving -= 1
    guard saving == 0 else { return }
    let waiting = whenSaved
    whenSaved.removeAll()
    for done in waiting { done() }
  }

  /// Stops a recording and saves it, then calls `done` once every GIF in the making is written: for quitting.
  func finish(then done: @escaping () -> Void) {
    if isRecording { stopRecording() }
    if saving == 0 {
      done()
    } else {
      whenSaved.append(done)
    }
  }

  var isBusy: Bool { isRecording || saving > 0 }

  private func save(_ clip: Clip, options: GIFOptions, note: String = "") {
    view.flash(note + "Making the GIF…")
    make(clip, options: options) { [weak self] result in
      guard let self else { return }
      do {
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        // Named now: another GIF may have been saved meanwhile.
        let saved = try Preferences.saveFolder.save(for: clip.start, extension: "gif") {
          try result.data.write(to: $0, options: .atomic)
        }
        if let moved = saved.moved { Preferences.saveFolder = moved }
        self.view.flash(note + saved.note(size: Self.size(result.data.count)))
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
        let url = folder.appendingPathComponent(SaveFolder.fileName(for: clip.start))
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

extension SaveFolder.Saved {
  /// What the window says once the file is written: where it went, and why not to the chosen folder when it didn't.
  func note(size: String? = nil) -> String {
    let onDesktop =
      url.deletingLastPathComponent().resolvingSymlinksInPath().path
      == SaveFolder.desktopURL.resolvingSymlinksInPath().path
    let file = url.lastPathComponent + (size.map { " (\($0))" } ?? "")
    if let instead { return "\(instead), so it went to the Desktop: \(file)" }
    return "Saved to \(onDesktop ? "the Desktop" : folder): \(file)"
  }
}

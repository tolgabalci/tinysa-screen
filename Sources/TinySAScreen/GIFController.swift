import AppKit
import SwiftUI
import TinySAKit

/// Record: GIFs of the analyzer's screen. A recording holds on to the seconds kept from before Record was pressed
/// (Settings › Recording), runs from ⌘R until it is stopped or has run as long as Settings lets it, and Stop opens the
/// editor with its GIF starting the lead-in set in Settings before Record, to trim it or take in more of the seconds
/// before; ⌥ Stop & Save saves that GIF as it is. GIFs go to the folder chosen in Settings (the Desktop at first).
@MainActor
final class GIFController {
  private let recorder: FrameRecorder
  private weak var window: NSWindow?
  private let view: ScreenView
  /// Where the picture comes from (the analyzer and its firmware, or the feeding program), kept in the GIF's comment.
  var source = ""
  /// Why no live picture comes (the window's note), or nil while it's live; and since when it hasn't come. A GIF never
  /// shows an old picture as if it were live: Record starts only from a live picture, and a GIF ends where it stopped.
  var notLive: (note: String, since: Date)?
  /// Recording began, ticked or ended: for the toolbar and the menus.
  var onChange: (() -> Void)?
  /// A GIF written (saved, or copied as a file): its file, for the toolbar's link to it.
  var onMade: ((URL) -> Void)?

  /// The recording running: the recorder's, how long it may run, and how far before Record its GIF starts.
  private var recording: (id: UUID, longest: TimeInterval, leadIn: TimeInterval)?
  private var timer: Timer?
  /// The editor Stop opened, while it's open.
  private var editor: (sheet: NSWindow, model: TrimModel)?
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
  var isEditing: Bool { editor != nil }

  /// How long the recording has been running since Record was pressed.
  var elapsed: TimeInterval {
    guard let recording, let started = recorder.started(recording.id) else { return 0 }
    return Date().timeIntervalSince(started)
  }

  /// How long the recording's GIF is so far, as Stop & Save would save it: from the lead-in before Record (as far back
  /// as the seconds kept went) to now.
  var length: TimeInterval {
    guard let recording, let started = recorder.started(recording.id), let from = recorder.clipStart(recording.id)
    else { return 0 }
    return Date().timeIntervalSince(max(from, started.addingTimeInterval(-recording.leadIn)))
  }

  /// How far before Record the GIF starts, and the longest the recording runs after it: those of the recording
  /// running, or Settings' for the next.
  var leadIn: TimeInterval { recording?.leadIn ?? TimeInterval(Preferences.recordLeadIn) }
  var longest: TimeInterval { recording?.longest ?? TimeInterval(Preferences.recordLongest) }

  /// Record can start (not while the editor is open) or stop.
  var canRecord: Bool { isRecording || (editor == nil && recorder.hasSnapshot) }

  // MARK: Record

  /// Record, or Stop: the editor opens, or with `andSave` (⌥), the GIF is saved as it is.
  func toggleRecording(andSave: Bool = false) {
    if isRecording { stopRecording(andSave: andSave) } else { startRecording() }
  }

  func startRecording() {
    guard recording == nil, editor == nil else { return }
    if let notLive {
      view.flash("Nothing to record: \(notLive.note)")
      return
    }
    guard recorder.hasSnapshot else {
      view.flash("Nothing to record yet: no picture from the tinySA.")
      return
    }
    let longest = TimeInterval(Preferences.recordLongest)
    let id = recorder.begin(before: TimeInterval(Preferences.keptSeconds), longest: longest)
    recording = (id, longest, TimeInterval(Preferences.recordLeadIn))
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)  // the time and the stop at the longest go on while a menu is open
    self.timer = timer
    onChange?()
  }

  private func tick() {
    if let recording, elapsed >= recording.longest {
      stopRecording(reachedLimit: true)
    } else {
      onChange?()
    }
  }

  /// Stops the recording and opens the editor with its GIF, or with `andSave`, saves that GIF as it is.
  func stopRecording(andSave: Bool = false, reachedLimit: Bool = false) {
    guard let (id, longest, leadIn) = recording else { return }
    recording = nil
    timer?.invalidate()
    timer = nil
    let began = recorder.started(id) ?? Date()
    onChange?()
    guard let clip = recorder.end(id, at: notLive?.since ?? Date()) else {
      view.flash("Nothing was recorded: no picture came.")
      return
    }
    let trim = Trim(clip, began: began, leadIn: leadIn)
    let note =
      reachedLimit
      ? "Recording stopped at \(TimeText.duration(longest)), the longest Settings › Recording lets it run." : nil
    if andSave || window == nil {
      save(clip.part(trim), options: options(), note: note.map { $0 + " " } ?? "")
    } else {
      edit(clip, began: began, trim: trim, note: note)
    }
  }

  // MARK: The editor

  private func edit(_ clip: Clip, began: Date, trim: Trim, note: String?) {
    guard let window else { return }
    let model = TrimModel(clip: clip, began: began, trim: trim)
    let host = NSHostingController(
      rootView: RecordingEditor(model: model, note: note) { [weak self] action in self?.finishEditing(action) })
    let sheet = NSWindow(contentViewController: host)
    sheet.title = "Recording"
    model.undoManager = sheet.undoManager
    editor = (sheet, model)
    onChange?()
    window.beginSheet(sheet)
  }

  private func finishEditing(_ action: RecordingEditor.Action?) {
    guard let (sheet, model) = editor else { return }
    model.pause()
    window?.endSheet(sheet)
    editor = nil
    onChange?()
    guard let action else { return }
    let part = model.clip.part(model.trim)
    switch action {
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

  /// Stops a recording and saves it, or saves the GIF the editor shows, then calls `done` once every GIF in the making
  /// is written: for quitting, so that no recording is lost to it.
  func finish(then done: @escaping () -> Void) {
    if isRecording { stopRecording(andSave: true) }
    if editor != nil { finishEditing(.save) }
    if saving == 0 {
      done()
    } else {
      whenSaved.append(done)
    }
  }

  var isBusy: Bool { isRecording || editor != nil || saving > 0 }

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
        self.onMade?(saved.url)
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
        self.onMade?(url)
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

import AppKit
import SwiftUI
import TinySAKit
import UniformTypeIdentifiers

/// The editor Stop opens, in a window of its own: the whole recording, the seconds kept from before Record included,
/// with the part the GIF keeps between two yellow handles. It starts as Stop & Save would save it (from the lead-in set
/// in Settings before Record, to Stop); a handle dragged back takes in more of the seconds before, either one dragged
/// in trims. The picture shows the frame at the playhead as the GIF will, strip and all, as large as the window lets
/// it, and follows a handle while it moves; Play plays the part kept in a loop, as the GIF will. Beside it: the
/// date and time under the screen, the size, and the folder the GIF is saved in, kept for the next.
struct RecordingEditor: View {
  enum Action { case save, copy }

  @ObservedObject var model: TrimModel
  /// Why the recording stopped by itself, when it did.
  let note: String?
  let done: (Action?) -> Void

  @AppStorage(Preferences.Key.gifShowsDate) private var showsDate = true
  @AppStorage(Preferences.Key.gifShowsTime) private var showsTime = true
  @AppStorage(Preferences.Key.gifShowsElapsed) private var showsElapsed = true
  @AppStorage(Preferences.Key.gifShowsProgress) private var showsProgress = true
  @AppStorage(Preferences.Key.gifScale) private var scale = 2
  @AppStorage(Preferences.Key.gifLoops) private var loops = true
  @AppStorage(Preferences.Key.gifPauseAtEnd) private var pauseAtEnd = 5
  @StateObject private var stills = StillCache()
  @StateObject private var estimate = SizeEstimate()
  @FocusState private var typingFolder: Bool
  @State private var folderDropping = false
  @Environment(\.displayScale) private var displayScale

  /// The column beside the picture, the window's smallest content, and what isn't the picture in its size.
  static let side: CGFloat = 250
  static let smallest = CGSize(width: 760, height: 540)
  static let aroundPicture = CGSize(width: 20 + 20 + side + 20, height: 262)

  private var screen: (width: Int, height: Int) {
    (model.clip.frames.last?.width ?? 480, model.clip.frames.last?.height ?? 320)
  }

  /// How the GIF is made: Settings' choices (which the editor changes) and this GIF's speed.
  private var options: GIFOptions {
    GIFOptions(
      scale: scale, showsDate: showsDate, showsTime: showsTime, showsElapsed: showsElapsed,
      showsProgress: showsProgress, loops: loops,
      pauseAtEnd: TimeInterval(min(max(pauseAtEnd, 0), 10)), speed: model.speed,
      framesPerSecond: model.effectiveFramesPerSecond)
  }

  /// The strip's rows under the screen, at the screen's own size.
  private var captionRows: Int { options.hasCaption ? 16 : 0 }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      HStack(alignment: .top, spacing: 20) {
        preview
        ScrollView(.vertical) {
          side
            .background(GeometryReader { area in Color.clear.onAppear { model.sideHeight = area.size.height } })
        }
        .frame(width: Self.side)
      }
      .frame(maxHeight: .infinity)
      VStack(spacing: 8) {
        TrimStrip(model: model)
        transport
      }
      bottomBar
    }
    .padding(20)
    .frame(
      minWidth: Self.smallest.width, maxWidth: .infinity, minHeight: Self.smallest.height, maxHeight: .infinity,
      alignment: .topLeading
    )
    .background(KeyCatcher(model: model))
    .task(id: estimateKey) {
      var options = options
      options.scale = scale
      estimate.update(model.clip.part(model.trim), options: options)
    }
    .onDisappear {
      estimate.cancel()
      model.pause()
    }
    .alert("Delete the recording?", isPresented: $model.confirmingDelete) {
      Button("Delete", role: .destructive) { done(nil) }
      Button("Keep Editing", role: .cancel) {}
    } message: {
      Text("It isn't saved anywhere else, so it can't be brought back.")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let note {
        Text(note)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(hint)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.callout)
  }

  private var hint: String {
    let more = model.trim.start.timeIntervalSince(model.clip.start)
    return "Drag the yellow ends to choose the GIF's part, or press I or O at the playhead."
      + (more >= 1 ? " Its start can go back \(TimeText.spoken(more)) more." : "")
  }

  // MARK: The picture

  /// The frame at the playhead as the GIF shows it, strip and all, as large as fits: at a size where each of the
  /// screen's pixels is whole display pixels when that's near, drawn from a still made at least that sharp. Playing,
  /// it's the GIF's own moments (fewer at a faster speed with fewer frames a second), and its pause at the end. A
  /// click plays or pauses.
  private var preview: some View {
    GeometryReader { area in
      let rows = screen.height + captionRows
      let fit = min(area.size.width / CGFloat(screen.width), area.size.height / CGFloat(rows))
      let shown = Self.crisp(fit, displayScale: displayScale)
      let exact = shown * displayScale
      let pixels = min(max(Int((exact - 0.01).rounded(.up)), 1), 4)
      var still = options
      let _ = still.scale = pixels
      let moment = model.shownMoment(options)
      let caption = model.clip.caption(
        at: moment, from: model.trim.start, to: model.trim.end, window: max(1, options.stepOfRecording),
        ended: model.pausing && options.pauseAtEnd > 1)
      let image = stills.image(of: model.clip.frame(at: moment), caption: caption, options: still)
      let width = CGFloat(screen.width) * shown
      let height = CGFloat(rows) * shown
      // On whole display pixels, so a picture shown at its own pixels isn't blurred by half a pixel.
      let x = ((area.size.width - width) / 2 * displayScale).rounded(.down) / displayScale
      let _ = model.pictureArea = (area.size, CGSize(width: width, height: height))
      picture(image, width: width, height: height, whole: abs(exact - CGFloat(pixels)) < 0.01)
        .offset(x: x)
    }
  }

  /// Points a pixel of the screen takes: as many as fit, or a few fewer where that shows each pixel as whole display
  /// pixels (every half point on a Retina display, every point elsewhere), and no more than four display pixels.
  static func crisp(_ fit: CGFloat, displayScale: CGFloat) -> CGFloat {
    let display = max(displayScale, 1)
    let fit = min(fit, 4 / display)
    guard fit >= 1 else { return max(fit, 0.25) }
    let whole = (fit * display).rounded(.down) / display
    return fit <= whole * 1.06 ? whole : fit
  }

  private func picture(_ image: CGImage?, width: CGFloat, height: CGFloat, whole: Bool) -> some View {
    let outside =
      model.playhead < model.trim.start
      ? "Before the GIF" : model.playhead > model.trim.end ? "After the GIF" : nil
    return Group {
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(whole ? .none : .high)
      } else {
        Color.black
      }
    }
    .frame(width: width, height: height)
    .overlay(alignment: .bottomLeading) {
      if let outside {
        Text(outside)
          .font(.caption.weight(.medium))
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.thinMaterial, in: Capsule())
          .padding(6)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      model.takeKeys()
      model.togglePlay()
    }
    .accessibilityElement()
    .accessibilityLabel(
      "The GIF at \(TimeText.clock(model.playhead))" + (outside.map { ", \($0.lowercased())" } ?? ""))
    .accessibilityAddTraits(.isButton)
    .accessibilityHint(model.isPlaying ? "Pauses" : "Plays the GIF")
    .help(model.isPlaying ? "Pause (Space)" : "Play the GIF (Space)")
  }

  /// The GIF's start and end, and between them Play and where the playhead is in the GIF.
  private var transport: some View {
    let into = model.playhead.timeIntervalSince(model.trim.start)
    return HStack(spacing: 10) {
      Text(TimeText.preciseClock(model.trim.start))
        .help("When the GIF starts")
        .accessibilityLabel("Starts at \(TimeText.clock(model.trim.start))")
      Spacer()
      Button {
        model.takeKeys()
        model.togglePlay()
      } label: {
        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
          .frame(width: 30)
      }
      .buttonStyle(.borderless)
      .help(model.isPlaying ? "Pause (Space)" : "Play the GIF (Space)")
      .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
      Text("\(TimeText.precise(into)) / \(TimeText.precise(model.trim.duration))")
        .help("Where the playhead is in the recording's part, and how long it is")
        .accessibilityLabel(
          "\(TimeText.spoken(abs(into))) \(into < 0 ? "before the GIF" : "into the GIF"), of "
            + TimeText.spoken(model.trim.duration))
      Spacer()
      Text(TimeText.preciseClock(model.trim.end))
        .help("When the GIF ends")
        .accessibilityLabel("Ends at \(TimeText.clock(model.trim.end))")
    }
    .font(.system(size: 24).monospacedDigit())  // twice the callout size: the GIF's ends and length at a glance
    .foregroundStyle(.secondary)
  }

  // MARK: Beside the picture

  private var side: some View {
    VStack(alignment: .leading, spacing: 14) {
      group("Under the screen") {
        Toggle("The date", isOn: $showsDate)
        Toggle("The time, to the second", isOn: $showsTime)
        Toggle("Elapsed and total time", isOn: $showsElapsed)
          .help("How far into the GIF, of how long it is, at the strip's left: 0:10 / 2:30")
        Toggle("Progress bar", isOn: $showsProgress)
          .help("A bar at the strip's left that fills as the GIF plays, a second at a time, the time in it")
      }
      group("Playing") {
        Toggle("Loop", isOn: $loops)
          .help("Loop the GIF; off, it plays once and stays at its end")
        Stepper(value: $pauseAtEnd, in: 0...10) {
          Text("Pause at the end: \(pauseAtEnd == 0 ? "none" : "\(pauseAtEnd) s")")
            .monospacedDigit()
        }
        .help("Hold the last frame this long; longer than a second, \"End of recording\" shows under the screen")
        .accessibilityValue(pauseAtEnd == 0 ? "None" : "\(pauseAtEnd) seconds")
      }
      group("Resolution") {
        Picker("Resolution", selection: $scale) {
          Text(size(2)).tag(2)
          Text(size(1)).tag(1)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
      }
      group("Speed") {
        HStack(spacing: 8) {
          Slider(value: Binding(get: { model.speed }, set: { model.speed = $0.rounded() }), in: 1...20)
            .accessibilityValue("\(Int(model.speed)) times")
          Text("\(Int(model.speed))×")
            .monospacedDigit()
            .frame(width: 30, alignment: .trailing)
        }
        Text("Plays in \(TimeText.duration(options.playingTime(of: model.trim.duration)))")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .help("How many times faster than it happened the GIF plays: a minute at 10× plays in 6 seconds")
      group("Frames a second") {
        HStack(spacing: 8) {
          // 1 to 10, then Full: every frame.
          Slider(
            value: Binding(
              get: { Double(model.framesPerSecond ?? 11) },
              set: { value in
                let frames = Int(value.rounded())
                model.framesPerSecond = frames > 10 ? nil : frames
              }),
            in: 1...11
          )
          .accessibilityValue(model.framesPerSecond.map { "\($0) a second" } ?? "Every frame")
          Text(model.framesPerSecond.map { "\($0)" } ?? "Full")
            .monospacedDigit()
            .frame(width: 34, alignment: .trailing)
        }
        Text(
          model.speed <= 1
            ? "Faster than 1× to choose"
            : model.framesPerSecond == nil ? "Every frame: as smooth as it was" : "As it plays: fewer make it smaller")
          .font(.system(size: 24))  // twice the callout size: what the slider does, at a glance
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .disabled(model.speed <= 1)
      .help(
        "Full shows every frame of the recording. Fewer, each the screen as it was then, make a smaller file: at 10×, "
          + "1 a second shows every tenth second of the recording")
      VStack(alignment: .leading, spacing: 2) {
        Text("Estimated GIF size")
          .foregroundStyle(.secondary)
        if let bytes = estimate.bytes {
          Text(GIFController.size(bytes))
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .foregroundStyle(Self.sizeColor(bytes))
            .help("Green under 2 MB; orange from 2 MB; red from 10 MB, more than many chats and sites take")
        } else {
          ProgressView()
            .controlSize(.small)
            .frame(height: 36)
        }
      }
      .accessibilityElement(children: .combine)
    }
    .padding(.trailing, 4)
  }

  private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.headline)
      content()
    }
  }

  /// Green while small, orange from 2 MB, red from 10 MB (more than many chats and sites take).
  static func sizeColor(_ bytes: Int) -> Color {
    switch bytes {
    case ..<2_000_000: return Color(nsColor: .systemGreen)
    case ..<10_000_000: return Color(nsColor: .systemOrange)
    default: return Color(nsColor: .systemRed)
    }
  }

  // MARK: The bottom: Copy, and where the GIF is saved

  /// Copy at the left; at the right, the folder the GIF goes to (the one kept from the last GIF saved, the Desktop at
  /// first: typed over, chosen with Choose…, or a folder dropped on it), then Save and Cancel. The folder is kept for
  /// the next once the GIF is saved there, and made then if it's new.
  private var bottomBar: some View {
    HStack(spacing: 10) {
      Button("Copy") { done(.copy) }
        .buttonStyle(.borderedProminent)
        .tint(Color(nsColor: .systemGreen))
        .keyboardShortcut(typingFolder ? nil : KeyboardShortcut("c"))  // in the folder, ⌘C copies its text
        .help("Copy the GIF to paste into a chat or an email (⌘C)")
        .fixedSize()
      if let note = folderNote {
        Text(note.text)
          .font(.callout)
          .foregroundStyle(note.problem ? Color(nsColor: .systemRed) : .secondary)
          .lineLimit(2)
          .layoutPriority(-1)
      }
      Spacer(minLength: 16)
        .frame(maxWidth: 16)
      Text("Save to:")
        .fixedSize()
      TextField("Folder", text: $model.folder, prompt: Text("~/Desktop"))
        .textFieldStyle(.roundedBorder)
        .truncationMode(.head)  // a long path shows its end: the folder's own name
        .focused($typingFolder)
        .frame(minWidth: 220, maxWidth: .infinity)
        .layoutPriority(1)
        .help("The folder the GIF is saved in, kept for the next: type one, or drop one here")
        .accessibilityLabel("Save to folder")
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.accentColor, lineWidth: 2)
            .opacity(folderDropping ? 1 : 0)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $folderDropping) { providers in
          guard let provider = providers.first else { return false }
          _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
              MainActor.assumeIsolated { model.dropped(url) }
            }
          }
          return true
        }
      Button("Choose…") { model.chooseFolder() }
        .help("Choose the folder the GIF is saved in")
        .fixedSize()
      Button("Save") { save() }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSave)
        .help("Save the GIF in \(model.folder.isEmpty ? "the folder" : model.folder) (Return)")
        .fixedSize()
      Button("Cancel") {
        model.pause()
        model.confirmingDelete = true
      }
      .keyboardShortcut(.cancelAction)
      .help("Delete the recording without making a GIF (Esc)")
      .fixedSize()
      // ⌘S saves too, as the screenshot's does in the app's window.
      Button("") { save() }
        .keyboardShortcut("s")
        .disabled(!model.canSave)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
  }

  private var folderNote: (text: String, problem: Bool)? {
    if model.folder == model.keptFolder, model.keptFolderMissing {
      return ("Not found, so the GIF goes to the Desktop until it's back.", false)
    }
    switch model.folderStatus {
    case .ready: return nil
    case .new: return ("A new folder: it's made when the GIF is saved.", false)
    case .file: return ("That's a file, not a folder.", true)
    case .locked: return ("tinySA Screen can't save there.", true)
    case .empty: return ("Type a folder, or choose one.", true)
    }
  }

  /// Save, while Save to is somewhere it can save (a key can come before the button shows it can't).
  private func save() {
    guard model.canSave else {
      NSSound.beep()
      return
    }
    done(.save)
  }

  private var estimateKey: String {
    let start = model.trim.start.timeIntervalSinceReferenceDate
    let end = model.trim.end.timeIntervalSinceReferenceDate
    return "\(start) \(end) \(options.hashValue)"
  }

  private func size(_ scale: Int) -> String {
    let name = scale == 1 ? "Small" : "Sharp"
    return "\(name), \(screen.width * scale) × \(screen.height * scale + captionRows * scale)"
  }
}

/// The editor's window, over the app's: at first as large as the screen comfortably takes, its picture at the largest
/// size whose pixels show whole (up to two points a pixel of the screen), or the size the last one was left at; it
/// can be resized, and closing it asks first, as Cancel does. Not a sheet: the app's window stays where it is and keeps
/// showing the analyzer, and Record can start again while it's open.
@MainActor
final class EditorWindow: NSObject, NSWindowDelegate {
  let window: NSWindow
  let model: TrimModel

  init(model: TrimModel, note: String?, done: @escaping (RecordingEditor.Action?) -> Void) {
    self.model = model
    let host = NSHostingController(rootView: RecordingEditor(model: model, note: note, done: done))
    host.sizingOptions = [.minSize]
    window = NSWindow(contentViewController: host)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.title = "Recording at \(TimeText.clock(model.began))"
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.collectionBehavior.insert(.fullScreenAuxiliary)  // over the app's window in full screen too
    super.init()
    window.delegate = self
    model.window = window
    model.undoManager = window.undoManager
  }

  /// Opens it over `parent`, within its screen; the `nth` open at once a little lower and to the right.
  func show(over parent: NSWindow?, nth: Int = 0) {
    let screen = parent?.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 870)
    let chrome = window.frameRect(forContentRect: .zero).size  // the title bar
    let room = NSSize(width: visible.width - 16 - chrome.width, height: visible.height - 16 - chrome.height)
    let remembered = Preferences.editorSize
    let (estimate, picture) = Self.size(for: model.clip, room: room, displayScale: screen?.backingScaleFactor ?? 2)
    var size = remembered ?? estimate
    let least = NSSize(
      width: min(RecordingEditor.smallest.width, room.width), height: min(RecordingEditor.smallest.height, room.height))
    size.width = max(min(size.width, room.width), least.width)
    size.height = max(min(size.height, room.height), least.height)
    let center = parent.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSPoint(x: visible.midX, y: visible.midY)
    let step = CGFloat(nth * 24)
    func place(_ size: NSSize) {
      window.setContentSize(size)
      let frame = window.frame
      let x = min(max(center.x - frame.width / 2 + step, visible.minX + 8), visible.maxX - 8 - frame.width)
      let y = min(max(center.y - frame.height / 2 - step, visible.minY + 8), visible.maxY - 8 - frame.height)
      window.setFrameOrigin(NSPoint(x: x, y: y))
    }
    place(size)
    if remembered == nil {
      // Laid out, the window is made the size that gives the picture its own: room for it and the column beside it,
      // no more (the hint is shorter in a wider window, and the column can be taller than the picture). Twice, as the
      // hint can wrap the first time.
      for _ in 0..<2 {
        window.contentView?.layoutSubtreeIfNeeded()
        let area = model.pictureArea.0
        let wanted = CGSize(width: picture.width, height: max(picture.height, model.sideHeight))
        let change = CGSize(width: wanted.width - area.width, height: wanted.height - area.height)
        guard abs(change.width) > 1 || abs(change.height) > 1 else { break }
        size.width = min(max(size.width + change.width, least.width), room.width)
        size.height = min(max(size.height + change.height, least.height), room.height)
        place(size)
      }
    }
    window.makeKeyAndOrderFront(nil)
  }

  /// The content size, roughly, for the picture at the largest scale whose pixels show whole (half points on a Retina
  /// display, whole points elsewhere, up to two points a pixel) that leaves the window within `room`; and the
  /// picture's size then.
  static func size(for clip: Clip, room: NSSize, displayScale: CGFloat) -> (NSSize, CGSize) {
    let width = CGFloat(clip.frames.last?.width ?? 480)
    let caption = Preferences.gifOptions.hasCaption ? 16 : 0
    let rows = CGFloat((clip.frames.last?.height ?? 320) + caption)
    let around = RecordingEditor.aroundPicture
    let scales: [CGFloat] = displayScale >= 2 ? [2, 1.5, 1] : [2, 1]
    let fits = scales.first { width * $0 + around.width <= room.width && rows * $0 + around.height <= room.height }
    let scale = fits ?? 1
    let picture = CGSize(width: width * scale, height: rows * scale)
    return (NSSize(width: picture.width + around.width, height: picture.height + around.height), picture)
  }

  /// The close button and ⌘W ask, as Cancel does: the recording is nowhere else.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    model.pause()
    model.confirmingDelete = true
    return false
  }

  /// The size it's left at is the next one's.
  func windowDidEndLiveResize(_ notification: Notification) {
    Preferences.editorSize = window.contentLayoutRect.size
  }

  func close() {
    window.delegate = nil
    window.orderOut(nil)
    window.close()
  }
}

/// The filmstrip of the whole recording: the part the GIF keeps framed in yellow between two handles, the rest dimmed,
/// the playhead across it, and above it where Record was pressed. A handle dragged moves that end (⌥ for finer steps),
/// the playhead with it; a drag anywhere else moves the playhead.
struct TrimStrip: View {
  @ObservedObject var model: TrimModel
  @StateObject private var filmstrip = Filmstrip()
  @State private var drag: Drag?

  private enum Part { case start, end, playhead }
  /// A drag under way: what it moves, where that is (ahead of or behind the mouse after a finer step or a stop at the
  /// other handle), and where the mouse was.
  private struct Drag {
    var part: Part
    var x: CGFloat
    var mouse: CGFloat
  }

  static let height: CGFloat = 56
  static let handle: CGFloat = 13
  static let border: CGFloat = 3
  static let yellow = Color(red: 1, green: 0.8, blue: 0.04)

  var body: some View {
    VStack(spacing: 1) {
      GeometryReader { geometry in marker(width: geometry.size.width) }
        .frame(height: 20)
      GeometryReader { geometry in strip(width: geometry.size.width) }
        .frame(height: Self.height)
    }
  }

  // MARK: Where moments are

  private func x(_ moment: Date, _ width: CGFloat) -> CGFloat {
    let inner = max(width - 2 * Self.handle, 1)
    let fraction = model.total > 0 ? moment.timeIntervalSince(model.clip.start) / model.total : 0
    return Self.handle + inner * CGFloat(min(max(fraction, 0), 1))
  }

  private func moment(_ x: CGFloat, _ width: CGFloat) -> Date {
    let inner = max(width - 2 * Self.handle, 1)
    let fraction = Double(min(max((x - Self.handle) / inner, 0), 1))
    return model.clip.start.addingTimeInterval(fraction * model.total)
  }

  // MARK: Drawing

  /// "Record" over the moment it was pressed.
  private func marker(width: CGFloat) -> some View {
    let at = x(model.began, width)
    return VStack(spacing: 0) {
      Text("Record")
        .font(.caption2.weight(.medium))
      Image(systemName: "arrowtriangle.down.fill")
        .font(.system(size: 7))
    }
    .foregroundStyle(Color(nsColor: .systemRed))
    .fixedSize()
    .position(x: min(max(at, 20), width - 20), y: 10)
    .help("Where you pressed Record: before it are the seconds kept from before")
    .accessibilityLabel("Record pressed at \(TimeText.clock(model.began))")
  }

  private func strip(width: CGFloat) -> some View {
    let start = x(model.trim.start, width)
    let end = x(model.trim.end, width)
    let head = x(model.playhead, width)
    let height = Self.height
    let shade = Color.black.opacity(0.62)
    return ZStack(alignment: .topLeading) {
      thumbnails(width: width)
      // The parts the GIF leaves out.
      shade
        .frame(width: max(start - Self.handle, 0), height: height)
        .offset(x: Self.handle)
      shade
        .frame(width: max(width - Self.handle - end, 0), height: height)
        .offset(x: end)
      // The part it keeps, framed, a handle at each end.
      Self.yellow
        .frame(width: max(end - start, 0), height: Self.border)
        .offset(x: start)
      Self.yellow
        .frame(width: max(end - start, 0), height: Self.border)
        .offset(x: start, y: height - Self.border)
      handle(.start)
        .offset(x: start - Self.handle)
      handle(.end)
        .offset(x: end)
      // The playhead, over the frame the picture shows.
      Capsule()
        .fill(Color.white)
        .frame(width: 3, height: height + 8)
        .shadow(color: .black.opacity(0.7), radius: 1.5)
        .offset(x: head - 1.5, y: -4)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue(TimeText.clock(model.playhead))
        .accessibilityAdjustableAction { direction in model.step(forward: direction == .increment) }
    }
    .frame(width: width, height: height, alignment: .topLeading)
    #if DEBUG
      .background(
        GeometryReader { geometry in
          let _ = EditorDemo.strip = geometry.frame(in: .global)
          Color.clear
        })
    #endif
    .contentShape(Rectangle())
    .help(
      "Drag a yellow end to trim the GIF, or anywhere else to move the playhead. Space plays; ← and → step a frame; I "
        + "and O set the start and end at the playhead")
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in dragged(value, width: width, start: start, end: end) }
        .onEnded { _ in
          drag = nil
          model.endDrag()
        }
    )
    .task(id: Int(width)) {
      let tile = Self.height * CGFloat(screenAspect)
      let inner = width - 2 * Self.handle
      filmstrip.make(
        model.clip, count: max(1, Int((inner / tile).rounded(.up))), tileSeconds: model.total * Double(tile / inner),
        pixels: (Int(tile * 2), Int(Self.height * 2)))
    }
  }

  private var screenAspect: Double {
    guard let frame = model.clip.frames.last, frame.height > 0 else { return 1.5 }
    return Double(frame.width) / Double(frame.height)
  }

  private func thumbnails(width: CGFloat) -> some View {
    let tile = Self.height * CGFloat(screenAspect)
    return HStack(spacing: 0) {
      ForEach(filmstrip.tiles.indices, id: \.self) { i in
        Group {
          if let image = filmstrip.tiles[i] {
            Image(decorative: image, scale: 2)
              .resizable()
              .interpolation(.medium)
          } else {
            Color.black
          }
        }
        .frame(width: tile, height: Self.height)
      }
    }
    .frame(width: max(width - 2 * Self.handle, 0), height: Self.height, alignment: .leading)
    .background(Color.black)
    .clipped()
    .offset(x: Self.handle)
    .accessibilityHidden(true)
  }

  private func handle(_ part: Part) -> some View {
    let isStart = part == .start
    let moment = isStart ? model.trim.start : model.trim.end
    return HandleShape(leading: isStart)
      .fill(Self.yellow)
      .overlay {
        Image(systemName: isStart ? "chevron.compact.left" : "chevron.compact.right")
          .font(.system(size: 15, weight: .bold))
          .foregroundStyle(.black.opacity(0.75))
      }
      .frame(width: Self.handle, height: Self.height)
      .accessibilityElement()
      .accessibilityLabel(isStart ? "GIF start" : "GIF end")
      .accessibilityValue(TimeText.clock(moment))
      .accessibilityAdjustableAction { direction in
        let step: TimeInterval = direction == .increment ? 1 : -1
        model.change {
          if isStart {
            model.moveStart(to: model.trim.start.addingTimeInterval(step))
          } else {
            model.moveEnd(to: model.trim.end.addingTimeInterval(step))
          }
        }
      }
      .help("Drag to where the GIF \(isStart ? "starts" : "ends") (⌥ for finer steps)")
  }

  // MARK: Dragging

  private func dragged(_ value: DragGesture.Value, width: CGFloat, start: CGFloat, end: CGFloat) {
    if drag == nil {
      let down = value.startLocation.x
      // A handle is caught a little beyond its edges; between them, the playhead jumps to the mouse.
      let part: Part
      if down >= start - Self.handle - 4, down <= start + 3 {
        part = .start
      } else if down >= end - 3, down <= end + Self.handle + 4 {
        part = .end
      } else {
        part = .playhead
      }
      drag = Drag(part: part, x: part == .start ? start : part == .end ? end : down, mouse: down)
      model.takeKeys()
      model.beginDrag()
    }
    guard var current = drag else { return }
    // ⌥: a tenth as far as the mouse goes, for the frame wanted when the recording is long.
    let fine = NSEvent.modifierFlags.contains(.option)
    current.x += (value.location.x - current.mouse) * (fine ? 0.1 : 1)
    current.mouse = value.location.x
    current.x = min(max(current.x, 0), width)
    drag = current
    let moment = moment(current.x, width)
    switch current.part {
    case .start: model.moveStart(to: moment)
    case .end: model.moveEnd(to: moment)
    case .playhead: model.seek(to: moment)
    }
  }
}

/// A trim handle: rounded on its outer side, square where it meets the frame.
struct HandleShape: Shape {
  let leading: Bool

  func path(in rect: CGRect) -> Path {
    let radius = min(6, rect.width / 2)
    var path = Path()
    if leading {
      path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
      path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + radius), control: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
      path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    } else {
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
      path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
      path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    }
    path.closeSubpath()
    return path
  }
}

/// The editor's state: the recording, the part the GIF keeps, the playhead, and playing.
@MainActor
final class TrimModel: ObservableObject {
  let clip: Clip
  /// When Record was pressed.
  let began: Date
  @Published private(set) var trim: Trim
  @Published private(set) var playhead: Date
  @Published private(set) var isPlaying = false
  /// Times the strip was clicked, for the keys to go to it.
  @Published private(set) var keyRequests = 0
  /// Cancel, or the window's close button, is asking before the recording is deleted.
  @Published var confirmingDelete = false
  /// Save to: the folder as typed, chosen or dropped, and what it comes to.
  @Published var folder: String { didSet { folderStatus = SaveFolder.typed(folder).status } }
  @Published private(set) var folderStatus: SaveFolder.Typed.Status
  /// The folder kept from the last GIF saved, as Save to first shows it, and whether it's missing (on a drive that's
  /// unplugged, say: the GIF then goes to the Desktop, as before).
  let keptFolder: String
  let keptFolderMissing: Bool
  /// The editor's window: for Choose…'s panel, and its undo (⌘Z takes a change of the GIF's ends back).
  weak var window: NSWindow?
  /// The room for the picture and the picture's size, and the height of the column beside it, at their last layout:
  /// the window opens without the room neither takes.
  var pictureArea = (CGSize.zero, CGSize.zero)
  var sideHeight: CGFloat = 0
  /// How fast the GIF plays (1 to 20 times), and its frames a second at most when faster (1 to 10; nil, every frame):
  /// this GIF's own.
  @Published var speed: Double = 1
  @Published var framesPerSecond: Int?
  /// Playing reached the GIF's end and holds there for its pause, as the GIF does.
  @Published private(set) var pausing = false

  /// Frames a second: every frame at the GIF's own speed.
  var effectiveFramesPerSecond: Int? { speed > 1 ? framesPerSecond : nil }

  /// The moment the picture shows: while playing, the GIF's own moment then (fewer when it plays faster with fewer
  /// frames a second); else the playhead.
  func shownMoment(_ options: GIFOptions) -> Date {
    guard isPlaying, !pausing else { return playhead }
    let step = options.stepOfRecording
    let moment = Date(
      timeIntervalSinceReferenceDate: (playhead.timeIntervalSinceReferenceDate / step).rounded(.down) * step)
    return max(moment, trim.start)
  }
  weak var undoManager: UndoManager?
  private var timer: Timer?
  /// Where playing went from, and when.
  private var played: (from: Date, at: Date)?
  /// A drag under way: the ends before it, and whether it was playing (it goes on after, as in other editors).
  private var dragging: (trim: Trim, playing: Bool)?

  init(clip: Clip, began: Date, trim: Trim, saveFolder: SaveFolder = Preferences.saveFolder) {
    self.clip = clip
    self.began = began
    self.trim = trim
    playhead = trim.start
    let place = saveFolder.place()
    let shown = place.missing != nil ? saveFolder.path.map { URL(fileURLWithPath: $0) } ?? place.url : place.url
    keptFolder = SaveFolder.shortPath(shown)
    keptFolderMissing = place.missing != nil
    folder = keptFolder
    folderStatus = SaveFolder.typed(keptFolder).status
  }

  /// Save can save: to the folder kept (or the Desktop while it's missing), or to one typed that's there to write in
  /// or can be made.
  var canSave: Bool { folder == keptFolder || folderStatus == .ready || folderStatus == .new }

  /// Choose…: a folder panel over the editor, starting where Save to points (or the nearest folder above that's there).
  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.title = "Save the GIF To"
    panel.message = "Choose the folder to save the GIF in. It's kept for the next GIF and for screenshots too."
    panel.prompt = "Choose"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    var start = SaveFolder.typed(folder).url ?? SaveFolder.desktopURL
    while !FileManager.default.fileExists(atPath: start.path), start.path != "/" {
      start = start.deletingLastPathComponent()
    }
    panel.directoryURL = start
    let chosen = { [weak self] (response: NSApplication.ModalResponse) in
      guard response == .OK, let url = panel.url else { return }
      self?.folder = SaveFolder.shortPath(url)
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: chosen)
    } else {
      chosen(panel.runModal())
    }
  }

  /// A folder dropped on Save to, or a file: its folder.
  func dropped(_ url: URL) {
    var isFolder: ObjCBool = false
    let there = FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
    folder = SaveFolder.shortPath(there && isFolder.boolValue ? url : url.deletingLastPathComponent())
  }

  /// The whole recording's length.
  var total: TimeInterval { clip.duration }

  /// The GIF's start moved to `moment`, the playhead with it, so the picture shows the frame there.
  func moveStart(to moment: Date) {
    pause()
    trim.moveStart(to: moment)
    playhead = trim.start
  }

  func moveEnd(to moment: Date) {
    pause()
    trim.moveEnd(to: moment)
    playhead = trim.end
  }

  /// I and O: the GIF starts, or ends, at the playhead.
  func startAtPlayhead() { change { trim.moveStart(to: playhead) } }
  func endAtPlayhead() { change { trim.moveEnd(to: playhead) } }

  /// A change of the GIF's ends that ⌘Z takes back.
  func change(_ body: () -> Void) {
    let before = trim
    body()
    registerUndo(from: before)
  }

  func beginDrag() {
    guard dragging == nil else { return }
    dragging = (trim, isPlaying)
    pause()
  }

  func endDrag() {
    guard let (before, wasPlaying) = dragging else { return }
    dragging = nil
    registerUndo(from: before)
    if wasPlaying { play() }
  }

  private func registerUndo(from before: Trim) {
    guard before != trim, let undoManager else { return }
    undoManager.registerUndo(withTarget: self) { model in
      let after = model.trim
      model.pause()
      model.trim = before
      model.playhead = min(max(model.playhead, model.clip.start), model.clip.end)
      model.registerUndo(from: after)  // and ⇧⌘Z puts it back
    }
    undoManager.setActionName("Trim")
  }

  func seek(to moment: Date) {
    pause()
    playhead = min(max(moment, clip.start), clip.end)
  }

  /// The next frame, or back to the start of the one on the screen, then to the one before.
  func step(forward: Bool) {
    seek(to: forward ? clip.frameTime(after: playhead) : clip.frameTime(before: playhead))
  }

  func skip(_ seconds: TimeInterval) { seek(to: playhead.addingTimeInterval(seconds)) }
  func toStart() { seek(to: trim.start) }
  func toEnd() { seek(to: trim.end) }

  func togglePlay() {
    if isPlaying { pause() } else { play() }
  }

  /// Plays the GIF's part from the playhead, or from its start when the playhead is outside it or at its end, as fast
  /// as the GIF will; at the end it holds for the pause, then starts over, as the GIF does, or stops there when it
  /// plays once.
  func play() {
    guard !isPlaying else { return }
    if playhead < trim.start || playhead >= trim.end.addingTimeInterval(-0.05) { playhead = trim.start }
    played = (playhead, Date())
    pausing = false
    isPlaying = true
    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func tick() {
    guard let played else { return }
    let speed = min(max(speed, 1), 20)
    let moment = played.from.addingTimeInterval(Date().timeIntervalSince(played.at) * speed)
    guard moment >= trim.end else {
      playhead = moment
      return
    }
    playhead = trim.end
    let held = moment.timeIntervalSince(trim.end) / speed
    if held < TimeInterval(Preferences.gifPauseAtEnd) {
      if !pausing { pausing = true }
    } else if Preferences.gifLoops {
      pausing = false
      self.played = (trim.start, Date())
      playhead = trim.start
    } else {
      pause()
    }
  }

  func pause() {
    timer?.invalidate()
    timer = nil
    played = nil
    pausing = false
    isPlaying = false
  }

  /// The strip was clicked: the keys go to it.
  func takeKeys() { keyRequests += 1 }
}

/// The editor's keys, while no other control has them, as in QuickTime Player: Space plays and pauses, ← and → step a
/// frame (⇧ a second), ⌥← and ⌥→ (or ↑ and ↓, Home and End) go to the GIF's start and end, and I and O set them at
/// the playhead. Return, Esc, ⌘C, ⌘S and ⌘Z are the buttons' and the menus'. The keys go here when the editor opens
/// and when the strip is clicked; with keyboard navigation on, Tab takes them to the other controls (Space then ticks a
/// box).
struct KeyCatcher: NSViewRepresentable {
  @ObservedObject var model: TrimModel

  func makeNSView(context: Context) -> CatcherView {
    let view = CatcherView()
    view.model = model
    return view
  }

  func updateNSView(_ view: CatcherView, context: Context) {
    view.model = model
    if view.keyRequests != model.keyRequests {
      view.keyRequests = model.keyRequests
      view.window?.makeFirstResponder(view)
    }
  }

  final class CatcherView: NSView {
    weak var model: TrimModel?
    var keyRequests = 0

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      DispatchQueue.main.async { [weak self] in
        guard let self, let window = self.window else { return }
        window.makeFirstResponder(self)
      }
    }

    override func keyDown(with event: NSEvent) {
      guard let model, handle(event, model) else {
        super.keyDown(with: event)
        return
      }
    }

    private func handle(_ event: NSEvent, _ model: TrimModel) -> Bool {
      let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
      guard !modifiers.contains(.command), !modifiers.contains(.control) else { return false }
      let shift = modifiers.contains(.shift)
      let option = modifiers.contains(.option)
      switch event.specialKey {
      case .leftArrow?:
        if option { model.toStart() } else if shift { model.skip(-1) } else { model.step(forward: false) }
        return true
      case .rightArrow?:
        if option { model.toEnd() } else if shift { model.skip(1) } else { model.step(forward: true) }
        return true
      case .upArrow?, .home?:
        model.toStart()
        return true
      case .downArrow?, .end?:
        model.toEnd()
        return true
      default:
        break
      }
      switch event.charactersIgnoringModifiers?.lowercased() {
      case " ":
        model.togglePlay()
        return true
      case "i":
        model.startAtPlayhead()
        return true
      case "o":
        model.endAtPlayhead()
        return true
      default:
        return false
      }
    }
  }
}

/// How times read in the editor, the toolbar and Settings.
enum TimeText {
  /// "0:15", "1:00", "10:00": whole seconds.
  static func duration(_ seconds: TimeInterval) -> String {
    let whole = Int(max(seconds, 0).rounded())
    return String(format: "%d:%02d", whole / 60, whole % 60)
  }

  /// "0:15.3", "−0:20.0": to the tenth.
  static func precise(_ seconds: TimeInterval) -> String {
    let tenths = Int((abs(seconds) * 10).rounded())
    let sign = seconds < 0 && tenths > 0 ? "−" : ""
    return String(format: "%@%d:%02d.%d", sign, tenths / 600, tenths / 10 % 60, tenths % 10)
  }

  /// "14:32:05", as the Mac shows times.
  static func clock(_ moment: Date) -> String {
    moment.formatted(date: .omitted, time: .standard)
  }

  /// "14:32:05.3": the Mac's time, to the tenth.
  static func preciseClock(_ moment: Date) -> String {
    moment.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(1)))
  }

  /// "1 second", "15 seconds", "1 minute 5 seconds", for VoiceOver and the hints.
  static func spoken(_ seconds: TimeInterval) -> String {
    let whole = Int(seconds.rounded())
    let (minutes, rest) = (whole / 60, whole % 60)
    let secondsText = rest == 1 ? "1 second" : "\(rest) seconds"
    guard minutes > 0 else { return secondsText }
    let minutesText = minutes == 1 ? "1 minute" : "\(minutes) minutes"
    return rest == 0 ? minutesText : "\(minutesText) \(secondsText)"
  }
}

/// The picture of the frame at the playhead as the GIF shows it, made again only when the frame, the second the strip
/// shows or the choices change.
@MainActor
final class StillCache: ObservableObject {
  private var key: (frame: Date, words: Caption, options: GIFOptions)?
  private var image: CGImage?

  func image(of frame: RecordedFrame?, caption: Caption, options: GIFOptions) -> CGImage? {
    guard let frame else { return nil }
    // The same words make the same picture: the clock to the second, the count, the ink, the end.
    var words = caption
    words.clock = Date(timeIntervalSinceReferenceDate: caption.clock.timeIntervalSinceReferenceDate.rounded(.down))
    if key?.frame != frame.time || key?.words != words || key?.options != options {
      key = (frame.time, words, options)
      #if DEBUG
        let began = Date()
      #endif
      image = frame.snapshot().flatMap { GIF.still($0, caption: caption, options: options).image() }
      #if DEBUG
        let second = words.clock.timeIntervalSinceReferenceDate
        EditorDemo.renders.append((Date(), Date().timeIntervalSince(began), second))
      #endif
    }
    return image
  }
}

/// The strip's pictures: the recording's frames, one a tile across it, made small in the background.
@MainActor
final class Filmstrip: ObservableObject {
  @Published private(set) var tiles: [CGImage?] = []
  private var made: Int?
  /// Pictures asked for: those of an older ask (a width the window was resized through) are let go.
  private var asked = 0

  func make(_ clip: Clip, count: Int, tileSeconds: TimeInterval, pixels: (width: Int, height: Int)) {
    guard made != count, pixels.width > 0, pixels.height > 0 else { return }
    made = count
    asked += 1
    let ask = asked
    let frames = (0..<count).map { clip.frame(at: clip.start.addingTimeInterval((Double($0) + 0.5) * tileSeconds)) }
    DispatchQueue.global(qos: .userInitiated).async {
      var images: [CGImage?] = []
      var last: (time: Date, image: CGImage?)?
      for frame in frames {
        if let frame, let last, last.time == frame.time {
          images.append(last.image)  // the screen kept still: the same picture
          continue
        }
        let image = frame?.snapshot()?.image().flatMap { Self.scaled($0, to: pixels) }
        if let frame { last = (frame.time, image) }
        images.append(image)
      }
      let made = Tiles(images: images)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard ask == self.asked else { return }
          self.tiles = made.images
        }
      }
    }
  }

  /// Pictures handed from the background to the main thread, made and not changed after.
  private struct Tiles: @unchecked Sendable { let images: [CGImage?] }

  private nonisolated static func scaled(_ image: CGImage, to size: (width: Int, height: Int)) -> CGImage? {
    guard
      let context = CGContext(
        data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    return context.makeImage()
  }
}

/// The size of the GIF the editor would make, measured by making it in the background a moment after the choices stop
/// changing; a measurement no longer wanted stops.
@MainActor
final class SizeEstimate: ObservableObject {
  @Published private(set) var bytes: Int?
  private var current: Ticket?
  private static let queue = DispatchQueue(label: "GIF size", qos: .userInitiated)

  /// A measurement, until a newer one is asked for.
  final class Ticket: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
      lock.lock()
      defer { lock.unlock() }
      return stopped
    }

    func stop() {
      lock.lock()
      stopped = true
      lock.unlock()
    }
  }

  func update(_ clip: Clip, options: GIFOptions) {
    current?.stop()
    let ticket = Ticket()
    current = ticket
    bytes = nil
    Self.queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard !ticket.isStopped else { return }
      let bytes = GIF.make(clip, options: options, stop: { ticket.isStopped })?.data.count
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, !ticket.isStopped else { return }
          self.bytes = bytes
        }
      }
    }
  }

  /// No more measuring (the editor closed).
  func cancel() {
    current?.stop()
    current = nil
  }
}

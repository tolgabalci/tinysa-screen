import AppKit
import SwiftUI
import TinySAKit

/// The editor Stop opens: the whole recording, the seconds kept from before Record included, with the part the GIF
/// keeps between two yellow handles. It starts as Stop & Save would save it (from the lead-in set in Settings before
/// Record, to Stop); a handle dragged back takes in more of the seconds before, either one dragged in trims. The
/// picture shows the frame at the playhead as the GIF will, strip and all, and follows a handle while it moves; Play
/// plays the part kept over and over, as the GIF will.
struct RecordingEditor: View {
  enum Action { case save, copy }

  @ObservedObject var model: TrimModel
  /// Why the recording stopped by itself, when it did.
  let note: String?
  let done: (Action?) -> Void

  @AppStorage(Preferences.Key.gifShowsDate) private var showsDate = true
  @AppStorage(Preferences.Key.gifShowsTime) private var showsTime = true
  @AppStorage(Preferences.Key.gifScale) private var scale = 2
  @StateObject private var stills = StillCache()
  @StateObject private var estimate = SizeEstimate()
  @State private var confirmingDelete = false

  private var screen: (width: Int, height: Int) {
    (model.clip.frames.last?.width ?? 480, model.clip.frames.last?.height ?? 320)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      preview
        .frame(maxWidth: .infinity)
      VStack(spacing: 8) {
        TrimStrip(model: model)
        transport
      }
      Divider()
      choices
      buttons
    }
    .padding(20)
    .frame(width: 600)
    .background(KeyCatcher(model: model))
    .task(id: estimateKey) {
      estimate.update(
        model.clip.part(model.trim), options: GIFOptions(scale: scale, showsDate: showsDate, showsTime: showsTime))
    }
    .onDisappear {
      estimate.cancel()
      model.pause()
    }
    .alert("Delete the recording?", isPresented: $confirmingDelete) {
      Button("Delete", role: .destructive) { done(nil) }
      Button("Keep Editing", role: .cancel) {}
    } message: {
      Text("It isn't saved anywhere else, so it can't be brought back.")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Make a GIF of the recording")
        .font(.headline)
      if let note {
        Text(note)
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(hint)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var hint: String {
    let more = model.trim.start.timeIntervalSince(model.clip.start)
    return "The GIF is the part between the yellow ends: drag them, or press I or O to set one at the playhead."
      + (more >= 1 ? " The start can go back \(TimeText.spoken(more)) more, into what was kept before." : "")
  }

  /// The frame at the playhead as the GIF shows it, strip and all: drawn twice the screen's size, shown at half that,
  /// so a Retina display shows each pixel of it. A click plays or pauses.
  private var preview: some View {
    let options = GIFOptions(scale: 2, showsDate: showsDate, showsTime: showsTime)
    let image = stills.image(of: model.clip.frame(at: model.playhead), at: model.playhead, options: options)
    let width = CGFloat(min(screen.width, 480))  // a wider fed picture is shown smaller, to fit the sheet
    let height =
      image.map { width * CGFloat($0.height) / CGFloat($0.width) }
      ?? width * CGFloat(screen.height + (showsDate || showsTime ? 16 : 0)) / CGFloat(screen.width)
    let outside =
      model.playhead < model.trim.start
      ? "Before the GIF" : model.playhead > model.trim.end ? "After the GIF" : nil
    return Group {
      if let image {
        Image(decorative: image, scale: 2)
          .resizable()
          .interpolation(.high)
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
    .onTapGesture { model.togglePlay() }
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
        model.togglePlay()
      } label: {
        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
          .frame(width: 18)
      }
      .buttonStyle(.borderless)
      .help(model.isPlaying ? "Pause (Space)" : "Play the GIF (Space)")
      .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
      Text("\(TimeText.precise(into)) / \(TimeText.precise(model.trim.duration))")
        .help("Where the playhead is in the GIF, and how long the GIF is")
        .accessibilityLabel(
          "\(TimeText.spoken(abs(into))) \(into < 0 ? "before the GIF" : "into the GIF"), of "
            + TimeText.spoken(model.trim.duration))
      Spacer()
      Text(TimeText.preciseClock(model.trim.end))
        .help("When the GIF ends")
        .accessibilityLabel("Ends at \(TimeText.clock(model.trim.end))")
    }
    .font(.callout.monospacedDigit())
    .foregroundStyle(.secondary)
  }

  private var choices: some View {
    VStack(alignment: .leading, spacing: 10) {
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
    }
  }

  private var buttons: some View {
    HStack {
      Spacer()
      Button("Cancel") {
        model.pause()
        confirmingDelete = true
      }
      .keyboardShortcut(.cancelAction)
      .help("Delete the recording without making a GIF (Esc)")
      Button("Copy") { done(.copy) }
        .keyboardShortcut("c")
        .help("Copy the GIF to paste into a chat or an email (⌘C)")
      Button("Save to \(Preferences.saveFolderName)") { done(.save) }
        .keyboardShortcut(.defaultAction)
        .help("Save the GIF (Return)")
      // ⌘S saves too, as the screenshot's does outside the sheet.
      Button("") { done(.save) }
        .keyboardShortcut("s")
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
  }

  private var estimateKey: String {
    let start = model.trim.start.timeIntervalSinceReferenceDate
    let end = model.trim.end.timeIntervalSinceReferenceDate
    return "\(start) \(end) \(scale) \(showsDate) \(showsTime)"
  }

  private func size(_ scale: Int) -> String {
    let strip = showsDate || showsTime ? 16 * scale : 0
    let name = scale == 1 ? "Small" : "Sharp"
    return "\(name), \(screen.width * scale) × \(screen.height * scale + strip)"
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

  static let height: CGFloat = 48
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
  /// The sheet's, for ⌘Z to take a change of the GIF's ends back (Edit › Undo Trim).
  weak var undoManager: UndoManager?
  private var timer: Timer?
  /// Where playing went from, and when.
  private var played: (from: Date, at: Date)?
  /// A drag under way: the ends before it, and whether it was playing (it goes on after, as in other editors).
  private var dragging: (trim: Trim, playing: Bool)?

  init(clip: Clip, began: Date, trim: Trim) {
    self.clip = clip
    self.began = began
    self.trim = trim
    playhead = trim.start
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

  /// Plays the GIF's part from the playhead, or from its start when the playhead is outside it or at its end; at the
  /// end it starts over, as the GIF does.
  func play() {
    guard !isPlaying else { return }
    if playhead < trim.start || playhead >= trim.end.addingTimeInterval(-0.05) { playhead = trim.start }
    played = (playhead, Date())
    isPlaying = true
    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func tick() {
    guard let played else { return }
    let moment = played.from.addingTimeInterval(Date().timeIntervalSince(played.at))
    if moment >= trim.end {
      self.played = (trim.start, Date())
      playhead = trim.start
    } else {
      playhead = moment
    }
  }

  func pause() {
    timer?.invalidate()
    timer = nil
    played = nil
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
  private var key: (frame: Date, second: Double, options: GIFOptions)?
  private var image: CGImage?

  func image(of frame: RecordedFrame?, at moment: Date, options: GIFOptions) -> CGImage? {
    guard let frame else { return nil }
    let second = moment.timeIntervalSinceReferenceDate.rounded(.down)
    if key?.frame != frame.time || key?.second != second || key?.options != options {
      key = (frame.time, second, options)
      image = frame.snapshot().flatMap { GIF.still($0, at: moment, options: options).image() }
    }
    return image
  }
}

/// The strip's pictures: the recording's frames, one a tile across it, made small in the background.
@MainActor
final class Filmstrip: ObservableObject {
  @Published private(set) var tiles: [CGImage?] = []
  private var made: Int?

  func make(_ clip: Clip, count: Int, tileSeconds: TimeInterval, pixels: (width: Int, height: Int)) {
    guard made != count, pixels.width > 0, pixels.height > 0 else { return }
    made = count
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
        MainActor.assumeIsolated { self.tiles = made.images }
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

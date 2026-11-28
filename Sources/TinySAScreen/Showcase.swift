#if DEBUG
  import AppKit
  import ImageIO
  import TinySAKit

  /// For the README's pictures, in debug builds only: real frames of the analyzer's screen replayed through the app's
  /// window (TINYSA_SCREEN_SHOWCASE) or its editor (TINYSA_SCREEN_SHOWCASE_EDITOR), each set to a folder of PNG screens
  /// in the order they came, with `times.txt` (each one's seconds from the first, a line each) and `start.txt` (when
  /// the first came, ISO 8601). Pictures go to TINYSA_SCREEN_EDITOR_SNAPSHOTS, a PNG each, to make GIFs of: the window
  /// at each frame, then the GIF the app makes of them (`app.gif`); the editor every fifth of a second as it plays and
  /// is trimmed. The peak hold is the app's own, its labels read with the Mac's text recognition as the app reads them,
  /// and nothing touches the analyzer or the control socket. TINYSA_SCREEN_SHOWCASE_PEAKS sets how many peaks (9);
  /// for the window, _DISPLAY how they show (labels, box, list or none: the hold off), _TITLE the window's title (as a
  /// release names itself), _NOTE a note over the picture ("The tinySA is lent to …"), _WIDTH its width in points
  /// (960), and _NOGIF leaves the app's GIF out; _STILL adds `still.png`, the app's screenshot (⌘S) of the last frame.
  @MainActor
  enum Showcase {
    struct Frame {
      var screen: Snapshot
      var image: CGImage
      var time: Date
    }

    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var count: Int { Int(environment["TINYSA_SCREEN_SHOWCASE_PEAKS"] ?? "") ?? 9 }
    static let look = PeakLook(color: .cyan, readouts: .labels, labelColor: .orange)

    static func frames(in folder: URL) -> [Frame] {
      func lines(_ name: String) -> [String] {
        ((try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? "")
          .split(separator: "\n").map(String.init)
      }
      let times = lines("times.txt").compactMap(Double.init)
      let exact = ISO8601DateFormatter()
      exact.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let start =
        lines("start.txt").first.flatMap { exact.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } ?? Date()
      let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
      return files.enumerated().compactMap { i, url in
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let screen = Snapshot(image)
        else { return nil }
        let seconds = i < times.count ? times[i] : 0.5 * Double(i)
        return Frame(screen: screen, image: image, time: start.addingTimeInterval(seconds))
      }
    }

    /// The span and levels the labels say, read once for each fingerprint, as the app reads them.
    final class Labels {
      private var scales: [Int: GraphScale] = [:]

      func scale(of screen: Snapshot) -> GraphScale? {
        guard let graph = Graph.find(on: screen) else { return nil }
        let print = graph.labelPrint(on: screen)
        if let known = scales[print] { return known }
        let read = GraphScale.read(graph, on: screen)
        if let read { scales[print] = read }
        return read
      }
    }

    /// A recording of `frames` with the peak hold on as the window had it, begun `began` seconds after the first.
    static func recording(_ frames: [Frame], labels: Labels, began: TimeInterval) -> (Clip, Date)? {
      guard let first = frames.first, let last = frames.last else { return nil }
      let recorder = FrameRecorder()
      recorder.keepRecent = 300
      let hold = PeakHold(readsLabels: false)
      hold.window = 300
      hold.peakCount = count
      var id: UUID?
      for frame in frames {
        if id == nil, frame.time >= first.time.addingTimeInterval(began) {
          id = recorder.begin(at: frame.time, before: 300, longest: 300)
        }
        recorder.add(frame.screen, at: frame.time)
        hold.add(frame.screen, at: frame.time, labels: labels.scale(of: frame.screen))
        recorder.notePeaks(hold.state, at: frame.time)
      }
      guard let id, let start = recorder.started(id), let clip = recorder.end(id, at: last.time.addingTimeInterval(0.5))
      else { return nil }
      return (clip, start)
    }

    private static func save(_ image: CGImage?, _ url: URL) {
      guard let image, let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
      else { return print("No picture for \(url.lastPathComponent)") }
      CGImageDestinationAddImage(destination, image, nil)
      CGImageDestinationFinalize(destination)
    }

    // MARK: The window

    /// The window in front, the peak hold on with labels, the Last recording link showing: a picture after each frame,
    /// then the GIF the editor would make of them all (New peak capture from the first), and the app quits.
    static func window(
      _ window: NSWindow, frames folder: URL, show: @escaping (CGImage) -> Void, made: @escaping (URL) -> Void,
      peaks: @escaping (PeakHold.State?) -> Void, say: @escaping (String?) -> Void
    ) {
      guard let out = environment["TINYSA_SCREEN_EDITOR_SNAPSHOTS"].map({ URL(fileURLWithPath: $0) }) else { exit(1) }
      let frames = frames(in: folder)
      guard let first = frames.first else {
        print("No frames in \(folder.path)")
        exit(1)
      }
      let pictures = out.appendingPathComponent("window")
      try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
      let defaults = Preferences.defaults
      let display = PeakDisplay(rawValue: environment["TINYSA_SCREEN_SHOWCASE_DISPLAY"] ?? "labels")
      defaults.set(display != nil, forKey: Preferences.Key.peakHold)
      defaults.set((display ?? .labels).rawValue, forKey: Preferences.Key.peakDisplay)
      if let title = environment["TINYSA_SCREEN_SHOWCASE_TITLE"] { window.title = title }
      say(environment["TINYSA_SCREEN_SHOWCASE_NOTE"])
      defaults.set(300, forKey: Preferences.Key.peakWindow)
      defaults.set(count, forKey: Preferences.Key.peakCount)
      show(first.image)
      let width = Double(environment["TINYSA_SCREEN_SHOWCASE_WIDTH"] ?? "") ?? 960
      let list = display == .list ? PeakListView.width : 0  // the window wider for the list, as the app makes it
      window.setContentSize(NSSize(width: width + list, height: width * 2 / 3))
      // On a Retina screen, if there is one, for sharp pictures.
      if let retina = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }) {
        let frame = retina.visibleFrame
        window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
      }
      EditorDemo.drawInFront(window)
      ToolbarLook.drawnInFront = true
      ToolbarLook.redraw(window.toolbar)
      made(out.appendingPathComponent("tinySA 2026-11-28 at 09.41.07.gif"))
      let labels = Labels()
      let hold = PeakHold(readsLabels: false)
      hold.window = 300
      hold.peakCount = count
      func step(_ i: Int) {
        guard i < frames.count else { return finish() }
        let frame = frames[i]
        show(frame.image)
        hold.add(frame.screen, at: frame.time, labels: labels.scale(of: frame.screen))
        if display != nil { peaks(hold.state) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          save(EditorDemo.picture(of: window), pictures.appendingPathComponent(String(format: "%04d.png", i)))
          step(i + 1)
        }
      }
      func finish() {
        print("Pictured \(frames.count) frames of the window, \(Int(window.frame.width)) × \(Int(window.frame.height))")
        if environment["TINYSA_SCREEN_SHOWCASE_STILL"] != nil, let last = frames.last, let state = hold.state {
          let options = GIFOptions(scale: 2, showsDate: false, showsTime: false, peaks: look)
          save(
            GIF.still(last.screen, caption: Caption(clock: last.time), options: options, peaks: state).image(),
            out.appendingPathComponent("still.png"))
        }
        if environment["TINYSA_SCREEN_SHOWCASE_NOGIF"] == nil,
          let (clip, _) = recording(frames, labels: labels, began: 0)
        {
          let options = GIFOptions(
            scale: 2, showsDate: true, showsTime: true, showsElapsed: true, showsProgress: true, loops: true,
            pauseAtEnd: 3, peaks: look)
          if let gif = GIF.make(clip.peaksCapturedAfresh(count: count), options: options) {
            try? gif.data.write(to: out.appendingPathComponent("app.gif"))
            print("The app's GIF: \(gif.data.count / 1024) KB, \(gif.width) × \(gif.height), \(gif.duration) s")
          }
        }
        exit(0)
      }
      // The Last recording link's pulse over, the labels of the first frame read (the first read takes a while).
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
        _ = labels.scale(of: first.screen)
        EditorDemo.drawInFront(window, again: true)  // moved to another screen, the window lost it
        step(0)
      }
    }

    // MARK: The editor

    /// The editor on a recording of the frames, begun TINYSA_SCREEN_SHOWCASE_BEGAN seconds after the first (5), its GIF
    /// from 5 seconds before that: as it opens, playing, its start dragged back and played again. True when asked.
    static func editorIfAsked() -> Bool {
      guard let folder = environment["TINYSA_SCREEN_SHOWCASE_EDITOR"],
        let out = environment["TINYSA_SCREEN_EDITOR_SNAPSHOTS"].map({ URL(fileURLWithPath: $0) })
      else { return false }
      let app = NSApplication.shared
      app.setActivationPolicy(.regular)
      app.mainMenu = makeMenuBar()
      Preferences.register()
      Preferences.defaults.set(GIFPeaks.labels.rawValue, forKey: Preferences.Key.gifPeaks)
      Preferences.defaults.set(true, forKey: Preferences.Key.gifFreshPeaks)
      Preferences.defaults.set(count, forKey: Preferences.Key.peakCount)
      let frames = frames(in: URL(fileURLWithPath: folder))
      let began = Double(environment["TINYSA_SCREEN_SHOWCASE_BEGAN"] ?? "") ?? 5
      guard let (clip, start) = recording(frames, labels: Labels(), began: began) else {
        print("No recording of the frames in \(folder)")
        exit(1)
      }
      let pictures = out.appendingPathComponent("editor")
      try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
      let parent = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 660, height: 760), styleMask: [.titled, .closable], backing: .buffered,
        defer: false)
      if let retina = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }) {
        let frame = retina.visibleFrame
        parent.setFrameOrigin(NSPoint(x: frame.midX - parent.frame.width / 2, y: frame.midY - parent.frame.height / 2))
      }
      parent.orderFront(nil)
      let model = TrimModel(clip: clip, began: start, trim: Trim(clip, began: start, leadIn: 5))
      let editor = EditorWindow(model: model, note: nil) { _ in exit(0) }
      editor.show(over: parent)
      EditorDemo.drawInFront(editor.window)
      var n = 0
      let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
        MainActor.assumeIsolated {
          save(EditorDemo.picture(of: editor.window), pictures.appendingPathComponent(String(format: "%04d.png", n)))
          n += 1
        }
      }
      let startDragged = model.trim.start.addingTimeInterval(-6)
      let steps: [(TimeInterval, () -> Void)] = [
        (2.5, { RunLoop.main.add(timer, forMode: .common) }),  // the estimate and the first frame's labels ready
        (1.5, { model.play() }),
        (9, { model.pause() }),
        (0.8, { model.beginDrag() }),
      ]
        + (1...15).map { k in
          // Each step a share of the way left: the last there.
          (0.1, {
            let left = startDragged.timeIntervalSince(model.trim.start)
            model.moveStart(to: model.trim.start.addingTimeInterval(left / Double(16 - k)))
          })
        } + [
          (0.1, { model.endDrag() }),
          (2.5, { model.play() }),
          (9, {
            timer.invalidate()
            let size = editor.window.frame.size
            print("Pictured the editor \(n) times, \(Int(size.width)) × \(Int(size.height))")
            exit(0)
          }),
        ]
      func run(_ index: Int) {
        guard index < steps.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + steps[index].0) {
          steps[index].1()
          run(index + 1)
        }
      }
      run(0)
      app.run()
      return true
    }
  }
#endif

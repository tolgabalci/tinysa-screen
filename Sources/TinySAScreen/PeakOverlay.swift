import AppKit
import TinySAKit

/// The peak hold, drawn over the analyzer's picture: the held trace as a line in its colour (cyan unless another is
/// chosen), its highest peaks numbered, and their frequencies and levels in a box at the top of the graph, in the corner
/// the analyzer leaves emptier.
@MainActor
final class PeakOverlay {
  let layer = CALayer()
  private let line = CAShapeLayer()
  private let marks = CALayer()
  private(set) var state: PeakHold.State?

  /// The line's colour, its tags' and its box's edge.
  var color = PeakColor.cyan.color

  init() {
    line.fillColor = nil
    line.lineWidth = 1.5
    line.lineJoin = .round
    line.shadowColor = NSColor.black.cgColor
    line.shadowOpacity = 0.8
    line.shadowRadius = 1
    line.shadowOffset = .zero
    layer.addSublayer(line)
    layer.addSublayer(marks)
    layer.zPosition = 5
  }

  func show(_ state: PeakHold.State?, in rect: CGRect, scale: CGFloat, contentsScale: CGFloat) {
    self.state = state
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    layer.frame = layer.superlayer?.bounds ?? rect
    marks.sublayers = nil
    guard let state, scale > 0 else {
      line.path = nil
      return
    }
    line.strokeColor = color.cgColor
    func point(_ column: Int, _ row: Int) -> CGPoint {
      CGPoint(x: rect.minX + (CGFloat(column) + 0.5) * scale, y: rect.maxY - (CGFloat(row) + 0.5) * scale)
    }
    let path = CGMutablePath()
    var drawing = false
    for (i, row) in state.rows.enumerated() {
      guard let row else {
        drawing = false
        continue
      }
      let p = point(state.graph.left + i, row)
      if drawing { path.addLine(to: p) } else { path.move(to: p) }
      drawing = true
    }
    line.path = path
    line.lineWidth = max(1, scale * 0.75)

    // Numbered tags at the right of each peak's top (the analyzer centres its own markers above them).
    let font = NSFont.monospacedDigitSystemFont(ofSize: max(8, 5.5 * scale), weight: .semibold)
    for (n, peak) in state.peaks.enumerated() {
      let top = point(peak.column, peak.row)
      let tag = text("\(n + 1)", font: font, color: .black, contentsScale: contentsScale)
      let size = tag.preferredFrameSize()
      let box = CALayer()
      box.backgroundColor = color.cgColor
      box.cornerRadius = 2 * scale
      box.frame = CGRect(
        x: top.x + 3 * scale, y: top.y - size.height / 2, width: size.width + 4 * scale, height: size.height)
      tag.frame = CGRect(x: 2 * scale, y: 0, width: size.width, height: size.height)
      box.addSublayer(tag)
      marks.addSublayer(box)
    }

    // The readouts, when the labels have been read.
    guard let scaleRead = state.scale, !state.peaks.isEmpty else { return }
    let span = Double(scaleRead.stop - scaleRead.start)
    let perColumn = span / Double(max(state.graph.right - state.graph.left - 1, 1))
    var lines = [Self.title(state)]
    for (n, peak) in state.peaks.enumerated() {
      guard let frequency = peak.frequency, let level = peak.level else { continue }
      lines.append(
        "\(n + 1)  \(Self.frequency(frequency, resolution: perColumn))  \(Self.level(level, resolution: abs(scaleRead.perRow)))")
    }
    let readout = text(lines.joined(separator: "\n"), font: font, color: .white, contentsScale: contentsScale)
    let size = readout.preferredFrameSize()
    let box = CALayer()
    box.backgroundColor = NSColor(white: 0, alpha: 0.72).cgColor
    box.borderColor = color.withAlphaComponent(0.8).cgColor
    box.borderWidth = 1
    box.cornerRadius = 3 * scale
    let padding = 3 * scale
    // At the emptiest spot the hold found (its top left corner), kept inside the graph.
    let corner = point(state.quietSpot.x, state.quietSpot.y)
    let right = point(state.graph.right, 0).x - 36 * scale
    let x = min(corner.x, right - size.width - 2 * padding)
    box.frame = CGRect(
      x: max(rect.minX, x), y: corner.y - size.height - 2 * padding, width: size.width + 2 * padding,
      height: size.height + 2 * padding)
    readout.frame = CGRect(x: padding, y: padding, width: size.width, height: size.height)
    box.addSublayer(readout)
    marks.addSublayer(box)
  }

  /// "Peak hold" with how long it keeps levels: "last 1:00", or since when.
  static func title(_ state: PeakHold.State) -> String {
    if let window = state.window {
      let seconds = Int(window)
      return "Peak hold, last " + (seconds >= 60 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "\(seconds) s")
    }
    return "Peak hold since " + state.since.formatted(date: .omitted, time: .shortened)
  }

  /// A frequency in megahertz with as many decimals as a column of the graph resolves.
  static func frequency(_ hertz: Int64, resolution: Double) -> String {
    let decimals = max(0, min(6, Int((-log10(max(resolution, 1) / 1e6)).rounded(.up))))
    return String(format: "%.\(decimals)f MHz", Double(hertz) / 1e6)
  }

  /// A level to the decibel, or the tenth where a row of the graph resolves that finely.
  static func level(_ dBm: Double, resolution: Double) -> String {
    let text = resolution < 0.25 ? String(format: "%.1f dBm", dBm) : String(format: "%.0f dBm", dBm)
    return text.replacingOccurrences(of: "-", with: "−")
  }

  private func text(_ string: String, font: NSFont, color: NSColor, contentsScale: CGFloat) -> CATextLayer {
    let layer = CATextLayer()
    layer.string = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    layer.contentsScale = contentsScale
    layer.isWrapped = false
    return layer
  }
}

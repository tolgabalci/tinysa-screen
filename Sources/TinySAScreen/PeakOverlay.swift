import AppKit
import TinySAKit

/// The peak hold, drawn over the analyzer's picture: the held trace as a line in its colour (cyan unless another is
/// chosen); with the peaks listed, their numbers in tags and their frequencies, levels and times in a box at the top of
/// the graph, in the corner the analyzer leaves emptier; else beside each peak, when, the megahertz and the level. As
/// a GIF or a screenshot draws it (`PeakPicture`), the words the same.
@MainActor
final class PeakOverlay {
  let layer = CALayer()
  private let line = CAShapeLayer()
  private let marks = CALayer()
  private(set) var state: PeakHold.State?

  /// The line's colour, its tags' and its boxes' edge.
  var color = PeakColor.cyan.color
  /// The readouts listed in a box, the peaks numbered; or beside each peak.
  var listed = true

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

    let font = NSFont.monospacedDigitSystemFont(ofSize: max(8, 5.5 * scale), weight: .semibold)
    guard listed else {
      // Beside each peak: when, the megahertz and the level, placed as a GIF places them (top-down in the picture).
      let padding = 2 * scale
      let texts = state.peaks.map {
        text($0.label().joined(separator: "\n"), font: font, color: .white, contentsScale: contentsScale)
      }
      let sizes = texts.map { text in
        let size = text.preferredFrameSize()
        return CGSize(width: size.width + 2 * padding, height: size.height + 2 * padding)
      }
      let tops = state.peaks.map { CGPoint(x: (CGFloat($0.column) + 0.5) * scale, y: (CGFloat($0.row) + 0.5) * scale) }
      let graph = CGRect(
        x: CGFloat(state.graph.left) * scale, y: CGFloat(state.graph.top) * scale,
        width: CGFloat(state.graph.right - state.graph.left) * scale,
        height: CGFloat(state.graph.bottom - state.graph.top) * scale)
      // The oldest peak's label first: a newer one gives way, moved clear with an arrow to its peak.
      let order = state.peaks.indices.sorted {
        (state.peaks[$0].time ?? .distantPast, state.peaks[$0].number)
          < (state.peaks[$1].time ?? .distantPast, state.peaks[$1].number)
      }
      let places = PeakLabels.place(sizes, at: tops, order: order, within: graph, gap: 4 * scale)
      // From the picture's top-down points to the layer's.
      func layer(_ point: CGPoint) -> CGPoint { CGPoint(x: rect.minX + point.x, y: rect.maxY - point.y) }
      for (place, top) in zip(places, tops) where place.away {
        let (from, to) = PeakLabels.arrow(from: place.rect, to: top)
        marks.addSublayer(arrow(from: layer(from), to: layer(to), scale: scale))
      }
      for (text, place) in zip(texts, places) {
        let box = readoutBox(scale: scale)
        let r = place.rect
        box.frame = CGRect(x: rect.minX + r.minX, y: rect.maxY - r.maxY, width: r.width, height: r.height)
        text.frame = CGRect(x: padding, y: padding, width: r.width - 2 * padding, height: r.height - 2 * padding)
        box.addSublayer(text)
        marks.addSublayer(box)
      }
      return
    }

    // Numbered tags at the right of each peak's top (the analyzer centres its own markers above them).
    for peak in state.peaks {
      let top = point(peak.column, peak.row)
      let tag = text("\(peak.number)", font: font, color: .black, contentsScale: contentsScale)
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
    let lines = state.readouts()
    guard !lines.isEmpty else { return }
    let readout = text(lines.joined(separator: "\n"), font: font, color: .white, contentsScale: contentsScale)
    let size = readout.preferredFrameSize()
    let box = readoutBox(scale: scale)
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

  /// A line in the hold's colour from a label to its peak's top, its head there.
  private func arrow(from: CGPoint, to: CGPoint, scale: CGFloat) -> CAShapeLayer {
    let layer = CAShapeLayer()
    let length = hypot(to.x - from.x, to.y - from.y)
    guard length > 1 else { return layer }
    let (ux, uy) = ((to.x - from.x) / length, (to.y - from.y) / length)
    let head = 5 * scale
    let side = 2.5 * scale
    let base = CGPoint(x: to.x - ux * head, y: to.y - uy * head)
    let line = CGMutablePath()
    line.move(to: from)
    line.addLine(to: base)
    let tip = CGMutablePath()
    tip.move(to: to)
    tip.addLine(to: CGPoint(x: base.x - uy * side, y: base.y + ux * side))
    tip.addLine(to: CGPoint(x: base.x + uy * side, y: base.y - ux * side))
    tip.closeSubpath()
    let shaft = CAShapeLayer()
    shaft.path = line
    shaft.strokeColor = color.cgColor
    shaft.lineWidth = max(1, 0.6 * scale)
    shaft.fillColor = nil
    layer.path = tip
    layer.fillColor = color.cgColor
    layer.addSublayer(shaft)
    layer.shadowColor = NSColor.black.cgColor
    layer.shadowOpacity = 0.8
    layer.shadowRadius = 1
    layer.shadowOffset = .zero
    return layer
  }

  /// A box for words over the graph: black, mostly opaque, edged in the hold's colour.
  private func readoutBox(scale: CGFloat) -> CALayer {
    let box = CALayer()
    box.backgroundColor = NSColor(white: 0, alpha: 0.72).cgColor
    box.borderColor = color.withAlphaComponent(0.8).cgColor
    box.borderWidth = 1
    box.cornerRadius = 3 * scale
    return box
  }

  private func text(_ string: String, font: NSFont, color: NSColor, contentsScale: CGFloat) -> CATextLayer {
    let layer = CATextLayer()
    layer.string = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    layer.contentsScale = contentsScale
    layer.isWrapped = false
    return layer
  }
}

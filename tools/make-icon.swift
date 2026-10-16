// Draws tinySA Screen's icon: a spectrum analyzer's screen in miniature (a green trace with a few peaks over the
// noise, a strip of waterfall below) with a red dot, as a live picture has.
// swift tools/make-icon.swift Resources/AppIcon.png
import AppKit
import CoreGraphics

let size = 1024
let args = CommandLine.arguments
guard args.count == 2 else {
  FileHandle.standardError.write("usage: swift tools/make-icon.swift <out.png>\n".data(using: .utf8)!)
  exit(2)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
  data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// The macOS icon grid: an 824-point rounded square centered on the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.setFillColor(rgb(14, 18, 26))
ctx.fill(tile)

// The screen: a grid, the waterfall strip at the bottom.
let screen = tile.insetBy(dx: 70, dy: 70)
let waterfall = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height * 0.26)
let graph = CGRect(
  x: screen.minX, y: waterfall.maxY + 22, width: screen.width, height: screen.maxY - waterfall.maxY - 22)
ctx.setStrokeColor(rgb(60, 72, 88))
ctx.setLineWidth(3)
for i in 0...5 {
  let y = graph.minY + graph.height * CGFloat(i) / 5
  ctx.move(to: CGPoint(x: graph.minX, y: y))
  ctx.addLine(to: CGPoint(x: graph.maxX, y: y))
}
for i in 0...6 {
  let x = graph.minX + graph.width * CGFloat(i) / 6
  ctx.move(to: CGPoint(x: x, y: graph.minY))
  ctx.addLine(to: CGPoint(x: x, y: graph.maxY))
}
ctx.strokePath()

// The waterfall: navy noise with a few bursts, in the analyzer's palette.
var seed: UInt64 = 7
func random() -> CGFloat {
  seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
  return CGFloat(seed >> 33) / CGFloat(1 << 31)
}
let cell: CGFloat = 12
var y = waterfall.minY
while y < waterfall.maxY {
  var x = waterfall.minX
  while x < waterfall.maxX {
    let v = random()
    ctx.setFillColor(rgb(10 + 30 * v, 40 + 60 * v, 150 + 90 * v))
    ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
    x += cell
  }
  y += cell
}
for (fx, fy, w) in [(0.22, 0.65, 0.07), (0.55, 0.30, 0.09), (0.74, 0.78, 0.05), (0.38, 0.10, 0.06)] {
  let burst = CGRect(
    x: waterfall.minX + waterfall.width * fx, y: waterfall.minY + waterfall.height * fy,
    width: waterfall.width * w, height: cell)
  ctx.setFillColor(rgb(255, 140, 0))
  ctx.fill(burst)
  ctx.setFillColor(rgb(255, 230, 0))
  ctx.fill(burst.insetBy(dx: burst.width * 0.3, dy: 0))
}

// The trace: noise near the floor, three peaks (the held maximum), drawn in the analyzer's green.
let floorY = graph.minY + graph.height * 0.12
let peaks: [(CGFloat, CGFloat, CGFloat)] = [(0.22, 0.88, 0.035), (0.55, 0.62, 0.04), (0.74, 0.76, 0.03)]
let trace = CGMutablePath()
let steps = 220
for i in 0...steps {
  let f = CGFloat(i) / CGFloat(steps)
  var level = floorY + graph.height * 0.05 * random()
  for (center, height, width) in peaks {
    let d = (f - center) / width
    level = max(level, graph.minY + graph.height * height * exp(-d * d))
  }
  let point = CGPoint(x: graph.minX + graph.width * f, y: level)
  if i == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
}
ctx.setLineJoin(.round)
ctx.setStrokeColor(rgb(76, 217, 100, 0.35))
ctx.setLineWidth(26)
ctx.addPath(trace)
ctx.strokePath()
ctx.setStrokeColor(rgb(76, 217, 100))
ctx.setLineWidth(11)
ctx.addPath(trace)
ctx.strokePath()

// The red dot at the top right, ringed so it stands off the grid: live.
do {
  let dot = CGRect(x: tile.maxX - 200, y: tile.maxY - 200, width: 112, height: 112)
  ctx.setFillColor(rgb(14, 18, 26))
  ctx.fillEllipse(in: dot.insetBy(dx: -18, dy: -18))
  ctx.setFillColor(rgb(255, 59, 48))
  ctx.fillEllipse(in: dot)
}
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))

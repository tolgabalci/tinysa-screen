import AppKit
import SwiftUI
import TinySAKit

/// The peaks beside the screen: every peak the hold has had since the app started, a row each, newest at the bottom.
@MainActor
final class PeakList: ObservableObject {
  @Published private(set) var log = PeakLog()
  /// The peak to ring on the screen, by its number: the row the pointer is over, while that peak is held; nil when
  /// it's over none.
  var onHover: (Int?) -> Void = { _ in }
  /// Save: the list as a CSV file.
  var onSave: () -> Void = {}

  func update(_ state: PeakHold.State?) {
    var log = self.log
    if log.update(with: state) { self.log = log }
  }
}

/// The list as the window shows it, at the screen's right: the hold's period and Save at its top, then a row a peak,
/// its number (on the screen too), when its level came in, its frequency to as many decimals as the graph resolves,
/// and its level; a peak no longer held greyed. It follows the newest row as they come, unless the pointer is over it
/// (so a row being read doesn't move away), and scrolls. The pointer over a held peak's row rings the peak on the
/// screen.
struct PeakListView: View {
  @ObservedObject var list: PeakList
  @State private var pointerOver = false
  @State private var hovered: Int?

  static let width: CGFloat = 300
  private static let columns: [CGFloat] = [24, 96, 82, 48]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      row(["#", "Time", "MHz", "dBm"])
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
      Divider()
      rows
    }
    .frame(width: Self.width)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Peaks").font(.headline)
        Text(list.log.title.isEmpty ? "Peak hold" : list.log.title)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        list.onSave()
      } label: {
        Label("Save", systemImage: "square.and.arrow.down")
      }
      .disabled(list.log.entries.isEmpty)
      .help("Save the list as a CSV file (number, date and time, MHz, dBm), to the folder GIFs go to")
    }
    .padding(10)
  }

  private var rows: some View {
    ScrollViewReader { scroller in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(list.log.entries) { entry in
            peakRow(entry).id(entry.id)
          }
        }
        .padding(.vertical, 2)
      }
      .onHover { pointerOver = $0 }
      .onAppear {
        if let last = list.log.entries.last { scroller.scrollTo(last.id, anchor: .bottom) }
      }
      .onChange(of: list.log.entries.count) { _ in
        guard !pointerOver, let last = list.log.entries.last else { return }
        withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(last.id, anchor: .bottom) }
      }
    }
  }

  private func row(_ texts: [String]) -> some View {
    HStack(spacing: 8) {
      ForEach(Array(texts.enumerated()), id: \.offset) { i, text in
        Text(text).frame(width: Self.columns[i], alignment: i == 1 ? .leading : .trailing)
      }
    }
    .padding(.horizontal, 10)
  }

  private func peakRow(_ entry: PeakLog.Entry) -> some View {
    row(["\(entry.number)", PeakHold.clock(entry.time), entry.megahertz, entry.dBm])
      .font(.system(size: 14).monospacedDigit())
      .foregroundStyle(entry.held ? .primary : .secondary)
      .padding(.vertical, 3)
      .background(hovered == entry.id ? Color.accentColor.opacity(0.25) : Color.clear)
      .contentShape(Rectangle())
      .onHover { inside in
        if inside {
          hovered = entry.id
        } else if hovered == entry.id {
          hovered = nil
        }
        list.onHover(inside && entry.held ? entry.number : nil)
      }
      .help(entry.held ? "Peak \(entry.number), ringed on the screen" : "Peak \(entry.number): no longer held")
      .accessibilityElement(children: .combine)
  }
}

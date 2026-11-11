import SwiftUI
import UIKit

/// Stats › 3×3 Chart: your nine most played albums (and loose songs) of the week, month, year
/// or all time as one square image to share, like the Last.fm collages.
struct ChartCollageView: View {
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var library: LibraryStore
    @State private var period: ChartPeriod = .allTime
    @AppStorage("chart.showNames") private var showNames = true
    @State private var image: UIImage?
    @State private var file: URL?
    @State private var isEmpty = false

    /// Redraw when the period, the names switch or the library changes.
    private var renderKey: String {
        "\(period.rawValue)|\(showNames)|\(library.tracks.count)|\(library.artworkRevision)"
    }

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(ChartPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                preview
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)

                Toggle("Show Names and Plays", isOn: $showNames)
            } footer: {
                Text("Albums, and songs that aren't in one, from your library by number of plays. Week, month and year count plays day by day since colon3 1.4.0; from before that, only each song's last play is known.")
            }

            if let file {
                Section {
                    ShareLink(item: file) {
                        Label("Share Image", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("3\u{00D7}3 Chart")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: renderKey) { await render() }
    }

    @ViewBuilder
    private var preview: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if isEmpty {
            ContentUnavailableView("Nothing Played Yet",
                                   systemImage: "square.grid.3x3",
                                   description: Text("Nothing in your library was played in this period."))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .aspectRatio(1, contentMode: .fit)
                .overlay { ProgressView() }
        }
    }

    private func render() async {
        let top = stats.topItems(period, limit: 9, in: library)
        guard !top.isEmpty else {
            image = nil
            file = nil
            isEmpty = true
            return
        }
        isEmpty = false
        var cells: [ChartCollage.Cell] = []
        for entry in top {
            let cover = await ArtworkStore.shared.image(for: entry.item.artwork, maxPixel: 640)
            cells.append(ChartCollage.Cell(image: cover, title: entry.item.title,
                                           artist: entry.item.artist, plays: entry.plays))
        }
        guard !Task.isCancelled else { return }
        let rendered = ChartCollage.render(cells, caption: period.caption, showNames: showNames)
        image = rendered
        file = ChartCollage.write(rendered, name: "colon3-top-" + period.rawValue)
    }
}

/// Draws the collage: a 3 × 3 grid of covers, 1080 pixels across, with a strip underneath
/// saying what it is.
@MainActor
enum ChartCollage {
    struct Cell {
        let image: UIImage?
        let title: String
        let artist: String
        let plays: Int
    }

    private static let side: CGFloat = 360
    private static let footer: CGFloat = 64

    static func render(_ cells: [Cell], caption: String, showNames: Bool) -> UIImage {
        let size = CGSize(width: side * 3, height: side * 3 + footer)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let canvas = context.cgContext
            UIColor(white: 0.07, alpha: 1).setFill()
            canvas.fill(CGRect(origin: .zero, size: size))

            for index in 0..<9 {
                let rect = CGRect(x: CGFloat(index % 3) * side, y: CGFloat(index / 3) * side,
                                  width: side, height: side)
                canvas.saveGState()
                canvas.clip(to: rect)
                if index < cells.count {
                    draw(cells[index], in: rect, canvas: canvas, showNames: showNames)
                } else {
                    UIColor(white: 0.12, alpha: 1).setFill()
                    canvas.fill(rect)
                }
                canvas.restoreGState()
            }

            let strip = CGRect(x: 0, y: side * 3, width: size.width, height: footer)
            text("colon3", in: strip.insetBy(dx: 22, dy: 15),
                 font: .systemFont(ofSize: 27, weight: .heavy), color: .white, alignment: .left)
            text("Top albums \u{00B7} " + caption, in: strip.insetBy(dx: 22, dy: 18),
                 font: .systemFont(ofSize: 22, weight: .medium),
                 color: UIColor(white: 1, alpha: 0.7), alignment: .right)
        }
    }

    private static func draw(_ cell: Cell, in rect: CGRect, canvas: CGContext, showNames: Bool) {
        if let image = cell.image, image.size.width > 0, image.size.height > 0 {
            // Fill the square, cropping whatever sticks out.
            let scale = max(rect.width / image.size.width, rect.height / image.size.height)
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                  width: drawn.width, height: drawn.height))
        } else {
            UIColor(white: 0.2, alpha: 1).setFill()
            canvas.fill(rect)
            let symbol = UIImage(systemName: "music.note",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 90, weight: .regular))?
                .withTintColor(UIColor(white: 0.45, alpha: 1), renderingMode: .alwaysOriginal)
            if let symbol {
                symbol.draw(at: CGPoint(x: rect.midX - symbol.size.width / 2, y: rect.midY - symbol.size.height / 2))
            }
        }
        guard showNames else { return }

        // Darken the bottom so the names read on any cover.
        let colors = [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.85).cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                     locations: [0, 1]) {
            canvas.drawLinearGradient(gradient,
                                      start: CGPoint(x: rect.minX, y: rect.maxY - 160),
                                      end: CGPoint(x: rect.minX, y: rect.maxY),
                                      options: [])
        }
        let left = rect.minX + 14
        let width = rect.width - 28
        text(cell.title, in: CGRect(x: left, y: rect.maxY - 86, width: width, height: 30),
             font: .systemFont(ofSize: 23, weight: .bold), color: .white, alignment: .left)
        text(cell.artist, in: CGRect(x: left, y: rect.maxY - 57, width: width, height: 25),
             font: .systemFont(ofSize: 19, weight: .medium), color: UIColor(white: 1, alpha: 0.85), alignment: .left)
        let plays = cell.plays == 1 ? "1 play" : "\(cell.plays) plays"
        text(plays, in: CGRect(x: left, y: rect.maxY - 32, width: width, height: 22),
             font: .systemFont(ofSize: 16, weight: .regular), color: UIColor(white: 1, alpha: 0.7), alignment: .left)
    }

    /// One line, cut short with an ellipsis when it doesn't fit.
    private static func text(_ string: String, in rect: CGRect, font: UIFont, color: UIColor,
                             alignment: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        (string as NSString).draw(in: rect, withAttributes: attributes)
    }

    /// Saves the image where the share sheet can pick it up.
    static func write(_ image: UIImage, name: String) -> URL? {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".jpg")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

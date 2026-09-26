import Foundation
import MosaicSolver

/// How often each photograph is used, column against column.
///
/// The batch page says how many photographs a mosaic draws on and how often the
/// busiest one appears, which is two points of a distribution. Two settings can
/// agree on both and still differ in what the eye sees: a few photographs
/// carrying a whole sky, or the same count spread over every region. This page
/// draws the whole distribution, summed over the batch's subjects.
///
/// Two views of the same counts, because they answer different questions:
/// *photographs* by how many cells each holds says how much of the corpus is
/// used and how evenly; *cells* by how many uses their photograph has says how
/// much of the screen is made of repeats, which is what gets noticed.
enum UsagePage {
    /// Bins on a doubling scale: the counts run from 0 to the thousands, and
    /// the difference between 1 and 2 uses matters as much as between 64 and 128.
    struct Bin {
        let lower: Int
        let upper: Int  // inclusive

        var label: String {
            lower == upper ? "\(lower)" : "\(lower)–\(upper)"
        }
    }

    static let bins: [Bin] = {
        var bins = [Bin(lower: 0, upper: 0), Bin(lower: 1, upper: 1), Bin(lower: 2, upper: 2)]
        var lower = 3
        var upper = 4
        while upper < 1 << 20 {
            bins.append(Bin(lower: lower, upper: upper))
            lower = upper + 1
            upper *= 2
        }
        return bins
    }()

    struct Series {
        let name: String
        /// A CSS class: penalties in oranges, tolerances in blues from light
        /// to dark, the floor in grey — so a family reads as one at a glance.
        var style = "ref"
        /// Per bin, averaged over the subjects: photographs, and cells.
        let photos: [Double]
        let cells: [Double]
        let meanPhotoCount: Double
        let meanCellCount: Double
    }

    static func series(name: String, runs: [SolveStatistics]) -> Series {
        var photos = [Double](repeating: 0, count: bins.count)
        var cells = [Double](repeating: 0, count: bins.count)
        for run in runs {
            for uses in run.photoUses {
                let bin = bins.firstIndex { uses <= $0.upper }!
                photos[bin] += 1
                cells[bin] += Double(uses)
            }
        }
        let count = Double(runs.count)
        return Series(
            name: name,
            photos: photos.map { $0 / count },
            cells: cells.map { $0 / count },
            meanPhotoCount: Double(runs.map(\.photoUses.count).reduce(0, +)) / count,
            meanCellCount: Double(runs.map(\.cellCount).reduce(0, +)) / count
        )
    }

    static func series(of subjects: [BatchExporter.Subject], columns: [BatchExporter.Column]) -> [Series] {
        var penalties = 0
        var tolerances = 0
        return columns.indices.map { position in
            var s = series(name: columns[position].caption, runs: subjects.map { $0.mosaics[position].statistics })
            switch columns[position] {
            case .penalty:
                s.style = "p\(min(penalties, 2))"
                penalties += 1
            case .tolerance:
                s.style = "t\(min(tolerances, 2))"
                tolerances += 1
            }
            return s
        } + [series(name: "floor", runs: subjects.map(\.floor))]
    }

    /// The bins any series reaches, so the axis ends where the data does.
    static func usedBins(_ series: [Series]) -> Range<Int> {
        let last = series.map { s in s.photos.lastIndex { $0 > 0 } ?? 0 }.max() ?? 0
        return 0..<(last + 1)
    }

    static func csv(_ series: [Series]) -> String {
        var lines = ["column,uses_from,uses_to,photos_per_mosaic,cells_per_mosaic"]
        for s in series {
            for index in usedBins(series) {
                lines.append(String(
                    format: "%@,%d,%d,%.2f,%.2f",
                    s.name, bins[index].lower, bins[index].upper, s.photos[index], s.cells[index]
                ))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - The page

    static func page(_ series: [Series], subjects: Int, settings: String) -> String {
        let range = usedBins(series)
        let photoShares = series.map { s in s.photos.map { 100 * $0 / s.meanPhotoCount } }
        let cellShares = series.map { s in s.cells.map { 100 * $0 / s.meanCellCount } }

        let legend = series.indices.map { index in
            "<span><i class=\"\(series[index].style)\"></i>\(escape(series[index].name))</span>"
        }.joined()

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Photograph usage</title>
        <style>
        :root {
          --bg: #fafaf8; --ink: #1d1d1b; --muted: #6b6b66; --rule: #e2e1dc; --grid: #ecebe6;
          --p0: #d9722b; --p1: #f0a868; --p2: #a4501a; --t0: #9ec5f4; --t1: #3987e5; --t2: #184f95; --ref: #b4b3ad;
        }
        @media (prefers-color-scheme: dark) { :root {
          --bg: #1b1b1a; --ink: #ecebe6; --muted: #9a9993; --rule: #34342f; --grid: #2a2a27;
          --p0: #e8894a; --p1: #f5bb88; --p2: #c0662a; --t0: #cde2fb; --t1: #6da7ec; --t2: #256abf; --ref: #5b5a55;
        } }
        body { background: var(--bg); color: var(--ink); font: 14px/1.45 -apple-system, system-ui, sans-serif; margin: 24px; max-width: 1100px; }
        h1 { font-size: 20px; margin: 0 0 4px; }
        h2 { font-size: 15px; margin: 36px 0 4px; }
        p { margin: 4px 0; }
        .muted { color: var(--muted); }
        .legend { display: flex; flex-wrap: wrap; gap: 16px; margin: 16px 0 0; font-size: 13px; }
        .legend span { display: flex; align-items: center; gap: 6px; }
        .legend i { display: block; width: 12px; height: 12px; border-radius: 2px; }
        svg { width: 100%; height: auto; display: block; margin-top: 8px; }
        svg text { fill: var(--muted); font: 11px -apple-system, system-ui, sans-serif; font-variant-numeric: tabular-nums; }
        svg .axis { stroke: var(--rule); }
        svg .grid { stroke: var(--grid); }
        .p0 { background: var(--p0); fill: var(--p0); } .p1 { background: var(--p1); fill: var(--p1); }
        .p2 { background: var(--p2); fill: var(--p2); } .t0 { background: var(--t0); fill: var(--t0); }
        .t1 { background: var(--t1); fill: var(--t1); } .t2 { background: var(--t2); fill: var(--t2); }
        .ref { background: var(--ref); fill: var(--ref); }
        .scroll { overflow-x: auto; }
        table { border-collapse: collapse; margin: 12px 0; font-variant-numeric: tabular-nums; font-size: 12px; }
        th, td { padding: 3px 10px 3px 0; text-align: right; border-bottom: 1px solid var(--rule); white-space: nowrap; }
        th:first-child, td:first-child { text-align: left; }
        th { font-weight: 600; color: var(--muted); }
        </style>
        </head>
        <body>
        <h1>Photograph usage</h1>
        <p class="muted">\(escape(settings)) · averaged over \(subjects) subjects · uses binned by doubling</p>
        <div class="legend">\(legend)</div>

        <h2>Photographs, by how many cells each one holds</h2>
        <p class="muted">Share of the pool. The bar at 0 is the part of the corpus a mosaic leaves out.</p>
        \(chart(photoShares, series: series, range: range))
        \(table(series.map(\.photos), shares: photoShares, series: series, range: range, unit: "photos"))

        <h2>Cells, by how many uses their photograph has</h2>
        <p class="muted">Share of the screen. Mass on the right is screen made of repeats: that is what the eye counts.</p>
        \(chart(cellShares, series: series, range: range, skipFirst: true))
        \(table(series.map(\.cells), shares: cellShares, series: series, range: range, unit: "cells"))
        </body>
        </html>

        """
    }

    /// Grouped bars: one group per bin, one bar per series, on one shared scale.
    private static func chart(
        _ shares: [[Double]], series: [Series], range: Range<Int>, skipFirst: Bool = false
    ) -> String {
        let bins = skipFirst ? Array(range.dropFirst()) : Array(range)
        let width = 1000.0, height = 300.0
        let left = 44.0, right = 8.0, top = 10.0, bottom = 36.0
        let plotWidth = width - left - right, plotHeight = height - top - bottom

        let peak = bins.flatMap { bin in shares.map { $0[bin] } }.max() ?? 1
        let step = niceStep(peak / 5)
        let ceiling = (peak / step).rounded(.up) * step

        var svg = "<svg viewBox=\"0 0 \(Int(width)) \(Int(height))\" role=\"img\">"
        var tick = 0.0
        while tick <= ceiling + 1e-9 {
            let y = top + plotHeight * (1 - tick / ceiling)
            svg += String(format: "<line class=\"%@\" x1=\"%.1f\" x2=\"%.1f\" y1=\"%.1f\" y2=\"%.1f\"/>",
                          tick == 0 ? "axis" : "grid", left, width - right, y, y)
            svg += String(format: "<text x=\"%.1f\" y=\"%.1f\" text-anchor=\"end\">%@%%</text>",
                          left - 6, y + 4, format(tick))
            tick += step
        }

        let group = plotWidth / Double(bins.count)
        let bar = min(18, (group * 0.8) / Double(series.count))
        for (slot, bin) in bins.enumerated() {
            let groupLeft = left + group * Double(slot) + (group - bar * Double(series.count)) / 2
            for index in series.indices {
                let value = shares[index][bin]
                let barHeight = plotHeight * value / ceiling
                svg += String(
                    format: "<rect class=\"%@\" x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%.1f\"><title>%@ · %@ uses · %.1f%%</title></rect>",
                    series[index].style,
                    groupLeft + bar * Double(index), top + plotHeight - barHeight, max(bar - 1, 1), barHeight,
                    escape(series[index].name), UsagePage.bins[bin].label, value
                )
            }
            svg += String(format: "<text x=\"%.1f\" y=\"%.1f\" text-anchor=\"middle\">%@</text>",
                          left + group * (Double(slot) + 0.5), height - bottom + 16, UsagePage.bins[bin].label)
        }
        svg += String(format: "<text x=\"%.1f\" y=\"%.1f\" text-anchor=\"middle\">uses of the photograph</text>",
                      left + plotWidth / 2, height - 4)
        return svg + "</svg>"
    }

    private static func table(
        _ counts: [[Double]], shares: [[Double]], series: [Series], range: Range<Int>, unit: String
    ) -> String {
        var html = "<div class=\"scroll\"><table><tr><th>\(unit) per mosaic</th>"
        for bin in range { html += "<th>\(bins[bin].label)</th>" }
        html += "</tr>"
        for index in series.indices {
            html += "<tr><td>\(escape(series[index].name))</td>"
            for bin in range {
                html += String(format: "<td title=\"%.1f%%\">%@</td>", shares[index][bin], format(counts[index][bin]))
            }
            html += "</tr>"
        }
        return html + "</table></div>"
    }

    private static func niceStep(_ raw: Double) -> Double {
        guard raw > 0 else { return 1 }
        let magnitude = pow(10, (log10(raw)).rounded(.down))
        for multiple in [1.0, 2, 2.5, 5, 10] where multiple * magnitude >= raw {
            return multiple * magnitude
        }
        return 10 * magnitude
    }

    private static func format(_ value: Double) -> String {
        value >= 10 || value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

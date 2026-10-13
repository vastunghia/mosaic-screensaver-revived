import Foundation
import Metal
import MosaicCore
import MosaicEngine
import MosaicSolver

/// Many mosaics, each solved several ways — at several repetition penalties,
/// several tolerances, or both — with one page to look at them side by side.
///
/// One export is an anecdote: a single photograph can be kind or cruel to a
/// corpus, and a sunset with a peach sky says little about a snowfield. The
/// subjects are the ones cycles `first…first+N-1` would show — the ordinary
/// seeded sequence, so they are a sample rather than a selection, and every
/// column sees the same photographs with the same B in the anchor.
enum BatchExporter {
    /// One way of solving: a penalty with whatever cap `--max-uses` says, or a
    /// tolerance with no cap at all, since leaving the repetitions to the
    /// corpus is what a tolerance is for.
    enum Column {
        case penalty(Double)
        case tolerance(Double)
        /// A tolerance, the anchor's ring taking any photograph or only those
        /// sharp enough for it (`--compare-ring`).
        case ring(Double, sharp: Bool)

        /// `p1`, `t10`: short enough for a file name, exact enough to tell apart.
        var name: String {
            switch self {
            case .penalty(let value): return "p" + BatchExporter.label(value)
            case .tolerance(let value): return "t" + BatchExporter.label(value)
            case .ring(let value, let sharp): return "t" + BatchExporter.label(value) + (sharp ? "-sharp" : "-any")
            }
        }

        var caption: String {
            switch self {
            case .penalty(let value): return "penalty " + BatchExporter.label(value)
            case .tolerance(let value): return "tolerance " + BatchExporter.label(value)
            case .ring(let value, let sharp):
                return "tolerance " + BatchExporter.label(value) + (sharp ? ", sharp ring" : ", any ring")
            }
        }

        func apply(to options: Options) -> Options {
            var variant = options
            switch self {
            case .penalty(let value):
                variant.repeatPenalty = value
                variant.tolerance = nil
            case .tolerance(let value):
                variant.tolerance = value
                variant.maximumUses = nil
            case .ring(let value, let sharp):
                variant.tolerance = value
                variant.maximumUses = nil
                variant.sharpRing = sharp
            }
            return variant
        }
    }

    struct Mosaic {
        let column: Column
        let file: String
        let errorFile: String
        let ringFile: String
        let statistics: SolveStatistics
    }

    struct Subject {
        let number: Int
        let cycle: Int
        let photo: PhotoID
        let targetFile: String
        var targetRingFile = ""
        /// Where the ring is in the crops, as CSS percentages.
        var ringBox = ""

        /// The same target with the spacing, the penalty and the cap all off:
        /// the closest this corpus can get to the photograph at all. What a
        /// mosaic loses above it is the price of variety; the floor itself is
        /// a photograph the corpus has no colours for.
        let floor: SolveStatistics
        var mosaics: [Mosaic] = []
    }

    static func export(
        to directory: URL,
        subjects count: Int,
        firstCycle: Int,
        columns: [Column],
        width: Int,
        options: Options,
        device: MTLDevice,
        library: MTLLibrary,
        photos: PhotoSourceFactory.Resolved
    ) throws {
        guard count > 0, !columns.isEmpty else { throw BatchError.nothingToExport }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let height = CanonicalAspect.height(forWidth: width)
        var subjects: [Subject] = []

        // One engine per column, built one at a time: each holds an atlas of
        // the whole pool, and three of them at once is a gigabyte for nothing.
        for (position, column) in columns.enumerated() {
            var variant = column.apply(to: options)
            variant.subject = nil
            guard let planner = PlannerFactory.make(options: variant, photos: photos).planner else {
                // Random tiles have no statistics, and a batch of them would
                // compare nothing with nothing.
                throw BatchError.noSolver
            }

            let engine = try MosaicEngine(
                device: device,
                settings: options.settings,
                source: photos.source,
                planner: planner,
                library: library,
                seed: options.seed,
                tilePixelWidth: options.tileWidth
            )
            guard let texture = engine.makeOffscreenTexture(width: width, height: height) else {
                throw ExportError.couldNotAllocateTexture
            }

            let started = Date()
            for index in 0..<count {
                let number = index + 1
                let cycle = firstCycle + index
                let photo = engine.renderMosaic(cycle: cycle, into: texture)

                // The engine falls back to random tiles rather than fail, which
                // is right for a screen saver and wrong here: the numbers would
                // belong to an older mosaic.
                if let error = engine.statistics.lastError {
                    throw BatchError.solverFailed(cycle: cycle, reason: error)
                }
                guard let statistics = engine.statistics.solve else {
                    throw BatchError.solverFailed(cycle: cycle, reason: "no statistics")
                }

                let around = ringRegion(
                    anchor: statistics.anchorIndex, rows: options.rows, ring: options.closeUpOptions.ring,
                    width: width, height: height
                )
                if position == 0 {
                    let targetFile = String(format: "%02d-target.png", number)
                    var targetRingFile = ""
                    if let image = try? photos.source.canonicalImage(for: photo, maxPixelWidth: width) {
                        try PNGWriter.write(image: image, to: directory.appendingPathComponent(targetFile))
                        if let around, image.width == width, let crop = image.cropping(to: around) {
                            targetRingFile = String(format: "%02d-target.ring.png", number)
                            try PNGWriter.write(image: crop, to: directory.appendingPathComponent(targetRingFile))
                        }
                    }
                    let box = around.flatMap { around in
                        ringRegion(
                            anchor: statistics.anchorIndex, rows: options.rows, ring: options.closeUpOptions.ring,
                            width: width, height: height, reach: options.closeUpOptions.ring
                        ).map { ring in
                            String(
                                format: "left:%.2f%%;top:%.2f%%;width:%.2f%%;height:%.2f%%",
                                100 * (ring.minX - around.minX) / around.width, 100 * (ring.minY - around.minY) / around.height,
                                100 * ring.width / around.width, 100 * ring.height / around.height
                            )
                        }
                    } ?? ""
                    subjects.append(Subject(
                        number: number, cycle: cycle, photo: photo, targetFile: targetFile,
                        targetRingFile: targetRingFile, ringBox: box,
                        floor: try floor(
                            of: photo, cycle: cycle, sequence: planner, options: options, photos: photos
                        )
                    ))
                } else if subjects[index].photo != photo {
                    // The subject sequence depends on the pool and the seed and
                    // on nothing a column touches. If this ever fires, the
                    // columns of the page compare different photographs.
                    throw BatchError.subjectsDiverged(cycle: cycle)
                }

                let stem = String(format: "%02d-%@", number, column.name)
                let file = stem + ".png"
                let errorFile = stem + ".error.png"
                let pixels = MosaicExporter.readBack(texture)
                try PNGWriter.write(
                    pixels: pixels, width: width, height: height,
                    to: directory.appendingPathComponent(file)
                )
                var ringFile = ""
                if let around {
                    ringFile = stem + ".ring.png"
                    try PNGWriter.write(
                        pixels: crop(pixels, width: width, to: around),
                        width: Int(around.width), height: Int(around.height),
                        to: directory.appendingPathComponent(ringFile)
                    )
                }
                try ErrorMap.write(
                    cellDeltaE: statistics.cellDeltaE, rows: options.rows,
                    width: width, height: height,
                    to: directory.appendingPathComponent(errorFile)
                )
                subjects[index].mosaics.append(Mosaic(
                    column: column, file: file, errorFile: errorFile, ringFile: ringFile, statistics: statistics
                ))
            }
            print(String(
                format: "  %@: %d mosaics in %.1f s",
                column.caption, count, Date().timeIntervalSince(started)
            ))
        }

        let summary = summarise(subjects, columns: columns)
        try csv(subjects).write(to: directory.appendingPathComponent("summary.csv"), atomically: true, encoding: .utf8)
        try page(subjects, summary: summary, options: options, photos: photos, device: device)
            .write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let usage = UsagePage.series(of: subjects, columns: columns)
        try UsagePage.csv(usage).write(to: directory.appendingPathComponent("usage.csv"), atomically: true, encoding: .utf8)
        try UsagePage.page(usage, subjects: subjects.count, settings: settings(options, photos: photos, device: device))
            .write(to: directory.appendingPathComponent("usage.html"), atomically: true, encoding: .utf8)

        print("")
        print(table(summary))
        print("")
        print("  \(directory.appendingPathComponent("index.html").path)")
        print("  \(directory.appendingPathComponent("usage.html").path)")
        print("  \(directory.appendingPathComponent("summary.csv").path)")
    }

    /// The anchor's ring and as much again around it, in pixels of a
    /// `width × height` render: what the camera shows at the start of the
    /// next cycle, where a few dozen cells of thousands decide how it looks.
    static func ringRegion(
        anchor: Int, rows: Int, ring: Int, width: Int, height: Int, reach: Int? = nil
    ) -> CGRect? {
        guard anchor >= 0, ring > 0 else { return nil }
        let reach = reach ?? 2 * ring
        let row = anchor / rows
        let column = anchor % rows
        let first = (column: max(0, column - reach), row: max(0, row - reach))
        let last = (column: min(rows - 1, column + reach), row: min(rows - 1, row + reach))
        func x(_ column: Int) -> Int { column * width / rows }
        func y(_ row: Int) -> Int { row * height / rows }
        return CGRect(
            x: x(first.column), y: y(first.row),
            width: x(last.column + 1) - x(first.column), height: y(last.row + 1) - y(first.row)
        )
    }

    /// Rows of four bytes a pixel, cut to `rect`.
    static func crop(_ pixels: [UInt8], width: Int, to rect: CGRect) -> [UInt8] {
        var cropped: [UInt8] = []
        cropped.reserveCapacity(Int(rect.width * rect.height) * 4)
        for row in Int(rect.minY)..<Int(rect.maxY) {
            let start = (row * width + Int(rect.minX)) * 4
            cropped.append(contentsOf: pixels[start..<start + Int(rect.width) * 4])
        }
        return cropped
    }

    /// Solves one target with every constraint off, without rendering it: only
    /// the numbers are wanted.
    static func floor(
        of photo: PhotoID,
        cycle: Int,
        sequence: any MosaicPlanner,
        options: Options,
        photos: PhotoSourceFactory.Resolved
    ) throws -> SolveStatistics {
        var unconstrained = options
        unconstrained.spacing = 0
        unconstrained.repeatPenalty = 0
        unconstrained.maximumUses = .max
        unconstrained.tolerance = nil
        unconstrained.sharpRing = false
        unconstrained.subject = nil
        guard let planner = PlannerFactory.make(options: unconstrained, photos: photos).planner else {
            throw BatchError.noSolver
        }
        let planned = try planner.plan(
            rows: options.rows,
            subject: photo,
            previousSubject: cycle > 0 ? sequence.subject(ofCycle: cycle - 1) : sequence.openingSubject,
            seed: UInt64(cycle)
        )
        guard let statistics = planned.statistics else {
            throw BatchError.solverFailed(cycle: cycle, reason: "no statistics for the floor")
        }
        return statistics
    }

    // MARK: - Aggregates

    /// One column across every subject. The mean says how it does usually; the
    /// worst subject says how bad it gets, and a screen saver shows them all.
    struct Aggregate {
        let name: String
        let meanRMS: Double
        let worstRMS: Double
        let worstSubject: Int
        let worstCell: Double
        let meanDistinct: Double
        let maximumUses: Int
        /// The anchor's ring: its root mean square delta E over every
        /// subject's ring cells, and how many of those cells were not sharp.
        let ringRMS: Double
        let ringNotSharp: Int
        let ringCells: Int
    }

    static func summarise(_ subjects: [Subject], columns: [Column]) -> [Aggregate] {
        let floor = aggregate("floor", subjects, subjects.map(\.floor))
        return [floor] + columns.indices.map { position in
            aggregate(columns[position].caption, subjects, subjects.map { $0.mosaics[position].statistics })
        }
    }

    private static func aggregate(_ name: String, _ subjects: [Subject], _ runs: [SolveStatistics]) -> Aggregate {
        let rms = runs.map(\.rootMeanSquareDeltaE)
        let worst = rms.indices.max { rms[$0] < rms[$1] }!
        let ringCells = runs.map(\.ringCells).reduce(0, +)
        let ringSquares = runs.map { $0.ringRootMeanSquareDeltaE * $0.ringRootMeanSquareDeltaE * Double($0.ringCells) }
            .reduce(0, +)
        return Aggregate(
            name: name,
            meanRMS: rms.reduce(0, +) / Double(rms.count),
            worstRMS: rms[worst],
            worstSubject: subjects[worst].number,
            worstCell: runs.map(\.maximumDeltaE).max()!,
            meanDistinct: Double(runs.map(\.distinctPhotos).reduce(0, +)) / Double(runs.count),
            maximumUses: runs.map(\.maximumUses).max()!,
            ringRMS: ringCells > 0 ? (ringSquares / Double(ringCells)).squareRoot() : 0,
            ringNotSharp: runs.map(\.ringNotSharp).reduce(0, +),
            ringCells: ringCells
        )
    }

    static func table(_ summary: [Aggregate]) -> String {
        let width = max(13, summary.map(\.name.count).max() ?? 0)
        var lines = ["  column" + String(repeating: " ", count: width - 6)
            + "   mean rms   worst rms (#)   worst cell   mean distinct   max uses   ring rms   ring not sharp"]
        for row in summary {
            lines.append(String(
                format: "  %@   %8.2f   %9.2f (%02d)   %10.2f   %13.0f   %8d   %8.2f   %5d of %5d",
                row.name + String(repeating: " ", count: max(0, width - row.name.count)),
                row.meanRMS, row.worstRMS, row.worstSubject,
                row.worstCell, row.meanDistinct, row.maximumUses,
                row.ringRMS, row.ringNotSharp, row.ringCells
            ))
        }
        return lines.joined(separator: "\n")
    }

    static func csv(_ subjects: [Subject]) -> String {
        var lines = ["number,cycle,subject,column,rms_delta_e,worst_delta_e,distinct,cells,max_uses,anchor_delta_e,ring_rms_delta_e,ring_cells,ring_not_sharp"]
        for subject in subjects {
            let rows = [("floor", subject.floor)] + subject.mosaics.map { ($0.column.name, $0.statistics) }
            for (column, s) in rows {
                let name = "\"" + subject.photo.rawValue.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                lines.append(String(
                    format: "%d,%d,%@,%@,%.3f,%.3f,%d,%d,%d,%.3f,%.3f,%d,%d",
                    subject.number, subject.cycle, name, column,
                    s.rootMeanSquareDeltaE, s.maximumDeltaE, s.distinctPhotos,
                    s.cellCount, s.maximumUses, s.anchorDeltaE,
                    s.ringRootMeanSquareDeltaE, s.ringCells, s.ringNotSharp
                ))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - The page

    static func page(
        _ subjects: [Subject],
        summary: [Aggregate],
        options: Options,
        photos: PhotoSourceFactory.Resolved,
        device: MTLDevice
    ) -> String {
        let settings = escape(settings(options, photos: photos, device: device))

        var summaryRows = ""
        for row in summary {
            summaryRows += String(
                format: "<tr><td>%@</td><td>%.2f</td><td>%.2f <a href=\"#s%02d\">#%02d</a></td><td>%.2f</td><td>%.0f</td><td>%d</td><td>%.2f</td><td>%d of %d</td></tr>\n",
                row.name, row.meanRMS, row.worstRMS, row.worstSubject, row.worstSubject,
                row.worstCell, row.meanDistinct, row.maximumUses,
                row.ringRMS, row.ringNotSharp, row.ringCells
            )
        }

        var sections = ""
        for subject in subjects {
            var mosaics = ""
            var maps = ""
            var usage = ""
            var rings = ""
            // One scale for the row, so the four shapes compare; not one for the
            // page, or a night sky's tail would flatten every other subject.
            let ceiling = subject.mosaics.map { mosaic in
                Double(mosaic.statistics.photoUses.max() ?? 0) / Double(max(mosaic.statistics.cellCount, 1))
            }.max() ?? 0
            for mosaic in subject.mosaics {
                let s = mosaic.statistics
                mosaics += """
                <figure><a href="\(mosaic.file)"><img src="\(mosaic.file)" loading="lazy" alt=""></a>
                <figcaption><b>\(mosaic.column.caption)</b> \(String(
                    format: "ΔE rms %.2f · worst %.2f · %d distinct · max %d uses",
                    s.rootMeanSquareDeltaE, s.maximumDeltaE, s.distinctPhotos, s.maximumUses
                ))</figcaption></figure>

                """
                usage += usageChart(mosaic.statistics, ceiling: ceiling)
                rings += mosaic.ringFile.isEmpty ? "<figure></figure>\n" : """
                <figure><a class="ring" href="\(mosaic.ringFile)"><img src="\(mosaic.ringFile)" loading="lazy" alt=""><i style="\(subject.ringBox)"></i></a>
                <figcaption>\(String(
                    format: "ring ΔE rms %.2f · %d of %d not sharp",
                    s.ringRootMeanSquareDeltaE, s.ringNotSharp, s.ringCells
                ))</figcaption></figure>

                """
                maps += """
                <figure><a href="\(mosaic.errorFile)"><img src="\(mosaic.errorFile)" loading="lazy" alt=""></a></figure>

                """
            }
            sections += """
            <section id="\(String(format: "s%02d", subject.number))">
            <h2>\(String(format: "%02d", subject.number)) · \(escape(subject.photo.rawValue)) <span>cycle \(subject.cycle)</span></h2>
            <div class="row">
            <figure><a href="\(subject.targetFile)"><img src="\(subject.targetFile)" loading="lazy" alt=""></a><figcaption><b>target</b> \(String(
                format: "floor ΔE rms %.2f · worst %.2f", subject.floor.rootMeanSquareDeltaE, subject.floor.maximumDeltaE
            ))</figcaption></figure>
            \(mosaics)</div>
            <div class="row maps"><figure></figure>
            \(maps)</div>
            <div class="row rings">\(subject.targetRingFile.isEmpty ? "<figure></figure>" : """
            <figure><a class="ring" href="\(subject.targetRingFile)"><img src="\(subject.targetRingFile)" loading="lazy" alt=""><i style="\(subject.ringBox)"></i></a><figcaption><b>around the anchor</b> the ring of \(options.closeUpOptions.ring) cells (outlined) and as much again; the target the same</figcaption></figure>
            """)
            \(rings)</div>
            <div class="row usage"><figure><figcaption><b>uses</b> every photograph of the pool, least used to most, as a share of the cells; one scale per row, 0 to \(String(format: "%.2f", 100 * ceiling)) %</figcaption></figure>
            \(usage)</div>
            </section>

            """
        }

        let columns = summary.count   // the target, where the floor is, and one per column
        let gradient = ErrorMap.cssStops.joined(separator: ", ")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Mosaic batch</title>
        <style>
        :root { --bg: #fafaf8; --ink: #1d1d1b; --muted: #6b6b66; --rule: #c9c8c2; --plot: #f0efeb; --bar: #256abf; }
        @media (prefers-color-scheme: dark) { :root { --bg: #1b1b1a; --ink: #ecebe6; --muted: #9a9993; --rule: #4a4a45; --plot: #242422; --bar: #6da7ec; } }
        body { background: var(--bg); color: var(--ink); font: 14px/1.4 -apple-system, system-ui, sans-serif; margin: 24px; }
        h1 { font-size: 20px; margin: 0 0 4px; }
        h2 { font-size: 15px; margin: 32px 0 8px; }
        h2 span, .muted { color: var(--muted); font-weight: normal; }
        table { border-collapse: collapse; margin: 16px 0; font-variant-numeric: tabular-nums; }
        th, td { padding: 4px 14px 4px 0; text-align: right; border-bottom: 1px solid var(--rule); }
        th:first-child, td:first-child { text-align: left; }
        th { font-weight: 600; color: var(--muted); }
        .row { display: grid; grid-template-columns: repeat(\(columns), minmax(0, 1fr)); gap: 8px; }
        .maps, .usage { margin-top: 4px; }
        .usage svg { width: 100%; height: 72px; display: block; background: var(--plot); border-top: 1px solid var(--rule); }
        .usage path { fill: var(--bar); }
        figure { margin: 0; }
        img { width: 100%; display: block; }
        a.ring { position: relative; display: block; }
        a.ring i { position: absolute; outline: 2px solid rgba(255, 255, 255, 0.85); box-shadow: 0 0 0 3px rgba(0, 0, 0, 0.45); pointer-events: none; }
        figcaption { font-size: 12px; color: var(--muted); margin-top: 3px; font-variant-numeric: tabular-nums; }
        figcaption b { color: var(--ink); font-weight: 600; }
        .legend { display: flex; align-items: center; gap: 8px; color: var(--muted); font-size: 12px; }
        .legend i { display: block; width: 240px; height: 10px; background: linear-gradient(to right, \(gradient)); }
        </style>
        </head>
        <body>
        <h1>Mosaic batch</h1>
        <p class="muted">\(settings)</p>
        <p><a href="usage.html">How often each photograph is used →</a></p>
        <table>
        <tr><th>column</th><th>mean ΔE rms</th><th>worst subject</th><th>worst cell</th><th>mean distinct</th><th>max uses</th><th>ring ΔE rms</th><th>ring cells not sharp</th></tr>
        \(summaryRows)</table>
        <div class="legend">error map: ΔE <span>0</span><i></i><span>\(String(format: "%.0f", ErrorMap.ceiling))+</span> — fixed scale, so maps compare across mosaics</div>
        \(sections)
        </body>
        </html>

        """
    }

    /// Every photograph of the pool as one bar, least used to most, the height
    /// its share of the cells. Sorted, the bars are a staircase, so they are
    /// drawn as one path with a step per run of equal counts: 2048 rectangles
    /// per chart, eighty charts a page, would be a slow page for nothing.
    static func usageChart(_ statistics: SolveStatistics, ceiling: Double) -> String {
        let uses = statistics.photoUses.sorted()
        let cells = Double(max(statistics.cellCount, 1))
        let width = uses.count
        let height = 1000.0
        var path = "M0 \(Int(height))"
        var index = 0
        while index < width {
            var end = index
            while end < width, uses[end] == uses[index] { end += 1 }
            let y = ceiling > 0 ? height * (1 - Double(uses[index]) / cells / ceiling) : height
            path += String(format: " L%d %.1f L%d %.1f", index, y, end, y)
            index = end
        }
        path += " L\(width) \(Int(height)) Z"
        let most = uses.last ?? 0
        let used = uses.filter { $0 > 0 }.count
        return """
        <figure><svg viewBox="0 0 \(width) \(Int(height))" preserveAspectRatio="none" role="img" aria-label="uses per photograph"><path d="\(path)"/></svg>
        <figcaption>\(String(
            format: "%d of %d used · most %d uses, %.2f %%", used, width, most, 100 * Double(most) / cells
        ))</figcaption></figure>

        """
    }

    /// The line under a page's title: what every column had in common.
    static func settings(_ options: Options, photos: PhotoSourceFactory.Resolved, device: MTLDevice) -> String {
        String(
            format: "R = %d · k = %d · spacing %d · max uses %@ for penalties, none for tolerances · weights L %.2f C %.2f · %@ · %@",
            options.rows, options.detail, options.spacing,
            options.maximumUses.map(String.init) ?? "derived",
            options.lightnessWeight, options.chromaWeight,
            photos.description, device.name
        )
    }

    static func label(_ value: Double) -> String {
        String(format: "%g", value)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

enum BatchError: Error, CustomStringConvertible {
    case nothingToExport
    case noSolver
    case solverFailed(cycle: Int, reason: String)
    case subjectsDiverged(cycle: Int)

    var description: String {
        switch self {
        case .nothingToExport:
            return "a batch needs at least one subject, and one penalty or tolerance"
        case .noSolver:
            return "a batch needs real photographs and the solver: pass --folder, and not --random-tiles"
        case .solverFailed(let cycle, let reason):
            return "the solver failed on cycle \(cycle), so its numbers would be of another mosaic: \(reason)"
        case .subjectsDiverged(let cycle):
            return "cycle \(cycle) depicts a different photograph in a different column"
        }
    }
}

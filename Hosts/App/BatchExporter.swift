import Foundation
import Metal
import MosaicCore
import MosaicEngine
import MosaicSolver

/// Many mosaics, each solved at several repetition penalties, with one page to
/// look at them side by side.
///
/// One export is an anecdote: a single photograph can be kind or cruel to a
/// corpus, and a sunset with a peach sky says little about a snowfield. The
/// subjects are the ones cycles `first…first+N-1` would show — the ordinary
/// seeded sequence, so they are a sample rather than a selection, and every
/// penalty sees the same photographs with the same B in the anchor.
enum BatchExporter {
    struct Mosaic {
        let penalty: Double
        let file: String
        let errorFile: String
        let statistics: SolveStatistics
    }

    struct Subject {
        let number: Int
        let cycle: Int
        let photo: PhotoID
        let targetFile: String

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
        penalties: [Double],
        width: Int,
        options: Options,
        device: MTLDevice,
        library: MTLLibrary,
        photos: PhotoSourceFactory.Resolved
    ) throws {
        guard count > 0, !penalties.isEmpty else { throw BatchError.nothingToExport }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let height = CanonicalAspect.height(forWidth: width)
        var subjects: [Subject] = []

        // One engine per penalty, built one at a time: each holds an atlas of
        // the whole pool, and three of them at once is a gigabyte for nothing.
        for (column, penalty) in penalties.enumerated() {
            var variant = options
            variant.repeatPenalty = penalty
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

                if column == 0 {
                    let targetFile = String(format: "%02d-target.png", number)
                    if let image = try? photos.source.canonicalImage(for: photo, maxPixelWidth: width) {
                        try PNGWriter.write(image: image, to: directory.appendingPathComponent(targetFile))
                    }
                    subjects.append(Subject(
                        number: number, cycle: cycle, photo: photo, targetFile: targetFile,
                        floor: try floor(
                            of: photo, cycle: cycle, sequence: planner, options: options, photos: photos
                        )
                    ))
                } else if subjects[index].photo != photo {
                    // The subject sequence depends on the pool and the seed and
                    // on nothing the penalty touches. If this ever fires, the
                    // columns of the page compare different photographs.
                    throw BatchError.subjectsDiverged(cycle: cycle)
                }

                let stem = String(format: "%02d-p%@", number, label(penalty))
                let file = stem + ".png"
                let errorFile = stem + ".error.png"
                try PNGWriter.write(
                    pixels: MosaicExporter.readBack(texture), width: width, height: height,
                    to: directory.appendingPathComponent(file)
                )
                try ErrorMap.write(
                    cellDeltaE: statistics.cellDeltaE, rows: options.rows,
                    width: width, height: height,
                    to: directory.appendingPathComponent(errorFile)
                )
                subjects[index].mosaics.append(Mosaic(
                    penalty: penalty, file: file, errorFile: errorFile, statistics: statistics
                ))
            }
            print(String(
                format: "  penalty %@: %d mosaics in %.1f s",
                label(penalty), count, Date().timeIntervalSince(started)
            ))
        }

        let summary = summarise(subjects, penalties: penalties)
        try csv(subjects).write(to: directory.appendingPathComponent("summary.csv"), atomically: true, encoding: .utf8)
        try page(subjects, summary: summary, options: options, photos: photos, device: device)
            .write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        print("")
        print(table(summary))
        print("")
        print("  \(directory.appendingPathComponent("index.html").path)")
        print("  \(directory.appendingPathComponent("summary.csv").path)")
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
        unconstrained.subject = nil
        guard let planner = PlannerFactory.make(options: unconstrained, photos: photos).planner else {
            throw BatchError.noSolver
        }
        _ = try planner.layout(
            rows: options.rows,
            subject: photo,
            previousSubject: cycle > 0 ? sequence.subject(ofCycle: cycle - 1) : nil,
            seed: UInt64(cycle)
        )
        guard let statistics = planner.lastStatistics else {
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
    }

    static func summarise(_ subjects: [Subject], penalties: [Double]) -> [Aggregate] {
        let floor = aggregate("floor", subjects, subjects.map(\.floor))
        return [floor] + penalties.indices.map { column in
            aggregate(label(penalties[column]), subjects, subjects.map { $0.mosaics[column].statistics })
        }
    }

    private static func aggregate(_ name: String, _ subjects: [Subject], _ runs: [SolveStatistics]) -> Aggregate {
        let rms = runs.map(\.rootMeanSquareDeltaE)
        let worst = rms.indices.max { rms[$0] < rms[$1] }!
        return Aggregate(
            name: name,
            meanRMS: rms.reduce(0, +) / Double(rms.count),
            worstRMS: rms[worst],
            worstSubject: subjects[worst].number,
            worstCell: runs.map(\.maximumDeltaE).max()!,
            meanDistinct: Double(runs.map(\.distinctPhotos).reduce(0, +)) / Double(runs.count),
            maximumUses: runs.map(\.maximumUses).max()!
        )
    }

    static func table(_ summary: [Aggregate]) -> String {
        var lines = ["  penalty   mean rms   worst rms (#)   worst cell   mean distinct   max uses"]
        for row in summary {
            lines.append(String(
                format: "  %@   %8.2f   %9.2f (%02d)   %10.2f   %13.0f   %8d",
                String(repeating: " ", count: max(0, 7 - row.name.count)) + row.name,
                row.meanRMS, row.worstRMS, row.worstSubject,
                row.worstCell, row.meanDistinct, row.maximumUses
            ))
        }
        return lines.joined(separator: "\n")
    }

    static func csv(_ subjects: [Subject]) -> String {
        var lines = ["number,cycle,subject,penalty,rms_delta_e,worst_delta_e,distinct,cells,max_uses,anchor_delta_e"]
        for subject in subjects {
            let rows = [("floor", subject.floor)] + subject.mosaics.map { (label($0.penalty), $0.statistics) }
            for (penalty, s) in rows {
                let name = "\"" + subject.photo.rawValue.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                lines.append(String(
                    format: "%d,%d,%@,%@,%.3f,%.3f,%d,%d,%d,%.3f",
                    subject.number, subject.cycle, name, penalty,
                    s.rootMeanSquareDeltaE, s.maximumDeltaE, s.distinctPhotos,
                    s.cellCount, s.maximumUses, s.anchorDeltaE
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
        let settings = String(
            format: "R = %d · k = %d · spacing %d · max uses %@ · weights L %.2f C %.2f · %@ · %@",
            options.rows, options.detail, options.spacing,
            options.maximumUses.map(String.init) ?? "derived",
            options.lightnessWeight, options.chromaWeight,
            escape(photos.description), escape(device.name)
        )

        var summaryRows = ""
        for row in summary {
            summaryRows += String(
                format: "<tr><td>%@</td><td>%.2f</td><td>%.2f <a href=\"#s%02d\">#%02d</a></td><td>%.2f</td><td>%.0f</td><td>%d</td></tr>\n",
                row.name, row.meanRMS, row.worstRMS, row.worstSubject, row.worstSubject,
                row.worstCell, row.meanDistinct, row.maximumUses
            )
        }

        var sections = ""
        for subject in subjects {
            var mosaics = ""
            var maps = ""
            for mosaic in subject.mosaics {
                let s = mosaic.statistics
                mosaics += """
                <figure><a href="\(mosaic.file)"><img src="\(mosaic.file)" loading="lazy" alt=""></a>
                <figcaption><b>penalty \(label(mosaic.penalty))</b> \(String(
                    format: "ΔE rms %.2f · worst %.2f · %d distinct · max %d uses",
                    s.rootMeanSquareDeltaE, s.maximumDeltaE, s.distinctPhotos, s.maximumUses
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
            </section>

            """
        }

        let columns = summary.count + 1
        let gradient = ErrorMap.cssStops.joined(separator: ", ")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Mosaic batch</title>
        <style>
        :root { --bg: #fafaf8; --ink: #1d1d1b; --muted: #6b6b66; --rule: #e2e1dc; }
        @media (prefers-color-scheme: dark) { :root { --bg: #1b1b1a; --ink: #ecebe6; --muted: #9a9993; --rule: #34342f; } }
        body { background: var(--bg); color: var(--ink); font: 14px/1.4 -apple-system, system-ui, sans-serif; margin: 24px; }
        h1 { font-size: 20px; margin: 0 0 4px; }
        h2 { font-size: 15px; margin: 32px 0 8px; }
        h2 span, .muted { color: var(--muted); font-weight: normal; }
        table { border-collapse: collapse; margin: 16px 0; font-variant-numeric: tabular-nums; }
        th, td { padding: 4px 14px 4px 0; text-align: right; border-bottom: 1px solid var(--rule); }
        th:first-child, td:first-child { text-align: left; }
        th { font-weight: 600; color: var(--muted); }
        .row { display: grid; grid-template-columns: repeat(\(columns), minmax(0, 1fr)); gap: 8px; }
        .maps { margin-top: 4px; }
        figure { margin: 0; }
        img { width: 100%; display: block; }
        figcaption { font-size: 12px; color: var(--muted); margin-top: 3px; font-variant-numeric: tabular-nums; }
        figcaption b { color: var(--ink); font-weight: 600; }
        .legend { display: flex; align-items: center; gap: 8px; color: var(--muted); font-size: 12px; }
        .legend i { display: block; width: 240px; height: 10px; background: linear-gradient(to right, \(gradient)); }
        </style>
        </head>
        <body>
        <h1>Mosaic batch</h1>
        <p class="muted">\(settings)</p>
        <table>
        <tr><th>penalty</th><th>mean ΔE rms</th><th>worst subject</th><th>worst cell</th><th>mean distinct</th><th>max uses</th></tr>
        \(summaryRows)</table>
        <div class="legend">error map: ΔE <span>0</span><i></i><span>\(String(format: "%.0f", ErrorMap.ceiling))+</span> — fixed scale, so maps compare across mosaics</div>
        \(sections)
        </body>
        </html>

        """
    }

    /// `0.5`, `1`, `2`: short enough for a file name, exact enough to tell apart.
    static func label(_ penalty: Double) -> String {
        String(format: "%g", penalty)
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
            return "a batch needs at least one subject and one penalty"
        case .noSolver:
            return "a batch needs real photographs and the solver: pass --folder, and not --random-tiles"
        case .solverFailed(let cycle, let reason):
            return "the solver failed on cycle \(cycle), so its numbers would be of another mosaic: \(reason)"
        case .subjectsDiverged(let cycle):
            return "cycle \(cycle) depicts a different photograph at a different penalty"
        }
    }
}

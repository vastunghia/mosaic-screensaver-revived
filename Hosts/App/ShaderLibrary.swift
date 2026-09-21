import Foundation
import Metal

/// Finds default.metallib.
///
/// In a built .app this is the production path and needs no help: the library
/// sits in Contents/Resources and Bundle.main finds it. The env var and the
/// next-to-the-executable fallback exist for `swift run`, where there is no
/// bundle — a development convenience, and deliberately not something the
/// library itself knows about.
enum ShaderLibrary {
    static func load(device: MTLDevice) throws -> MTLLibrary {
        if let library = try? device.makeDefaultLibrary(bundle: .main) {
            return library
        }

        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["MOSAIC_METALLIB"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("default.metallib")
        )

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return try device.makeLibrary(URL: candidate)
        }

        throw HarnessError.noShaderLibrary(tried: candidates.map(\.path))
    }
}

enum HarnessError: Error, CustomStringConvertible {
    case noMetalDevice
    case noShaderLibrary(tried: [String])
    case indexingWithoutAFolder

    var description: String {
        switch self {
        case .indexingWithoutAFolder:
            return "--build-index needs a --folder to index"
        case .noMetalDevice:
            return "no MTLDevice available"
        case .noShaderLibrary(let tried):
            return """
                default.metallib not found. Looked in: \(tried.joined(separator: ", ")).
                Build with Hosts/App/build.sh, or point at it with MOSAIC_METALLIB.
                """
        }
    }
}

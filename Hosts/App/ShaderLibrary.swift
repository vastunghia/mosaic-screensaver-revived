import Foundation
import Metal
import MosaicPhotoKit

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
    case photosNotAuthorized(PhotoLibraryAccess.Status)
    case unknownAlbums([String], known: [String])
    case verifyingWithoutPhotographs
    case facesWithoutAFolder
    case unknownScreen(String, known: [String])

    var description: String {
        switch self {
        case .indexingWithoutAFolder:
            return "--build-index needs a --folder or --photos-library to index"
        case .photosNotAuthorized(let status):
            return """
                no access to the Photos library (\(status)). Grant it in System Settings › \
                Privacy & Security › Photos, and launch with `open Mosaic.app --args …` so the \
                grant is the app's and not the terminal's.
                """
        case .unknownAlbums(let missing, let known):
            return "no album called \(missing.joined(separator: ", ")). Albums: \(known.joined(separator: ", "))"
        case .unknownScreen(let name, let known):
            return "no display called \(name). Displays: \(known.joined(separator: ", "))"
        case .facesWithoutAFolder:
            return "--export-faces needs a --folder"
        case .verifyingWithoutPhotographs:
            return "--verify-canonical needs a --folder or --photos-library"
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

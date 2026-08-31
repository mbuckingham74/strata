import Foundation

enum StemExportError: Error, LocalizedError, Equatable {
    case sourceAndDestinationMatch

    var errorDescription: String? {
        switch self {
        case .sourceAndDestinationMatch:
            return "Choose a location other than the original stem file."
        }
    }
}

struct StemExporter {
    static func defaultFilename(for stem: StemName) -> String {
        "\(stem.rawValue).wav"
    }

    static func export(
        _ artifact: StemArtifact,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let sourceURL = artifact.url.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDestinationURL = destinationURL.standardizedFileURL.resolvingSymlinksInPath()

        guard sourceURL != resolvedDestinationURL else {
            throw StemExportError.sourceAndDestinationMatch
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: artifact.url, to: destinationURL)
    }
}

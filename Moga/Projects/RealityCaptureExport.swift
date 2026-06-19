import Foundation

// Generates a Reality Capture project file pointing at the scanned photos folder.

final class RealityCaptureExport {

    func export(project: MogaProject, photosURL: URL) throws -> URL {
        let exportURL = photosURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(project.name).rcproj")

        let content = """
        <?xml version="1.0" encoding="utf-8"?>
        <RealityCaptureProject version="1">
          <name>\(project.name)</name>
          <imageFolder>\(photosURL.path)</imageFolder>
        </RealityCaptureProject>
        """

        try content.write(to: exportURL, atomically: true, encoding: .utf8)
        return exportURL
    }
}

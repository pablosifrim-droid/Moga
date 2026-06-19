import Foundation

// Generates a Meshroom .mg project file pointing at the scanned photos folder.

final class MeshroomExport {

    func export(project: MogaProject, photosURL: URL) throws -> URL {
        let exportURL = photosURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(project.name).mg")

        let content = """
        {
          "header": {
            "releaseVersion": "2023.3.0",
            "fileVersion": "1.1",
            "template": false
          },
          "graph": {
            "CameraInit_1": {
              "nodeType": "CameraInit",
              "inputs": {
                "viewpoints": [
                  {"path": "\(photosURL.path)"}
                ]
              }
            }
          }
        }
        """

        try content.write(to: exportURL, atomically: true, encoding: .utf8)
        return exportURL
    }
}

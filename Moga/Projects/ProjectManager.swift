import Foundation
import AppKit

struct MogaProject: Codable {
    let id: UUID
    var name: String
    let createdAt: Date
    var photoCount: Int
    var patternName: String
    var focusStackEnabled: Bool
    var stackSize: Int
}

@Observable
final class ProjectManager {
    private(set) var projects: [MogaProject] = []

    private var rootURL: URL {
        URL.documentsDirectory.appendingPathComponent("Moga Projects", isDirectory: true)
    }

    func projectURL(_ project: MogaProject) -> URL {
        rootURL.appendingPathComponent(project.name, isDirectory: true)
    }

    func photosURL(_ project: MogaProject) -> URL {
        projectURL(project).appendingPathComponent("Photos", isDirectory: true)
    }

    // MARK: - Create

    func createProject(name: String, photoCount: Int, pattern: String,
                       focusStack: Bool, stackSize: Int) throws -> MogaProject {
        let project = MogaProject(
            id: UUID(), name: name, createdAt: Date(),
            photoCount: photoCount, patternName: pattern,
            focusStackEnabled: focusStack, stackSize: stackSize
        )
        let photosDir = photosURL(project)
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        try saveMetadata(project)
        projects.append(project)
        return project
    }

    // MARK: - Save photos

    func savePhoto(_ data: Data, project: MogaProject, positionIndex: Int, stackIndex: Int) throws {
        let filename = String(format: "photo_%04d_%02d.jpg", positionIndex, stackIndex)
        let url = photosURL(project).appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
    }

    func saveMergedPhoto(_ data: Data, project: MogaProject, positionIndex: Int) throws {
        let filename = String(format: "merged_%04d.jpg", positionIndex)
        let url = photosURL(project).appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Zip

    func zipProject(_ project: MogaProject) async throws -> URL {
        let sourceURL = photosURL(project)
        let zipURL = projectURL(project).appendingPathComponent("\(project.name).zip")
        try await Task.detached(priority: .utility) {
            let coordinator = NSFileCoordinator()
            var error: NSError?
            coordinator.coordinate(readingItemAt: sourceURL, options: .forUploading, error: &error) { url in
                try? FileManager.default.copyItem(at: url, to: zipURL)
            }
        }.value
        return zipURL
    }

    // MARK: - Load projects from disk

    func loadProjects() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil) else { return }
        projects = contents.compactMap { url in
            let metaURL = url.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let project = try? JSONDecoder().decode(MogaProject.self, from: data)
            else { return nil }
            return project
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func openProjectFolder(_ project: MogaProject) {
        NSWorkspace.shared.open(projectURL(project))
    }

    // MARK: - Private

    private func saveMetadata(_ project: MogaProject) throws {
        let data = try JSONEncoder().encode(project)
        try data.write(to: projectURL(project).appendingPathComponent("project.json"), options: .atomic)
    }
}

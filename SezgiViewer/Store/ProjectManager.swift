import Foundation
import SwiftUI

/// One entry of the projects index shown on the welcome screen.
struct ProjectInfo: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// JSON file name inside the Projects directory.
    var fileName: String
    var createdAt: Date
    var lastOpenedAt: Date?

    init(id: UUID = UUID(),
         name: String,
         fileName: String,
         createdAt: Date = Date(),
         lastOpenedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}

/// Owns the list of projects and the currently open one. Each project lives in
/// its own JSON file under Application Support/SezgiViewer/Projects, with a
/// small index file alongside.
@MainActor
final class ProjectManager: ObservableObject {

    @Published private(set) var projects: [ProjectInfo] = []
    @Published private(set) var activeProject: ProjectInfo?
    @Published private(set) var activeStore: ProjectStore?

    private let baseDir: URL
    private let projectsDir: URL
    private let indexURL: URL

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        baseDir = base.appendingPathComponent("SezgiViewer", isDirectory: true)
        projectsDir = baseDir.appendingPathComponent("Projects", isDirectory: true)
        indexURL = baseDir.appendingPathComponent("projects.json")
        try? fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        loadIndex()
        migrateLegacyProjectIfNeeded()
    }

    // MARK: - Index persistence

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([ProjectInfo].self, from: data) else { return }
        projects = list
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Adopts the single pre-projects `project.json` as a first project so
    /// nothing is lost on upgrade.
    private func migrateLegacyProjectIfNeeded() {
        guard projects.isEmpty else { return }
        let legacy = baseDir.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }

        let info = ProjectInfo(name: "My Project", fileName: UUID().uuidString + ".json")
        let destination = projectsDir.appendingPathComponent(info.fileName)
        do {
            try FileManager.default.moveItem(at: legacy, to: destination)
        } catch {
            guard (try? FileManager.default.copyItem(at: legacy, to: destination)) != nil else { return }
        }
        projects = [info]
        saveIndex()
    }

    private func fileURL(for info: ProjectInfo) -> URL {
        projectsDir.appendingPathComponent(info.fileName)
    }

    // MARK: - Project lifecycle

    func createProject(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = ProjectInfo(name: trimmed.isEmpty ? "Untitled Project" : trimmed,
                               fileName: UUID().uuidString + ".json")
        projects.insert(info, at: 0)
        saveIndex()
        openProject(info)
    }

    func openProject(_ info: ProjectInfo) {
        var info = info
        info.lastOpenedAt = Date()
        if let idx = projects.firstIndex(where: { $0.id == info.id }) {
            projects[idx] = info
        }
        saveIndex()
        activeProject = info
        activeStore = ProjectStore(persistenceURL: fileURL(for: info))
    }

    /// Returns to the welcome screen. The store saves on every mutation, so
    /// there is nothing to flush here.
    func closeProject() {
        activeStore = nil
        activeProject = nil
    }

    func renameProject(_ info: ProjectInfo, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = projects.firstIndex(where: { $0.id == info.id }) else { return }
        projects[idx].name = trimmed
        if activeProject?.id == info.id { activeProject?.name = trimmed }
        saveIndex()
    }

    /// Removes the project and its data file. The tracked PDFs themselves are
    /// untouched — only the app-side project record is deleted.
    func deleteProject(_ info: ProjectInfo) {
        if activeProject?.id == info.id { closeProject() }
        try? FileManager.default.removeItem(at: fileURL(for: info))
        projects.removeAll { $0.id == info.id }
        saveIndex()
    }
}

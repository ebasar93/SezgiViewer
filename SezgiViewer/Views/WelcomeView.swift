import SwiftUI

/// Startup screen: create a new project or open an existing one.
struct WelcomeView: View {
    @EnvironmentObject private var manager: ProjectManager

    @State private var showNewProject = false
    @State private var newName = ""
    @State private var renameTarget: ProjectInfo?
    @State private var renameText = ""
    @State private var deleteTarget: ProjectInfo?

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(width: 280)
                .frame(maxHeight: .infinity)
                .background(.thickMaterial)
            Divider()
            projectList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("New Project", isPresented: $showNewProject) {
            TextField("Project Name", text: $newName)
            Button("Create") {
                manager.createProject(named: newName)
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("PDFs you add are tracked per project.")
        }
        .alert("Rename Project", isPresented: renameAlertShown) {
            TextField("Project Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    manager.renameProject(target, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Delete Project?", isPresented: deleteAlertShown) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    manager.deleteProject(target)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("\u{201C}\(deleteTarget?.name ?? "")\u{201D} and its highlight data will be removed. The PDF files themselves are not touched.")
        }
    }

    private var renameAlertShown: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    private var deleteAlertShown: Binding<Bool> {
        Binding(get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } })
    }

    private var leftPanel: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "highlighter")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
            Text("SezgiViewer")
                .font(.title.weight(.semibold))
            Text("Collect PDF highlights into one clean summary.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                showNewProject = true
            } label: {
                Label("New Project…", systemImage: "plus")
                    .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
            Spacer()
        }
    }

    @ViewBuilder private var projectList: some View {
        if manager.projects.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No projects yet")
                    .font(.headline)
                Text("Create a project to start tracking PDFs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section("Existing Projects") {
                    ForEach(manager.projects) { info in
                        ProjectRow(info: info)
                            .contentShape(Rectangle())
                            .onTapGesture { manager.openProject(info) }
                            .contextMenu {
                                Button("Open") { manager.openProject(info) }
                                Button("Rename…") {
                                    renameText = info.name
                                    renameTarget = info
                                }
                                Divider()
                                Button("Delete…", role: .destructive) {
                                    deleteTarget = info
                                }
                            }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct ProjectRow: View {
    let info: ProjectInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        if let opened = info.lastOpenedAt {
            return "Last opened \(df.string(from: opened))"
        }
        return "Created \(df.string(from: info.createdAt))"
    }
}

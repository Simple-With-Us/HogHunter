import Foundation

/// Entry in `~/.hoghunter/maintenance/registry.json`.
struct MaintainScriptEntry: Codable, Identifiable, Equatable {
    var id: String
    var path: String
    var mode: String // "owned" or "observed"
    var scope: String // "local" or "remote"
    var owner: String
    var argv: [String]?

    var isOwned: Bool { mode.lowercased() == "owned" }
    var isObserved: Bool { mode.lowercased() == "observed" }
    var isLocal: Bool { scope.lowercased() == "local" }
    var isRemote: Bool { scope.lowercased() == "remote" }

    var displayName: String {
        if id == "maintain_entrypoints" { return "Hog Hunter Maintenance" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? id : name
    }
}

struct MaintainRegistryData: Codable, Equatable {
    var version: Int
    var scripts: [MaintainScriptEntry]
}

enum MaintainRegistryStore {
    static var baseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hoghunter", isDirectory: true)
            .appendingPathComponent("maintenance", isDirectory: true)
    }

    static var scriptsDirectory: URL {
        baseDirectory.appendingPathComponent("scripts", isDirectory: true)
    }

    static var registryURL: URL {
        baseDirectory.appendingPathComponent("registry.json")
    }

    /// Loads the script entries from `registry.json` plus any standalone scripts discovered in `scripts/`.
    static func loadScripts(baseDirectory: URL? = nil, fileManager: FileManager = .default,
                            mountPaths: [String]? = nil) -> [MaintainScriptEntry] {
        let base = baseDirectory ?? self.baseDirectory
        let registryURL = base.appendingPathComponent("registry.json")
        let scriptsDirectory = base.appendingPathComponent("scripts", isDirectory: true)
        let mounts = mountPaths ?? MountedDriveStore.cachedMountRecords().map(\.path)
        func safeURL(_ url: URL) -> URL? {
            DirectorySizeWalker.automaticCanonicalPath(url.path, mountPaths: mounts)
                .map { URL(fileURLWithPath: $0) }
        }
        var registered: [MaintainScriptEntry] = []
        if let safeRegistry = safeURL(registryURL), let data = try? Data(contentsOf: safeRegistry),
           let parsed = try? JSONDecoder().decode(MaintainRegistryData.self, from: data) {
            registered = parsed.scripts
        }

        // Auto-discover any scripts dropped into ~/.hoghunter/maintenance/scripts/
        // Folder creation is an explicit Open Scripts Folder action, never a polling side effect.
        if let safeScripts = safeURL(scriptsDirectory),
           let items = try? fileManager.contentsOfDirectory(at: safeScripts, includingPropertiesForKeys: nil) {
            let existingPaths = Set(registered.map { URL(fileURLWithPath: $0.path).standardized.path })
            for item in items {
                guard !item.lastPathComponent.hasPrefix(".") else { continue }
                let stdPath = item.standardized.path
                if !existingPaths.contains(stdPath), let safeItem = safeURL(item),
                   fileManager.isExecutableFile(atPath: safeItem.path) {
                    let entry = MaintainScriptEntry(
                        id: item.deletingPathExtension().lastPathComponent,
                        path: stdPath,
                        mode: "owned",
                        scope: "local",
                        owner: "Custom script in ~/.hoghunter/maintenance/scripts",
                        argv: nil
                    )
                    registered.append(entry)
                }
            }
        }

        return presentationEntries(registered)
    }

    /// The shipped scheduler and manual entry are two callers of one script.
    /// Combine their inventory rows without changing the executable registry.
    static func presentationEntries(_ entries: [MaintainScriptEntry]) -> [MaintainScriptEntry] {
        guard let scheduled = entries.first(where: { $0.id == "maintain_scheduler" }),
              let manual = entries.first(where: { $0.id == "maintain_cli" }),
              URL(fileURLWithPath: scheduled.path).standardizedFileURL ==
                URL(fileURLWithPath: manual.path).standardizedFileURL,
              scheduled.mode == manual.mode, scheduled.scope == manual.scope else {
            return entries
        }
        var combined = scheduled
        combined.id = "maintain_entrypoints"
        combined.owner = "Scheduled by launchd and available through the app or CLI"
        return entries.compactMap { entry in
            if entry.id == "maintain_cli" { return nil }
            return entry.id == "maintain_scheduler" ? combined : entry
        }
    }

    static func ensureDirectoriesExist() {
        try? FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
    }
}

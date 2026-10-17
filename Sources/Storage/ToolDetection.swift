import Foundation

/// Information about an external CLI tool used by Hog Hunter maintenance steps.
struct ToolInfo: Identifiable, Sendable {
    let id: String
    let name: String
    let candidatePaths: [String]
    let installUrl: String
    let installCommand: String
    let description: String

    var installedPaths: [String] {
        candidatePaths.filter { path in
            FileManager.default.isExecutableFile(atPath: path)
        }
    }

    var isInstalled: Bool {
        !installedPaths.isEmpty
    }

    var hasMultipleInstallations: Bool {
        installedPaths.count > 1
    }
}

enum ToolCatalog {
    private static var homePath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    static let cleanMyMac = ToolInfo(
        id: "cleanmymac",
        name: "CleanMyMac CLI",
        candidatePaths: [
            "/opt/homebrew/bin/cleanmymac",
            "/usr/local/bin/cleanmymac",
            "\(homePath)/.local/bin/cleanmymac",
            "/opt/homebrew/Caskroom/cleanmymac-cli/1.0.0/CleanMyMac_5_CLI.app/Contents/MacOS/CleanMyMac_5_CLI"
        ],
        installUrl: "https://github.com/macpaw/cleanmymac-cli",
        installCommand: "brew install --cask cleanmymac-cli",
        description: "Official command-line interface for CleanMyMac system junk and purgeable storage optimization."
    )

    static let npm = ToolInfo(
        id: "npm",
        name: "Node Package Manager (npm)",
        candidatePaths: [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            "/usr/bin/npm",
            "\(homePath)/.nvm/current/bin/npm"
        ],
        installUrl: "https://nodejs.org",
        installCommand: "brew install node",
        description: "Package manager and cache for Node.js runtimes."
    )

    static let pm2 = ToolInfo(
        id: "pm2",
        name: "PM2 Process Manager",
        candidatePaths: [
            "/opt/homebrew/bin/pm2",
            "/usr/local/bin/pm2",
            "\(homePath)/.local/bin/pm2"
        ],
        installUrl: "https://pm2.keymetrics.io",
        installCommand: "npm install -g pm2",
        description: "Production process manager for Node.js applications and background microservices."
    )

    static let brew = ToolInfo(
        id: "brew",
        name: "Homebrew",
        candidatePaths: [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ],
        installUrl: "https://brew.sh",
        installCommand: "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
        description: "The Missing Package Manager for macOS."
    )

    static let xcode = ToolInfo(
        id: "xcode",
        name: "Xcode Developer Tools",
        candidatePaths: [
            "/Applications/Xcode.app/Contents/MacOS/Xcode",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
            "/Library/Developer/CommandLineTools/usr/bin/xcodebuild"
        ],
        installUrl: "https://developer.apple.com/xcode/",
        installCommand: "xcode-select --install",
        description: "Apple developer toolchain, simulators, and build caches."
    )

    /// Tools whose binary a maintenance step actually runs, so the path picked
    /// under Connected CLI (`tool_paths` in the maintain config) changes what
    /// runs.  `_tool_command` in `scripts/vacuum/engine.py` reads it for these.
    /// The PM2 step truncates log files and the Xcode steps delete folders, so
    /// neither runs a binary and a picker for them would change nothing.
    static let pathConfigurableToolIds: Set<String> = ["cleanmymac", "npm", "brew"]

    static func engineRunsPickedPath(_ tool: ToolInfo) -> Bool {
        pathConfigurableToolIds.contains(tool.id)
    }

    static func tool(for stepId: String) -> ToolInfo? {
        switch stepId {
        case "cleanmymac_cli": return cleanMyMac
        case "npm_cache": return npm
        case "pm2_logs": return pm2
        case "brew_cleanup": return brew
        case "xcode_derived_data", "xcode_device_support", "simctl_delete_unavailable", "shutdown_simulators": return xcode
        default: return nil
        }
    }
}

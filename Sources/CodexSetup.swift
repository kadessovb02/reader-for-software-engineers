import AppKit
import Combine
import Foundation

/// Only paths are stored in the reader's preferences. Login and credentials remain
/// entirely owned by the official Codex CLI.
enum CodexSetup {
    static let customPathKey = "codexExecutablePath"
    static let installationURL = URL(string: "https://learn.chatgpt.com/docs/codex/cli")!
    static let authenticationURL = URL(string: "https://learn.chatgpt.com/docs/auth")!
    static let installCommand = "npm install -g @openai/codex@latest"

    static func findCLI(customPath: String?) -> URL? {
        findCLICandidates(customPath: customPath).first
    }

    static func findCLICandidates(customPath: String?) -> [URL] {
        let manager = FileManager.default
        func executable(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: path, isDirectory: &isDirectory) &&
                !isDirectory.boolValue && manager.isExecutableFile(atPath: path)
        }
        if let customPath, !customPath.isEmpty {
            return executable(customPath) ? [URL(fileURLWithPath: customPath)] : []
        }
        let home = manager.homeDirectoryForCurrentUser.path
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        var candidates = (pathDirectories + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin"])
            .map { "\($0)/codex" }
        let versions = URL(fileURLWithPath: home).appendingPathComponent(".nvm/versions/node")
        if let directories = try? manager.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) {
            candidates += directories.sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
                .map { $0.appendingPathComponent("bin/codex").path }
        }
        // A separately installed public CLI wins over an internal app bundle binary.
        candidates = candidates.filter { !$0.contains(".app/Contents/") } +
            candidates.filter { $0.contains(".app/Contents/") } + [
                "/Applications/Codex.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/MacOS/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "\(home)/Applications/Codex.app/Contents/Resources/codex",
                "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            ]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted && executable($0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func missingCapabilities(globalHelp: String, execHelp: String) -> [String] {
        let globalFlags = ["--no-daemon", "--ask-for-approval", "--config"]
        let execFlags = ["--ignore-user-config", "--ignore-rules", "--ephemeral", "--sandbox",
                         "--skip-git-repo-check", "--color", "--json", "--output-last-message", "--output-schema"]
        return globalFlags.filter { !advertises($0, in: globalHelp) } +
            execFlags.filter { !advertises($0, in: execHelp) }
    }

    private static func advertises(_ flag: String, in help: String) -> Bool {
        let expression = "(?<![A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: flag) + "(?![A-Za-z0-9_-])"
        return help.range(of: expression, options: .regularExpression) != nil
    }

    @MainActor static func chooseCLI() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Выберите исполняемый файл codex"
        panel.message = "Например, /opt/homebrew/bin/codex или файл из вашей установки Node.js."
        panel.prompt = "Выбрать Codex"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor static func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCommand, forType: .string)
    }
}

/// Optional practice setup is checked only when requested. Reading and ChatGPT
/// questions do not require Docker and never start it automatically.
@MainActor
final class PracticeSetupStatus: ObservableObject {
    @Published private(set) var status = "Не проверено"
    @Published private(set) var isChecking = false
    @Published private(set) var isReady = false

    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let runner = PracticeRunner()
        await runner.refresh()
        isReady = runner.isReady
        status = runner.status
    }

    func openDocker() {
        let manager = FileManager.default
        let candidates = ["/Applications/Docker.app", manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Docker.app").path]
        if let path = candidates.first(where: { manager.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            NSWorkspace.shared.open(URL(string: "https://docs.docker.com/desktop/setup/install/mac-install/")!)
        }
    }
}

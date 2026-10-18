import Foundation
#if TEST_MODULE
@testable import ListReaderCore
#endif

/// Tests onboarding without a real account, network or credential files.
@main
struct CodexSetupSmoke {
    struct Failure: Error { let message: String }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    @MainActor static func main() async throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("ListReader-SetupTest-\(UUID().uuidString)")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let suite = "ListReader-SetupTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cli = temporary.appendingPathComponent("codex")
        let global = "--no-daemon --ask-for-approval --config"
        let exec = "--ignore-user-config --ignore-rules --ephemeral --sandbox --skip-git-repo-check --color --json --output-last-message --output-schema"
        try require(CodexSetup.missingCapabilities(globalHelp: global, execHelp: exec).isEmpty,
                    "Current CLI flags must be accepted")
        try require(CodexSetup.missingCapabilities(globalHelp: global, execHelp: exec.replacingOccurrences(of: "--ignore-rules", with: "--ignore-rules-obsolete")) == ["--ignore-rules"],
                    "A similar but unsupported switch must not bypass compatibility checking")
        try require(CodexSetup.findCLI(customPath: temporary.appendingPathComponent("missing").path) == nil,
                    "An explicit missing path must not silently switch to another account/installation")

        func writeCLI(execHelp: String) throws {
            // The fixture emits only help and a synthetic login status. It never reads auth.
            let script = """
            #!/bin/sh
            case "$1 $2" in
              "--help ") printf '%s\\n' '\(global)' ;;
              "exec --help") printf '%s\\n' '\(execHelp)' ;;
              "--version ") printf '%s\\n' 'codex-cli fixture' ;;
              "login status") printf '%s\\n' 'Logged in using ChatGPT' ;;
              *) exit 19 ;;
            esac
            """
            try script.write(to: cli, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        }
        defaults.set(cli.path, forKey: CodexSetup.customPathKey)
        let service = CodexService(defaults: defaults)
        try writeCLI(execHelp: exec.replacingOccurrences(of: "--ignore-user-config", with: ""))
        await service.refreshStatus()
        try require(!service.isConnected && !service.isCompatible, "Legacy CLI must fail closed")
        try require(service.setupDetail.contains("--ignore-user-config"), "Missing isolation flag must be actionable")
        try writeCLI(execHelp: exec)
        await service.refreshStatus()
        try require(service.isConnected && service.isCompatible, "Compatible CLI and ChatGPT status should connect")
        try require(service.cliVersion == "codex-cli fixture", "Diagnostics should show the checked version")
        try manager.removeItem(at: cli)
        await service.refreshStatus()
        try require(!service.isConnected && !service.isCompatible, "Disappearing executable must clear previous connected state")

        let broken = temporary.appendingPathComponent("broken-codex")
        try "#!/bin/sh\nprintf '%s\\n' 'missing optional npm package' >&2\nexit 1\n".write(to: broken, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: broken.path)
        try writeCLI(execHelp: exec)
        defaults.removeObject(forKey: CodexSetup.customPathKey)
        let automatic = CodexService(defaults: defaults, automaticCandidates: { [broken, cli] })
        await automatic.refreshStatus()
        try require(automatic.isConnected && automatic.cliPath == cli.path,
                    "Automatic discovery must skip a broken npm shim and select a working CLI")
        defaults.set(broken.path, forKey: CodexSetup.customPathKey)
        await automatic.refreshStatus()
        try require(!automatic.isConnected && automatic.cliPath == broken.path,
                    "An explicit broken CLI must not silently switch installations")

        // npm's entry point uses /usr/bin/env node. A disposable interpreter with
        // the same name proves the CLI's own bin directory takes PATH priority,
        // without depending on a system Node install or opening real credentials.
        let node = temporary.appendingPathComponent("node")
        try manager.createSymbolicLink(at: node, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        let shim = try String(contentsOf: cli).replacingOccurrences(of: "#!/bin/sh", with: "#!/usr/bin/env node")
        try shim.write(to: cli, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        defaults.set(cli.path, forKey: CodexSetup.customPathKey)
        await service.refreshStatus()
        try require(service.isConnected, "npm env-node shebang must resolve Node next to the selected CLI")
        print("CodexSetupSmoke passed: isolation compatibility, strict explicit path, broken automatic candidate fallback, env-node shebang lookup, synthetic login status.")
    }
}

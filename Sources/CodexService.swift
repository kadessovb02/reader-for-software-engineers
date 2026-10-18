import AppKit
import Combine
import Foundation

struct ChatTurn: Codable, Identifiable {
    var id = UUID()
    var role: String
    var text: String
}

struct ReadingContext: Sendable {
    var book: String
    var author: String
    var chapter: String
    var location: String
    var overview: String
    var visibleText: String
    var selection: String
}

enum ReaderAIError: LocalizedError {
    case unavailable, disconnected, busy, timedOut, failed(String), emptyResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Не найден Codex CLI. Откройте Настройки → ChatGPT: установите CLI по инструкции или выберите исполняемый файл, затем нажмите «Проверить»."
        case .disconnected: return "Сначала войдите в свой аккаунт ChatGPT."
        case .busy: return "Дождитесь текущего ответа или остановите его."
        case .timedOut: return "Ответ занял слишком много времени. Попробуйте ещё раз."
        case .failed(let message): return message
        case .emptyResponse: return "Codex не вернул ответ. Попробуйте ещё раз."
        }
    }
}

/// Uses the official CLI's own browser sign-in and credential storage.
/// The reader never reads, copies or manages authentication tokens.
@MainActor
final class CodexService: ObservableObject {
    @Published var status = "Проверяем подключение…"
    @Published var isConnected = false
    @Published var isBusy = false
    @Published private(set) var cliPath = ""
    @Published private(set) var cliVersion = ""
    @Published private(set) var setupDetail = ""
    @Published private(set) var isCompatible = false
    @Published private(set) var isChecking = false

    private var currentJob: ReaderCLIJob?
    private let defaults: UserDefaults
    private let automaticCandidates: () -> [URL]
    private var checkedExecutable: URL?

    init(defaults: UserDefaults = .standard,
         automaticCandidates: @escaping () -> [URL] = { CodexSetup.findCLICandidates(customPath: nil) }) {
        self.defaults = defaults
        self.automaticCandidates = automaticCandidates
    }

    var customCLIPath: String { defaults.string(forKey: CodexSetup.customPathKey) ?? "" }

    func chooseCLI() async {
        guard !isBusy, !isChecking, let url = CodexSetup.chooseCLI() else { return }
        defaults.set(url.path, forKey: CodexSetup.customPathKey)
        await refreshStatus()
    }

    func useAutomaticCLI() async {
        guard !isBusy, !isChecking else { return }
        defaults.removeObject(forKey: CodexSetup.customPathKey)
        await refreshStatus()
    }

    func refreshStatus() async {
        guard !isBusy, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        isConnected = false
        isCompatible = false
        checkedExecutable = nil
        cliVersion = ""
        setupDetail = ""
        let candidates = customCLIPath.isEmpty ? automaticCandidates() : CodexSetup.findCLICandidates(customPath: customCLIPath)
        guard !candidates.isEmpty else {
            cliPath = customCLIPath
            isConnected = false
            status = customCLIPath.isEmpty ? "Установите Codex CLI, затем нажмите «Проверить»" : "Выбранный файл Codex недоступен. Выберите его снова или включите автопоиск."
            return
        }
        status = "Проверяем Codex CLI…"
        for executable in candidates {
            cliPath = executable.path
            do {
            // Fail closed for older CLIs. Removing unsupported isolation switches
            // would load personal instructions, MCP servers or tools into book chat.
            let global = try await ReaderCLIJob().run(executable: executable,
                arguments: ["--help"], input: nil, directory: nil, timeout: 8)
            guard global.exitCode == 0 else {
                status = "Codex CLI не запускается. Переустановите его или выберите другой файл."
                setupDetail = "Исполняемый файл найден, но команда codex --help завершилась с ошибкой."
                continue
            }
            let exec = try await ReaderCLIJob().run(executable: executable,
                arguments: ["exec", "--help"], input: nil, directory: nil, timeout: 8)
            guard exec.exitCode == 0 else {
                status = "Codex CLI не запускается. Переустановите его или выберите другой файл."
                setupDetail = "Не удалось проверить команду codex exec --help."
                continue
            }
            let missing = CodexSetup.missingCapabilities(globalHelp: global.stdout + global.stderr,
                                                        execHelp: exec.stdout + exec.stderr)
            guard missing.isEmpty else {
                status = "Обновите Codex CLI: этой версии не хватает режима изоляции для помощника."
                setupDetail = "Не поддерживаются: " + missing.joined(separator: ", ")
                continue
            }
            let version = try await ReaderCLIJob().run(executable: executable,
                arguments: ["--version"], input: nil, directory: nil, timeout: 8)
            guard version.exitCode == 0 else {
                status = "Codex CLI не запускается. Переустановите его или выберите другой файл."
                setupDetail = "Не удалось проверить версию Codex CLI."
                continue
            }
            cliVersion = String(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            isCompatible = true
            checkedExecutable = executable
            setupDetail = ""
            break
            } catch is CancellationError {
                status = "Проверка Codex отменена"
                return
            } catch {
                status = "Не удалось проверить Codex. Переустановите CLI или выберите другой файл."
                setupDetail = "Проверьте, что выбранный файл запускается и его зависимости установлены."
            }
        }
        guard let executable = checkedExecutable else { return }
        do {
            let job = ReaderCLIJob()
            let result = try await job.run(executable: executable,
                arguments: ["login", "status"], input: nil, directory: nil, timeout: 12)
            let message = result.stdout + "\n" + result.stderr
            isConnected = result.exitCode == 0 && message.localizedCaseInsensitiveContains("ChatGPT")
            if isConnected {
                status = "Подключён через ChatGPT"
            } else if result.exitCode == 0 {
                status = "В Codex используется API-ключ. Войдите через ChatGPT."
            } else {
                status = "Войдите в ChatGPT"
            }
        } catch {
            isConnected = false
            status = "Не удалось проверить Codex. Нажмите «Проверить»."
        }
    }

    /// Called only after the reader presses the sign-in button.
    /// `codex login` opens OpenAI's browser authentication flow itself.
    func login() async {
        guard !isBusy, !isChecking else { return }
        await refreshStatus()
        guard isCompatible, let executable = checkedExecutable else { return }
        if isConnected { return }
        isBusy = true
        status = "Завершите вход в открывшемся браузере…"
        let job = ReaderCLIJob()
        currentJob = job
        do {
            let result = try await job.run(executable: executable,
                arguments: ["login"], input: nil, directory: nil, timeout: 240)
            currentJob = nil
            isBusy = false
            if result.exitCode == 0 {
                await refreshStatus()
            } else {
                status = "Вход не завершён. Попробуйте ещё раз."
            }
        } catch is CancellationError {
            currentJob = nil
            isBusy = false
            status = "Вход отменён"
        } catch {
            currentJob = nil
            isBusy = false
            status = error.localizedDescription
        }
    }

    func cancel() {
        currentJob?.cancel()
    }

    func ask(context: ReadingContext, history: [ChatTurn], question: String,
             search: ChatBookSearchSession? = nil, progress: ((String) -> Void)? = nil) async throws -> String {
        guard !isBusy else { throw ReaderAIError.busy }
        guard isConnected else { throw ReaderAIError.disconnected }
        isBusy = true
        defer {
            isBusy = false
            status = isConnected ? "Подключён через ChatGPT" : "Войдите в ChatGPT"
        }
        let lookup: ((ChatSearchRequest) async throws -> ChatSearchResult)?
        if let search { lookup = { request in try await search.retrieve(request) } }
        else { lookup = nil }
        return try await ChatAssistant.answer(context: context, history: history, question: question,
            retrieve: lookup, progress: { [weak self] message in
                self?.status = message; progress?(message)
            }, perform: { [weak self] instructions, payload in
                guard let self else { throw CancellationError() }
                return try await self.perform(instructions: instructions, payload: payload,
                                              status: "Читаю контекст…", managesActivity: false,
                                              outputSchema: ChatAssistant.responseSchema)
            })
    }

    /// Structured practice uses app-owned developer instructions while all book,
    /// learner code and exercise content remain untrusted data in the user payload.
    func performPractice(instructions: String, payload: String) async throws -> String {
        guard instructions.utf8.count <= 32000, payload.utf8.count <= 250000 else {
            throw ReaderAIError.failed("Для практики выбран слишком большой фрагмент. Выберите текущее место.")
        }
        return try await perform(instructions: instructions, payload: payload, status: "Готовлю практику…")
    }

    private func perform(instructions: String, payload: String, status activity: String,
                         managesActivity: Bool = true, outputSchema: String? = nil) async throws -> String {
        if managesActivity { guard !isBusy else { throw ReaderAIError.busy } }
        guard isConnected else { throw ReaderAIError.disconnected }
        guard isCompatible, let executable = checkedExecutable,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw ReaderAIError.unavailable }
        try Task.checkCancellation()
        isBusy = true
        status = activity
        let job = ReaderCLIJob()
        currentJob = job
        defer {
            currentJob = nil
            if managesActivity {
                isBusy = false
                status = isConnected ? "Подключён через ChatGPT" : "Войдите в ChatGPT"
            }
        }

        // A private empty working directory prevents project instructions and unrelated
        // workspace content from becoming part of a book conversation.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ListReader-AI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let answerURL = directory.appendingPathComponent("answer.txt")

        var arguments = ["--no-daemon", "--ask-for-approval", "never", "exec",
            "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules", "--ephemeral",
            "--sandbox", "read-only", "--color", "never", "--json",
            "--output-last-message", answerURL.path,
            "-c", "forced_login_method=\"chatgpt\"",
            "-c", "web_search=\"disabled\"",
            "-c", "mcp_servers={}",
            "-c", "project_doc_max_bytes=0",
            "-c", "skills.include_instructions=false",
            "-c", "developer_instructions=\(Self.tomlString(instructions))"]
        if let outputSchema {
            let schemaURL = directory.appendingPathComponent("response-schema.json")
            try outputSchema.write(to: schemaURL, atomically: true, encoding: .utf8)
            arguments += ["--output-schema", schemaURL.path]
        }

        // These are official CLI feature flags. User configuration and plugins are
        // ignored so reading assistance cannot invoke local commands or connectors.
        for feature in ["shell_tool", "unified_exec", "apps", "plugins", "browser_use",
                        "browser_use_external", "computer_use", "in_app_browser",
                        "multi_agent", "multi_agent_v2", "view_image", "image_generation",
                        "hooks", "goals", "sleep_tool", "workspace_dependencies", "memories",
                        "skill_search", "code_mode_host"] {
            arguments += ["-c", "features.\(feature)=false"]
        }
        arguments += ["-c", "features.skip_host_skill_discovery=true", "-"]

        let result = try await job.run(executable: executable, arguments: arguments,
            input: payload, directory: directory, timeout: 150)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            let errorText = result.stderr + "\n" + result.stdout
            if errorText.localizedCaseInsensitiveContains("unauthorized") ||
                errorText.localizedCaseInsensitiveContains("not logged in") ||
                errorText.localizedCaseInsensitiveContains("refresh_token") {
                isConnected = false
                throw ReaderAIError.disconnected
            }
            if errorText.localizedCaseInsensitiveContains("usage limit") ||
                errorText.localizedCaseInsensitiveContains("rate limit") {
                throw ReaderAIError.failed("Достигнут лимит Codex для вашего аккаунта ChatGPT. Повторите позже.")
            }
            if errorText.localizedCaseInsensitiveContains("unexpected argument") ||
                errorText.localizedCaseInsensitiveContains("unknown variant") {
                throw ReaderAIError.failed("Эта версия Codex CLI несовместима. Обновите Codex и повторите запрос.")
            }
            throw ReaderAIError.failed("Codex не смог ответить. Проверьте интернет и подключение ChatGPT.")
        }
        let answer = (try? String(contentsOf: answerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !answer.isEmpty else { throw ReaderAIError.emptyResponse }
        return answer
    }

    private static func tomlString(_ text: String) -> String {
        // JSON's escaped strings are valid TOML basic strings for these instructions.
        let data = try! JSONEncoder().encode(text)
        return String(decoding: data, as: UTF8.self)
    }

}

private struct ReaderCLIResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

/// Redirecting output to private temporary files avoids pipe back-pressure even
/// when Codex produces a large diagnostic stream. All waits happen off the UI thread.
private final class ReaderCLIJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var wasCancelled = false
    private var didTimeOut = false

    func cancel() {
        lock.lock()
        wasCancelled = true
        let running = process
        lock.unlock()
        Self.stop(running)
    }

    func run(executable: URL, arguments: [String], input: String?, directory: URL?, timeout: TimeInterval) async throws -> ReaderCLIResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    let manager = FileManager.default
                    let captureDirectory = manager.temporaryDirectory
                        .appendingPathComponent("ListReader-Process-\(UUID().uuidString)", isDirectory: true)
                    do {
                        try manager.createDirectory(at: captureDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
                        defer { try? manager.removeItem(at: captureDirectory) }
                        let stdoutURL = captureDirectory.appendingPathComponent("stdout")
                        let stderrURL = captureDirectory.appendingPathComponent("stderr")
                        manager.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                        manager.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                        let stdout = try FileHandle(forWritingTo: stdoutURL)
                        let stderr = try FileHandle(forWritingTo: stderrURL)
                        defer { try? stdout.close(); try? stderr.close() }
                        let child = Process()
                        child.executableURL = executable
                        child.arguments = arguments
                        child.currentDirectoryURL = directory
                        child.environment = Self.environment(executable: executable)
                        child.standardOutput = stdout
                        child.standardError = stderr
                        // A file instead of a pipe also bounds stdin setup and avoids
                        // a writer thread becoming stuck if a child exits before reading.
                        let inputURL = captureDirectory.appendingPathComponent("stdin")
                        try Data((input ?? "").utf8).write(to: inputURL, options: [.atomic])
                        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)
                        let stdin = try FileHandle(forReadingFrom: inputURL)
                        child.standardInput = stdin
                        defer { try? stdin.close() }

                        lock.lock()
                        if wasCancelled {
                            lock.unlock()
                            throw CancellationError()
                        }
                        process = child
                        do {
                            // Keep cancellation from observing the not-yet-started process.
                            try child.run()
                            lock.unlock()
                        } catch {
                            process = nil
                            lock.unlock()
                            throw error
                        }
                        let timeoutWork = DispatchWorkItem { [weak self, weak child] in
                            guard let self else { return }
                            self.lock.lock()
                            let active = self.process === child
                            if active { self.didTimeOut = true }
                            self.lock.unlock()
                            if active { Self.stop(child) }
                        }
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
                        child.waitUntilExit()
                        timeoutWork.cancel()
                        lock.lock()
                        process = nil
                        let cancelled = wasCancelled
                        let timedOut = didTimeOut
                        lock.unlock()
                        if cancelled { throw CancellationError() }
                        if timedOut { throw ReaderAIError.timedOut }
                        let result = ReaderCLIResult(exitCode: child.terminationStatus,
                            stdout: Self.readTail(stdoutURL), stderr: Self.readTail(stderrURL))
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { [self] in cancel() })
    }

    private static func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak process] in
            guard let process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func readTail(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65536 ? size - 65536 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func environment(executable: URL) -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        // Do not inherit API keys or the desktop app's internal IPC environment.
        let allowed = ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "CODEX_HOME",
                       "XDG_CONFIG_HOME", "CODEX_CA_CERTIFICATE", "SSL_CERT_FILE", "SSL_CERT_DIR",
                       "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                       "http_proxy", "https_proxy", "all_proxy", "no_proxy"]
        var environment = source.filter { allowed.contains($0.key) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["HOME"] = home
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" +
            (source["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin"
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        return environment
    }
}

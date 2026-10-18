import Combine
import Foundation

enum PracticeRunnerError: LocalizedError {
    case busy, unavailable, daemonUnavailable, preparation(String), codeTooLarge, notExecutable
    var errorDescription: String? {
        switch self {
        case .busy: return "Дождитесь запуска или нажмите «Остановить»."
        case .unavailable: return "Для изолированной практики нужен Docker Desktop. Установите и запустите его, затем нажмите «Проверить»."
        case .daemonUnavailable: return "Запустите Docker Desktop и нажмите «Проверить». Код на самом ноутбуке не выполняется."
        case .preparation(let detail): return "Не удалось подготовить среду. " + detail
        case .codeTooLarge: return "Решение слишком большое: максимум 512 КБ."
        case .notExecutable: return "Для ответа словами запуск кода не нужен. Используйте проверку ИИ."
        }
    }
}

/// Every execution receives a new, disposable container. No host files, Docker
/// socket, ports, network, or existing containers are exposed to the exercise.
@MainActor
final class PracticeRunner: ObservableObject {
    @Published var isRunning = false
    @Published var status = "Проверяем среду…"
    @Published var isReady = false

    private var job: PracticeDockerJob?
    private var checking = false
    private var cancelled = false

    func refresh() async {
        guard !isRunning, !checking else { return }
        checking = true
        defer { checking = false }
        guard let docker = Self.findDocker() else {
            isReady = false
            status = PracticeRunnerError.unavailable.localizedDescription
            return
        }
        do {
            let result = try await PracticeDockerJob(docker: docker).run(
                arguments: ["info", "--format", "{{.ServerVersion}}"], timeout: 8)
            isReady = result.exitCode == 0 && !result.timedOut
            status = isReady ? "Изолированная среда готова" : PracticeRunnerError.daemonUnavailable.localizedDescription
        } catch {
            isReady = false
            status = PracticeRunnerError.daemonUnavailable.localizedDescription
        }
    }

    func prepare(language: PracticeLanguage) async throws {
        guard !isRunning else { throw PracticeRunnerError.busy }
        guard language.isExecutable else { return }
        guard let docker = Self.findDocker() else {
            isReady = false
            status = PracticeRunnerError.unavailable.localizedDescription
            throw PracticeRunnerError.unavailable
        }
        isRunning = true
        cancelled = false
        defer { isRunning = false; job = nil }
        do {
            _ = try await prepareImage(language: language, docker: docker)
            isReady = true
            status = "Среда \(language.title) готова"
        } catch {
            status = error is CancellationError ? "Подготовка остановлена" : error.localizedDescription
            throw error
        }
    }

    func run(code: String, language: PracticeLanguage) async throws -> PracticeRunResult {
        guard !isRunning else { throw PracticeRunnerError.busy }
        guard language.isExecutable else { throw PracticeRunnerError.notExecutable }
        guard code.utf8.count <= 512 * 1024 else { throw PracticeRunnerError.codeTooLarge }
        guard let docker = Self.findDocker() else { throw PracticeRunnerError.unavailable }
        try Task.checkCancellation()
        isRunning = true
        cancelled = false
        defer { isRunning = false; job = nil }
        do {
            let image = try await prepareImage(language: language, docker: docker)
            try checkCancellation()
            let name = "list-practice-" + UUID().uuidString.lowercased()
            let execution = PracticeDockerJob(docker: docker, containerName: name)
            job = execution
            status = "Выполняю в изолированной среде…"
            var arguments = ["run", "--rm", "--pull", "never", "--name", name,
                "--network", "none", "--read-only", "--cap-drop", "ALL",
                "--security-opt", "no-new-privileges", "--user", "65534:65534",
                "--memory", "256m", "--memory-swap", "256m", "--cpus", "1",
                "--pids-limit", "32", "--log-driver", "none", "--init",
                "--ulimit", "core=0", "--ulimit", "nofile=64:64",
                "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777",
                "--tmpfs", "/work:rw,noexec,nosuid,nodev,size=16m,mode=1777",
                "--workdir", "/work", "--env", "HOME=/tmp", "-i", image]
            let input: String
            switch language {
            case .python:
                arguments += ["python3", "-I", "-B", "-u", "-"]
                input = code
            case .javascript:
                arguments += ["node", "--max-old-space-size=128", "--input-type=commonjs", "-"]
                input = code
            case .sql:
                arguments += ["python3", "-I", "-B", "-u", "-c", Self.sqliteRunner]
                input = code
            case .reasoning: throw PracticeRunnerError.notExecutable
            }
            let result = try await execution.run(arguments: arguments, input: input, timeout: 10)
            try checkCancellation()
            var output = result.stdout
            if !result.stderr.isEmpty {
                if !output.isEmpty { output += "\n" }
                output += result.stderr
            }
            if result.truncated { output += "\n[Вывод сокращён: лимит 128 КБ.]" }
            if result.timedOut { output += "\n[Запуск остановлен: лимит 10 секунд.]" }
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output = "Программа завершилась без вывода." }
            status = result.timedOut ? "Лимит времени. Контейнер удалён." : "Выполнено. Контейнер удалён."
            return PracticeRunResult(output: output, exitCode: result.exitCode, timedOut: result.timedOut)
        } catch {
            status = error is CancellationError ? "Остановлено. Контейнер удалён." : error.localizedDescription
            throw error
        }
    }

    func cancel() { cancelled = true; job?.cancel() }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func prepareImage(language: PracticeLanguage, docker: URL) async throws -> String {
        let tag = language == .javascript ? "docker.io/library/node:22-alpine" : "docker.io/library/python:3.12-alpine"
        // A local image ID prevents a tag changing between inspection and execution.
        let inspect = PracticeDockerJob(docker: docker)
        job = inspect
        var result = try await inspect.run(arguments: ["image", "inspect", "--format", "{{.Id}}", tag], timeout: 8)
        try checkCancellation()
        if result.exitCode != 0 || result.timedOut {
            let info = PracticeDockerJob(docker: docker)
            job = info
            let availability = try await info.run(arguments: ["info", "--format", "{{.ServerVersion}}"], timeout: 8)
            try checkCancellation()
            guard availability.exitCode == 0, !availability.timedOut else {
                isReady = false
                throw PracticeRunnerError.daemonUnavailable
            }
            isReady = true
            status = "Первый запуск: загружаю \(language == .javascript ? "Node.js" : "Python / SQLite")…"
            let pull = PracticeDockerJob(docker: docker)
            job = pull
            let pulled = try await pull.run(arguments: ["pull", tag], timeout: 240, progress: { [weak self] line in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning, self.job === pull else { return }
                    self.status = "Загрузка среды: " + String(line.suffix(150))
                }
            })
            try checkCancellation()
            guard pulled.exitCode == 0, !pulled.timedOut else {
                throw PracticeRunnerError.preparation(pulled.timedOut ? "Загрузка заняла слишком много времени." : String(pulled.stderr.suffix(1000)))
            }
            let verification = PracticeDockerJob(docker: docker)
            job = verification
            result = try await verification.run(arguments: ["image", "inspect", "--format", "{{.Id}}", tag], timeout: 8)
        }
        try checkCancellation()
        let id = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !result.timedOut,
              id.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw PracticeRunnerError.preparation("Не удалось проверить образ Docker.")
        }
        isReady = true
        return id
    }

    private static func findDocker() -> URL? {
        let paths = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                     "/Applications/Docker.app/Contents/Resources/bin/docker"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/docker" }
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    // complete_statement handles triggers, comments and semicolons in strings.
    // Each run starts with a fresh in-memory database; all changes disappear.
    private static let sqliteRunner = """
    import sqlite3, sys, json
    db = sqlite3.connect(':memory:')
    source = sys.stdin.read()
    statements, pending = [], ''
    for ch in source:
        pending += ch
        if ch == ';' and sqlite3.complete_statement(pending):
            statements.append(pending)
            pending = ''
    if pending.strip():
        statements.append(pending)
    try:
        for statement in statements:
            cursor = db.execute(statement)
            if cursor.description:
                print(' | '.join(column[0] for column in cursor.description))
                count = 0
                for row in cursor:
                    print(' | '.join('NULL' if value is None else str(value) for value in row))
                    count += 1
                print('Строк: ' + str(count))
            elif cursor.rowcount >= 0:
                print('Изменено строк: ' + str(cursor.rowcount))
        db.commit()
        if not statements:
            print('Введите SQL-запрос.')
    except sqlite3.Error as error:
        print('SQLite: ' + str(error), file=sys.stderr)
        sys.exit(1)
    finally:
        db.close()
    """
}

private struct PracticeDockerResult {
    var stdout: String
    var stderr: String
    var exitCode: Int32
    var timedOut: Bool
    var truncated: Bool
}

/// Pipes are always drained, but only 64 KiB per stream is retained. In
/// particular, exercise output never grows a host-side log or temporary file.
private final class PracticeBoundedStream: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var data = Data()
    private var dropped = false
    private var lastProgress = Date.distantPast
    private let progress: ((String) -> Void)?
    private let done = DispatchGroup()

    init(progress: ((String) -> Void)?) { self.progress = progress }

    func start() {
        done.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { done.leave() }
            while true {
                let chunk: Data
                do { chunk = try pipe.fileHandleForReading.read(upToCount: 8192) ?? Data() }
                catch { break }
                if chunk.isEmpty { break }
                lock.lock()
                let remaining = max(0, 65536 - data.count)
                data.append(chunk.prefix(remaining))
                if chunk.count > remaining { dropped = true }
                let shouldReport = Date().timeIntervalSince(lastProgress) > 0.3
                if shouldReport { lastProgress = Date() }
                lock.unlock()
                if shouldReport, let progress {
                    let line = String(decoding: chunk, as: UTF8.self)
                        .split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last.map(String.init) ?? ""
                    if !line.isEmpty { progress(line) }
                }
            }
            try? pipe.fileHandleForReading.close()
        }
    }

    func finish() -> (String, Bool) {
        try? pipe.fileHandleForWriting.close()
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: data, as: UTF8.self), dropped)
    }
}

private final class PracticeDockerJob: @unchecked Sendable {
    private let docker: URL
    private let containerName: String?
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    init(docker: URL, containerName: String? = nil) {
        self.docker = docker
        self.containerName = containerName
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let child = process
        lock.unlock()
        Self.stop(child)
        // Cleanup also runs after the client exits, covering cancellation during
        // container creation. The generated name belongs only to this job.
        if child != nil { DispatchQueue.global(qos: .utility).async { self.removeOwnedContainer() } }
    }

    func run(arguments: [String], input: String = "", timeout: TimeInterval,
             progress: ((String) -> Void)? = nil) async throws -> PracticeDockerResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    let manager = FileManager.default
                    let directory = manager.temporaryDirectory.appendingPathComponent("List-Practice-" + UUID().uuidString)
                    let stdout = PracticeBoundedStream(progress: progress)
                    let stderr = PracticeBoundedStream(progress: progress)
                    var didStartStreams = false
                    do {
                        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        defer { try? manager.removeItem(at: directory) }
                        let inputURL = directory.appendingPathComponent("stdin")
                        manager.createFile(atPath: inputURL.path, contents: Data(input.utf8), attributes: [.posixPermissions: 0o600])
                        let stdin = try FileHandle(forReadingFrom: inputURL)
                        defer { try? stdin.close() }
                        let child = Process()
                        child.executableURL = docker
                        child.arguments = arguments
                        child.environment = Self.environment()
                        child.currentDirectoryURL = directory
                        child.standardInput = stdin
                        child.standardOutput = stdout.pipe
                        child.standardError = stderr.pipe
                        lock.lock()
                        if cancelled { lock.unlock(); throw CancellationError() }
                        process = child
                        do {
                            try child.run()
                            lock.unlock()
                        } catch {
                            process = nil
                            lock.unlock()
                            throw error
                        }
                        stdout.start(); stderr.start(); didStartStreams = true
                        let deadline = DispatchWorkItem { [weak self, weak child] in
                            guard let self else { return }
                            self.lock.lock()
                            let active = self.process === child
                            if active { self.timedOut = true }
                            self.lock.unlock()
                            if active {
                                Self.stop(child)
                                self.removeOwnedContainer()
                            }
                        }
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
                        child.waitUntilExit()
                        deadline.cancel()
                        // Never rely on termination of the Docker client to imply
                        // termination of its container.
                        removeOwnedContainer()
                        let capturedOut = stdout.finish()
                        let capturedError = stderr.finish()
                        lock.lock()
                        process = nil
                        let wasCancelled = cancelled
                        let didTimeOut = timedOut
                        lock.unlock()
                        if wasCancelled { throw CancellationError() }
                        continuation.resume(returning: PracticeDockerResult(stdout: capturedOut.0,
                            stderr: capturedError.0, exitCode: child.terminationStatus,
                            timedOut: didTimeOut, truncated: capturedOut.1 || capturedError.1))
                    } catch {
                        if !didStartStreams {
                            try? stdout.pipe.fileHandleForReading.close()
                            try? stdout.pipe.fileHandleForWriting.close()
                            try? stderr.pipe.fileHandleForReading.close()
                            try? stderr.pipe.fileHandleForWriting.close()
                        }
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { [self] in cancel() })
    }

    private func removeOwnedContainer() {
        guard let containerName else { return }
        let removal = Process()
        removal.executableURL = docker
        removal.arguments = ["rm", "-f", containerName]
        removal.environment = Self.environment()
        removal.standardInput = FileHandle.nullDevice
        removal.standardOutput = FileHandle.nullDevice
        removal.standardError = FileHandle.nullDevice
        do {
            try removal.run()
            let deadline = DispatchWorkItem { Self.stop(removal) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: deadline)
            removal.waitUntilExit()
            deadline.cancel()
        } catch { /* The daemon may already have removed this --rm container. */ }
    }

    private static func stop(_ child: Process?) {
        guard let child, child.isRunning else { return }
        child.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak child] in
            if let child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    private static func environment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let allowed = ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "DOCKER_HOST",
                       "DOCKER_CONTEXT", "DOCKER_CONFIG", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"]
        var environment = source.filter { allowed.contains($0.key) }
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (source["PATH"] ?? "")
        environment["TERM"] = "dumb"
        return environment
    }
}

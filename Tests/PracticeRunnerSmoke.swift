import Foundation
#if TEST_MODULE
@testable import ListReaderCore
#endif

@main
struct PracticeRunnerSmoke {
    @MainActor
    static func main() async throws {
        let runner = PracticeRunner()
        await runner.refresh()
        precondition(runner.isReady, runner.status)
        print("Docker: ready")
        try await runner.prepare(language: .python)
        print("Python image: ready")
        try await runner.prepare(language: .javascript)
        print("Node image: ready")

        let python = try await runner.run(code: "print(6 * 7)", language: .python)
        precondition(python.exitCode == 0 && python.output.contains("42"), python.output)
        print("Python: pass")
        let javascript = try await runner.run(code: "console.log(6 * 7)", language: .javascript)
        precondition(javascript.exitCode == 0 && javascript.output.contains("42"), javascript.output)
        print("JavaScript: pass")
        let sql = try await runner.run(code: "CREATE TABLE events (id INTEGER, label TEXT); INSERT INTO events VALUES (1, 'one;two'); SELECT id, label FROM events;", language: .sql)
        precondition(sql.exitCode == 0 && sql.output.contains("1 | one;two"), sql.output)
        print("SQLite statements: pass")
        let sqlReset = try await runner.run(code: "SELECT * FROM events;", language: .sql)
        precondition(sqlReset.exitCode != 0 && sqlReset.output.contains("no such table"), sqlReset.output)
        print("Fresh database per execution: pass")

        let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent("List-Host-Sentinel-" + UUID().uuidString)
        try Data("host secret".utf8).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        let escapedPath = String(decoding: try JSONEncoder().encode(sentinel.path), as: UTF8.self)
        let isolation = try await runner.run(code: """
        import os, socket
        assert os.getuid() == 65534
        assert not os.path.exists(\(escapedPath))
        assert not os.path.exists('/var/run/docker.sock')
        try:
            open('/host-write-test', 'w').write('bad')
            raise AssertionError('root was writable')
        except OSError:
            pass
        open('/work/local.txt', 'w').write('temporary')
        s = socket.socket()
        s.settimeout(1)
        try:
            s.connect(('1.1.1.1', 53))
            raise AssertionError('network was available')
        except OSError:
            pass
        print('isolation passed')
        """, language: .python)
        precondition(isolation.exitCode == 0 && isolation.output.contains("isolation passed"), isolation.output)
        print("No host files/socket, read-only root, non-root user, disabled network: pass")
        let clean = try await runner.run(code: "import os; assert not os.path.exists('/work/local.txt'); print('clean')", language: .python)
        precondition(clean.exitCode == 0 && clean.output.contains("clean"), clean.output)
        print("Fresh filesystem per execution: pass")

        let flood = try await runner.run(code: "import sys; sys.stdout.write('x' * 1000000)", language: .python)
        precondition(flood.exitCode == 0 && flood.output.utf8.count < 140000 && flood.output.contains("Вывод сокращён"), "Output capture was unbounded")
        print("Output flood bounded: pass")

        let start = Date()
        let timeout = try await runner.run(code: "while True: pass", language: .python)
        precondition(timeout.timedOut && Date().timeIntervalSince(start) < 18, timeout.output)
        print("10-second time limit: pass")

        let cancellation = Task { @MainActor in try await runner.run(code: "while True: pass", language: .python) }
        try await Task.sleep(nanoseconds: 800_000_000)
        runner.cancel()
        do {
            _ = try await cancellation.value
            preconditionFailure("Cancellation unexpectedly returned success")
        } catch is CancellationError {
            precondition(!runner.isRunning)
        }
        print("Explicit cancellation: pass")
        let recovery = try await runner.run(code: "print('recovered')", language: .python)
        precondition(recovery.exitCode == 0 && recovery.output.contains("recovered"), recovery.output)
        print("Run after cancellation: pass")
        print("ALL RUNTIME TESTS PASSED")
    }
}

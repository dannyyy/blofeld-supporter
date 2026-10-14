import Foundation

/// Runs an external CLI (`pup`, `az`) off the main thread with a watchdog
/// timeout. Shared by `PupClient` and `AzureCLIClient` — the app's only
/// subprocesses.
enum CLIRunner {
    struct Result { let code: Int32; let stdout: Data; let stderr: String }

    enum Failure: Error {
        /// The process could not be launched at all.
        case launch(String)
        /// The watchdog terminated a hung process.
        case timedOut
    }

    static func run(path: String, args: [String], environment: [String: String],
                    timeout: TimeInterval) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                process.environment = environment

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure.launch(error.localizedDescription))
                    return
                }

                // Watchdog: terminate a hung process so a slow call can't wedge
                // polling. `didTimeout` is read on this worker thread and written
                // on the watchdog thread, so it's guarded by a serial queue.
                let flagQ = DispatchQueue(label: "com.danflash.blofeld.cli.timeout")
                var didTimeout = false
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        flagQ.sync { didTimeout = true }
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Both CLIs keep stderr tiny (a notice or a short error), so a
                // sequential drain after the large stdout won't fill its 64K pipe.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                if flagQ.sync(execute: { didTimeout }) {
                    continuation.resume(throwing: Failure.timedOut)
                    return
                }
                let errString = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: Result(code: process.terminationStatus, stdout: outData, stderr: errString))
            }
        }
    }
}

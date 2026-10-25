import Foundation

public enum ValidationStatus: Sendable, Equatable {
    /// EPUBCheckが正常実行され、ERROR/FATALがゼロ
    case passed
    /// EPUBCheckが正常実行され、ERROR/FATALが1件以上
    case failed
    /// 起動失敗・タイムアウト・JSON不正・異常終了など。**合格として扱ってはならない** (PM-CHECK-002)
    case unavailable(reason: String)
}

public struct ValidationMessage: Sendable, Equatable {
    public let id: String
    public let severity: Severity
    public let message: String
    public let path: String?
    public let line: Int?
}

public struct ValidationReport: Sendable {
    public let toolVersion: String?
    public let checkedAt: Date
    public let status: ValidationStatus
    public let errorCount: Int      // ERROR + FATAL
    public let warningCount: Int
    public let messages: [ValidationMessage]
    public let rawJSON: Data?

    static func unavailable(_ reason: String, raw: Data? = nil) -> ValidationReport {
        ValidationReport(
            toolVersion: nil, checkedAt: Date(), status: .unavailable(reason: reason),
            errorCount: 0, warningCount: 0, messages: [], rawJSON: raw)
    }
}

public protocol EPUBValidating: Sendable {
    /// 失敗は例外ではなく `.unavailable` で返す。呼び出し側が誤って成功扱いにできないようにするため。
    func validate(epubURL: URL) async -> ValidationReport
}

/// 同梱JRE + EPUBCheck JARを `Process` で起動する (設計書 §10.3)。
/// シェルを介さず、絶対パス + 引数配列のみ。標準出力/標準エラーはファイルに受けてパイプ詰まりを避ける。
public struct ProcessEPUBCheckRunner: EPUBValidating {
    public let executableURL: URL
    public let leadingArguments: [String]   // 例: ["-jar", "<epubcheck.jar>"]
    public let workDirectory: URL
    public let timeout: TimeInterval

    public init(executableURL: URL, leadingArguments: [String], workDirectory: URL, timeout: TimeInterval = 300) {
        self.executableURL = executableURL
        self.leadingArguments = leadingArguments
        self.workDirectory = workDirectory
        self.timeout = timeout
    }

    /// `--version` の標準出力(+標準エラー)を返す。取得できなければnil。
    public func queryVersion() async -> String? {
        let outcome = await run(arguments: leadingArguments + ["--version"], tag: "version")
        guard outcome.launched, !outcome.timedOut, outcome.exitCode == 0 else { return nil }
        let text = (outcome.stdout + "\n" + outcome.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public func validate(epubURL: URL) async -> ValidationReport {
        let reportURL = workDirectory.appendingPathComponent("validation-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: reportURL) }

        let outcome = await run(
            arguments: leadingArguments + ["--json", reportURL.path, epubURL.path], tag: "validate")
        if Task.isCancelled { return .unavailable("検証がキャンセルされました") }
        guard outcome.launched else { return .unavailable("検証器を起動できません: \(outcome.launchError ?? "unknown")") }
        if outcome.timedOut { return .unavailable("検証がタイムアウトしました (\(Int(timeout))秒)") }

        // EPUBCheckの終了コード: 0=ERROR/FATALなし, 1=ERROR/FATALあり。それ以外は異常終了。
        guard outcome.exitCode == 0 || outcome.exitCode == 1 else {
            return .unavailable("検証器が異常終了しました (exit \(outcome.exitCode))")
        }
        guard let raw = try? Data(contentsOf: reportURL) else {
            return .unavailable("検証レポートが出力されませんでした (exit \(outcome.exitCode))")
        }
        return EPUBCheckReportParser.parse(json: raw, exitCode: outcome.exitCode)
    }

    // MARK: Process

    private struct Outcome {
        var launched = false
        var launchError: String?
        var timedOut = false
        var exitCode: Int32 = -1
        var stdout = ""
        var stderr = ""
    }

    private final class Controller: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var cancelled = false
        private(set) var timedOut = false

        func start() throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            if cancelled { return false }
            try process.run()
            return true
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if process.isRunning { process.terminate() }
        }
        func timeout() {
            lock.lock(); defer { lock.unlock() }
            guard process.isRunning else { return }
            timedOut = true
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(pid, SIGKILL) }
        }
    }

    private func run(arguments: [String], tag: String) async -> Outcome {
        var outcome = Outcome()
        let outURL = workDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString).out")
        let errURL = workDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString).err")
        let fm = FileManager.default
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL)
        else {
            outcome.launchError = "作業ディレクトリに書き込めません"
            return outcome
        }
        defer { try? outHandle.close(); try? errHandle.close() }

        let c = Controller()
        c.process.executableURL = executableURL
        c.process.arguments = arguments
        c.process.currentDirectoryURL = workDirectory
        c.process.standardOutput = outHandle
        c.process.standardError = errHandle
        c.process.standardInput = FileHandle.nullDevice
        c.process.environment = ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]

        let timeoutSeconds = timeout
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                c.process.terminationHandler = { _ in cont.resume() }
                do {
                    guard try c.start() else {   // 起動前にキャンセルされた
                        c.process.terminationHandler = nil
                        cont.resume()
                        return
                    }
                    outcome.launched = true
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { c.timeout() }
                } catch {
                    c.process.terminationHandler = nil
                    outcome.launchError = error.localizedDescription
                    cont.resume()
                }
            }
        } onCancel: {
            c.cancel()
        }

        if outcome.launched {
            outcome.exitCode = c.process.terminationStatus
            outcome.timedOut = c.timedOut
        }
        outcome.stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        outcome.stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return outcome
    }
}

/// EPUBCheck `--json` の解析。
///
/// 注意: 実バージョンの出力で型を確定する前の暫定実装 (設計書 §10.3)。想定スキーマは
/// `checker.{checkerVersion,nError,nFatal,nWarning}` と `messages[].{ID,severity,message,locations[].{path,line}}`。
/// 想定外の形・件数と終了コードの矛盾は `.unavailable` に倒し、偽の合格を出さない。
public enum EPUBCheckReportParser {
    public static func parse(json raw: Data, exitCode: Int32) -> ValidationReport {
        guard let root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let rawMessages = root["messages"] as? [[String: Any]]
        else { return .unavailable("検証レポートのJSONを解釈できません", raw: raw) }

        let checker = root["checker"] as? [String: Any]
        let version = checker?["checkerVersion"] as? String

        var messages: [ValidationMessage] = []
        for m in rawMessages {
            guard let sevRaw = (m["severity"] as? String)?.uppercased() else {
                return .unavailable("severity のないメッセージがあります", raw: raw)
            }
            let severity: Severity
            switch sevRaw {
            case "FATAL": severity = .fatal
            case "ERROR": severity = .error
            case "WARNING": severity = .warning
            case "INFO", "USAGE", "SUPPRESSED": severity = .info
            default: severity = .error   // 未知の重大度は安全側(エラー)に倒す
            }
            let loc = (m["locations"] as? [[String: Any]])?.first
            messages.append(ValidationMessage(
                id: (m["ID"] as? String) ?? "UNKNOWN",
                severity: severity,
                message: (m["message"] as? String) ?? "",
                path: loc?["path"] as? String,
                line: (loc?["line"] as? Int).flatMap { $0 > 0 ? $0 : nil }))
        }

        let errors = messages.filter { $0.severity == .error || $0.severity == .fatal }.count
        let warnings = messages.filter { $0.severity == .warning }.count

        // checker の集計値がある場合は messages と突き合わせる。食い違えば信用しない。
        if let c = checker, let nE = c["nError"] as? Int, let nF = c["nFatal"] as? Int, nE + nF != errors {
            return .unavailable("検証レポートの集計とメッセージ件数が一致しません", raw: raw)
        }

        let status: ValidationStatus
        switch (exitCode, errors) {
        case (0, 0): status = .passed
        case (1, let n) where n > 0: status = .failed
        default: status = .unavailable(reason: "終了コード(\(exitCode))とエラー件数(\(errors))が矛盾しています")
        }
        return ValidationReport(
            toolVersion: version, checkedAt: Date(), status: status,
            errorCount: errors, warningCount: warnings, messages: messages, rawJSON: raw)
    }
}

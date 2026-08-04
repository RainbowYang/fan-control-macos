import Foundation

/// 封装 `smctl` CLI 的所有调用。单例，供 SwiftUI 各视图使用。
final class FanService: ObservableObject {

    // MARK: - 二进制定位

    /// 解析 smctl 可执行文件路径。优先级：
    /// 1. 系统路径（Homebrew：/opt/homebrew/bin 或 /usr/local/bin）
    /// 2. 与 app 捆绑（Contents/MacOS/smctl，发布时随 bundle）
    /// 3. 项目 vendor 目录（开发期 ./vendor/smctl/smctl）
    /// 找不到返回 nil。
    static func resolveExecutable() -> String? {
        let bundledName = "smctl"
        let fileManager = FileManager.default
        let homebrew = ["/opt/homebrew/bin/smctl", "/usr/local/bin/smctl"]
        for path in homebrew where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        let bundleExecDir = Bundle.main.bundleURL
            .appendingPathComponent("Contents").appendingPathComponent("MacOS").path
        let bundled = bundleExecDir + "/" + bundledName
        if fileManager.isExecutableFile(atPath: bundled) {
            return bundled
        }
        // 开发期：以源码目录为锚点定位项目 vendor
        let devVendor = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Core/
            .deletingLastPathComponent()      // FanControl/
            .deletingLastPathComponent()      // 项目根
            .appendingPathComponent("vendor/smctl/smctl").path
        return fileManager.isExecutableFile(atPath: devVendor) ? devVendor : nil
    }

    /// 已解析的可执行路径（nil = 未就绪）
    static let installedPath: String? = resolveExecutable()

    // MARK: - 状态

    @Published private(set) var snapshot: SensorSnapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var isInstalled: Bool = installedPath != nil
    @Published private(set) var daemonRunning: Bool = false

    private var fetchTask: Task<Void, Never>?

    // MARK: - 读取（无需 root）

    func refreshSensors() async {
        guard let bin = Self.installedPath else {
            await MainActor.run { isInstalled = false }
            return
        }
        do {
            let json = try await execSync(path: bin, args: ["sensors", "--json"])
            guard let data = json.data(using: .utf8) else {
                throw FanServiceError.exitCode(-1, "无法将 smctl 输出编码为 UTF-8")
            }
            let snap = try SensorSnapshot.parse(data)
            await MainActor.run {
                snapshot = snap
                lastError = nil
            }
        } catch {
            await MainActor.run { lastError = error.localizedDescription }
        }
    }

    /// 检查 smctld daemon 是否运行。
    /// 用 `daemon ping` 探活：成功返回 `smctld ok …`（退出码 0），比解析
    /// `daemon status` 的文本可靠（status 输出不含 running/enabled 字样）。
    func checkDaemon() async -> Bool {
        guard let bin = Self.installedPath else { return false }
        do {
            _ = try await execSync(path: bin, args: ["daemon", "ping"])
            await MainActor.run { daemonRunning = true }
            return true
        } catch {
            await MainActor.run { daemonRunning = false }
            return false
        }
    }

    func startPolling(interval: TimeInterval = 1.5) {
        fetchTask?.cancel()
        fetchTask = Task(priority: .background) {
            while !Task.isCancelled {
                await refreshSensors()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        fetchTask?.cancel()
        fetchTask = nil
    }

    // MARK: - 写入（需 daemon；admin 用户经 XPC 即可，无需每次 sudo）

    /// 解析可执行路径，缺失时抛 `notInstalled`。
    private func resolvedBin() throws -> String {
        guard let bin = Self.installedPath else { throw FanServiceError.notInstalled }
        return bin
    }

    func setFanSpeed(_ rpm: Int, fan: Int? = nil) async throws {
        let bin = try resolvedBin()
        var args = ["fan", "set", "\(rpm)"]
        if let fan { args += ["--fan", "\(fan)"] }
        _ = try await execSync(path: bin, args: args)
    }

    func setProfile(_ profile: String) async throws {
        let bin = try resolvedBin()
        _ = try await execSync(path: bin, args: ["fan", "profile", profile])
    }

    /// 交还系统控制。必须用 `fan profile auto`（而非 `fan auto`）：
    /// 实测 `fan auto` 只复位 target 不切回 system mode（profile 停在 manual），
    /// `fan profile auto` 才会正确交还系统控制。
    func revertToAuto() async throws {
        let bin = try resolvedBin()
        _ = try await execSync(path: bin, args: ["fan", "profile", "auto"])
    }

    // MARK: - 安装

    /// 安装 smctld。以管理员权限弹一次性密码框执行 `smctl daemon install`，返回是否成功。
    func installDaemon() async throws -> Bool {
        let bin = try resolvedBin()
        let success = try await promptAdmin("\(bin) daemon install")
        await MainActor.run { daemonRunning = success }
        return success
    }

    // MARK: - AppleScript 管理员授权

    /// 通过 osascript 以管理员权限执行一条命令（弹一次性系统密码框）。
    private func promptAdmin(_ command: String) async throws -> Bool {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let result = try await execAsync(path: "/usr/bin/osascript", args: ["-e", script])
        return result.terminatedCleanly
    }

    // MARK: - 底层执行

    enum FanServiceError: LocalizedError {
        case notInstalled
        case exitCode(Int32, String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "smctl 未就绪。请在 /Applications 拖入后运行，或在项目 vendor/smctl 下放置 smctl 二进制。"
            case .exitCode(let code, let stderr):
                return "smctl 退出码 \(code): \(stderr)"
            }
        }
    }

    struct ExecResult {
        let stdout: String
        let stderr: String
        let terminatedCleanly: Bool

        var stdoutLines: [String] {
            stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
    }

    /// 同步执行并等待（用于高频传感器轮询，数据量小）。
    private func execSync(path: String, args: [String]) async throws -> String {
        let result = try await execAsync(path: path, args: args)
        guard result.terminatedCleanly else {
            let msg = result.stderr.isEmpty ? result.stdout : result.stderr
            throw FanServiceError.exitCode(-1, msg)
        }
        return result.stdout
    }

    /// 在后台线程同步执行，返回完整结果。异步包装避免阻塞主线程。
    private func execAsync(path: String, args: [String]) async throws -> ExecResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = Pipe()   // 关闭以避免阻塞
            try process.run()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return ExecResult(
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "",
                terminatedCleanly: process.terminationStatus == 0
            )
        }.value
    }
}

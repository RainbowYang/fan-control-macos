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

    // MARK: - 目标温度闭环控制

    /// 当前生效的目标温度（nil = 未启用，系统自动控制）
    @Published private(set) var currentTargetTemp: Int?

    /// 设定目标温度：把「目标温度→风扇」曲线写入 config.toml 并激活。
    /// daemon 会按该温度每秒自动调速，把温度压回设定值（系统级持续，app 退出也生效）。
    func applyTargetTemp(_ t: Int) async throws {
        let bin = try resolvedBin()
        let curveName = "target-\(t)"

        // 1. 生成完整新 config：基于现有 config，剔除旧的 target-* 曲线，复用其它段
        let existing = await promptAdminOutput("cat /etc/smctl/config.toml") ?? ""
        let newConfig = ConfigBuilder.builtConfig(existing: existing,
                                                  curveName: curveName,
                                                  points: targetCurvePoints(target: t))

        // 2. 写临时文件（用户可写）
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smctl-config-\(UUID().uuidString).toml")
        try newConfig.write(to: tempURL, atomically: true, encoding: .utf8)

        // 3. 用 admin 权限：确保目录 → 覆盖写 config → 重启 daemon 重载
        _ = try await promptAdmin("mkdir -p /etc/smctl")
        _ = try await promptAdmin("cp \"\(tempURL.path)\" /etc/smctl/config.toml")
        try? FileManager.default.removeItem(at: tempURL)
        _ = try await promptAdmin("\(bin) daemon restart")

        // 4. 激活曲线（该命令落盘 + 立即生效）
        _ = try await promptAdmin("\(bin) fan profile \(curveName)")

        await MainActor.run { currentTargetTemp = t }
    }

    /// 交还系统自动控制。
    func revertTargetTemp() async throws {
        let bin = try resolvedBin()
        _ = try await promptAdmin("\(bin) fan profile auto")
        await MainActor.run { currentTargetTemp = nil }
    }

    /// 生成「目标温度→风扇」曲线的 points。
    /// 在目标温度附近用陡段提前干预，确保压住温升；最高点压向护栏(108°C)前。
    private func targetCurvePoints(target: Int) -> String {
        // 注意 TOML 数字必须浮点格式（smctl issue #9：整数会解析失败）
        // 温度升到 target 偏下就开始拉转速，target 附近陡升，超过 target 逼近 max
        let lo = target - 10
        let mid = target - 3
        let upper = min(target + 8, 105)
        return "[[50, 1200.0], [\(lo), 1500.0], [\(mid), 3200.0], [\(target), 4300.0], [\(upper), 5400.0], [108, \"max\"]]"
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

    /// promptAdmin 的变体：额外捕获 stdout（如 `cat` 命令的结果）。失败返回 nil。
    private func promptAdminOutput(_ command: String) async -> String? {
        do {
            let escaped = command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = "do shell script \"\(escaped)\" with administrator privileges"
            let result = try await execAsync(path: "/usr/bin/osascript", args: ["-e", script])
            return result.terminatedCleanly ? result.stdout : nil
        } catch {
            return nil
        }
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

/// 重建 /etc/smctl/config.toml：在保持其它配置段不变的前提下，
/// 移除旧的 target-* 曲线并写入新曲线。用逐行/顶层段解析，避免复杂正则出错。
enum ConfigBuilder {
    /// 本机 CPU 热点 key（实测），作曲线输入。daemon 取这组里的最高温度。
    private static let sensorKeys = ["Tp0E", "Tp02", "Tp06", "Tp0M"]

    static func builtConfig(existing: String, curveName: String, points: String) -> String {
        // 1. 按顶层 section 切块：[fan]、[[fan.curves]、[safety] 由我们重建，其余原样保留
        var keepLines: [String] = []
        var inFan = false
        var inCurveOrSafety = false

        let lines = existing.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[[fan.curves]]") {
                inCurveOrSafety = true
                continue                       // 跳过所有旧曲线
            } else if trimmed.hasPrefix("[fan]") {
                inFan = true
                inCurveOrSafety = false
                continue                       // [fan] 段整体重建，跳过
            } else if trimmed.hasPrefix("[safety]") {
                inCurveOrSafety = true
                continue                       // safety 段我们也重建，跳过旧的
            } else if trimmed.hasPrefix("[") {
                // 其它顶层段（battery / update / sentry ...）正常保留
                inFan = false
                inCurveOrSafety = false
                keepLines.append(line)
                continue
            }
            // 在 fan/curve/safety 块内的行全部丢弃（整段重建）
            if inFan || inCurveOrSafety { continue }
            keepLines.append(line)
        }

        let existingConfig = keepLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. 组装新 config
        let curve = """
        [fan]
        profile = "auto"

        [[fan.curves]]
        name = "\(curveName)"
        sensors = \(tomlArray(sensorKeys))
        points = \(points)
        hysteresis = 3.0
        slew_rate = 600.0
        fall_slew_rate = 300.0

        [safety]
        temp_ceiling = 100.0
        allow_below_minimum = false
        """

        return existingConfig.isEmpty
            ? curve
            : existingConfig + "\n\n" + curve
    }

    private static func tomlArray(_ items: [String]) -> String {
        "[" + items.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }
}

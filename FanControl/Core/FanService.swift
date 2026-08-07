import Foundation

/// 风扇当前的四种互斥工作模式，UI 高亮与状态显示的唯一依据。
enum FanMode: Equatable {
    case auto      // 系统自动控制
    case quiet     // 静音曲线
    case full      // 全速
    case target(Int)   // 目标温度闭环控温（到 N°C）

    /// 是否为「目标温度控温」模式（用于 UI 展开温度条 / 判断是否已启用）。
    var isTarget: Bool {
        if case .target = self { return true }
        return false
    }
}

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
        await MainActor.run {
            stopTargetControlLoop()     // 切走模式时停掉闭环，避免两个模式打架
            switch profile {
            case "quiet": mode = .quiet
            case "full": mode = .full
            default: mode = .auto
            }
        }
    }

    /// 交还系统控制。必须用 `fan profile auto`（而非 `fan auto`）：
    /// 实测 `fan auto` 只复位 target 不切回 system mode（profile 停在 manual），
    /// `fan profile auto` 才会正确交还系统控制。
    func revertToAuto() async throws {
        let bin = try resolvedBin()
        _ = try await execSync(path: bin, args: ["fan", "profile", "auto"])
        await MainActor.run {
            stopTargetControlLoop()
            mode = .auto
        }
    }

    // MARK: - 安装

    /// 安装 smctld。以管理员权限弹一次性密码框执行 `smctl daemon install`，返回是否成功。
    func installDaemon() async throws -> Bool {
        let bin = try resolvedBin()
        let success = try await promptAdmin("\(bin) daemon install")
        await MainActor.run { daemonRunning = success }
        return success
    }

    // MARK: - 目标温度闭环控制（app 内闭环，零权限弹窗）

    /// 当前生效的工作模式（UI 高亮 & 状态展示的唯一依据）。
    @Published private(set) var mode: FanMode = .auto

    /// 当前生效的目标温度（nil = 未启用，系统自动控制）。
    @Published private(set) var currentTargetTemp: Int?

    /// 闭环用状态：上一周期写入的转速，用于步进限制与降速平滑。
    private var lastFanRPM: Int = 0

    /// 目标温控的采样周期（秒）。
    private static let controlInterval: TimeInterval = 1.5

    /// 闭环控制 Task（nil = 未启用）。
    private var controlTask: Task<Void, Never>?

    /// 设定目标温度。
    ///
    /// 完全由 app 内部跑闭环：每 `controlInterval` 读一次热点温度，按滞回控制器算出
    /// 目标转速，经 `smctl fan set`（XPC 免 root、不写 /etc、不重启 daemon）应用。
    /// 因此全程不弹密码框；代价是控温仅在 app 存活期间生效，退出即还原 auto
    /// （已在 `stop` 上交还，避免把风扇冻在高转速）。
    func applyTargetTemp(_ t: Int) {
        let target = t
        stopTargetControlLoop()   // 取消旧的闭环（若正在运行），直接起步，不走 revertToAuto
        currentTargetTemp = target
        mode = .target(target)
        lastFanRPM = 0

        controlTask = Task(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                await self?.controlTick(target: target)
                try? await Task.sleep(nanoseconds: UInt64(Self.controlInterval * 1_000_000_000))
            }
        }
    }

    /// 停掉并交还系统自动控制。
    func revertTargetTemp() {
        stopTargetControlLoop()
        mode = .auto
        Task {
            // 交还 auto，避免退出时把风扇冻在高转速；失败不致命，尽力而为。
            try? await self.revertToAuto()
        }
    }

    /// 取消闭环 Task 并清空相关状态（须在主线程调用）。
    private func stopTargetControlLoop() {
        controlTask?.cancel()
        controlTask = nil
        currentTargetTemp = nil
        lastFanRPM = 0
    }

    /// 单个控制周期：读温度 → 算目标转速 → 应用（限制步进）。
    private func controlTick(target: Int) async {
        // snapshot 由主线程写入，读操作 hop 到主线程，避免并发数据竞争。
        let hot = await MainActor.run { Int(self.snapshot?.effectiveTemp.rounded() ?? 999) }
        let maxRPM = await MainActor.run { Int(self.snapshot?.fans.first?.maximumRPM ?? 0) }
        if maxRPM <= 0 { return }

        let rpm = targetRPM(hot: hot, target: target, maxRPM: maxRPM)
        // 步进限制：每周期最多变更 1200 RPM，防止转速陡变/闸蜂。
        let delta = rpm - lastFanRPM
        let bounded = lastFanRPM + max(-1200, min(1200, delta))
        guard bounded != lastFanRPM else { return }          // 转速不变就不写
        lastFanRPM = bounded
        do {
            try await setFanSpeed(bounded)
        } catch {
            // 写失败静默，等下一周期重试；由 UI 的最近错误反馈可见。
        }
    }

    /// 滞回温度控制器 → 目标转速（RPM）。
    ///
    /// 输入为「掌托体感」温度（`effectiveTemp`，与主展示/控温档位同量纲）。
    /// - 掌托比目标高 ≥2°C：比例拉升，Δ 越大越逼近 max（Δ=8°C 封顶约 85% span）。
    /// - 掌托已被压到目标以下：比例回落回基线(1200)，增益 0.33 防骤降。
    /// - 过热硬护栏：掌托 ≥50°C（手感已明显烫手，远超正常 30-40°C 区间）直接压向 max，绝不留砖。
    private func targetRPM(hot: Int, target: Int, maxRPM: Int) -> Int {
        let base = 1200
        let riseAbove = hot - target                  // >0 过烫
        let dropBelow = target - hot                  // >0 已凉

        if hot >= 50 { return maxRPM }                // 硬护栏（掌托已烫手）
        if dropBelow >= 2 {                           // 已压低，比例回落
            let ramp = Int(Double(dropBelow) * 0.33 * Double(maxRPM) / 10.0)
            return max(base, min(maxRPM, lastFanRPM - ramp))
        }
        if riseAbove > 0 {                            // 过烫，比例拉升
            let span = Double(maxRPM - base)
            let frac = min(0.85, Double(riseAbove) * 0.85 / 8.0)  // Δ=8°C→0.85 span
            return base + Int(span * frac)
        }
        // 滞回带（±1°C）内维持当前转速，不动作防抖动。
        return lastFanRPM == 0 ? base : lastFanRPM
    }

    // MARK: - AppleScript 管理员授权（仅安装 daemon 用）

    /// 通过 osascript 以管理员权限执行一条命令（弹一次性系统密码框）。仅首次安装 daemon 时调用。
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


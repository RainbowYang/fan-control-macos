import Foundation
import ServiceManagement

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

/// 封装 `smctl` CLI 的所有调用。App 生命周期内共享同一实例。
final class FanService: ObservableObject {

    /// 全局共享实例：SwiftUI 视图与 AppDelegate 生命周期回调共用。
    static let shared = FanService()

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

    // MARK: - 对外状态（@Published 镜像只在主线程写）

    @Published private(set) var snapshot: SensorSnapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var isInstalled: Bool = installedPath != nil
    @Published private(set) var daemonRunning: Bool = false

    /// 当前生效的工作模式（UI 高亮 & 状态展示的唯一依据）。
    @Published private(set) var mode: FanMode = .auto

    /// 当前生效的目标温度（nil = 未启用，系统自动控制）。
    @Published private(set) var currentTargetTemp: Int?

    /// 历史采样（最多保留约 15 分钟：1.5s × 600）。
    @Published private(set) var history: [HistoryPoint] = []

    /// 是否已注册「登录时打开」（SMAppService.mainApp）。
    @Published private(set) var launchAtLogin = false

    /// 修改开机自启失败时的错误说明（供设置面板展示）。
    @Published private(set) var launchAtLoginError: String?

    /// 单个历史采样点：掌托温度 + 最高风扇实际转速。
    struct HistoryPoint: Identifiable {
        let id = UUID()
        let date: Date
        let temperature: Double
        let rpm: Double
    }

    private static let historyLimit = 600   // 约 15 分钟（1.5s 采样）

    private var fetchTask: Task<Void, Never>?

    // MARK: - 控制状态（NSLock 保护，后台控制循环与主线程 UI 均可安全访问）

    private let stateLock = NSLock()
    private var internalMode: FanMode = .auto
    private var internalLastFanRPM = 0
    private var internalControlTask: Task<Void, Never>?

    /// 所有 smctl 写命令都经同一串行队列：保证「切模式」和「控温写入」不会并发交错，
    /// 过期控温写入在真正执行前会再次校验模式，因此不可能覆盖刚切换的模式。
    private let writeQueue = CommandQueue()

    // MARK: - 生命周期

    /// App 启动后调用：开始传感器轮询并探测 daemon。
    /// 轮询挂在 App 生命周期（而非下拉面板 onAppear），面板关闭时菜单栏图标依旧实时更新。
    func start() {
        refreshLaunchAtLogin()
        startPolling()
        Task { _ = await checkDaemon() }
    }

    // MARK: - 开机自启（Login Item）

    /// 读取当前「登录时打开」状态。
    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// 注册/注销登录项。失败时保留错误信息给设置面板展示。
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// 退出前调用：停掉控温闭环并同步交还系统自动控制。
    /// 经串行写队列执行，能保证排在退出前的其它写命令先完成、且之后不会再被覆盖。
    func shutdown() {
        stopTargetControlLoop()
        writeMode(.auto)
        guard let bin = Self.installedPath else { return }
        writeQueue.sync {
            _ = try? Self.execProcessSync(path: bin, args: ["fan", "profile", "auto"])
        }
    }

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
            let rpm = snap.fans.map(\.actualRPM).max() ?? 0
            let point = HistoryPoint(date: Date(), temperature: snap.effectiveTemp, rpm: rpm)
            await MainActor.run {
                snapshot = snap
                history.append(point)
                if history.count > Self.historyLimit {
                    history.removeFirst(history.count - Self.historyLimit)
                }
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

    /// 每 `interval` 秒读一次传感器；每 10 个周期顺手探一次 daemon 存活。
    func startPolling(interval: TimeInterval = 1.5) {
        fetchTask?.cancel()
        fetchTask = Task(priority: .background) {
            var tick = 0
            while !Task.isCancelled {
                await refreshSensors()
                tick += 1
                if tick % 10 == 0 {
                    _ = await checkDaemon()
                }
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

    /// 手动设定目标转速。
    /// - Parameter onlyIfTarget: 若传入，仅当当前模式仍是该目标温度时才执行写入。
    ///   控温闭环用它防止「已切走模式 / 已改目标」的过期写入覆盖新状态。
    func setFanSpeed(_ rpm: Int, fan: Int? = nil, onlyIfTarget target: Int? = nil) async throws {
        let bin = try resolvedBin()
        var args = ["fan", "set", "\(rpm)"]
        if let fan { args += ["--fan", "\(fan)"] }
        try await writeQueue.run {
            if let target, self.readMode() != .target(target) { return }
            _ = try Self.execProcessSync(path: bin, args: args)
        }
    }

    /// 切换风扇预设：quiet / full / auto。
    /// 模式切换本身也走串行写队列，成功后才更新状态；同一队列保证它和控温写入
    /// 严格有序，杜绝「旧控温写入手动 RPM 覆盖刚交还的 auto」。
    func setProfile(_ profile: String) async throws {
        let bin = try resolvedBin()
        let newMode: FanMode
        switch profile {
        case "quiet": newMode = .quiet
        case "full": newMode = .full
        default: newMode = .auto
        }
        try await writeQueue.run {
            _ = try Self.execProcessSync(path: bin, args: ["fan", "profile", profile])
            self.stopTargetControlLoop()     // 切走模式时停掉闭环，避免两个模式打架
            self.writeMode(newMode)
        }
    }

    /// 交还系统控制。必须用 `fan profile auto`（而非 `fan auto`）：
    /// 实测 `fan auto` 只复位 target 不切回 system mode（profile 停在 manual），
    /// `fan profile auto` 才会正确交还系统控制。
    func revertToAuto() async throws {
        let bin = try resolvedBin()
        try await writeQueue.run {
            _ = try Self.execProcessSync(path: bin, args: ["fan", "profile", "auto"])
            self.stopTargetControlLoop()
            self.writeMode(.auto)
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

    /// 目标温控的采样周期（秒）。
    private static let controlInterval: TimeInterval = 1.5

    /// 设定目标温度。
    ///
    /// 完全由 app 内部跑闭环：每 `controlInterval` 读一次掌托温度，按滞回控制器算出
    /// 目标转速，经 `smctl fan set`（XPC 免 root、不写 /etc、不重启 daemon）应用。
    /// 因此全程不弹密码框；代价是控温仅在 app 存活期间生效，退出即还原 auto
    /// （见 `shutdown()`）。
    func applyTargetTemp(_ t: Int) {
        stopTargetControlLoop()   // 取消旧的闭环（若正在运行），直接起步，不走 revertToAuto
        writeTargetTemp(t)
        writeMode(.target(t))
        resetLastFanRPM()

        let task = Task(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                await self?.controlTick(target: t)
                try? await Task.sleep(nanoseconds: UInt64(Self.controlInterval * 1_000_000_000))
            }
        }
        storeControlTask(task)
    }

    /// 取消闭环 Task 并清空相关状态（线程安全，主线程或写队列均可调用）。
    private func stopTargetControlLoop() {
        takeControlTask()?.cancel()
        writeTargetTemp(nil)
        resetLastFanRPM()
    }

    /// 单个控制周期：读温度 → 算目标转速 → 串行队列内二次校验后应用（限制步进）。
    private func controlTick(target: Int) async {
        guard !Task.isCancelled, readMode() == .target(target) else { return }

        // snapshot 由主线程写入，读操作 hop 到主线程，避免并发数据竞争。
        let hot = await MainActor.run { Int(self.snapshot?.effectiveTemp.rounded() ?? 999) }
        let maxRPM = await MainActor.run { Int(self.snapshot?.fans.first?.maximumRPM ?? 0) }
        guard maxRPM > 0 else { return }

        let last = readLastFanRPM()
        let rpm = Self.targetRPM(hot: hot, target: target, maxRPM: maxRPM, last: last)
        // 步进限制：每周期最多变更 1200 RPM，防止转速陡变/闸蜂。
        let delta = rpm - last
        let bounded = last + max(-1200, min(1200, delta))
        guard bounded != last else { return }          // 转速不变就不写
        setLastFanRPM(bounded)

        do {
            // onlyIfTarget 会在串行队列真正执行前再校验一次模式：
            // 若这期间用户已切到自动/静音/全速或改了目标，本次写入自动放弃。
            try await setFanSpeed(bounded, onlyIfTarget: target)
        } catch {
            // 写失败静默，等下一周期重试；由 UI 的最近错误反馈可见。
        }
    }

    /// 滞回温度控制器 → 目标转速（RPM）。纯函数，状态经参数传入，便于在任意线程调用。
    ///
    /// 输入为「掌托体感」温度（`effectiveTemp`，与主展示/控温档位同量纲）。
    /// - 掌托比目标高 ≥2°C：比例拉升，Δ 越大越逼近 max（Δ=8°C 封顶约 85% span）。
    /// - 掌托已被压到目标以下：比例回落回基线(1200)，增益 0.33 防骤降。
    /// - 过热硬护栏：掌托 ≥50°C（手感已明显烫手，远超正常 30-40°C 区间）直接压向 max，绝不留砖。
    private static func targetRPM(hot: Int, target: Int, maxRPM: Int, last: Int) -> Int {
        let base = 1200
        let riseAbove = hot - target                  // >0 过烫
        let dropBelow = target - hot                  // >0 已凉

        if hot >= 50 { return maxRPM }                // 硬护栏（掌托已烫手）
        if dropBelow >= 2 {                           // 已压低，比例回落
            let ramp = Int(Double(dropBelow) * 0.33 * Double(maxRPM) / 10.0)
            return max(base, min(maxRPM, last - ramp))
        }
        if riseAbove > 0 {                            // 过烫，比例拉升
            let span = Double(maxRPM - base)
            let frac = min(0.85, Double(riseAbove) * 0.85 / 8.0)  // Δ=8°C→0.85 span
            return base + Int(span * frac)
        }
        // 滞回带（±1°C）内维持当前转速，不动作防抖动。
        return last == 0 ? base : last
    }

    // MARK: - 控制状态线程安全访问

    private func readMode() -> FanMode {
        stateLock.lock(); defer { stateLock.unlock() }
        return internalMode
    }

    private func readLastFanRPM() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return internalLastFanRPM
    }

    private func setLastFanRPM(_ value: Int) {
        stateLock.lock(); defer { stateLock.unlock() }
        internalLastFanRPM = value
    }

    private func resetLastFanRPM() {
        setLastFanRPM(0)
    }

    private func writeMode(_ newMode: FanMode) {
        stateLock.lock(); internalMode = newMode; stateLock.unlock()
        if Thread.isMainThread {
            mode = newMode
        } else {
            DispatchQueue.main.async { [weak self] in self?.mode = newMode }
        }
    }

    private func writeTargetTemp(_ value: Int?) {
        // currentTargetTemp 只在主线程读/写；跨线程调用时派回主线程。
        if Thread.isMainThread {
            currentTargetTemp = value
        } else {
            DispatchQueue.main.async { [weak self] in self?.currentTargetTemp = value }
        }
    }

    private func takeControlTask() -> Task<Void, Never>? {
        stateLock.lock(); defer { stateLock.unlock() }
        let task = internalControlTask
        internalControlTask = nil
        return task
    }

    private func storeControlTask(_ task: Task<Void, Never>) {
        stateLock.lock(); defer { stateLock.unlock() }
        internalControlTask?.cancel()
        internalControlTask = task
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
        let terminationStatus: Int32
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
            throw FanServiceError.exitCode(result.terminationStatus, msg)
        }
        return result.stdout
    }

    /// 在后台线程同步执行，返回完整结果。异步包装避免阻塞主线程。
    private func execAsync(path: String, args: [String]) async throws -> ExecResult {
        await Task.detached(priority: .utility) {
            Self.runProcess(path: path, args: args)
        }.value
    }

    /// 同步执行并校验退出码。供串行写队列使用，保证写命令一个接一个执行。
    private static func execProcessSync(path: String, args: [String]) throws -> String {
        let result = runProcess(path: path, args: args)
        guard result.terminatedCleanly else {
            let msg = result.stderr.isEmpty ? result.stdout : result.stderr
            throw FanServiceError.exitCode(result.terminationStatus, msg)
        }
        return result.stdout
    }

    /// 同步运行进程并收集输出（阻塞当前线程）。
    /// 注意：smctl 单次 stdout/stderr 都很小（sensors JSON 约 8KB，写命令仅一行），
    /// 顺序读取两个管道不会触发 64KB 管道缓冲区写满死锁。
    private static func runProcess(path: String, args: [String]) -> ExecResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = Pipe()   // 关闭以避免阻塞

        do {
            try process.run()
        } catch {
            return ExecResult(stdout: "", stderr: error.localizedDescription,
                              terminationStatus: -1, terminatedCleanly: false)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ExecResult(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            terminationStatus: process.terminationStatus,
            terminatedCleanly: process.terminationStatus == 0
        )
    }
}

/// 串行命令队列：所有 smctl 写命令依次执行。
/// 控温闭环与模式切换共用这一个队列，从根上消除「切换自动后又被过期控温写入覆盖」的竞态。
private final class CommandQueue {
    private static let key = DispatchSpecificKey<UInt8>()
    private static let marker: UInt8 = 1

    private let queue: DispatchQueue

    init() {
        queue = DispatchQueue(label: "local.fancontrol.smctl-write")
        queue.setSpecific(key: Self.key, value: Self.marker)
    }

    /// 异步入队：返回时本次命令已执行完毕。
    func run(_ body: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try body()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 同步入队：排在此刻之前的所有命令执行完后才执行本命令并返回。
    /// 仅供退出还原使用；若已在队列线程上则直接执行，避免死锁。
    func sync(_ body: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: Self.key) == Self.marker {
            body()
        } else {
            queue.sync(execute: body)
        }
    }
}

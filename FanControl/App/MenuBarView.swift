import AppKit
import Charts
import OSLog
import SwiftUI

/// 菜单栏下拉面板：温度、风扇、转速控制
struct MenuBarView: View {
    @EnvironmentObject private var service: FanService
    @State private var feedbackMessage: String?
    @State private var targetTemp: Double = 32
    @AppStorage("historyTemperatureEnabled") private var historyTemperatureEnabled = true
    @AppStorage("historyFanEnabled") private var historyFanEnabled = false
    @AppStorage("showTemperatureSection") private var showTemperatureSection = true
    @AppStorage("showFansSection") private var showFansSection = true

    private var anyHistoryEnabled: Bool {
        historyTemperatureEnabled || historyFanEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if showTemperatureSection {
                Divider()
                tempsSection
            }
            if anyHistoryEnabled {
                Divider()
                historySection
            }
            if showFansSection {
                Divider()
                fansSection
            }
            Divider()
            controlsSection
            Divider()
            footerRow
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            // 轮询已由 App 生命周期常驻运行，这里只需在每次打开面板时刷新 daemon 状态。
            Task { _ = await service.checkDaemon() }
        }
    }

    /// 底部：打开设置 / 显式退出（退出会经 AppDelegate 交还系统自动控制）。
    private var footerRow: some View {
        HStack {
            Button {
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开 FanControl 设置")
            Spacer()
            Button("退出 FanControl") {
                NSApp.terminate(nil)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
        }
    }

    /// 打开独立设置窗口：直接调用独立控制器（不经过 NSApp.delegate）。
    private func openSettings() {
        let logger = Logger(subsystem: "local.fancontrol.app", category: "menu-bar")
        logger.notice("settings button tapped; delegate=\(String(describing: NSApp.delegate), privacy: .public)")
        SettingsWindowController.shared.show()
    }

    // MARK: - 顶部：主温度 + 功耗 + 安装状态

    private var header: some View {
        HStack(alignment: .center) {
            if let snapshot = service.snapshot {
                Text("\(Int(snapshot.effectiveTemp.rounded()))°C")
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                Spacer()
                if !service.daemonRunning {
                    Button("装服务") { installDaemon() }
                        .font(.caption)
                }
                if let pwr = snapshot.totalPower {
                    Text(String(format: "%.0fW", pwr))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else if service.isInstalled {
                Spacer()
                ProgressView().controlSize(.small)
                Text("读取中…").font(.caption).foregroundStyle(.secondary)
            } else {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("smctl 未就绪").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 温度分组

    private var tempsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("温度").font(.headline)
            if let snapshot = service.snapshot {
                // 左右掌托同一行展示。
                HStack {
                    Text("掌托").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let l = snapshot.palmRestLeft {
                        Text("左 \(Int(l.rounded()))°").font(.callout.monospacedDigit())
                    }
                    if let r = snapshot.palmRestRight {
                        Text("右 \(Int(r.rounded()))°").font(.callout.monospacedDigit())
                    }
                }
                // CPU、GPU 同一行展示。
                HStack {
                    Text("内部").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let cpu = snapshot.cpuDieTemp {
                        Text("CPU \(Int(cpu.rounded()))°").font(.callout.monospacedDigit())
                    }
                    if let gpu = snapshot.gpuTemp {
                        Text("GPU \(Int(gpu.rounded()))°").font(.callout.monospacedDigit())
                    }
                }
            } else {
                Text("无数据").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 历史曲线（温度/风扇转速可多选，独立开关）

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("历史").font(.headline)
            if service.history.count >= 2 {
                if historyTemperatureEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("温度")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        temperatureHistoryChart
                            .frame(height: 72)
                    }
                }
                if historyFanEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("风扇转速")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        fanHistoryChart
                            .frame(height: 72)
                    }
                }
            } else {
                Text("收集数据中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var temperatureHistoryChart: some View {
        Chart(service.history) { point in
            AreaMark(
                x: .value("时间", point.date),
                y: .value("温度", point.temperature)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.orange.opacity(0.35), Color.orange.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            LineMark(
                x: .value("时间", point.date),
                y: .value("温度", point.temperature)
            )
            .foregroundStyle(.orange)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text("\(Int(number.rounded()))°")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var fanHistoryChart: some View {
        Chart(service.history) { point in
            AreaMark(
                x: .value("时间", point.date),
                y: .value("RPM", point.rpm)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.green.opacity(0.35), Color.green.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            LineMark(
                x: .value("时间", point.date),
                y: .value("RPM", point.rpm)
            )
            .foregroundStyle(.green)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text("\(Int(number.rounded()))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 风扇

    private var fansSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("风扇").font(.headline)
                Spacer()
                if let mode = service.snapshot?.fans.first?.mode {
                    Text(mode.uppercased())
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(mode == "auto" ? Color.green.opacity(0.2) : Color.orange.opacity(0.2)))
                }
            }
            if let fans = service.snapshot?.fans, !fans.isEmpty {
                ForEach(fans, id: \.index) { fan in
                    HStack {
                        Text("风扇 \(fan.index + 1)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(fan.actualRPM.rounded()))")
                            .font(.callout.monospacedDigit())
                        Text("/ \(Int((fan.targetRPM ?? fan.actualRPM).rounded()))")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("RPM").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("无风扇数据").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 控制

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("控制").font(.headline)

            // 四种并列的工作模式：自动 / 静音 / 全速 / 控温（当前一项高亮）
            HStack(spacing: 6) {
                presetButton("自动", icon: "arrow.clockwise", isActive: service.mode == .auto) {
                    try await service.revertToAuto()
                }
                presetButton("静音", icon: "speaker.wave.2", isActive: service.mode == .quiet) {
                    try await service.setProfile("quiet")
                }
                presetButton("全速", icon: "speedometer", isActive: service.mode == .full) {
                    try await service.setProfile("full")
                }
                presetButton("控温", icon: "target", isActive: service.mode.isTarget) {
                    // 切换到控温模式：按下即用当前滑杆目标温度启动闭环。
                    service.applyTargetTemp(Int(self.targetTemp))
                }
            }
            .frame(maxWidth: .infinity)

            if let feedback = feedbackMessage {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(feedback.hasPrefix("❌") ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity)
            }

            // 仅在「控温」模式下才展开目标温度条；切到其它模式即折叠并停用控温。
            if service.mode.isTarget {
                Divider()
                targetTempBar
            }
        }
    }

    /// 控温模式专属的温度条：滑杆即拖即用，拖动实时改变控温目标。
    private var targetTempBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("目标温度").font(.headline)
                Spacer()
                if let active = service.currentTargetTemp {
                    Label("控温 \(active)°C", systemImage: "target")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            HStack {
                Text("\(Int(targetTemp))°C")
                    .font(.callout.monospacedDigit())
                    .frame(width: 44, alignment: .leading)
                Slider(value: $targetTemp, in: 25...45, step: 1)
                    .onChange(of: targetTemp) { _, newValue in
                        // 拖动即启用/更新控温，无需确认按钮。
                        service.applyTargetTemp(Int(newValue))
                    }
            }
        }
    }

    private func presetButton(
        _ label: String,
        icon: String,
        isActive: Bool,
        action: @escaping () async throws -> Void
    ) -> some View {
        // 选中态用实心不透明 accent 填充 + 白字，避免被面板毛玻璃背景透色稀释。
        // 未选中保持半透明浅灰，刻意低调。
        let fg: Color = isActive ? .white : .primary
        let bg: Color = isActive ? Color.accentColor : Color.primary.opacity(0.06)
        let weight: Font.Weight = isActive ? .semibold : .regular

        return Button {
            Task {
                // 模式状态已由按钮高亮表达，成功不再弹文案；仅失败时提示。
                do {
                    try await action()
                } catch {
                    feedbackMessage = "❌ 切换失败: \(error.localizedDescription)"
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .fontWeight(isActive ? .bold : .regular)
                    .foregroundStyle(fg)
                Text(label).font(.caption).fontWeight(weight)
                    .foregroundStyle(fg)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(bg)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func installDaemon() {
        Task { try? await service.installDaemon() }
    }
}

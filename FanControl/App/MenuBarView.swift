import SwiftUI

/// 菜单栏下拉面板：温度、风扇、转速控制
struct MenuBarView: View {
    @EnvironmentObject private var service: FanService
    @State private var feedbackMessage: String?
    @State private var targetTemp: Double = 55

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            tempsSection
            Divider()
            fansSection
            Divider()
            controlsSection
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            service.startPolling()
            Task { _ = await service.checkDaemon() }   // 启动时刷新 daemon 状态
        }
        .onDisappear {
            service.stopPolling()
        }
    }

    // MARK: - 顶部：温度 + 安装状态

    private var header: some View {
        HStack {
            if let snapshot = service.snapshot {
                Text("\(Int(snapshot.effectiveTemp.rounded()))°C")
                    .font(.system(size: 28, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("热点最高") .font(.caption).foregroundStyle(.secondary)
                    if let pwr = snapshot.totalPower {
                        Text(String(format: "功耗 %.1f W", pwr))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if service.isInstalled {
                ProgressView().controlSize(.small)
                Text("读取中…").font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("smctl 未就绪").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !service.daemonRunning {
                Button("装服务") { installDaemon() }
                    .font(.caption)
            }
        }
    }

    // MARK: - 温度分组

    private var tempsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("温度").font(.headline)
                Spacer()
                Text("主温度=表面体感").font(.caption2).foregroundStyle(.secondary)
            }
            if let snapshot = service.snapshot {
                // 主温度大字已在顶部 header 显示；这里罗列不同位置的温度。
                if let cpu = snapshot.cpuDieTemp {
                    tempRow(label: "CPU 硅片", value: cpu, hint: "真实核心温度")
                }
                if let surf = snapshot.surfaceTemp {
                    tempRow(label: "表面(体感)", value: surf)
                }
                if let board = snapshot.boardTemp {
                    tempRow(label: "板面", value: board)
                }
                if let gpu = snapshot.gpuTemp {
                    tempRow(label: "GPU", value: gpu)
                }
                if snapshot.temperatures.count > 0 {
                    tempRow(label: "平均", value: snapshot.averageTemp, format: true)
                }
            } else {
                Text("无数据").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tempRow(label: String, value: Double?, format: Bool = false, hint: String? = nil) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let hint {
                Text(hint).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if let value {
                Text(format ? String(format: "%.1f°C", value) : "\(Int(value.rounded()))°C")
                    .font(.callout.monospacedDigit())
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
                Slider(value: $targetTemp, in: 45...65, step: 1)
                    .onChange(of: targetTemp) { newValue in
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
        let fg: Color = isActive ? .accentColor : .primary
        let bg: Color = isActive ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)

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
                    .foregroundStyle(fg)
                Text(label).font(.caption)
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

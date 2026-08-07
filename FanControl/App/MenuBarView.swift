import SwiftUI

/// 菜单栏下拉面板：温度、风扇、转速控制
struct MenuBarView: View {
    @EnvironmentObject private var service: FanService
    @State private var feedbackMessage: String?
    @State private var targetTemp: Double = 75

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
            Text("温度").font(.headline)
            if let snapshot = service.snapshot {
                let hotspots = snapshot.hotspots
                if !hotspots.isEmpty {
                    tempRow(label: "热点最高", value: hotspots.first?.celsius)
                }
                if let overall = snapshot.hottestOverall {
                    tempRow(label: "全局最高", value: overall)
                }
                if snapshot.temperatures.count > 0 {
                    tempRow(label: "平均", value: snapshot.averageTemp, format: true)
                }
            } else {
                Text("无数据").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tempRow(label: String, value: Double?, format: Bool = false) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
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
            Text("风扇").font(.headline)
            if let fans = service.snapshot?.fans, !fans.isEmpty {
                ForEach(fans, id: \.index) { fan in
                    HStack {
                        Text("风扇 \(fan.index + 1)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(fan.mode.uppercased())
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(fan.mode == "auto" ? Color.green.opacity(0.2) : Color.orange.opacity(0.2)))
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

            // 预设按钮（当前 profile 高亮；点击有反馈）
            HStack(spacing: 6) {
                presetButton("自动", icon: "arrow.clockwise", profile: "auto") {
                    try await service.revertToAuto()
                }
                presetButton("静音", icon: "speaker.wave.2", profile: "quiet") {
                    try await service.setProfile("quiet")
                }
                presetButton("全速", icon: "speedometer", profile: "full") {
                    try await service.setProfile("full")
                }
            }
            .frame(maxWidth: .infinity)

            if let feedback = feedbackMessage {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(feedback.hasPrefix("❌") ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity)
            }

            Divider()

            // 目标温度闭环控制
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("目标温度").font(.headline)
                    Spacer()
                    if let active = service.currentTargetTemp {
                        Label("控温 \(active)°C", systemImage: "target")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Label("系统自动", systemImage: "checkmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("\(Int(targetTemp))°C")
                        .font(.callout.monospacedDigit())
                        .frame(width: 44, alignment: .leading)
                    Slider(value: $targetTemp, in: 60...90, step: 5)
                        .disabled(service.currentTargetTemp != nil)
                    Button(service.currentTargetTemp == nil ? "启用" : "还原") {
                        Task { await toggleTargetTemp() }
                    }
                    .buttonStyle(.bordered)
                }
                Text("风扇将按设定目标自动调速，把温度压回该值以下（系统级，退出 app 也生效）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toggleTargetTemp() {
        Task {
            if service.currentTargetTemp != nil {
                feedbackMessage = "⏳ 还原系统自动…"
                do {
                    try await service.revertTargetTemp()
                    feedbackMessage = "已交还系统自动控制"
                } catch {
                    feedbackMessage = "❌ 还原失败: \(error.localizedDescription)"
                }
            } else {
                let t = Int(targetTemp)
                feedbackMessage = "⏳ 设置目标温度 \(t)°C…"
                do {
                    try await service.applyTargetTemp(t)
                    feedbackMessage = "已启用控温 \(t)°C"
                } catch {
                    feedbackMessage = "❌ 启用失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func presetButton(
        _ label: String,
        icon: String,
        profile: String,
        action: @escaping () async throws -> Void
    ) -> some View {
        let isActive = (profile == currentProfile)
        let fg: Color = isActive ? .accentColor : .primary
        let bg: Color = isActive ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)

        return Button {
            Task {
                feedbackMessage = "⏳ 正在切换…"
                do {
                    try await action()
                    feedbackMessage = "已切到「\(label)」"
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

    /// 当前激活的 profile 标识：auto=系统自动；manual 时按目标转速高低判 quiet/full。
    private var currentProfile: String {
        guard let fan = service.snapshot?.fans.first else { return "auto" }
        if fan.mode == "auto" { return "auto" }
        let span = max(fan.maximumRPM - fan.minimumRPM, 1)
        let ratio = (fan.targetRPM ?? fan.actualRPM) / span
        return ratio > 0.6 ? "full" : "quiet"
    }

    private func installDaemon() {
        Task { try? await service.installDaemon() }
    }
}

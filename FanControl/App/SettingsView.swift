import SwiftUI

/// 历史曲线展示的指标。存 AppStorage 用 rawValue。
enum HistoryMetric: String, CaseIterable, Identifiable {
    case temperature
    case fanRPM

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .temperature: return "温度"
        case .fanRPM: return "风扇转速"
        }
    }
}

/// 独立设置面板：开机自启 + 历史曲线选项 + 关于。
struct SettingsView: View {
    @EnvironmentObject private var service: FanService
    @AppStorage("historyMetric") private var historyMetricRaw = HistoryMetric.temperature.rawValue

    var body: some View {
        Form {
            Section("通用") {
                Toggle("开机自动启动", isOn: Binding(
                    get: { service.launchAtLogin },
                    set: { service.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                if let message = service.launchAtLoginError {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("菜单栏面板") {
                Picker("历史曲线", selection: $historyMetricRaw) {
                    ForEach(HistoryMetric.allCases) { metric in
                        Text(metric.displayName).tag(metric.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("关于") {
                LabeledContent("版本") {
                    Text(versionDescription)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("底层") {
                    Text("smctl \(smctlVersion)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }

    private var smctlVersion: String {
        let output = Process.smctlVersionOutput
        return output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知"
    }
}

private extension Process {
    /// 同步执行一次 `smctl --version` 获取底层版本号（仅设置面板展示用，失败返回 nil）。
    static var smctlVersionOutput: String? {
        let path = FanService.installedPath
        guard let path else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

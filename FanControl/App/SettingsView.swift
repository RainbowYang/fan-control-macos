import SwiftUI

/// 独立设置面板：开机自启 + 历史曲线选项 + 关于。
struct SettingsView: View {
    @EnvironmentObject private var service: FanService
    @AppStorage("historyTemperatureEnabled") private var historyTemperatureEnabled = true
    @AppStorage("historyFanEnabled") private var historyFanEnabled = false
    @AppStorage("showTemperatureSection") private var showTemperatureSection = true
    @AppStorage("showFansSection") private var showFansSection = true

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
                Toggle("温度面板", isOn: $showTemperatureSection)
                Toggle("风扇面板", isOn: $showFansSection)
            }

            Section("菜单栏历史曲线") {
                Toggle("温度曲线", isOn: $historyTemperatureEnabled)
                Toggle("风扇转速曲线", isOn: $historyFanEnabled)
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
                LabeledContent("项目") {
                    Link("github.com/RainbowYang/fan-control-macos",
                         destination: URL(string: "https://github.com/RainbowYang/fan-control-macos")!)
                        .foregroundStyle(.tint)
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

import AppKit
import OSLog
import SwiftUI

/// App 生命周期钩子：
/// - 启动时开始传感器轮询（保证面板关闭时菜单栏图标仍实时更新）
/// - 退出前同步交还系统自动控制，避免风扇停在手动高转速
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        FanService.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        FanService.shared.shutdown()
    }
}

/// 独立设置窗口控制器：用原生 NSWindow + NSHostingController 承载设置界面。
/// 不依赖 SwiftUI Settings scene / SettingsLink，也不依赖 NSApp.delegate 链路。
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private static let logger = Logger(subsystem: "local.fancontrol.app", category: "settings-window")

    private var windowController: NSWindowController?

    func show() {
        Self.logger.notice("show() called")

        if let windowController, let window = windowController.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Self.logger.notice("re-show existing window: \(window.isVisible, privacy: .public)")
            return
        }

        let rootView = SettingsView().environmentObject(FanService.shared)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FanControl 设置"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Self.logger.notice("created and showing window: \(window.isVisible, privacy: .public)")
    }
}

@main
struct FanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var service: FanService

    init() {
        _service = StateObject(wrappedValue: FanService.shared)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(service)
        } label: {
            MenuBarIcon(snapshot: service.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 菜单栏图标：显示温度，随热度变色
struct MenuBarIcon: View {
    let snapshot: SensorSnapshot?

    var temp: Double { snapshot?.effectiveTemp ?? 0 }
    var color: Color {
        // 主温度为「掌托体感」温度（待机 30-35°C），色界按手感知觉定。
        switch temp {
        case ..<36: return .green    // 清凉
        case 36..<42: return .orange // 温热
        default: return .red         // 手已感到明显热
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "fan.fill")
                .foregroundStyle(color)
            if temp > 0 {
                Text("\(Int(temp.rounded()))°")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(color)
            }
        }
    }
}

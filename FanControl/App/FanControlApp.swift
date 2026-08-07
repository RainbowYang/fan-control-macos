import SwiftUI

@main
struct FanControlApp: App {
    @StateObject private var service = FanService()

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

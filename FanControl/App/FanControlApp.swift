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
        // 主温度为「表面体感」温度，色界按体感档位定。
        switch temp {
        case ..<50: return .green    // 清凉
        case 50..<62: return .orange // 温热
        default: return .red         // 偏烫
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

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
        switch temp {
        case ..<70: return .green    // 凉
        case 70..<85: return .orange // 温
        default: return .red         // 热
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

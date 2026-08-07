import Foundation

/// 单个温度传感器读数
struct SensorReading: Codable {
    let key: String
    let celsius: Double
    let group: String?

    /// 是否是热点/快速响应的传感器（Tp* 前缀或苹果 TC 组）
    var isHotspot: Bool {
        key.hasPrefix("Tp")
    }
}

/// 单个风扇状态
struct FanStatus: Codable {
    let index: Int
    let actualRPM: Double
    let targetRPM: Double?
    let minimumRPM: Double
    let maximumRPM: Double
    let mode: String        // "auto" / "manual"
}

/// 功耗读数
struct PowerReading: Codable, Identifiable {
    let key: String
    let name: String?
    let value: Double
    let unit: String?
    var id: String { key }
}

/// 一次 `smctl sensors --json` 的完整快照
struct SensorSnapshot: Codable {
    let temperatures: [SensorReading]
    let fans: [FanStatus]
    let power: [PowerReading]?

    /// 所有传感器中的最高温
    var hottestOverall: Double? {
        temperatures.map(\.celsius).max()
    }

    // MARK: - 分组温度（按 SMC 组前缀区分物理位置/性质）

    /// 某组前缀里温度最高的一项（组不存在返回 nil）。
    private func hottest(inGroup prefix: String) -> Double? {
        temperatures.filter { $0.key.hasPrefix(prefix) }.map(\.celsius).max()
    }

    /// CPU 硅片最高热点（Tp*）：真实 CPU 核心温度，散热/过热监控用，但非人摸到的表面。
    var cpuDieTemp: Double? { hottest(inGroup: "Tp") }

    /// 表面温度群（Ts*）：芯片附近封装表面，最接近「摸得到的外壳暖感」。
    var surfaceTemp: Double? { hottest(inGroup: "Ts") }

    /// 板面温度群（TC*）：板载热耦合点，贴近机身外壳。
    var boardTemp: Double? { hottest(inGroup: "TC") }

    /// GPU / 图形组（Tg*）。
    var gpuTemp: Double? { hottest(inGroup: "Tg") }

    /// 品牌"即时表面"探点（Ts0P）：部分机型直接暴露人体可感的表面温度。
    var immediateSurfaceTemp: Double? {
        temperatures.first { $0.key == "Ts0P" }?.celsius
    }

    /// 主温度（菜单栏大字 + 控温闭环输入）：采用「体感」—表面温度群最高值。
    ///
    /// 说明：人摸键盘/触控板感受到的是封装表面与外壳温度，而非 CPU 硅片 die
    /// （die 常比表面高 ~20°C）。本 app 主展示与控温统一锚定表面温度，让
    /// 「目标温度」就是「摸上去热不热」，不需要脑补换算。想查看真实 CPU 硅片
    /// 温度见 `cpuDieTemp`。
    var effectiveTemp: Double {
        surfaceTemp ?? immediateSurfaceTemp ?? hottestOverall ?? 0
    }

    /// 平均温度（视觉中线）
    var averageTemp: Double {
        guard !temperatures.isEmpty else { return 0 }
        return temperatures.map(\.celsius).reduce(0, +) / Double(temperatures.count)
    }

    var totalPower: Double? {
        // macOS 26+ 便携机优先 PSTR（系统总功耗），其次是 PDTR
        if let p = power?.first(where: { $0.key == "PSTR" }) { return p.value }
        if let p = power?.first(where: { $0.key == "PDTR" }) { return p.value }
        return nil
    }

    static func parse(_ jsonData: Data) throws -> SensorSnapshot {
        let decoder = JSONDecoder()
        return try decoder.decode(SensorSnapshot.self, from: jsonData)
    }
}

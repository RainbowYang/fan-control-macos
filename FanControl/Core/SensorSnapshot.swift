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

    /// CPU 硅片最高热点（Tp*）：真实 CPU 核心温度，散热/过热监控用，但非人碰到的表面。
    var cpuDieTemp: Double? { hottest(inGroup: "Tp") }

    /// GPU / 图形组（Tg*）。
    var gpuTemp: Double? { hottest(inGroup: "Tg") }

    /// 左掌托温度（Ts0P）：键盘下方、触控板旁，打字时手腕搁的位置。
    var palmRestLeft: Double? {
        temperatures.first { $0.key == "Ts0P" }?.celsius
    }

    /// 右掌托温度（Ts1P）。
    var palmRestRight: Double? {
        temperatures.first { $0.key == "Ts1P" }?.celsius
    }

    /// 掌托温度（用户实际会碰到的体感）：取左右掌托较高者。
    var palmRestTemp: Double? {
        (palmRestLeft ?? palmRestRight ?? hottest(inGroup: "Ts"))
    }

    /// 主温度（菜单栏大字 + 控温闭环输入）：掌托温度。
    ///
    /// 用户只关心「手碰到的部位热不热」，主温度与控温统一锚定掌托温度
    /// （Ts0P/Ts1P —— 苹果专为手腕搁点提供的探点），让「目标温度」就是
    /// 「摸上去热不热」的体感值，无需脑补换算。真实 CPU 硅片温度见 `cpuDieTemp`。
    var effectiveTemp: Double {
        palmRestTemp ?? hottestOverall ?? 0
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

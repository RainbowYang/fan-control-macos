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

    /// 所有热点（Tp*）读数，按温度降序
    var hotspots: [SensorReading] {
        temperatures.filter { $0.isHotspot }.sorted { $0.celsius > $1.celsius }
    }

    /// CPU/GPU 等热点最高温度（用于菜单栏图标变色和展示）
    var hottestHotspot: Double? {
        hotspots.first?.celsius
    }

    /// 所有传感器中的最高温
    var hottestOverall: Double? {
        temperatures.map(\.celsius).max()
    }

    /// 计算给用户看的"热度"指标：优先热点最高温，否则整体最高温
    var effectiveTemp: Double {
        hottestHotspot ?? hottestOverall ?? 0
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

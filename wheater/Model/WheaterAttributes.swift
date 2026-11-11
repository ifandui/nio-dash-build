//
//  WheaterAttributes.swift
//  wheater
//
//  蔚来车况 灵动岛 / 实时活动 (Live Activity) 数据属性模型
//  本文件同时编译进 App 与 Widget Extension 两个 target，
//  主题令牌（AnimeThemeToken）亦在此定义以供两端共享。
//

import SwiftUI
import ActivityKit

struct WheaterAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        // 车辆基础状态
        var vehicleName: String
        var soc: Double              // 电量百分比 e.g. 78.5
        var remainingRangeKm: Int     // 剩余续航 e.g. 420
        var actualRangeKm: Int?       // 实际估算续航 e.g. 330
        var mileageKm: Int?           // 总里程

        // 充电与行车状态
        var isCharging: Bool
        var chargeStateText: String  // e.g. "直流快充中", "慢充中", "未充电", "已充满"
        var chargingPowerKw: Double? // e.g. 68.5
        var isDriving: Bool?         // 是否行驶中

        // 车锁与车门车窗
        var isLocked: Bool
        var anyDoorOpen: Bool
        var anyWindowOpen: Bool?

        // 胎压 (bar)
        var tyrePressFL: Double?
        var tyrePressFR: Double?
        var tyrePressRL: Double?
        var tyrePressRR: Double?

        // 座舱与模式
        var insideTemp: Double?      // 车内温度
        var outsideTemp: Double?     // 车外温度
        var defenderActive: Bool     // 守卫模式
        var defenderWarnCount: Int?  // 守卫告警数
        var petModeActive: Bool      // 宠物模式
        var campModeActive: Bool     // 露营模式
        var powerHoldActive: Bool    // 离车不下电
        var frdgActive: Bool?        // 车载冰箱
        var frdgTemp: Double?        // 冰箱当前温
        var v2lActive: Bool?         // 对外放电
        // 特殊模式（可选字段，旧负载缺省安全解码为 nil）
        var hiDryActive: Bool?       // 超强干燥（座舱高温干燥）cbn_hi_t_dry_sts
        var defrostActive: Bool?     // 极速除霜 ccu_max_defrst_sts
        var overheatProtectActive: Bool? // 座舱过热保护 cbn_ovr_ht_act_sts

        // 更新时间
        var updateTimestamp: Date

        // v4.8 扩展字段（可选：兼容旧活动负载，缺省安全解码为 nil）
        var themeRaw: String?            // 当前主题 rawValue，Widget据此渲染主题色
        var chargingTargetSoc: Double?   // 充电目标电量（上限/锁电），e.g. 90
        var batteryCapacityKwh: Double?  // 电池包容量推算，e.g. 75
        var chargeEtaDate: Date?         // 预计充满时刻（用于免刷新实时倒计时）
        var lvBattSoc: Int?              // 12V 小电瓶电量 %
        var lvBattVolt: Double?          // 12V 小电瓶电压 V
        var vehicleVersion: String?      // 车机固件短版本号 (FOTA，e.g. "5.1.5"，取不到则 nil)
        var preferActualRange: Bool?     // 用户是否偏好实估续航展示模式
        var refreshNotice: String?       // 最近一次刷新结果标签（"已更新"/"无数据更新"），Widget 与锁屏实时活动展示

        // 辅助格式化
        var socDisplay: String {
            guard soc.isFinite else { return "--" }
            if let whole = soc.safeInt, soc == soc.rounded() {
                return "\(whole)%"
            }
            return "\(String(format: "%.1f", soc))%"
        }

        var rangeDisplay: String {
            "\(remainingRangeKm)km"
        }

        var tempDisplay: String {
            if let t = insideTemp {
                return String(format: "%.1f℃", t)
            }
            return "—"
        }

        var powerDisplay: String? {
            guard let p = chargingPowerKw, p > 0 else { return nil }
            return String(format: "%.1f kW", p)
        }

        /// 充满剩余分钟数（依据功率与电池容量推算）
        var chargeEtaMinutes: Int? {
            guard isCharging, let p = chargingPowerKw, p > 0.3, p.isFinite else { return nil }
            let capacity = batteryCapacityKwh ?? 75.0
            let target = min(100.0, chargingTargetSoc ?? 100.0)
            let remainKwh = max(0.0, (target - soc) / 100.0 * capacity)
            guard remainKwh.isFinite, remainKwh > 0.2 else { return 0 }
            return (remainKwh / p * 60.0).rounded(.up).safeInt
        }

        /// 用于去重的"显著变化"指纹（忽略时间戳与主题等非关键差异）
        var significantFingerprint: String {
            [
                String(format: "%.1f", soc),
                "\(remainingRangeKm)",
                "\(actualRangeKm ?? -1)",
                isCharging ? "c" : "-",
                chargeStateText,
                String(format: "%.1f", chargingPowerKw ?? -1),
                isDriving.map { $0 ? "d" : "-" } ?? "?",
                isLocked ? "L" : "u",
                anyDoorOpen ? "D" : "-",
                (anyWindowOpen ?? false) ? "W" : "-",
                String(format: "%.1f", tyrePressFL ?? -1),
                String(format: "%.1f", tyrePressFR ?? -1),
                String(format: "%.1f", tyrePressRL ?? -1),
                String(format: "%.1f", tyrePressRR ?? -1),
                String(format: "%.1f", insideTemp ?? -99),
                String(format: "%.1f", outsideTemp ?? -99),
                defenderActive ? "G\(defenderWarnCount ?? 0)" : "-",
                petModeActive ? "P" : "-",
                campModeActive ? "C" : "-",
                powerHoldActive ? "H" : "-",
                (frdgActive ?? false) ? "F" : "-",
                (v2lActive ?? false) ? "V" : "-",
                (hiDryActive ?? false) ? "Y" : "-",
                (defrostActive ?? false) ? "Z" : "-",
                (overheatProtectActive ?? false) ? "O" : "-",
                lvBattSoc.map { "\($0)" } ?? "-",
                vehicleVersion ?? "-",
                chargeEtaDate.map { "\(Int($0.timeIntervalSince1970 / 300))" } ?? "-",
                // 刷新结果标签纳入指纹：标签翻转（已更新↔无数据更新）即触发一次推送，
                // 保证 Widget / 锁屏实时活动的标签始终反映最近一轮拉取结果
                refreshNotice ?? "-"
            ].joined(separator: "|")
        }
    }

    // 静态标识属性
    var vehicleId: String
}

// MARK: - 主题令牌（App 与 Widget 共享的唯一定义）
// 字段以 hex 字符串存储，两端各自解析，避免依赖 app-only 的扩展。

public struct AnimeThemeToken: Codable, Sendable, Equatable {
    public var backgroundPrimary: String
    public var backgroundSecondary: String
    public var accentColor: String
    public var glowColor: String
    public var warmAccent: String
    public var gradientStart: String
    public var gradientEnd: String
    public var cardBackground: String
    public var cardBorder: String
    public var textPrimary: String
    public var textSecondary: String
    public var isDark: Bool

    public init(
        backgroundPrimary: String,
        backgroundSecondary: String,
        accentColor: String,
        glowColor: String,
        warmAccent: String,
        gradientStart: String,
        gradientEnd: String,
        cardBackground: String,
        cardBorder: String,
        textPrimary: String,
        textSecondary: String,
        isDark: Bool
    ) {
        self.backgroundPrimary = backgroundPrimary
        self.backgroundSecondary = backgroundSecondary
        self.accentColor = accentColor
        self.glowColor = glowColor
        self.warmAccent = warmAccent
        self.gradientStart = gradientStart
        self.gradientEnd = gradientEnd
        self.cardBackground = cardBackground
        self.cardBorder = cardBorder
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.isDark = isDark
    }

    // ── 二次元 ─────────────────────────────────────────────

    /// 蜜桃兔兔 · 浅色（参考 YumikoToys 主站浅藕荷粉紫风）
    public static let kawaiiLight = AnimeThemeToken(
        backgroundPrimary:   "EEF1FB",
        backgroundSecondary: "E4E9F8",
        accentColor:         "FF6F9F",
        glowColor:           "7C6CEB",
        warmAccent:          "F59E42",
        gradientStart:       "FF7AA8",
        gradientEnd:         "9A8CF8",
        cardBackground:      "FFFFFF",
        cardBorder:          "DFE4F5",
        textPrimary:         "322B4D",
        textSecondary:       "6E6795",
        isDark:              false
    )

    /// 樱夜粉兔 · 深色（软萌草莓夜）
    public static let kawaii = AnimeThemeToken(
        backgroundPrimary:   "1D1220",
        backgroundSecondary: "28182C",
        accentColor:         "FF7597",
        glowColor:           "FFB3C6",
        warmAccent:          "FFB703",
        gradientStart:       "FF7597",
        gradientEnd:         "B79CFF",
        cardBackground:      "2A1A2E",
        cardBorder:          "45273F",
        textPrimary:         "FFF3F6",
        textSecondary:       "E4B9CD",
        isDark:              true
    )

    /// 抹茶奶盖 · 浅色（日系治愈）
    public static let healing = AnimeThemeToken(
        backgroundPrimary:   "F2F7EE",
        backgroundSecondary: "E7F0E0",
        accentColor:         "3E8E52",
        glowColor:           "2E8C7A",
        warmAccent:          "D98E1F",
        gradientStart:       "5CB46E",
        gradientEnd:         "E8C46A",
        cardBackground:      "FFFFFF",
        cardBorder:          "DCE8D4",
        textPrimary:         "2C3A26",
        textSecondary:       "66785C",
        isDark:              false
    )

    // ── 简洁 ─────────────────────────────────────────────

    /// 云石膏 · 浅色（极简单色）
    public static let minimalLight = AnimeThemeToken(
        backgroundPrimary:   "F6F7F9",
        backgroundSecondary: "ECEEF2",
        accentColor:         "3E6DF0",
        glowColor:           "5E76C9",
        warmAccent:          "D9822B",
        gradientStart:       "3E6DF0",
        gradientEnd:         "7FA8F5",
        cardBackground:      "FFFFFF",
        cardBorder:          "E3E6EC",
        textPrimary:         "1B1F2A",
        textSecondary:       "5F6675",
        isDark:              false
    )

    /// 曜石灰 · 深色（极简单色）
    public static let minimalDark = AnimeThemeToken(
        backgroundPrimary:   "0F1013",
        backgroundSecondary: "17181C",
        accentColor:         "4D9FFF",
        glowColor:           "9AB0C8",
        warmAccent:          "E0A34D",
        gradientStart:       "4D9FFF",
        gradientEnd:         "7CC4FF",
        cardBackground:      "191B20",
        cardBorder:          "2A2D34",
        textPrimary:         "F2F4F8",
        textSecondary:       "9AA3B2",
        isDark:              true
    )

    // ── 酷 ─────────────────────────────────────────────

    /// 赛博霓虹 · 深色（电光青 × 品红）
    public static let cyber = AnimeThemeToken(
        backgroundPrimary:   "07090F",
        backgroundSecondary: "0E1320",
        accentColor:         "00F0FF",
        glowColor:           "FF2E97",
        warmAccent:          "FFB84D",
        gradientStart:       "00F0FF",
        gradientEnd:         "8B5CF6",
        cardBackground:      "10141F",
        cardBorder:          "26304A",
        textPrimary:         "F5F9FF",
        textSecondary:       "8FA1C0",
        isDark:              true
    )

    /// 暮光星野 · 深色（新海诚式暮蓝 × 落日玫瑰）
    public static let makoto = AnimeThemeToken(
        backgroundPrimary:   "0D1526",
        backgroundSecondary: "16233B",
        accentColor:         "45B8F8",
        glowColor:           "F96D9C",
        warmAccent:          "FFB86B",
        gradientStart:       "45B8F8",
        gradientEnd:         "F65678",
        cardBackground:      "18263F",
        cardBorder:          "2B3D5E",
        textPrimary:         "F4F8FF",
        textSecondary:       "93A7C7",
        isDark:              true
    )

    public static let defaultToken: AnimeThemeToken = .kawaiiLight

    /// 以 rawValue 字符串取预设（未知名回退默认主题）
    public static func preset(named raw: String?) -> AnimeThemeToken {
        switch raw {
        case "kawaiiLight":  return .kawaiiLight
        case "kawaii":       return .kawaii
        case "healing":      return .healing
        case "minimalLight": return .minimalLight
        case "minimalDark":  return .minimalDark
        case "cyber":        return .cyber
        case "makoto":       return .makoto
        default:             return .defaultToken
        }
    }
}

// MARK: - Widget 侧主题色解析

public struct WheaterThemeColors: Sendable {
    public let background: Color
    public let backgroundSoft: Color
    public let accent: Color
    public let glow: Color
    public let warm: Color
    public let gradientStart: Color
    public let gradientEnd: Color
    public let cardFill: Color
    public let cardStroke: Color
    public let text: Color
    public let textSoft: Color
    public let isDark: Bool

    public init(token: AnimeThemeToken) {
        background = Color(wheaterHex: token.backgroundPrimary)
        backgroundSoft = Color(wheaterHex: token.backgroundSecondary)
        accent = Color(wheaterHex: token.accentColor)
        glow = Color(wheaterHex: token.glowColor)
        warm = Color(wheaterHex: token.warmAccent)
        gradientStart = Color(wheaterHex: token.gradientStart)
        gradientEnd = Color(wheaterHex: token.gradientEnd)
        cardFill = Color(wheaterHex: token.cardBackground)
        cardStroke = Color(wheaterHex: token.cardBorder)
        text = Color(wheaterHex: token.textPrimary)
        textSoft = Color(wheaterHex: token.textSecondary)
        isDark = token.isDark
    }

    public init(themeRaw: String?) {
        self.init(token: .preset(named: themeRaw))
    }

    /// 电量进度条用渐变
    public var socGradient: [Color] { [gradientStart, gradientEnd] }
}

public extension Double {
    /// NaN / Infinity / 越界安全转 Int：脏数据返回 nil 而非直接 trap
    /// （`Int(Double)` 对非有限值会崩溃；服务端脏字段（"nan"/"1e400"）经此防护）
    var safeInt: Int? {
        guard isFinite, self >= Double(Int.min), self <= Double(Int.max) else { return nil }
        return Int(self)
    }
}

public extension Color {
    /// 独立命名的 hex 初始化器，避免与 app target 既有 Color(hex:) 冲突
    init(wheaterHex hex: String) {
        let h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch h.count {
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }
}

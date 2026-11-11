//
//  NIOLaunchStyle.swift
//  wheater
//
//  启动动画系统 v5.0 · 多风格可选
//  · 能量充能（默认）：电池环 0→100% 充能 + 电弧凝聚 Logo
//  · 像素重制：15x15 点阵波次点亮 → 高清 Logo（见 NIOPixelLaunchSplashView）
//  · 极简快启：Logo 淡入 + 细进度线，≤1.1s 直达看板
//  省电动效模式（nio_reduced_fx）开启时强制极简快启。
//

import SwiftUI
import UIKit

// MARK: - 设置键与工具

enum NIOBootSettings {
    static let styleKey = "nio_boot_style"
    static let paceKey = "nio_boot_pace"
    static let hapticsKey = "nio_boot_haptics"
    static let dailyOnceKey = "nio_boot_daily_once"
    static let lastShownKey = "nio_boot_last_shown"

    /// 今日戳格式化器（静态缓存，避免每次调用重复创建）
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 今日戳（用于"每日一次"判定）
    static var todayStamp: String {
        stampFormatter.string(from: Date())
    }
}

// MARK: - 启动动画风格

enum NIOBootStyle: String, CaseIterable, Codable, Identifiable {
    case energyCharge   // 能量充能（默认）
    case pixelRemaster  // 像素重制 v5
    case minimalFast    // 极简快启

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .energyCharge:  return "能量充能"
        case .pixelRemaster: return "像素重制"
        case .minimalFast:   return "极简快启"
        }
    }

    var styleDescription: String {
        switch self {
        case .energyCharge:  return "电池环充能 · 星流汇聚"
        case .pixelRemaster: return "点阵点亮 · 复古像素"
        case .minimalFast:   return "一步到位 · 极速直达"
        }
    }

    var icon: String {
        switch self {
        case .energyCharge:  return "battery.100.bolt"
        case .pixelRemaster: return "square.grid.3x3.middle.filled"
        case .minimalFast:   return "hare.fill"
        }
    }

    /// 当前生效风格（省电动效强制极简）
    static var effective: NIOBootStyle {
        if UserDefaults.standard.bool(forKey: "nio_reduced_fx") { return .minimalFast }
        let raw = UserDefaults.standard.string(forKey: NIOBootSettings.styleKey)
        return NIOBootStyle(rawValue: raw ?? "") ?? .energyCharge
    }
}

// MARK: - 节奏（标准 / 疾速）

enum NIOBootPace: String, CaseIterable, Codable, Identifiable {
    case standard
    case swift

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "标准"
        case .swift:    return "疾速"
        }
    }

    /// 时间缩放系数
    var scale: Double {
        switch self {
        case .standard: return 1.0
        case .swift:    return 0.55
        }
    }

    /// 缩放后的时长
    func t(_ seconds: Double) -> Double { seconds * scale }

    /// 当前生效节奏
    static var current: NIOBootPace {
        NIOBootPace(rawValue: UserDefaults.standard.string(forKey: NIOBootSettings.paceKey) ?? "") ?? .standard
    }
}

// MARK: - 触感反馈

@MainActor
enum NIOBootHaptics {
    /// 尊重用户开关的触感反馈（默认开启）
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        let enabled = UserDefaults.standard.object(forKey: NIOBootSettings.hapticsKey) as? Bool ?? true
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - 主题开屏人设（三套风格共享）

struct NIOBootPersona {
    let topLabel: String
    let subtitle: String
    let statusEmoji: String
    let glowStrength: Double
    let subtitleMono: Bool

    static func forTheme(_ style: AnimeThemeStyle) -> NIOBootPersona {
        switch style {
        case .kawaiiLight:
            return NIOBootPersona(topLabel: "YUMIKOTOYS", subtitle: "正在唤醒兔可可的粉色小屋…", statusEmoji: "🥕", glowStrength: 1.0, subtitleMono: false)
        case .kawaii:
            return NIOBootPersona(topLabel: "YUMIKOTOYS", subtitle: "樱夜充电桩已就绪，兔兔上线中…", statusEmoji: "🌙", glowStrength: 1.0, subtitleMono: false)
        case .healing:
            return NIOBootPersona(topLabel: "YUMIKOTOYS", subtitle: "抹茶能量注入中，爱车苏醒…", statusEmoji: "🌿", glowStrength: 1.0, subtitleMono: false)
        case .minimalLight, .minimalDark:
            return NIOBootPersona(topLabel: "YUMIKOTOYS", subtitle: "正在启动 YumikoToysRR", statusEmoji: "◦", glowStrength: 0.0, subtitleMono: false)
        case .cyber:
            return NIOBootPersona(topLabel: "SYSTEM BOOT", subtitle: "正在建立 NIO 数据链路…", statusEmoji: "⚡️", glowStrength: 1.3, subtitleMono: true)
        case .makoto:
            return NIOBootPersona(topLabel: "YUMIKOTOYS", subtitle: "正在穿越暮光星野接近爱车…", statusEmoji: "☁️", glowStrength: 1.0, subtitleMono: false)
        }
    }
}

// MARK: - 共享跳过按钮（能量 / 极简风格用）

struct NIOBootSkipOverlay: View {
    @Binding var isFinished: Bool
    let visible: Bool
    @ObservedObject private var themeService = AnimeThemeService.shared

    private var token: AnimeThemeToken { themeService.currentToken }
    private var text: Color { Color(hex: token.textPrimary) }
    private var accent: Color { Color(hex: token.accentColor) }
    private var isDark: Bool { token.isDark }

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.28)) { isFinished = true }
                }) {
                    HStack(spacing: 4) {
                        Text("进入看板")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.05))
                    .foregroundStyle(text.opacity(0.9))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(accent.opacity(0.4), lineWidth: 0.8))
                }
            }
            .padding(.top, 50)
            .padding(.trailing, 20)
            Spacer()
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: 0.3), value: visible)
    }
}

// MARK: - 启动动画路由器

/// 按设置路由到对应风格的开屏动画，含"每日一次"闸门。
struct NIOLaunchSplashView: View {
    @Binding var isFinished: Bool
    /// 预览模式：跳过每日一次闸门
    var bypassGate = false

    @AppStorage(NIOBootSettings.styleKey) private var styleRaw = NIOBootStyle.energyCharge.rawValue
    @AppStorage("nio_reduced_fx") private var reducedFx = false
    @AppStorage(NIOBootSettings.dailyOnceKey) private var dailyOnce = false
    @AppStorage(NIOBootSettings.lastShownKey) private var lastShown = ""
    @ObservedObject private var themeService = AnimeThemeService.shared

    private var effectiveStyle: NIOBootStyle {
        if reducedFx { return .minimalFast }
        return NIOBootStyle(rawValue: styleRaw) ?? .energyCharge
    }

    private var gateAllowsShow: Bool {
        guard !bypassGate, dailyOnce else { return true }
        return lastShown != NIOBootSettings.todayStamp
    }

    var body: some View {
        ZStack {
            Color(hex: themeService.currentToken.backgroundPrimary)
                .ignoresSafeArea()

            if gateAllowsShow {
                content
                    .transition(.opacity)
            }
        }
        .onAppear {
            if gateAllowsShow {
                UserDefaults.standard.set(NIOBootSettings.todayStamp, forKey: NIOBootSettings.lastShownKey)
            } else {
                isFinished = true
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch effectiveStyle {
        case .energyCharge:
            NIOEnergyBootView(isFinished: $isFinished)
        case .pixelRemaster:
            NIOPixelLaunchSplashView(isFinished: $isFinished)
        case .minimalFast:
            NIOMinimalBootView(isFinished: $isFinished)
        }
    }
}

// MARK: - 可取消的延时任务集合

/// 启动动画序列的延时调度助手：所有 `DispatchQueue.main.asyncAfter` 统一经此排队，
/// 视图消失（用户跳过开屏 / 预览结束）时整体 cancel，避免向已脱离层级的 @State 脏写
final class NIOScheduledWork: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DispatchWorkItem] = []

    func schedule(after seconds: TimeInterval, _ body: @escaping () -> Void) {
        let work = DispatchWorkItem(block: body)
        lock.lock()
        items.append(work)
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// 取消此前所有未触发任务后再调度（防连点堆叠定时器）
    func scheduleReplacing(after seconds: TimeInterval, _ body: @escaping () -> Void) {
        cancelAll()
        schedule(after: seconds, body)
    }

    func cancelAll() {
        lock.lock()
        let all = items
        items.removeAll()
        lock.unlock()
        all.forEach { $0.cancel() }
    }
}

//
//  NIOHomeWidgets.swift
//  WheaterStatus
//
//  桌面车况小组件 (v5.3.0)
//  · 小尺寸：电量 / 续航 / 充电或车锁状态 / 温度 / 模式徽章 / 更新时间
//  · 中尺寸：灵动岛数据全量搬入 —— 电量/续航/温度/里程/12V/胎压占位/模式/充电详情
//  · 数据源：App Group 车况快照（主 App 每次刷新车况自动写入）
//  · 主题色：根据 isDark 强制对比度，浅色主题用深色字、深色主题用浅色字
//

import WidgetKit
import SwiftUI

// MARK: - 时间线

struct WheaterVehicleSnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WheaterVehicleSnapshot?
}

struct WheaterVehicleSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> WheaterVehicleSnapshotEntry {
        WheaterVehicleSnapshotEntry(date: Date(), snapshot: WheaterVehicleSnapshot.demo)
    }

    func getSnapshot(in context: Context, completion: @escaping (WheaterVehicleSnapshotEntry) -> Void) {
        let snap = WheaterVehicleSnapshot.load() ?? (context.isPreview ? WheaterVehicleSnapshot.demo : nil)
        completion(WheaterVehicleSnapshotEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WheaterVehicleSnapshotEntry>) -> Void) {
        let snap = WheaterVehicleSnapshot.load()
        let now = Date()
        let entry = WheaterVehicleSnapshotEntry(date: now, snapshot: snap)

        // 省电模式会大幅压缩 WidgetKit 刷新预算，导致小组件长时间停在旧数据。
        // 充电时预生成一系列"预测电量"时间线条目（按功率线性内插到限充值），
        // 即使系统迟迟不触发 reload，小组件也能随时间自动推进电量显示；
        // 非充电时仅当前条目 + 30 分钟后重载。
        var entries: [WheaterVehicleSnapshotEntry] = [entry]
        var reloadInterval = 1800
        if let s = snap, s.isCharging, let eta = s.chargeEtaDate, eta.timeIntervalSince(now) > 120,
           let target = s.chargingTargetSoc, target > s.soc {
            // 按 SOC 线性内插（功率推算已由主 App 完成，此处仅时间维度的平滑推进）
            let totalSeconds = eta.timeIntervalSince(now)
            let step: TimeInterval = min(600, max(300, totalSeconds / 8))
            var t = step
            while t < totalSeconds && entries.count < 12 {
                let predicted = min(target, s.soc + (target - s.soc) * (t / totalSeconds))
                var projected = s
                projected.soc = (predicted * 10).rounded() / 10
                entries.append(WheaterVehicleSnapshotEntry(date: now.addingTimeInterval(t), snapshot: projected))
                t += step
            }
            // 终点条目：到达限充
            var done = s
            done.soc = target
            entries.append(WheaterVehicleSnapshotEntry(date: eta, snapshot: done))
            // 充电中刷新预算被压缩，仍尽量请求短间隔重载以跟进真实功率/ETA
            reloadInterval = 600
        }

        let next = Calendar.current.date(byAdding: .second, value: reloadInterval, to: now)
            ?? now.addingTimeInterval(1800)
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

// MARK: - Widget 注册

struct NIOVehicleStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.YumikoToysRR.wheater.VehicleStatus", provider: WheaterVehicleSnapshotProvider()) { entry in
            NIOVehicleWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("蔚来车况")
        .description("电量、续航、充电与车锁速览（打开 App 自动同步）")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - 视图

/// 统一规格的元信息小胶囊：同字号 / 同图标 / 同内边距，保证底部行两端视觉对齐
func widgetMetaPill(icon: String, text: String, theme: WheaterThemeColors) -> some View {
    HStack(spacing: 2.5) {
        Image(systemName: icon)
            .font(.system(size: 7, weight: .semibold))
        Text(text)
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .lineLimit(1)
    }
    .foregroundStyle(theme.textSoft.opacity(0.85))
    .padding(.horizontal, 5)
    .padding(.vertical, 2)
    .background(theme.text.opacity(theme.isDark ? 0.08 : 0.05))
    .clipShape(Capsule())
}

struct NIOVehicleWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WheaterVehicleSnapshotEntry

    var body: some View {
        Group {
            if let snap = entry.snapshot {
                if family == .systemSmall {
                    NIOVehicleSmallView(snap: snap)
                } else {
                    NIOVehicleMediumView(snap: snap)
                }
            } else {
                NIOVehicleEmptyView()
            }
        }
    }
}

/// 无数据占位
struct NIOVehicleEmptyView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image("NIO_brand")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
            Text("打开 App 同步车况")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(wheaterHex: "EEF1FB"), Color(wheaterHex: "E4E9F8")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - 小尺寸

/// 小尺寸：电量 + 续航 + 状态 + 温度 + 模式徽章 + 电量条 + 更新时间
struct NIOVehicleSmallView: View {
    let snap: WheaterVehicleSnapshot
    private var theme: WheaterThemeColors { WheaterThemeColors(themeRaw: snap.themeRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部：车辆图标 + 在线状态 + 状态图标
            HStack(spacing: 4) {
                Image("NIO_brand")
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                    .foregroundStyle(theme.textSoft)
                if snap.vehicleVersion != nil {
                    Text("在线")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textSoft)
                }
                Spacer()
                statusIcon
            }

            Spacer(minLength: 0)

            // 电量大字
            Text(socText)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(theme.text)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            Text("续航 \(snap.remainingRangeKm) km")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSoft)

            // 状态行：充电/车锁 + 温度
            HStack(spacing: 6) {
                Text(stateText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(snap.isCharging ? theme.warm : theme.textSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let t = snap.insideTemp {
                    Text(String(format: "%.0f℃", t))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSoft)
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)

            // 模式徽章行（紧凑）
            if hasActiveMode {
                HStack(spacing: 3) {
                    if snap.defenderActive { miniBadge("守卫", color: .pink) }
                    if snap.petModeActive { miniBadge("宠物", color: .orange) }
                    if snap.campModeActive { miniBadge("露营", color: .purple) }
                    if snap.powerHoldActive { miniBadge("不下电", color: .blue) }
                    if snap.v2lActive ?? false { miniBadge("放电", color: .yellow) }
                    if snap.hiDryActive ?? false { miniBadge("干燥", color: .orange) }
                    if snap.defrostActive ?? false { miniBadge("除霜", color: .cyan) }
                    if snap.overheatProtectActive ?? false { miniBadge("过热保护", color: .red) }
                }
                .padding(.top, 2)
            }

            // 电量条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.text.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: theme.socGradient, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * CGFloat(min(1.0, max(0.0, snap.soc.isFinite ? snap.soc / 100.0 : 0.0)))))
                    // 充电目标刻度
                    if snap.isCharging, let target = snap.chargingTargetSoc, target > 1, target < 100 {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(theme.text.opacity(0.6))
                            .frame(width: 2, height: 6)
                            .offset(x: geo.size.width * CGFloat(target / 100) - 1)
                    }
                }
            }
            .frame(height: 6)
            .padding(.top, 5)

        // 底部行：12V 或 充电ETA + 刷新结果标签 + 更新时间
        HStack(spacing: 4) {
            if snap.isCharging, let eta = snap.chargeEtaDate {
                let min = Int(eta.timeIntervalSinceNow / 60)
                if min > 0 {
                    Text(min >= 60 ? "\(min/60)时\(min%60)分" : "\(min)分")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.warm)
                }
            } else if let lv = snap.lvBattSoc, lv > 0, lv < 30 {
                Text("12V \(lv)%")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            Spacer()
            if let notice = snap.refreshNotice, !notice.isEmpty {
                Text(notice)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(notice == "已更新" ? Color.green : theme.textSoft.opacity(0.8))
                    .lineLimit(1)
            }
            Text(updatedText)
                .font(.system(size: 9))
                .foregroundStyle(theme.textSoft.opacity(0.8))
        }
        .padding(.top, 3)
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [theme.background, theme.backgroundSoft],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var socText: String {
        guard snap.soc.isFinite else { return "--" }
        if let whole = snap.soc.safeInt, snap.soc == snap.soc.rounded() {
            return "\(whole)%"
        }
        return String(format: "%.1f%%", snap.soc)
    }

    private var stateText: String {
        if snap.isCharging {
            if let p = snap.chargingPowerKw, p > 0 {
                return String(format: "充电中 %.1f kW", p)
            }
            return "充电中"
        }
        if let target = snap.chargingTargetSoc {
            return "\(snap.isLocked ? "已上锁" : "未上锁") · 限充 \(Int(target))%"
        }
        return snap.isLocked ? "已上锁" : "未上锁"
    }

    private var hasActiveMode: Bool {
        snap.defenderActive || snap.petModeActive || snap.campModeActive || snap.powerHoldActive
            || (snap.v2lActive ?? false) || (snap.hiDryActive ?? false)
            || (snap.defrostActive ?? false) || (snap.overheatProtectActive ?? false)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if snap.isCharging {
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.warm)
        } else if snap.isLocked {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSoft)
        } else {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)
        }
    }

    private func miniBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(theme.isDark ? 0.18 : 0.12)))
    }

    private var updatedText: String {
        // 跟随主 App 首页的更新时间（同一数据源 lastVehicleFetch，同一精确时刻格式）。
        // 相对文案会被 WidgetKit 时间线冻结在构建时刻，最长 30 分钟不更新，故弃用。
        "更新 " + snap.updatedAt.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - 中尺寸

/// 中尺寸：灵动岛数据全量搬入 —— 左侧电量主区 + 右侧多行信息网格
struct NIOVehicleMediumView: View {
    let snap: WheaterVehicleSnapshot
    private var theme: WheaterThemeColors { WheaterThemeColors(themeRaw: snap.themeRaw) }

    var body: some View {
        VStack(spacing: 8) {
        HStack(alignment: .top, spacing: 14) {
            // 左：电量与续航主区
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image("NIO_brand")
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                        .foregroundStyle(theme.textSoft)
                    Text(snap.vehicleName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textSoft)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)

                Text("\(snap.soc.safeInt ?? 0)%")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.text)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                Text("续航 \(snap.remainingRangeKm) km")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.textSoft)

                // 副续航：实估优先时 actualRangeKm 实为 CLTC，主续航已显示实估，隐藏避免混淆；
                // 非实估优先时 actualRangeKm 为实估，才显示"实估"
                if snap.preferActualRange != true, let act = snap.actualRangeKm, act > 0 {
                    Text("实估 \(act) km")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.glow.opacity(theme.isDark ? 0.9 : 1.0))
                        .padding(.top, 1)
                }

                // 电量条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.text.opacity(0.12))
                        Capsule()
                            .fill(LinearGradient(colors: theme.socGradient, startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, geo.size.width * CGFloat(min(1.0, max(0.0, snap.soc.isFinite ? snap.soc / 100.0 : 0.0)))))
                        if snap.isCharging, let target = snap.chargingTargetSoc, target > 1, target < 100 {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(theme.text.opacity(0.6))
                                .frame(width: 2, height: 7)
                                .offset(x: geo.size.width * CGFloat(target / 100) - 1)
                        }
                    }
                }
                .frame(height: 7)
                .padding(.top, 6)

                // 底部补充行
                Text(leftFootnote)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textSoft.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.top, 5)
            }
            .frame(width: 112)

            // 右：信息网格（与灵动岛数据对齐）
            VStack(alignment: .leading, spacing: 6) {
                // 行1：充电或车锁 + 模式徽章
                HStack(spacing: 5) {
                    if snap.isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.warm)
                        Text(powerText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        Image(systemName: snap.isLocked ? "lock.fill" : "lock.open.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(snap.isLocked ? theme.textSoft : theme.accent)
                        Text(snap.isLocked ? "已上锁" : "未上锁")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.text)
                    }
                    Spacer(minLength: 4)
                    modeBadges
                }

                // 行2：车内外温度
                HStack(spacing: 10) {
                    if let t = snap.insideTemp {
                        Label(String(format: "%.0f℃", t), systemImage: "thermometer.medium")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSoft)
                    }
                    if let t = snap.outsideTemp {
                        Label(String(format: "%.0f℃", t), systemImage: "cloud.sun.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSoft)
                    }
                    Spacer(minLength: 0)
                }

                // 行3：总里程 + 12V电瓶
                HStack(spacing: 10) {
                    if let m = snap.mileageKm {
                        Label("\(m) km", systemImage: "road.lanes")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSoft)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    if let lv = snap.lvBattSoc, lv > 0 {
                        Label("\(lv)%", systemImage: "car.side.fill")
                            .font(.system(size: 10, weight: lv < 30 ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(lv < 30 ? .orange : theme.textSoft)
                    }
                    Spacer(minLength: 0)
                }

                // 行4：胎压（四轮）
                if let fl = snap.tyrePressFL, fl > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "tirepressure")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.textSoft)
                        ForEach(Array(tyrePairs.enumerated()), id: \.offset) { _, pair in
                            Text(pair)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.textSoft)
                        }
                        Spacer(minLength: 0)
                    }
                }

                // 行5：充电详情（仅充电时显示）
                if snap.isCharging {
                    HStack(spacing: 6) {
                        Text(snap.chargeStateText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.warm)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let eta = snap.chargeEtaDate {
                            let min = Int(eta.timeIntervalSinceNow / 60)
                            if min > 0 {
                                Text("· \(min >= 60 ? "\(min/60)时\(min%60)分" : "\(min)分")")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(theme.warm)
                            }
                        }
                        Spacer()
                    }
                }

            }
        }

        // 底部行：车机版本 + 刷新结果标签 + 更新时间（横跨全宽，左缘与电量条左缘对齐）
        HStack(spacing: 5) {
            if let ver = snap.vehicleVersion, !ver.isEmpty {
                widgetMetaPill(icon: "cpu", text: ver, theme: theme)
            }
            if let notice = snap.refreshNotice, !notice.isEmpty {
                widgetMetaPill(
                    icon: notice == "已更新" ? "checkmark.circle" : "tray.full",
                    text: notice,
                    theme: theme
                )
            }
            Spacer()
            widgetMetaPill(icon: "clock", text: updatedText, theme: theme)
        }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [theme.background, theme.backgroundSoft],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var leftFootnote: String {
        if snap.isCharging {
            if let target = snap.chargingTargetSoc {
                return "限充 \(Int(target))%"
            }
            return "充电中"
        } else if let volt = snap.lvBattVolt {
            return String(format: "12V %.1f V", volt)
        }
        return ""
    }

    /// 胎压配对文本：前/后各一行，格式 "前 2.5/2.5"
    private var tyrePairs: [String] {
        var pairs: [String] = []
        let fl = snap.tyrePressFL ?? 0
        let fr = snap.tyrePressFR ?? 0
        let rl = snap.tyrePressRL ?? 0
        let rr = snap.tyrePressRR ?? 0
        if fl > 0 || fr > 0 {
            pairs.append(String(format: "前 %.1f/%.1f", fl, fr))
        }
        if rl > 0 || rr > 0 {
            pairs.append(String(format: "后 %.1f/%.1f", rl, rr))
        }
        return pairs
    }

    private var powerText: String {
        if let p = snap.chargingPowerKw, p > 0 {
            return String(format: "%.1f kW", p)
        }
        return "充电中"
    }

    @ViewBuilder
    private var modeBadges: some View {
        if snap.defenderActive || snap.petModeActive || snap.campModeActive || snap.powerHoldActive
            || (snap.v2lActive ?? false) || (snap.hiDryActive ?? false)
            || (snap.defrostActive ?? false) || (snap.overheatProtectActive ?? false) {
            HStack(spacing: 4) {
                if snap.defenderActive { badge("守卫", "shield.fill", .pink) }
                if snap.petModeActive { badge("宠物", "pawprint.fill", .orange) }
                if snap.campModeActive { badge("露营", "tent.fill", .purple) }
                if snap.powerHoldActive { badge("不下电", "bolt.badge.clock.fill", .blue) }
                if snap.v2lActive ?? false { badge("放电", "powerplug.fill", .yellow) }
                if snap.hiDryActive ?? false { badge("干燥", "heat.waves", .orange) }
                if snap.defrostActive ?? false { badge("除霜", "windshield.front.defrost", .cyan) }
                if snap.overheatProtectActive ?? false { badge("过热保护", "thermometer.sun.fill", .red) }
            }
        }
    }

    private func badge(_ text: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
            Text(text)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(theme.isDark ? 0.16 : 0.12)))
    }

    private var updatedText: String {
        // 与主 App 首页同源的精确更新时刻（相对文案会被时间线冻结，见小尺寸同处注释）
        snap.updatedAt.formatted(date: .omitted, time: .shortened) + " 更新"
    }
}

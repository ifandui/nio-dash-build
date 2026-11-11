//
//  WheaterStatus.swift
//  WheaterStatus
//
//  蔚来车况灵动岛与锁屏实时活动（主题化 · v4.8 重设计）
//  · 三区展开布局：电量/实估续航双数字 + 模式状态 + 进度与告警
//  · 充电时展示实时功率与免刷新充满倒计时（Text 相对时间样式）
//  · 车窗/车门未关好时顶部告警条提示
//  · 锁屏卡片跟随 App 内主题换装（浅色主题自动切换白卡墨字）
//

import WidgetKit
import SwiftUI
import ActivityKit

@main
struct WheaterStatusBundle: WidgetBundle {
    var body: some Widget {
        WheaterStatusLiveActivityWidget()
        WheaterIslandControlWidget()
        NIOVehicleStatusWidget()
    }
}

struct WheaterStatusLiveActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WheaterAttributes.self) { context in
            // MARK: - 锁屏实时活动卡片 (Lock Screen Live Activity)
            LiveActivityLockScreenView(
                state: context.state,
                theme: WheaterThemeColors(themeRaw: context.state.themeRaw)
            )
        } dynamicIsland: { context in
            // MARK: - 灵动岛 (Dynamic Island) · 与 App 主题同步换装
            let state = context.state
            let theme = WheaterThemeColors(themeRaw: state.themeRaw)

            return DynamicIsland {
                // 展开状态：左侧 — 电量大字 + 充电功率 / 实估续航
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(state.socDisplay)
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                                .foregroundStyle(
                                    LinearGradient(colors: theme.socGradient, startPoint: .leading, endPoint: .trailing)
                                )
                            if state.isCharging {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                            }
                        }
                        if state.isCharging, let power = state.powerDisplay {
                            Text(power)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.green)
                        } else if state.preferActualRange != true, let act = state.actualRangeKm, act > 0 {
                            Text("实估 \(act)km")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.glow.opacity(0.95))
                        } else {
                            Text(state.isLocked ? "已上锁 🔒" : "未锁 ⚠️")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(state.isLocked ? .green : .orange)
                        }
                    }
                    .padding(.leading, 2)
                }

                // 展开状态：中央 — 当前模式 / 行车状态 + 充满倒计时
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        islandStatusView(state)
                        if state.isCharging, let eta = state.chargeEtaDate {
                            // 倒计时后缀并入同一 Text：避免相对时间宽度变化时"后"字独立换槽抖动/错位
                            Text("充满 \(eta, style: .relative)后")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.green.opacity(0.9))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                }

                // 展开状态：右侧 — 标称续航大字 + 车内温度 / 锁
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(state.remainingRangeKm)")
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                            Text("km")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        if state.preferActualRange != true, let act = state.actualRangeKm, act > 0 {
                            Text("实估 \(act)km")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.glow.opacity(0.95))
                        } else if let t = state.insideTemp {
                            Text(verbatim: "\(String(format: "车内 %.0f℃", t))")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        } else {
                            Text(state.isLocked ? "已关好" : "门未锁")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(state.isLocked ? .white.opacity(0.7) : .orange)
                        }
                    }
                    .padding(.trailing, 2)
                }

                // 展开状态：底部 — 告警条 + 电量进度条 + 车况数据面板
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 3) {
                        islandAlertRow(state)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.12))
                                Capsule()
                                    .fill(LinearGradient(colors: theme.socGradient, startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(6, geo.size.width * CGFloat(min(1.0, max(0.0, state.soc / 100.0)))))
                                if state.isCharging, let target = state.chargingTargetSoc, target > 1, target < 100 {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.white.opacity(0.9))
                                        .frame(width: 2, height: 6)
                                        .offset(x: geo.size.width * CGFloat(target / 100.0) - 1)
                                }
                            }
                        }
                        .frame(height: 4)

                        // 核心参数行：每项仅在拿到数据时显示（无冰箱/无胎压的车自动隐藏）
                        HStack(spacing: 5) {
                            if let fl = state.tyrePressFL, let fr = state.tyrePressFR, fl > 0, fr > 0 {
                                HStack(spacing: 2) {
                                    Text("🐾")
                                        .font(.system(size: 7))
                                    Text(tyreSummary(state))
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .foregroundStyle(lowTyre(state) != nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(theme.glow.opacity(0.95)))
                                }
                            }
                            if let t = state.outsideTemp {
                                Text(verbatim: "\(String(format: "车外 %.0f℃", t))")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            if state.anyWindowOpen == true {
                                Text("🪟 车窗开")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.orange)
                            }
                            if state.frdgActive == true {
                                Text(frdgLabel(state))
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.cyan)
                            }
                            if state.v2lActive == true {
                                Text("🔌 放电")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.yellow)
                            }
                            if state.hiDryActive == true {
                                Text("♨️ 干燥")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.orange)
                            }
                            if state.defrostActive == true {
                                Text("❄️ 除霜")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.cyan)
                            }
                            if state.overheatProtectActive == true {
                                Text("🌡️ 过热保护")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.red)
                            }
                            if let lv = state.lvBattSoc, lv > 0, lv < 30 {
                                Text("12V \(lv)%")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                        }

                        // 元信息行：车机版本 (独立胶囊) + 总里程 + 刷新时间 (带时钟图标)
                        HStack(spacing: 5) {
                            if let ver = state.vehicleVersion, !ver.isEmpty {
                                HStack(spacing: 2) {
                                    Image(systemName: "cpu")
                                        .font(.system(size: 6.5))
                                    Text(ver)
                                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Color.white.opacity(0.08))
                                .foregroundStyle(.white.opacity(0.6))
                                .clipShape(Capsule())
                            }
                            if let m = state.mileageKm, m > 0 {
                                Text("· \(m)km")
                                    .font(.system(size: 7.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                            Spacer()
                            HStack(spacing: 2.5) {
                                Image(systemName: "clock")
                                    .font(.system(size: 6.5))
                                Text(state.updateTimestamp, style: .time)
                                    .font(.system(size: 7.5, weight: .medium, design: .rounded))
                            }
                            .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                }
            } compactLeading: {
                // 紧凑左侧：纯图标（灵动岛紧凑区极窄，文字会被挖孔裁切）
                // 充电绿闪电 / 低电橙 / 常规主题色电量图形
                Image(systemName: state.isCharging ? "bolt.fill" : compactBatteryIcon(state.soc))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(compactSocStyle(state, theme))
                    .frame(width: 14, height: 14)
            } compactTrailing: {
                // 紧凑右侧：SOC 数字为主体（续航/ETA 空间放不下，留给展开态）
                // 未锁车时前置橙色警示点
                HStack(spacing: 2) {
                    if !state.isLocked {
                        Circle()
                            .fill(.orange)
                            .frame(width: 4, height: 4)
                    }
                    Text(verbatim: "\(state.soc.safeInt ?? 0)%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(compactSocStyle(state, theme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .fixedSize()
                }
            } minimal: {
                // 极简挖孔区：空间更小，只留单图标（色彩即信息）
                Image(systemName: state.isCharging ? "bolt.fill" : compactBatteryIcon(state.soc))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(compactSocStyle(state, theme))
                    .frame(width: 12, height: 12)
            }
        }
    }

    // MARK: - 灵动岛子组件

    /// 中央状态：充电 > 守卫 > 宠物 > 露营 > 不下电 > 行驶 > 驻车文案
    private func islandStatusView(_ state: WheaterAttributes.ContentState) -> some View {
        if state.isCharging {
            return AnyView(
                Label(state.chargeStateText, systemImage: "bolt.fill")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            )
        }
        if state.defenderActive {
            return AnyView(
                Label(state.defenderWarnCount ?? 0 > 0 ? "守卫(\(state.defenderWarnCount!)告警)" : "守卫中", systemImage: "shield.checkered")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.pink)
            )
        }
        if state.petModeActive {
            return AnyView(
                Text("🐾 宠物模式")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            )
        }
        if state.campModeActive {
            return AnyView(
                Text("⛺️ 露营模式")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.purple)
            )
        }
        if state.powerHoldActive {
            return AnyView(
                Text("🔋 离车不下电")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.cyan)
            )
        }
        if state.hiDryActive == true {
            return AnyView(
                Label("超强干燥中", systemImage: "heat.waves")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            )
        }
        if state.defrostActive == true {
            return AnyView(
                Label("极速除霜中", systemImage: "windshield.front.defrost")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.cyan)
            )
        }
        if state.overheatProtectActive == true {
            return AnyView(
                Text("🌡️ 座舱过热保护")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
            )
        }
        if state.isDriving == true {
            return AnyView(
                Label("行驶中", systemImage: "car.side.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.yellow)
            )
        }
        return AnyView(
            Text(state.chargeStateText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        )
    }

    /// 告警行：车门 / 车窗未关好 + 胎压偏低
    @ViewBuilder
    private func islandAlertRow(_ state: WheaterAttributes.ContentState) -> some View {
        let windowOpen = state.anyWindowOpen == true
        let doorOpen = state.anyDoorOpen
        let lowTyre = lowTyre(state)
        if windowOpen || doorOpen || lowTyre != nil {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                Text(alertText(state, doorOpen: doorOpen, windowOpen: windowOpen, lowTyre: lowTyre))
                    .font(.system(size: 8, weight: .bold))
                Spacer()
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.16))
            .clipShape(Capsule())
        }
    }

    private func alertText(_ state: WheaterAttributes.ContentState, doorOpen: Bool, windowOpen: Bool, lowTyre: Double?) -> String {
        var parts: [String] = []
        if doorOpen { parts.append("车门未关") }
        if windowOpen { parts.append("车窗未关") }
        if let t = lowTyre { parts.append(String(format: "胎压偏低 %.1fbar", t)) }
        return parts.joined(separator: " · ")
    }

    /// 最低胎压（低于 2.2bar 视为偏低，返回该数值）
    private func lowTyre(_ state: WheaterAttributes.ContentState) -> Double? {
        let values = [state.tyrePressFL, state.tyrePressFR, state.tyrePressRL, state.tyrePressRR].compactMap { $0 }.filter { $0 > 0 }
        guard let minTyre = values.min(), values.count >= 2, minTyre < 2.2 else { return nil }
        return minTyre
    }

    /// 四轮胎压摘要 "2.5|2.5|2.5|2.5"（缺数据显示前三项）
    private func tyreSummary(_ state: WheaterAttributes.ContentState) -> String {
        var parts: [String] = []
        if let fl = state.tyrePressFL, fl > 0 { parts.append(String(format: "%.1f", fl)) }
        if let fr = state.tyrePressFR, fr > 0 { parts.append(String(format: "%.1f", fr)) }
        if let rl = state.tyrePressRL, rl > 0 { parts.append(String(format: "%.1f", rl)) }
        if let rr = state.tyrePressRR, rr > 0 { parts.append(String(format: "%.1f", rr)) }
        return parts.joined(separator: "|")
    }

    /// 冰箱标签（带当前温度）
    private func frdgLabel(_ state: WheaterAttributes.ContentState) -> String {
        if let t = state.frdgTemp {
            return String(format: "🧊 冰箱 %.0f℃", t)
        }
        return "🧊 冰箱"
    }

    private func compactBatteryIcon(_ soc: Double) -> String {
        if soc >= 85 { return "battery.100percent" }
        if soc >= 60 { return "battery.75percent" }
        if soc >= 35 { return "battery.50percent" }
        if soc >= 10 { return "battery.25percent" }
        return "battery.0percent"
    }

    /// 紧凑/极简态电量配色：充电中绿色 / 低电橙色 / 常规主题渐变
    private func compactSocStyle(_ state: WheaterAttributes.ContentState, _ theme: WheaterThemeColors) -> AnyShapeStyle {
        if state.isCharging { return AnyShapeStyle(Color.green) }
        if state.soc < 20 { return AnyShapeStyle(Color.orange) }
        return AnyShapeStyle(LinearGradient(colors: theme.socGradient, startPoint: .leading, endPoint: .trailing))
    }
}

// MARK: - 锁屏大卡片视图（主题化）

struct LiveActivityLockScreenView: View {
    let state: WheaterAttributes.ContentState
    let theme: WheaterThemeColors

    var body: some View {
        VStack(spacing: 8) {
            // 顶部：Logo 徽章 + 车名 + 状态徽章 + 锁
            HStack {
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(theme.isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.05))
                            .frame(width: 22, height: 22)
                        Image("NIO_brand")
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                            .clipShape(Circle())
                    }
                    .overlay(Circle().stroke(theme.accent.opacity(0.7), lineWidth: 1))

                    Text(state.vehicleName.isEmpty ? "兔可可·蔚来" : state.vehicleName)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.text)

                    Text(state.chargeStateText)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(state.isCharging ? Color.green.opacity(theme.isDark ? 0.2 : 0.14) : theme.cardFill.opacity(0.6))
                        .foregroundStyle(state.isCharging ? Color.green : theme.textSoft)
                        .clipShape(Capsule())

                    if let ver = state.vehicleVersion, !ver.isEmpty {
                        HStack(spacing: 2.5) {
                            Image(systemName: "cpu")
                                .font(.system(size: 7))
                            Text(ver)
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                        .foregroundStyle(theme.textSoft.opacity(0.85))
                        .clipShape(Capsule())
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: state.isLocked ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 11))
                    Text(state.isLocked ? "已上锁" : "未锁")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(state.isLocked ? Color.green : .orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background((state.isLocked ? Color.green : .orange).opacity(theme.isDark ? 0.15 : 0.12))
                .clipShape(Capsule())
            }

            // 告警条：车门 / 车窗未关好 + 胎压偏低
            {
                let windowOpen = state.anyWindowOpen == true
                let doorOpen = state.anyDoorOpen
                var alerts: [String] = []
                if doorOpen { alerts.append("车门未关") }
                if windowOpen { alerts.append("车窗未关") }
                var lowTyre: Double? = nil
                let tyreValues = [state.tyrePressFL, state.tyrePressFR, state.tyrePressRL, state.tyrePressRR].compactMap { $0 }.filter { $0 > 0 }
                if let minValue = tyreValues.min(), tyreValues.count >= 2, minValue < 2.2 {
                    lowTyre = minValue
                    alerts.append(String(format: "胎压偏低 %.1fbar", minValue))
                }
                if !alerts.isEmpty {
                    return AnyView(
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                            Text("⚠️ " + alerts.joined(separator: " · ") + "，请检查车辆")
                                .font(.system(size: 10, weight: .bold))
                            Spacer()
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    )
                }
                return AnyView(EmptyView())
            }()

            // 中间：核心电量与续航大字展示
            HStack(alignment: .bottom) {
                // 电量
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(state.socDisplay)
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(colors: theme.socGradient, startPoint: .leading, endPoint: .trailing)
                            )
                        if state.isCharging {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.green)
                        }
                    }

                    if state.isCharging {
                        HStack(spacing: 4) {
                            if let power = state.powerDisplay {
                                Text("充电功率 \(power)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.green)
                            }
                            if let eta = state.chargeEtaDate {
                                HStack(spacing: 2) {
                                    Text("· 充满")
                                    Text(eta, style: .relative)
                                    Text("后")
                                }
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green.opacity(0.85))
                            }
                        }
                    } else if let mileage = state.mileageKm {
                        Text("里程 \(mileage) km")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textSoft)
                    }
                }

                Spacer()

                // 续航
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(state.remainingRangeKm)")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.text)
                        Text("km")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textSoft)
                    }

                    if state.preferActualRange != true, let act = state.actualRangeKm, act > 0 {
                        Text("实估 \(act) km")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.glow.opacity(theme.isDark ? 0.9 : 1.0))
                    }
                }
            }

            // 电量进度条（充电时带目标电量刻度）
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: theme.socGradient, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * CGFloat(min(100.0, max(0.0, state.soc))) / 100.0))
                    if state.isCharging, let target = state.chargingTargetSoc, target > 1, target < 100 {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(theme.isDark ? Color.white.opacity(0.9) : theme.text.opacity(0.7))
                            .frame(width: 2, height: 7)
                            .offset(x: geo.size.width * CGFloat(min(100.0, target) / 100.0) - 1)
                    }
                }
            }
            .frame(height: 5)

            // 胎压 4 联显示 (若有数据)
            if let fl = state.tyrePressFL, let fr = state.tyrePressFR, fl > 0, fr > 0 {
                HStack(spacing: 8) {
                    Text("🐾 胎压")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.textSoft)
                    HStack(spacing: 4) {
                        Text(verbatim: "\(String(format: "左前 %.1f", fl))")
                        Text(verbatim: "\(String(format: "右前 %.1f", fr))")
                        if let rl = state.tyrePressRL, let rr = state.tyrePressRR, rl > 0, rr > 0 {
                            Text(verbatim: "\(String(format: "左后 %.1f", rl))")
                            Text(verbatim: "\(String(format: "右后 %.1f", rr))")
                        }
                        Text("bar")
                    }
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.glow.opacity(theme.isDark ? 0.85 : 1.0))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // 底部：座舱与模式状态胶囊 + 独立版本/时间标签
            HStack(spacing: 5) {
                if let t = state.insideTemp {
                    chipView(icon: "thermometer.medium", label: "车内 \(String(format: "%.1f℃", t))", color: theme.glow)
                }

                if let out = state.outsideTemp {
                    chipView(icon: "sun.max.fill", label: "车外 \(String(format: "%.1f℃", out))", color: theme.textSoft)
                }

                if state.defenderActive {
                    chipView(icon: "shield.fill", label: state.defenderWarnCount ?? 0 > 0 ? "守卫(\(state.defenderWarnCount!)告警)" : "守卫开启", color: .pink)
                } else if state.petModeActive {
                    chipView(icon: "pawprint.fill", label: "宠物模式", color: .orange)
                } else if state.campModeActive {
                    chipView(icon: "tent.fill", label: "露营模式", color: .purple)
                } else if state.powerHoldActive {
                    chipView(icon: "bolt.badge.clock.fill", label: "离车不下电", color: .blue)
                }

                if state.frdgActive == true {
                    chipView(
                        icon: "snowflake",
                        label: state.frdgTemp.map { String(format: "冰箱 %.0f℃", $0) } ?? "冰箱",
                        color: .cyan
                    )
                }

                if state.v2lActive == true {
                    chipView(icon: "powerplug.fill", label: "对外放电", color: .yellow)
                }

                if let lv = state.lvBattSoc, lv > 0, lv < 30 {
                    chipView(icon: "car.side.fill", label: "12V \(lv)%", color: .orange)
                }

                Spacer()

                // 最近一次刷新结果标签（已更新 / 无数据更新）：随数据指纹一并下发，
                // 已更新为绿色，无数据更新弱化为次级色
                if let notice = state.refreshNotice, !notice.isEmpty {
                    Text(notice)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(notice == "已更新" ? Color.green : theme.textSoft.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background((notice == "已更新" ? Color.green : theme.textSoft).opacity(theme.isDark ? 0.15 : 0.10))
                        .clipShape(Capsule())
                }

                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 7.5))
                    Text(state.updateTimestamp, style: .time)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                }
                .foregroundStyle(theme.textSoft.opacity(0.6))
            }
        }
        .padding(12)
        .background(lockScreenBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// 主题化背景：深色主题为暗夜 + 粉/青辉光；浅色主题为白卡 + 柔和光晕
    private var lockScreenBackground: some View {
        ZStack {
            if theme.isDark {
                Color(red: 0.08, green: 0.07, blue: 0.16)
                RadialGradient(
                    colors: [Color.pink.opacity(0.15), Color.clear],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 160
                )
                RadialGradient(
                    colors: [Color.cyan.opacity(0.15), Color.clear],
                    center: .bottomLeading,
                    startRadius: 20,
                    endRadius: 160
                )
            } else {
                LinearGradient(
                    colors: [theme.background, theme.backgroundSoft],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [theme.accent.opacity(0.12), Color.clear],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 160
                )
                RadialGradient(
                    colors: [theme.glow.opacity(0.1), Color.clear],
                    center: .bottomLeading,
                    startRadius: 20,
                    endRadius: 160
                )
            }
        }
    }

    private func chipView(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(color.opacity(theme.isDark ? 0.12 : 0.1))
        .clipShape(Capsule())
    }
}

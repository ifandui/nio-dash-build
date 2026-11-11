//
//  NIODashboardCards.swift
//  wheater
//
//  看板增强卡组 v5.0（参考 ha-nio / NIO-Dash 语义）
//  · 特殊模式卡：守卫 / 宠物 / 露营 / 不下电保持 / V2L 对外放电
//  · 外设卡：12V 低压电瓶 / 车载冰箱 / 座舱加热 / 车灯照明
//  · 能耗评分卡：CLTC 达成率评级 + 推算百公里电耗
//  · 历史趋势卡：7 日 SOC 曲线 + 每日里程柱状（Swift Charts）
//  · 维保追踪卡：健康分 + 耗材寿命 + 维保花费统计
//  · 今日轨迹卡：当日行驶路径地图（MapPolyline）
//

import SwiftUI
import Charts
import MapKit

// MARK: - 卡片容器（看板与增强卡组统一外壳）

struct NIODashCardShell<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    // 主题渐变竖条：给每张卡片一个轻的主题锚点
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(NIOThemePaint.accentGradient)
                        .frame(width: 3.5, height: 14)
                    Text(title)
                        .font(.headline)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .background(NIOThemePaint.fill)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(NIOThemePaint.stroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(NIOThemePaint.isDark ? 0.30 : 0.06), radius: 10, y: 5)
    }
}

// MARK: - 特殊模式卡

struct NIOModesCard: View {
    let offcar: [String: NIOJSONValue]?
    let v2lStatus: Int?

    private struct ModeItem: Identifiable {
        let name: String
        let icon: String
        let isActive: Bool
        let detail: String
        var id: String { name }
    }

    private var items: [ModeItem] {
        let defender = NIOVehicleLib.defenderModeActive(offcar)
        // 键名对齐 NIO-Dash 实测 RVS 字段（offcar_mode_status 块内无 _status 后缀）
        let pet = NIOVehicleLib.modeActive(offcar?["pet_mode"] ?? offcar?["pet_mode_status"])
        let camping = NIOVehicleLib.modeActive(offcar?["camping_mode"] ?? offcar?["camp_mode_status"])
        let powerHold = NIOVehicleLib.modeActive(offcar?["power_hold_mode"] ?? offcar?["power_hold_mode_status"])
        let remoteVideo = NIOVehicleLib.modeActive(offcar?["remote_video"])
        let cpd = NIOVehicleLib.modeActive(offcar?["cpd_mode"])
        let v2l = (v2lStatus ?? 0) >= 1

        return [
            ModeItem(name: "守卫模式", icon: "shield.lefthalf.filled", isActive: defender.isActive,
                     detail: defender.isActive ? "监测中 · 提醒 \(defender.warnCount) 次" : "未启用"),
            ModeItem(name: "宠物模式", icon: "pawprint.fill", isActive: pet,
                     detail: pet ? "座舱温控看护中" : "未启用"),
            ModeItem(name: "露营模式", icon: "tent.fill", isActive: camping,
                     detail: camping ? "驻车空调持续供应" : "未启用"),
            ModeItem(name: "不下电保持", icon: "engine.combustion.fill", isActive: powerHold,
                     detail: powerHold ? "离车供电保持中" : "未启用"),
            ModeItem(name: "V2L 对外放电", icon: "powerplug.fill", isActive: v2l,
                     detail: v2l ? "正在对外供电" : "未启用"),
            ModeItem(name: "远程查看", icon: "video.fill", isActive: remoteVideo,
                     detail: remoteVideo ? "车外摄像头直播中" : "未启用"),
            ModeItem(name: "儿童遗留检测", icon: "figure.and.child.holdinghands", isActive: cpd,
                     detail: cpd ? "座舱内智能监测中" : "未启用")
        ]
    }

    var body: some View {
        NIODashCardShell(title: "特殊模式", subtitle: "离车生态与对外供电") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .foregroundStyle(item.isActive ? NIOThemePaint.accent : .secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.subheadline.weight(.medium))
                            Text(item.detail)
                                .font(.caption2)
                                .foregroundStyle(item.isActive ? NIOThemePaint.accent : .secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(item.isActive ? NIOThemePaint.accent.opacity(0.10) : Color.secondary.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(item.isActive ? NIOThemePaint.accent.opacity(0.22) : NIOThemePaint.stroke, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }
}

// MARK: - 外设卡（12V / 冰箱 / 加热 / 灯光）

struct NIOAccessoriesCard: View {
    let lvBatt: [String: NIOJSONValue]?
    let frdg: [String: NIOJSONValue]?
    let heating: [String: NIOJSONValue]?
    let light: [String: NIOJSONValue]?

    private var lvBattText: String? {
        guard let lv = lvBatt, !lv.isEmpty else { return nil }
        let volt = lv["lv_batt_volt"]?.doubleValue
        let socPct = lv["lv_batt_soc"]?.doubleValue
        switch (volt, socPct) {
        case let (v?, s?):
            return String(format: "%.1fV · %.0f%%", v > 100 ? v / 1000 : v, s > 1 ? s : s * 100)
        case let (v?, nil):
            return String(format: "%.1fV", v > 100 ? v / 1000 : v)
        case let (nil, s?):
            return String(format: "%.0f%%", s > 1 ? s : s * 100)
        default:
            return nil
        }
    }

    private var frdgText: String? {
        guard let f = frdg, !f.isEmpty else { return nil }
        let on = NIOVehicleLib.modeActive(f["frdg_pwr_sts"])
        let cur = f["frdg_cur_t"]?.doubleValue
        let target = f["frdg_tar_t"]?.doubleValue
        var parts = [on ? "运行中" : "已关闭"]
        if let cur { parts.append(String(format: "当前 %.0f℃", cur)) }
        if let target { parts.append(String(format: "目标 %.0f℃", target)) }
        return parts.joined(separator: " · ")
    }

    /// 语义化解析加热/灯光块：只识别已知开关字段（键名子串匹配），忽略 sample_time 等元数据。
    /// 返回开启项列表；字段存在但全部关闭返回「全部关闭」；无已知字段返回 nil（隐藏该行）。
    private func switchSummary(_ dict: [String: NIOJSONValue]?, candidates: [(needle: String, label: String)]) -> String? {
        guard let dict, !dict.isEmpty else { return nil }
        var active: [String] = []
        var sawKnownKey = false
        for (key, value) in dict {
            guard let match = candidates.first(where: { key.lowercased().contains($0.needle) }) else { continue }
            sawKnownKey = true
            let on = (value.intValue ?? value.doubleValue.map { Int($0) } ?? 0) >= 1
                || value.stringValue.map { ["1", "on", "true", "open", "active"].contains($0.lowercased()) } == true
            if on { active.append(match.label) }
        }
        if active.isEmpty { return sawKnownKey ? "全部关闭" : nil }
        return active.joined(separator: " · ")
    }

    /// 加热块：电池预热 / 高压预热 / 方向盘与座椅加热 / 除霜
    private var heatingText: String? {
        switchSummary(heating, candidates: [
            ("warm_up", "电池预热"),
            ("pre_sts", "高压预热"),
            ("steering", "方向盘加热"),
            ("seat_heat", "座椅加热"),
            ("defrost", "除霜")
        ])
    }

    /// 灯光块：大灯 / 日行灯 / 驻车灯 / 转向灯 / 雾灯 / 尾灯
    private var lightText: String? {
        switchSummary(light, candidates: [
            ("head", "大灯"),
            ("day_ti_runng", "日行灯"),
            ("dayti", "日行灯"),
            ("parking", "驻车灯"),
            ("turn", "转向灯"),
            ("fog", "雾灯"),
            ("tail", "尾灯")
        ])
    }

    var body: some View {
        let lvText = lvBattText
        let fridgeText = frdgText
        let heatText = heatingText
        let lightValueText = lightText

        return NIODashCardShell(title: "智能外设", subtitle: "低压电瓶 · 冰箱 · 加热 · 灯光") {
            VStack(spacing: 0) {
                if let lvText {
                    row(icon: "car.battery", label: "12V 低压电瓶", value: lvText, tint: .green)
                    Divider()
                }
                if let fridgeText {
                    row(icon: "refrigerator", label: "车载冰箱", value: fridgeText, tint: .cyan)
                    Divider()
                }
                if let heatText {
                    row(icon: "flame.fill", label: "座舱加热", value: heatText, tint: .orange)
                    Divider()
                }
                if let lightValueText {
                    row(icon: "lightbulb.max.fill", label: "车灯照明", value: lightValueText, tint: .yellow)
                    Divider()
                }
                if lvText == nil && fridgeText == nil && heatText == nil && lightValueText == nil {
                    Text("暂无外设遥测数据（RVS 未返回对应字段）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    private func row(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - 能耗评分卡

struct NIOEfficiencyCard: View {
    let soc: NIOSocStatus?
    let batteryCapacityKwh: Double

    private var nominalRange: Double? {
        guard let cltc = soc?.remainingRange, cltc > 0, let pct = soc?.soc, pct > 0 else { return nil }
        return cltc / pct * 100.0
    }

    private var score: NIOEfficiencyLib.EfficiencyScore? {
        guard let nominal = nominalRange else { return nil }
        return NIOEfficiencyLib.computeScore(nominalRange: nominal, actualRange: soc?.remainingActualRange, batteryCapacityKwh: batteryCapacityKwh)
    }

    private var gradeTint: Color {
        guard let grade = score?.grade else { return .secondary }
        if grade.hasPrefix("S") { return .yellow }
        if grade.hasPrefix("A") { return .green }
        if grade.hasPrefix("B") { return .blue }
        return .orange
    }

    var body: some View {
        NIODashCardShell(title: "能耗评分", subtitle: "续航达成率 · 百公里电耗") {
            if let score {
                HStack(spacing: 16) {
                    // 达成率环形
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        Circle()
                            .trim(from: 0, to: max(0.02, min(1.0, score.achievementRate / 100.0)))
                            .stroke(gradeTint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text(String(format: "%.0f%%", score.achievementRate))
                                .font(.system(size: 17, weight: .heavy, design: .rounded).monospacedDigit())
                            Text("达成率")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: score.icon)
                                .foregroundStyle(gradeTint)
                            Text(score.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        Text(score.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack(spacing: 10) {
                            Label(String(format: "%.1f kWh/100km", score.estimatedKwhPer100Km), systemImage: "bolt.horizontal.fill")
                            Text(score.grade)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(gradeTint)
                    }
                    Spacer(minLength: 0)
                }

                if let nominal = nominalRange {
                    Divider()
                    HStack {
                        Text("满电 CLTC 基准")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(nominal)) km · \(Int(batteryCapacityKwh))kWh 档")
                            .font(.caption.weight(.medium).monospacedDigit())
                    }
                }
            } else {
                Text("暂无续航数据，同步车辆状态后自动评分")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - 历史趋势卡（7 日 SOC + 每日里程）

struct NIOHistoryTrendCard: View {
    let snapshots: [NIOVehicleSnapshot]
    let deltas: [NIODailyDelta]
    @ObservedObject private var themeService = AnimeThemeService.shared

    private var accent: Color { NIOThemePaint.accent }
    private var glow: Color { NIOThemePaint.glow }

    /// 最近 7 天有 SOC 采样的点（同秒重复采样仅保留最后一条，避免 Chart identity 冲突）
    private var socPoints: [(date: Date, soc: Double)] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        var latestByDate: [Date: Double] = [:]
        for snap in snapshots where snap.soc > 0 && snap.ts > 0 {
            let sec = snap.ts > 1_000_000_000_000 ? TimeInterval(snap.ts) / 1000 : TimeInterval(snap.ts)
            let date = Date(timeIntervalSince1970: sec)
            guard date >= cutoff else { continue }
            latestByDate[date] = snap.soc
        }
        return latestByDate.map { (date: $0.key, soc: $0.value) }.sorted { $0.date < $1.date }
    }

    /// 最近 7 天每日里程
    private var recentDeltas: [NIODailyDelta] {
        Array(deltas.suffix(7))
    }

    var body: some View {
        NIODashCardShell(title: "历史趋势", subtitle: "近 7 日电量与里程") {
            if socPoints.count >= 2 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SOC 电量曲线")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Chart {
                        ForEach(socPoints, id: \.date) { point in
                            LineMark(
                                x: .value("时间", point.date),
                                y: .value("SOC", point.soc)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(
                                .linearGradient(colors: [accent, glow], startPoint: .leading, endPoint: .trailing)
                            )
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        }
                        ForEach(socPoints, id: \.date) { point in
                            PointMark(
                                x: .value("时间", point.date),
                                y: .value("SOC", point.soc)
                            )
                            .symbolSize(14)
                            .foregroundStyle(accent.opacity(0.6))
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .frame(height: 150)
                }
            } else {
                Text("采样不足，继续积累历史数据后展示 SOC 曲线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !recentDeltas.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("每日行驶里程 (km)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Chart {
                        ForEach(recentDeltas) { delta in
                            BarMark(
                                x: .value("日期", delta.label),
                                y: .value("里程", delta.delta)
                            )
                            .foregroundStyle(
                                .linearGradient(colors: [accent.opacity(0.85), glow.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                            )
                            .cornerRadius(4)
                            .annotation(position: .top) {
                                if delta.delta > 0 {
                                    Text(String(format: "%.0f", delta.delta))
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(height: 130)
                }
            }
        }
    }
}

// MARK: - 维保追踪卡

struct NIOMaintenanceCard: View {
    let mileageKm: Double?
    let orders: [NIOServiceOrder]

    private var report: NIOMaintenanceTracker.MaintenanceReport {
        NIOMaintenanceTracker.generateReport(currentMileage: mileageKm ?? 0, orders: orders)
    }

    private var healthTint: Color {
        let s = report.overallHealthScore
        if s >= 70 { return .green }
        if s >= 40 { return .orange }
        return .red
    }

    var body: some View {
        let report = self.report
        let urgentItems = report.items.filter(\.isUrgent)
        let shownItems = Array((urgentItems + report.items.filter { !$0.isUrgent }).prefix(4))

        return NIODashCardShell(title: "维保追踪", subtitle: "耗材寿命与保养花费") {
            HStack(spacing: 16) {
                // 健康分环
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    Circle()
                        .trim(from: 0, to: max(0.02, Double(report.overallHealthScore) / 100.0))
                        .stroke(healthTint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(report.overallHealthScore)")
                            .font(.system(size: 17, weight: .heavy, design: .rounded).monospacedDigit())
                        Text("健康分")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 5) {
                    Text(report.totalCount > 0 ? "累计维保 \(report.totalCount) 次" : "暂无维保订单记录")
                        .font(.subheadline.weight(.semibold))
                    if report.totalSpent > 0 {
                        Text(String(format: "累计花费 ¥%.0f", report.totalSpent))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if report.nextServiceKm > 0 {
                        Text("最近一项耗材剩余 \(Int(report.nextServiceKm)) km")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if report.lastServiceDate != "未记录" {
                        Text("上次保养 \(report.lastServiceDate)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            Divider()

            VStack(spacing: 0) {
                ForEach(shownItems) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .foregroundStyle(item.isUrgent ? .orange : .secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.subheadline.weight(.medium))
                            ProgressView(value: item.healthPercentage, total: 100)
                                .tint(item.isUrgent ? .orange : (item.healthPercentage > 60 ? .green : .blue))
                                .scaleEffect(x: 1, y: 0.7, anchor: .center)
                        }
                        Spacer(minLength: 0)
                        Text(item.isUrgent ? "建议检查 ⚠️" : "\(Int(item.remainingKm)) km")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(item.isUrgent ? .orange : .secondary)
                    }
                    .padding(.vertical, 8)
                    if item.id != shownItems.last?.id { Divider() }
                }
            }

            if mileageKm == nil || mileageKm == 0 {
                Text("当前里程未知，耗材寿命按 0 km 估算")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 今日轨迹卡

struct NIOTodayTrackCard: View {
    let path: NIODailyPath?

    var body: some View {
        NIODashCardShell(title: "行驶轨迹", subtitle: path.map { "\($0.label) · 基于本地采样" } ?? "基于本地采样") {
            if let path, path.points.count >= 2 {
                let coords = path.points
                    .filter { NIOVehicleLib.isValidGPS(lat: $0.lat, lng: $0.lng) }
                    .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }

                if coords.count >= 2 {
                    VStack(alignment: .leading, spacing: 10) {
                        Map(initialPosition: .region(Self.region(for: coords))) {
                            MapPolyline(coordinates: coords)
                                .stroke(
                                    .linearGradient(colors: [NIOThemePaint.gradientStart, NIOThemePaint.gradientEnd], startPoint: .leading, endPoint: .trailing),
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                                )
                        }
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                        HStack {
                            Label(String(format: "%.1f km", path.distanceKm), systemImage: "point.topleft.down.curvedto.point.bottomright.up.fill")
                            Spacer()
                            Label("\(path.points.count) 个采样点", systemImage: "scope")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                } else {
                    emptyHint
                }
            } else {
                emptyHint
            }
        }
    }

    private var emptyHint: some View {
        Text("当日暂无有效 GPS 采样轨迹")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }

    private static func region(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coords.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude); maxLng = max(maxLng, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let spanLat = max(0.008, (maxLat - minLat) * 1.5)
        let spanLng = max(0.008, (maxLng - minLng) * 1.5)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLng)
        )
    }
}

// MARK: - 服务与换电订单概览卡（累计订单 / 换电次数 / 累计与平均花费）

struct NIOSwapOverviewCard: View {
    let summary: NIOServiceSummary?

    var body: some View {
        NIODashCardShell(title: "服务与换电订单概览", subtitle: "订单同步数据解析") {
            if let s = summary, s.total > 0 {
                VStack(spacing: 0) {
                    overviewRow(label: "累计服务订单", value: "\(s.total) 单", tint: .blue)
                    Divider()
                    overviewRow(label: "换电完成次数", value: "\(s.swapCompleted) 次", tint: .green)
                    Divider()
                    overviewRow(label: "换电累计花费", value: NIOOrderLib.fmtMoney(s.swapSpent), tint: .primary)
                    Divider()
                    overviewRow(label: "平均换电花费", value: NIOOrderLib.fmtMoney(s.swapAvgSpent), tint: .primary)
                }
            } else {
                orderCardEmptyHint("暂无订单数据 · 拉取服务订单后自动解析")
            }
        }
    }

    private func overviewRow(label: String, value: String, tint: Color) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .padding(.vertical, 9)
    }
}

// MARK: - 常用换电站 Top 5 卡（按完成换电次数排行）

struct NIOTopStationsCard: View {
    let stations: [NIOStationStat]

    var body: some View {
        NIODashCardShell(title: "常用换电站 Top 5", subtitle: "按完成换电次数排行") {
            if stations.isEmpty {
                orderCardEmptyHint("暂无换电站足迹 · 完成换电后自动统计")
            } else {
                let top = Array(stations.prefix(5))
                let maxCount = max(top.first?.count ?? 1, 1)
                VStack(spacing: 12) {
                    ForEach(Array(top.enumerated()), id: \.element.id) { idx, station in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text("\(idx + 1)")
                                    .font(.caption.weight(.heavy).monospacedDigit())
                                    .foregroundStyle(idx == 0 ? .blue : .secondary)
                                    .frame(width: 16)
                                Text(station.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(station.count) 次 · \(NIOOrderLib.fmtMoney(station.spent))")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(station.count), total: Double(maxCount))
                                .tint(idx == 0 ? .blue : .secondary.opacity(0.5))
                                .scaleEffect(x: 1, y: 0.7, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 订单明细列表卡（点击展开订单解析明细）

struct NIOOrderListCard: View {
    let orders: [NIOServiceOrder]

    @State private var expandedOrderID: String?

    var body: some View {
        NIODashCardShell(title: "订单明细列表", subtitle: "共 \(orders.count) 单 · 点击展开明细") {
            if orders.isEmpty {
                orderCardEmptyHint("暂无订单")
            } else {
                VStack(spacing: 0) {
                    ForEach(orders) { order in
                        orderRow(order)
                        if order.id != orders.last?.id { Divider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func orderRow(_ order: NIOServiceOrder) -> some View {
        let isExpanded = expandedOrderID == order.id
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                expandedOrderID = isExpanded ? nil : order.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NIOOrderLib.orderTypeLabel(order))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(NIOOrderLib.fmtSwapDate(order.createTime))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(order.orderStatusName ?? "")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(orderToneColor(NIOOrderLib.orderStatusTone(order)))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())

                if isExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(NIOOrderLib.orderDetailLines(order).enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top) {
                                Text(line.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .leading)
                                Text(line.value)
                                    .font(.caption.weight(.medium).monospacedDigit())
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// 订单状态色调 → 颜色
private func orderToneColor(_ tone: String) -> Color {
    switch tone {
    case "success": return .green
    case "danger": return .red
    case "warning": return .orange
    default: return .secondary
    }
}

/// 订单类卡片空态提示
private func orderCardEmptyHint(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
}

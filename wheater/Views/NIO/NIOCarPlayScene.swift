//
//  NIOCarPlayScene.swift
//  wheater
//
//  CarPlay 车况看板 (v5.2.0)
//  · CPTemplateApplicationScene + CPListTemplate：电量 / 续航 / 充电 / 车锁 / 温度 / 总里程
//  · 一级详情 CPInformationTemplate：限充、胎压、充电桩类型、12V 电瓶等全维状态
//  · 数据直连 NIOService @Published，收到新数据自动重建模板
//  · 需要 com.apple.developer.carplay-maps 权限（TrollStore 安装自动具备，见 wheater.entitlements）
//

import Foundation
import CarPlay
import Combine

@MainActor
final class NIOCarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate, CPListTemplateDelegate {

    private var interfaceController: CPInterfaceController?
    private var dataCancellable: AnyCancellable?

    // MARK: - 场景连接

    nonisolated func scene(_ scene: CPTemplateApplicationScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        Task { @MainActor in
            let controller = scene.interfaceController
            self.interfaceController = controller
            self.rebuildTemplates()
            self.dataCancellable = NIOService.shared.$vehicleData
                .sink { [weak self] _ in
                    Task { @MainActor in self?.rebuildTemplates() }
                }
        }
    }

    nonisolated func sceneDidDisconnect(_ scene: UIScene) {
        Task { @MainActor in
            self.dataCancellable?.cancel()
            self.dataCancellable = nil
            self.interfaceController = nil
        }
    }

    // MARK: - 模板构建

    private func rebuildTemplates() {
        guard let controller = interfaceController else { return }

        // 当前根模板是列表时原地更新，避免每次数据刷新把导航栈弹空
        if let root = controller.rootTemplate as? CPListTemplate {
            root.updateSections(makeSections())
        } else {
            let root = CPListTemplate(title: "兔可可 · 蔚来", sections: makeSections())
            root.delegate = self
            controller.setRootTemplate(root, animated: false, completion: nil)
        }
    }

    private func makeSections() -> [CPListSection] {
        let status = NIOService.shared.vehicleData?.data?.status
        let socStatus = status?.socStatus

        let socInt = ((socStatus?.soc ?? 0).rounded()).safeInt ?? 0
        let rangeKm = ((socStatus?.remainingRange ?? 0).rounded()).safeInt ?? 0
        let actKm = socStatus?.remainingActualRange.flatMap { $0.rounded().safeInt }
        let charging = NIOVehicleLib.isRealCharging(socStatus: socStatus, offcarStatus: status?.offcarModeStatus)
        let chargeText = NIOVehicleLib.smartChargeStateDescription(socStatus: socStatus, offcarStatus: status?.offcarModeStatus)
        let powerText = socStatus?.chargingPower.map { String(format: "%.1f kW", $0 / 1000.0) }
        let doors = status?.doorStatus ?? [:]
        let isLocked = (doors["vehicle_lock_status"]?.intValue ?? 1) == 1

        // 车况总览
        let overviewItem = CPListItem(
            text: "电量 \(socInt)% · 续航 \(rangeKm) km",
            detailText: charging
                ? "⚡️ \(chargeText)\(powerText.map { " · \($0)" } ?? "")"
                : (isLocked ? "已上锁 🔒" : "未上锁 ⚠️")
        )
        overviewItem.accessoryType = .disclosureIndicator
        overviewItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                guard let self = self else { completion(); return }
                self.showDetail(completion: completion)
            }
        }

        // 环境与里程
        var envParts: [String] = []
        if let t = status?.hvacStatus?.temperature { envParts.append(String(format: "车内 %.0f℃", t)) }
        if let t = status?.hvacStatus?.outsideTemperature { envParts.append(String(format: "车外 %.0f℃", t)) }
        if let m = status?.exteriorStatus?.mileage { envParts.append("总里程 \(m.rounded().safeInt ?? 0) km") }
        let envItem = CPListItem(
            text: envParts.isEmpty ? "暂无环境数据" : envParts.joined(separator: " · "),
            detailText: actKm.map { "实估续航 \($0) km" } ?? "车内/车外温度与总里程"
        )
        envItem.accessoryType = .disclosureIndicator
        envItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                guard let self = self else { completion(); return }
                self.showDetail(completion: completion)
            }
        }

        // 刷新
        let refreshItem = CPListItem(text: "🔄 刷新车况", detailText: "立即拉取最新车辆数据")
        refreshItem.handler = { _, completion in
            Task { @MainActor in
                NIOService.shared.refreshAll(force: true)
                completion()
            }
        }

        return [
            CPListSection(items: [overviewItem, envItem]),
            CPListSection(items: [refreshItem])
        ]
    }

    // MARK: - 详情模板

    private func showDetail(completion: @escaping () -> Void) {
        guard let controller = interfaceController else { completion(); return }

        let status = NIOService.shared.vehicleData?.data?.status
        let socStatus = status?.socStatus

        func item(_ title: String, _ detail: String) -> CPInformationItem {
            CPInformationItem(title: title, detail: detail)
        }

        var items: [CPInformationItem] = []
        if let soc = socStatus?.soc {
            items.append(item("电量", String(format: "%.0f%%", soc)))
        }
        if let r = socStatus?.remainingRange {
            items.append(item("标称续航", "\(r.rounded().safeInt ?? 0) km"))
        }
        if let a = socStatus?.remainingActualRange, a > 0 {
            items.append(item("实估续航", "\(a.rounded().safeInt ?? 0) km"))
        }
        items.append(item("充电状态", NIOVehicleLib.smartChargeStateDescription(socStatus: socStatus, offcarStatus: status?.offcarModeStatus)))
        if let p = socStatus?.chargingPower, p > 0 {
            items.append(item("充电功率", String(format: "%.1f kW", p / 1000.0)))
        }
        if let type = socStatus?.chargerType {
            items.append(item("充电桩类型", NIOVehicleLib.chargerTypeLabel(type)))
        }
        if let target = socStatus?.targetSocPercentage, target > 0 {
            items.append(item("限充上限", String(format: "%.0f%%", target)))
        }
        let doors = status?.doorStatus ?? [:]
        items.append(item("车锁", (doors["vehicle_lock_status"]?.intValue ?? 1) == 1 ? "已上锁 🔒" : "未上锁 ⚠️"))
        if let t = status?.hvacStatus?.temperature {
            items.append(item("车内温度", String(format: "%.0f℃", t)))
        }
        if let t = status?.hvacStatus?.outsideTemperature {
            items.append(item("车外温度", String(format: "%.0f℃", t)))
        }
        if let m = status?.exteriorStatus?.mileage {
            items.append(item("总里程", "\(m.rounded().safeInt ?? 0) km"))
        }
        let tyre = NIOVehicleLib.extractTyreInfo(from: status)
        if tyre.hasData {
            let fmt: (Double?) -> Double = { $0 ?? 0 }
            items.append(item("四轮胎压", String(format: "%.0f / %.0f / %.0f / %.0f kPa",
                                                fmt(tyre.fl.press), fmt(tyre.fr.press),
                                                fmt(tyre.rl.press), fmt(tyre.rr.press))))
        }
        if let v = status?.lvBattStatus?["lv_batt_volt"]?.doubleValue {
            items.append(item("12V 电瓶", String(format: "%.1f V", v)))
        }

        let detail = CPInformationTemplate(title: "车辆详情", layout: .twoColumn, items: items, actions: [])
        controller.pushTemplate(detail, animated: true) { _, _ in completion() }
    }

    // MARK: - CPListTemplateDelegate（item.handler 为主通道，此处兜底）

    nonisolated func listTemplate(_ listTemplate: CPListTemplate, didSelect item: CPListItem, completionHandler: @escaping () -> Void) {
        // CarPlay 回调线程无主线程保证：跳回主隔离再分发，避免与 MainActor 状态竞态
        Task { @MainActor in
            if let handler = item.handler {
                handler(item, completionHandler)
            } else {
                completionHandler()
            }
        }
    }
}

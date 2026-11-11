//
//  WheaterVehicleSnapshot.swift
//  WheaterStatus
//
//  桌面 Widget 共享车况快照 (v5.2.0)
//  App 端每次刷新车况后写入 App Group；WidgetKit 时间线读取渲染。
//  本文件同时编译进主 App 与 Widget Extension 两个 target。
//

import Foundation

struct WheaterVehicleSnapshot: Codable {
    var vehicleName: String
    var soc: Double
    var remainingRangeKm: Int
    var actualRangeKm: Int?
    var mileageKm: Int?
    var isCharging: Bool
    var chargeStateText: String
    var chargingPowerKw: Double?
    var isDriving: Bool?
    var isLocked: Bool
    var anyDoorOpen: Bool
    var insideTemp: Double?
    var outsideTemp: Double?
    var defenderActive: Bool
    var petModeActive: Bool
    var campModeActive: Bool
    var powerHoldActive: Bool
    var v2lActive: Bool?
    var hiDryActive: Bool?
    var defrostActive: Bool?
    var overheatProtectActive: Bool?
    var chargingTargetSoc: Double?
    var chargeEtaDate: Date?
    var lvBattSoc: Int?
    var lvBattVolt: Double?
    var vehicleVersion: String?
    var preferActualRange: Bool?
    var tyrePressFL: Double?
    var tyrePressFR: Double?
    var tyrePressRL: Double?
    var tyrePressRR: Double?
    var themeRaw: String?
    var refreshNotice: String?
    var updatedAt: Date

    static let appGroupID = "group.com.YumikoToysRR.wheater"
    private static let storeKey = "nio_vehicle_snapshot_v1"

    /// App 端：从 Live Activity 状态提取并落盘（App Group UserDefaults）。
    /// 写入后读回验证，返回是否真正落盘成功（无 App Group 权限时 set 静默失败，读回为 nil）。
    @discardableResult
    static func save(from state: WheaterAttributes.ContentState) -> Bool {
        let snapshot = WheaterVehicleSnapshot(
            vehicleName: state.vehicleName,
            soc: state.soc,
            remainingRangeKm: state.remainingRangeKm,
            actualRangeKm: state.actualRangeKm,
            mileageKm: state.mileageKm,
            isCharging: state.isCharging,
            chargeStateText: state.chargeStateText,
            chargingPowerKw: state.chargingPowerKw,
            isDriving: state.isDriving,
            isLocked: state.isLocked,
            anyDoorOpen: state.anyDoorOpen,
            insideTemp: state.insideTemp,
            outsideTemp: state.outsideTemp,
            defenderActive: state.defenderActive,
            petModeActive: state.petModeActive,
            campModeActive: state.campModeActive,
            powerHoldActive: state.powerHoldActive,
            v2lActive: state.v2lActive,
            hiDryActive: state.hiDryActive,
            defrostActive: state.defrostActive,
            overheatProtectActive: state.overheatProtectActive,
            chargingTargetSoc: state.chargingTargetSoc,
            chargeEtaDate: state.chargeEtaDate,
            lvBattSoc: state.lvBattSoc,
            lvBattVolt: state.lvBattVolt,
            vehicleVersion: state.vehicleVersion,
            preferActualRange: state.preferActualRange,
            tyrePressFL: state.tyrePressFL,
            tyrePressFR: state.tyrePressFR,
            tyrePressRL: state.tyrePressRL,
            tyrePressRR: state.tyrePressRR,
            themeRaw: state.themeRaw,
            refreshNotice: state.refreshNotice,
            updatedAt: state.updateTimestamp
        )
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: storeKey)
        return defaults.data(forKey: storeKey) != nil
    }

    /// Widget 端：读取最新快照
    static func load() -> WheaterVehicleSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: storeKey) else { return nil }
        return try? JSONDecoder().decode(WheaterVehicleSnapshot.self, from: data)
    }

    /// Widget 占位预览数据
    static var demo: WheaterVehicleSnapshot {
        WheaterVehicleSnapshot(
            vehicleName: "ET5 · 自然奇境版",
            soc: 78, remainingRangeKm: 412, actualRangeKm: 356, mileageKm: 18650,
            isCharging: true, chargeStateText: "直流快充中", chargingPowerKw: 68.5,
            isDriving: false, isLocked: true, anyDoorOpen: false,
            insideTemp: 22.5, outsideTemp: 16.0,
            defenderActive: false, petModeActive: false, campModeActive: false,
            powerHoldActive: false, v2lActive: false, hiDryActive: false,
            defrostActive: false, overheatProtectActive: false, chargingTargetSoc: 90,
            chargeEtaDate: Date().addingTimeInterval(42 * 60),
            lvBattSoc: 96, lvBattVolt: 12.8, vehicleVersion: nil,
            preferActualRange: false,
            tyrePressFL: 2.5, tyrePressFR: 2.5, tyrePressRL: 2.4, tyrePressRR: 2.4,
            themeRaw: "kawaiiLight", refreshNotice: "已更新", updatedAt: Date()
        )
    }
}

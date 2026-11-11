//
//  IslandControlWidget.swift
//  WheaterStatus
//
//  灵动岛快速上岛控制胶囊 (Control Widget, v5.3.0)
//  被用户长按强制下岛后，从控制中心 / 锁屏一键重新上岛。
//  v5.3: 点击后常亮，打开 app 重新上灵动岛；上岛成功后自动复位。
//  本文件同时编译进主 App 与 Widget 扩展两个 target：
//  · RaiseIslandIntent 双 target 共享：iOS 18 Control Widget 的 perform 运行在扩展进程，
//    通过 App Group 标志位跨进程接力，主 App 前台激活时消费请求完成上岛
//  · WheaterIslandControlWidget 仅扩展 target（WHEATER_STATUS_EXTENSION）
//

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - 控制胶囊共享常量（主 App / Widget 扩展双 target）

enum WheaterIslandControl {
    /// Control Widget 点击的跨进程接力标志（App Group UserDefaults，值为请求时间戳）
    static let raiseRequestKey = "nio_raise_island_request"
    /// 常亮开关状态（App Group UserDefaults，bool）
    static let keepAliveKey = "nio_island_keep_alive"
    /// Control Widget 注册 kind（写入/清除常亮标志后需 reloadControls 让系统重渲染按钮）
    static let controlKind = "com.YumikoToysRR.wheater.IslandRaise"
    static let appGroupID = "group.com.YumikoToysRR.wheater"
}

// MARK: - 上岛意图（主 App / Widget 扩展共享）

struct RaiseIslandIntent: AppIntent {
    static var title: LocalizedStringResource = "灵动岛车况"
    static var description = IntentDescription("点一下常亮，打开 App 自动重新上灵动岛")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        #if WHEATER_STATUS_EXTENSION
        // iOS 18 Control Widget 的 perform 运行在扩展进程，无法直接启动 Live Activity。
        // openAppWhenRun = true 让系统拉起主 App（锁屏 / 控制中心均可），
        // 同时写三通道标志让主 App 知道是"上岛请求"而非普通打开：
        // · App Group UserDefaults 标志 + synchronize 强制刷新
        // · App Group 容器文件标志（文件系统跨进程即时可见，弥补 UserDefaults 同步延迟）
        // · Darwin 通知实时触发（App 已在前台时 scenePhase 无变化，靠通知即时消费）
        let now = Date().timeIntervalSince1970
        if let defaults = UserDefaults(suiteName: WheaterIslandControl.appGroupID) {
            defaults.set(true, forKey: WheaterIslandControl.keepAliveKey)
            defaults.set(now, forKey: WheaterIslandControl.raiseRequestKey)
            defaults.synchronize()
        }
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WheaterIslandControl.appGroupID
        ) {
            let flagURL = containerURL.appendingPathComponent("raise_island_flag")
            try? "\(now)".data(using: .utf8)?.write(to: flagURL, options: .atomic)
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.yumikotoysrr.wheater.raiseIsland" as CFString),
            nil, nil, true
        )
        // 常亮标志已写入，通知系统重渲染控制胶囊（否则按钮永远停在"灵动岛车况"灰态）
        ControlCenter.shared.reloadControls(ofKind: WheaterIslandControl.controlKind)
        return .result()
        #else
        await NIOService.shared.raiseLiveActivityFromControl()
        return .result()
        #endif
    }
}

#if WHEATER_STATUS_EXTENSION

// MARK: - 控制胶囊 Widget（仅扩展进程编译）

struct WheaterIslandControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WheaterIslandControl.controlKind) {
            let isOn = UserDefaults(suiteName: WheaterIslandControl.appGroupID)?
                .bool(forKey: WheaterIslandControl.keepAliveKey) ?? false
            ControlWidgetButton(action: RaiseIslandIntent()) {
                Label {
                    Text(isOn ? "常亮中" : "灵动岛车况")
                } icon: {
                    Image(systemName: isOn ? "bolt.car.fill" : "bolt.car")
                }
            }
            // 常亮时图标着绿色，锁屏 / 控制中心一眼可辨
            .tint(isOn ? Color.green : nil)
        }
        .displayName("灵动岛车况")
        .description("点一下常亮，打开 App 自动重新上灵动岛")
    }
}

#endif

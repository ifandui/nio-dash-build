//
//  wheaterApp.swift
//  wheater
//

import SwiftUI
import UserNotifications

@main
struct wheaterApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                print("[Notification] Push notification permissions granted")
            }
        }
        // 后台刷新注册（v5.2.0）：必须在启动完成前注册，否则 BGTaskScheduler 直接拒绝
        NIOService.registerBackgroundRefresh()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    // 控制胶囊 / 外部通过 yumikotoysrr://raise-island 拉起时直接触发上岛
                    if url.host == "raise-island" {
                        NIOService.shared.raiseLiveActivityFromControl()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // 后台定位保活：已配置凭证且授权后，轮询 Timer 在后台继续跑
                        NIOLocationKeepAlive.shared.requestAndStart()
                        // 控制胶囊上岛接力：App 激活时消费 Widget 扩展写入的快速上岛请求
                        NIOService.shared.checkPendingIslandRaise()
                    case .background:
                        // 退到后台预约一次 BGAppRefreshTask，后台仍定期刷新车况与灵动岛
                        NIOService.scheduleBackgroundRefresh()
                    default:
                        break
                    }
                }
        }
    }
}

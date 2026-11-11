//
//  NIOService.swift
//  wheater
//
//  蔚来 NIO 数据服务（iOS 原生适配版）
//

import Foundation
import Combine
import SwiftUI
import UIKit
import ActivityKit
import BackgroundTasks
import WidgetKit
import CoreLocation

/// 刷新结果 / 同行事件横幅模型：kind 决定图标与色调，id 驱动横幅 UI 重新计时自动消失
struct NIOTransientNotice: Identifiable, Equatable {
    enum Kind {
        /// 绿色 ✓ 数据有更新 / 正向结果
        case success
        /// 中性 无数据更新
        case neutral
        /// 橙色 警示（如到达但未上锁）
        case warn
        /// 主题色 一般提示（如开始同行）
        case info

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .neutral: return "tray.full.fill"
            case .warn: return "exclamationmark.triangle.fill"
            case .info: return "location.car.fill"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let message: String
    let at = Date()
}

@MainActor
final class NIOService: ObservableObject {
    static let shared = NIOService()

    // MARK: - Published 配置项 (UserDefaults 双向同步持久化)

    @Published var nioVehicleApiMode: String = UserDefaults.standard.string(forKey: "nio_vehicle_api_mode") ?? "url" {
        didSet { UserDefaults.standard.set(nioVehicleApiMode, forKey: "nio_vehicle_api_mode") }
    }
    @Published var nioVehicleApiURL: String = UserDefaults.standard.string(forKey: "nio_vehicle_api_url") ?? "" {
        didSet { UserDefaults.standard.set(nioVehicleApiURL, forKey: "nio_vehicle_api_url") }
    }
    @Published var nioVehicleId: String = UserDefaults.standard.string(forKey: "nio_vehicle_id") ?? "" {
        didSet { UserDefaults.standard.set(nioVehicleId, forKey: "nio_vehicle_id") }
    }
    @Published var nioDeviceId: String = UserDefaults.standard.string(forKey: "nio_device_id") ?? "" {
        didSet { UserDefaults.standard.set(nioDeviceId, forKey: "nio_device_id") }
    }
    @Published var nioVehicleSignSecret: String = UserDefaults.standard.string(forKey: "nio_vehicle_sign_secret") ?? NIOVehicleLib.builtinSignSecret {
        didSet { UserDefaults.standard.set(nioVehicleSignSecret, forKey: "nio_vehicle_sign_secret") }
    }
    @Published var nioVehicleSignAlgo: String = UserDefaults.standard.string(forKey: "nio_vehicle_sign_algo") ?? "md5_full" {
        didSet { UserDefaults.standard.set(nioVehicleSignAlgo, forKey: "nio_vehicle_sign_algo") }
    }
    @Published var nioVehicleApiSign: String = UserDefaults.standard.string(forKey: "nio_vehicle_sign") ?? "" {
        didSet { UserDefaults.standard.set(nioVehicleApiSign, forKey: "nio_vehicle_sign") }
    }
    @Published var nioVehicleApiTimestamp: String = UserDefaults.standard.string(forKey: "nio_vehicle_timestamp") ?? "" {
        didSet { UserDefaults.standard.set(nioVehicleApiTimestamp, forKey: "nio_vehicle_timestamp") }
    }
    @Published var nioVehicleAccessToken: String = UserDefaults.standard.string(forKey: "nio_vehicle_token") ?? "" {
        didSet {
            UserDefaults.standard.set(nioVehicleAccessToken, forKey: "nio_vehicle_token")
            // Token 实质变更时记录录入时间（蔚来 access_token 有效期 30 天，用于倒计时提醒）
            let normalized = normalizeBearer(nioVehicleAccessToken)
            let previous = normalizeBearer(oldValue)
            if normalized != previous {
                if normalized.isEmpty {
                    UserDefaults.standard.removeObject(forKey: "nio_token_created_at")
                } else {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "nio_token_created_at")
                }
            }
        }
    }
    @Published var nioUserAccessToken: String = UserDefaults.standard.string(forKey: "nio_user_access_token") ?? "" {
        didSet { UserDefaults.standard.set(nioUserAccessToken, forKey: "nio_user_access_token") }
    }
    @Published var nioChangeApiURL: String = UserDefaults.standard.string(forKey: "nio_change_api_url") ?? "" {
        didSet { UserDefaults.standard.set(nioChangeApiURL, forKey: "nio_change_api_url") }
    }
    @Published var nioChangeAccessToken: String = UserDefaults.standard.string(forKey: "nio_change_token") ?? "" {
        didSet { UserDefaults.standard.set(nioChangeAccessToken, forKey: "nio_change_token") }
    }
    @Published var nioCheckinApiURL: String = UserDefaults.standard.string(forKey: "nio_checkin_api_url") ?? "" {
        didSet { UserDefaults.standard.set(nioCheckinApiURL, forKey: "nio_checkin_api_url") }
    }
    @Published var nioCheckinAccessToken: String = UserDefaults.standard.string(forKey: "nio_checkin_token") ?? "" {
        didSet { UserDefaults.standard.set(nioCheckinAccessToken, forKey: "nio_checkin_token") }
    }
    @Published var nioIsAutoPollEnabled: Bool = UserDefaults.standard.object(forKey: "nio_auto_poll") == nil ? true : UserDefaults.standard.bool(forKey: "nio_auto_poll") {
        didSet { UserDefaults.standard.set(nioIsAutoPollEnabled, forKey: "nio_auto_poll") }
    }
    @Published var nioVehiclePollIntervalSeconds: Int = max(60, UserDefaults.standard.integer(forKey: "nio_poll_interval") > 0 ? UserDefaults.standard.integer(forKey: "nio_poll_interval") : 300) {
        didSet { UserDefaults.standard.set(nioVehiclePollIntervalSeconds, forKey: "nio_poll_interval") }
    }

    // MARK: - Token 生命周期（逆向实测：登录响应 expires_in=2592000 秒 = 30 天，服务端无 refresh 端点，过期需重抓）

    /// 蔚来 access_token 有效期（秒）：30 天
    static let nioTokenLifetimeSeconds: TimeInterval = 30 * 24 * 3600

    /// Token 预计到期时间（依据本机录入时间推算；无法得知服务端真实签发时刻，误差 ≤ 录入间隔）
    var nioTokenExpiryDate: Date? {
        guard !normalizeBearer(nioVehicleAccessToken).isEmpty,
              let created = UserDefaults.standard.object(forKey: "nio_token_created_at") as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: created + Self.nioTokenLifetimeSeconds)
    }

    /// Token 剩余天数（向上取整，最低 0）
    var nioTokenDaysRemaining: Int? {
        guard let expiry = nioTokenExpiryDate else { return nil }
        return max(0, Int(ceil(expiry.timeIntervalSinceNow / 86400)))
    }

    // MARK: - Published 业务状态

    @Published var vehicleData: NIOVehicleResponse?
    @Published var serviceSummary: NIOServiceSummary?
    @Published var recentOrders: [NIOServiceOrder] = []
    @Published var checkinData: NIOCheckinData?
    @Published var history: [NIOVehicleSnapshot] = []
    @Published var dailyPaths: [NIODailyPath] = []
    @Published var dailyMileageDeltas: [NIODailyDelta] = []
    @Published var fetchLogs: [NIOFetchLogEntry] = []

    @Published var isLoadingVehicle = false
    @Published var isLoadingChange = false
    @Published var isLoadingCheckin = false
    @Published var lastError: String?
    /// 最近一次成功拉取车况的时刻（主 App 首页与桌面 Widget 更新时间的唯一数据源）。
    /// 持久化到 UserDefaults，防止 App 重启后短暂为 nil 时被 `?? Date()` 兜底成"现在"。
    @Published var lastVehicleFetch: Date? {
        didSet {
            let key = Self.lastVehicleFetchKey
            if let lastVehicleFetch {
                UserDefaults.standard.set(lastVehicleFetch.timeIntervalSince1970, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
    private static let lastVehicleFetchKey = "nio_last_vehicle_fetch_time"
    @Published var is403Detected = false
    /// 最近一次智能识别的解析备注（识别到什么/过滤了什么），设置页智能识别卡展示
    @Published var lastParseNotes: [String] = []

    /// 刷新结果横幅（主界面顶部自动消失）：
    /// 进后台/回前台触发的刷新与手动刷新会 announce，后台定时轮询静默不打扰
    @Published var transientNotice: NIOTransientNotice?

    /// 发布一条临时横幅；新横幅直接替换旧横幅（横幅 UI 依 id 自动重新计时消失）
    func publishTransientNotice(_ kind: NIOTransientNotice.Kind, _ message: String) {
        transientNotice = NIOTransientNotice(kind: kind, message: message)
    }

    var isConfigured: Bool {
        if !nioVehicleAccessToken.isEmpty {
            if !nioVehicleApiURL.isEmpty || !nioVehicleId.isEmpty {
                return true
            }
        }
        return false
    }

    // MARK: - 调度状态

    private var vehicleTimer: Timer?
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 30.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // 节流时间戳：change / checkin 变化频率低，轮询时限制最小间隔，
    // 避免高频请求触发风控导致 token 被判定异常而快速失效
    private var lastChangeFetch: Date?
    private var lastCheckinFetch: Date?

    // MARK: - 统一设备指纹（防止服务器判定多端登录导致 token 过快失效）
    //
    // 服务器将 token 与登录设备指纹绑定；同一 token 出现多种 build/iOS 组合
    // 的 User-Agent 交替会被判定为多端登录并踢下线。因此所有请求共享同一指纹：
    //  · app_ver 取自抓包 URL（与签名请求同源），build 号与 app_ver 世代匹配，
    //    避免「NextevCar/6.7.15 + build:2586」这类不存在的组合被识别为伪造客户端
    //  · iOS 版本使用本机真实系统版本，与真机蔚来 App 指纹保持一致
    //  · User-Guid 回放抓包的 device_id，与登录设备绑定同一标识

    private func unifiedUserAgent(for url: URL?) -> String {
        // 优先级：当前请求 URL > 直推捕获的 App 版本 > 抓包 URL > 兜底
        let captured = url.flatMap { NIOVehicleLib.extractQueryParam(from: $0.absoluteString, key: "app_ver") }
            ?? UserDefaults.standard.string(forKey: "nio_captured_app_ver").flatMap { $0.isEmpty ? nil : $0 }
            ?? NIOVehicleLib.extractQueryParam(from: nioVehicleApiURL, key: "app_ver")
        let version = captured ?? "6.7.15"
        let build = version.compare("6.6.0", options: .numeric) == .orderedAscending ? 2586 : 2644
        return "NextevCar/\(version) (com.do1.WeiLaiApp; build:\(build); iOS \(UIDevice.current.systemVersion)) Alamofire/5.9.1"
    }

    private func applyDeviceFingerprint(to req: inout URLRequest, url: URL?) {
        req.setValue(unifiedUserAgent(for: url), forHTTPHeaderField: "User-Agent")
        if !nioDeviceId.isEmpty {
            req.setValue(nioDeviceId, forHTTPHeaderField: "User-Guid")
        }
    }

    private var dataDirectory: URL {
        // 文档目录理论上恒存在；不用强制解包，兜底沙盒临时目录
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = docs.appendingPathComponent("NIO_Data", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var vehicleFile: URL { dataDirectory.appendingPathComponent("vehicle.json") }
    private var cachedTyreFile: URL { dataDirectory.appendingPathComponent("cached_tyre.json") }
    private var cachedLvBattFile: URL { dataDirectory.appendingPathComponent("cached_lv_batt.json") }
    private var cachedFotaFile: URL { dataDirectory.appendingPathComponent("cached_fota.json") }
    private var cachedDoorFile: URL { dataDirectory.appendingPathComponent("cached_door.json") }
    private var cachedKeyFile: URL { dataDirectory.appendingPathComponent("cached_key.json") }
    private var cachedHeatingFile: URL { dataDirectory.appendingPathComponent("cached_heating.json") }
    private var cachedWindowFile: URL { dataDirectory.appendingPathComponent("cached_window.json") }
    private var cachedFrdgFile: URL { dataDirectory.appendingPathComponent("cached_frdg.json") }
    private var cachedBoxFile: URL { dataDirectory.appendingPathComponent("cached_box.json") }
    private var cachedLightFile: URL { dataDirectory.appendingPathComponent("cached_light.json") }
    private var cachedOffcarFile: URL { dataDirectory.appendingPathComponent("cached_offcar.json") }
    private var historyFile: URL { dataDirectory.appendingPathComponent("history.json") }
    private var checkinFile: URL { dataDirectory.appendingPathComponent("checkin.json") }
    private var logsFile: URL { dataDirectory.appendingPathComponent("logs.json") }
    private var ordersFile: URL { dataDirectory.appendingPathComponent("orders.json") }

    var cachedTyreStatus: [String: NIOJSONValue]? = nil
    var cachedLvBattStatus: [String: NIOJSONValue]? = nil
    var cachedFotaStatus: NIOFotaStatus? = nil
    var cachedDoorStatus: [String: NIOJSONValue]? = nil
    var cachedKeyStatus: [String: NIOJSONValue]? = nil
    var cachedHeatingStatus: [String: NIOJSONValue]? = nil
    var cachedWindowStatus: [String: NIOJSONValue]? = nil
    var cachedFrdgStatus: [String: NIOJSONValue]? = nil
    var cachedBoxStatus: [String: NIOJSONValue]? = nil
    var cachedLightStatus: [String: NIOJSONValue]? = nil
    var cachedOffcarStatus: [String: NIOJSONValue]? = nil
    private var lastFetchTimestamp: Date? = nil
    /// 从小组件 / 控制胶囊进入 App 时，fetchVehicle 正在跑会被 guard 吞掉；
    /// 记录 pending 标志，当前轮结束后自动补一轮，避免刷新卡住。
    private var pendingVehicleRefresh = false
    /// Widget is inexpensive and keeps the live activity fresh. Full RVS blocks
    /// (tyre, FOTA, doors…) are only refreshed when stale, explicitly requested,
    /// or still absent; this avoids repeatedly hitting the private telemetry API.
    private var lastTelemetryFetch: Date? = nil
    // RVS 遥测冷却：车级 vehicle_token 对 RVS 接口必然 auth_failed（app_id not login），
    // 失败后 30 分钟内跳过 RVS 路白发请求；widget/info（车级 token 的正确接口）独立承担数据。
    private var rvsBlockedUntil: Date? = nil
    private let telemetryRefreshInterval: TimeInterval = 15 * 60

    private init() {
        // 先恢复持久化的更新时间，再异步加载缓存/网络数据，
        // 确保冷启动初期 buildState 兜底不会把更新时间写成"现在"（init 内直接赋值不触发 didSet）
        if let ts = UserDefaults.standard.object(forKey: Self.lastVehicleFetchKey) as? TimeInterval, ts > 0 {
            lastVehicleFetch = Date(timeIntervalSince1970: ts)
        }
        loadPersistedData()
        startScheduling()
        setupLifecycleObservers()
        setupIslandRaiseObserver()
    }

    /// 控制胶囊上岛实时通道：App 已在前台运行时 scenePhase 不会变化（onChange 不触发），
    /// Widget 扩展点击胶囊后 post Darwin 通知，此处监听立即消费上岛请求。
    private func setupIslandRaiseObserver() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                Task { @MainActor in NIOService.shared.checkPendingIslandRaise() }
            },
            "com.yumikotoysrr.wheater.raiseIsland" as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 进入后台立即拉一轮车况（亮屏切聊天 / 锁屏都会走到这里），
                // 保证锁屏瞬间数据尽量新；结果经横幅反馈，下次回前台可见
                Task { await self.fetchVehicle(force: false, announce: true) }
                // 后台定位保活激活时，轮询定时器继续在后台跑（车况准实时）；
                // 未开保活则暂停轮询，杜绝后台无效网络唤醒与并发冲突
                guard !NIOLocationKeepAlive.shared.isKeepingAlive else { return }
                self.vehicleTimer?.invalidate()
                self.vehicleTimer = nil
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 回到前台后平滑恢复调度；与上一次成功拉取间隔 ≥ 60 秒即刷新一次（含横幅反馈）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self else { return }
                // 控制胶囊上岛接力：回前台先消费 Widget 扩展写入的快速上岛请求
                self.checkPendingIslandRaise()
                // 刷新节流以上一次"实际发起且成功"的拉取为准（lastFetchTimestamp），
                // 而非界面更新时间——后者现在只在数据变化时才推进
                let lastAttempt = self.lastFetchTimestamp ?? self.lastVehicleFetch
                if lastAttempt == nil || Date().timeIntervalSince(lastAttempt!) >= 60 {
                    Task { [weak self] in await self?.fetchVehicle(force: false, announce: true) }
                }
                self.scheduleNextVehiclePoll()
            }
        }
    }

    // MARK: - 调度管理 (智能退避 + 随机 Jitter 扰动)

    func startScheduling() {
        stopScheduling()
        guard isConfigured && nioIsAutoPollEnabled else { return }
        refreshAll()
        scheduleNextVehiclePoll()
    }

    func scheduleNextVehiclePoll() {
        vehicleTimer?.invalidate()
        guard isConfigured && nioIsAutoPollEnabled else { return }

        // 基础周期：若 403 触发则自动退避 15 分钟 (900秒) 避免频繁撞车封禁 Token
        let baseInterval: Double
        if is403Detected {
            baseInterval = 900.0
        } else {
            baseInterval = Double(max(60, nioVehiclePollIntervalSeconds))
        }

        // 注入 ± 15~35 秒随机 Jitter，错开与 macOS / 手机 App 的并发时间窗口
        let jitter = Double.random(in: -15...35)
        let finalInterval = max(60.0, baseInterval + jitter)

        vehicleTimer = Timer.scheduledTimer(withTimeInterval: finalInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchVehicle()
                self?.scheduleNextVehiclePoll()
            }
        }
    }

    func stopScheduling() {
        vehicleTimer?.invalidate()
        vehicleTimer = nil
    }

    // MARK: - 刷新全部

    /// 全量刷新。轮询走默认 force=false（change/checkin 受节流），用户手动刷新传 force=true。
    /// announce = true 时拉取结束弹横幅反馈「数据已更新 / 无数据更新」（进后台/回前台/手动刷新）。
    func refreshAll(force: Bool = false, announce: Bool = false) {
        Task {
            async let v: () = fetchVehicle(force: force, announce: announce)
            async let c: () = fetchChange(force: force)
            async let k: () = fetchCheckin(force: force)
            _ = await (v, c, k)
            // 更新时间由 fetchVehicle 成功路径（真实拿到数据后）写入。
            // 此处不可无条件重置为当前时刻：请求被防抖吞掉或失败时，
            // 会把"更新时间"伪刷新成"现在"，导致桌面 Widget 恒显示"刚刚"。
        }
    }

    // MARK: - 车辆双 API 协同调度拉取架构 (参考 nio-dash / ha-nio)
    // 链路 1 (Widget 动态签名接口): 专精拉取实时 SOC 电量、充电状态/功率、行车状态、车辆闭锁、实时定位与温度 (动态签名永不过期)
    // 链路 2 (RVS 全量遥测接口): 专精拉取 4 轮胎压/胎温、车机固件 FOTA、12V 小电瓶电压/电量、7门车窗天窗开度全景、车外灯光、座椅方向盘加热、车载冰箱、离车守卫/露营/宠物模式

    /// announce = true 时，无论数据是否变化都在拉取结束后发布横幅（数据已更新 / 无数据更新 / 拉取失败）。
    /// 后台定时轮询保持 announce=false 静默，避免高频打扰。
    func fetchVehicle(force: Bool = false, announce: Bool = false) async {
        guard isConfigured else { return }
        guard !isLoadingVehicle else {
            // 从小组件进入时可能正赶上后台轮询在跑，静默丢弃会导致"卡住"。
            // force 请求标记 pending，当前轮结束后自动补一轮。
            if force { pendingVehicleRefresh = true }
            return
        }

        // 防抖节流阀：防止短时间连续点击造成的并发突发请求
        if !force, let last = lastFetchTimestamp, Date().timeIntervalSince(last) < 8.0 {
            return
        }

        isLoadingVehicle = true
        defer {
            isLoadingVehicle = false
            scheduleNextVehiclePoll()
            // 补跑被 guard 吞掉的 force 请求（从小组件 / 控制胶囊进入时的刷新）
            if pendingVehicleRefresh {
                pendingVehicleRefresh = false
                Task { await fetchVehicle(force: true) }
            }
        }

        let token = normalizeBearer(nioVehicleAccessToken)
        guard !token.isEmpty else {
            lastError = "未配置有效的 Access Token"
            return
        }

        // 1. 获取 Widget 动态小组件实时状态 (高频动态)
        var widgetStatus: NIOVehicleStatus? = nil
        if let widgetUrl = buildWidgetTargetURL() {
            widgetStatus = await fetchWidgetData(url: widgetUrl, token: token)
        }

        // 2. Full RVS telemetry is deliberately decoupled from the high-frequency
        // Widget path. A user may paste several signed captures (one per line),
        // e.g. a lightweight live-status request plus a full tyre/FOTA request.
        // Each request is replayed unchanged because its `field` list is signed.
        let hasMissingTelemetry = !NIOVehicleLib.extractTyreInfo(self.vehicleData?.data?.status?.tyreStatus).hasData
            || (self.vehicleData?.data?.status?.fotaStatus?.currentVersion?.isEmpty != false)
        // Android 身份下 widget 高频路被跳过，RVS 成为唯一数据源——节流间隔跟随用户轮询间隔，
        // 避免沿用 iOS 双路时代的 15 分钟全量节流导致电量等动态数据滞后。
        let telemetryInterval: TimeInterval = nioVehicleSignAlgo == "md5_full"
            ? TimeInterval(max(60, nioVehiclePollIntervalSeconds))
            : telemetryRefreshInterval
        var shouldRefreshTelemetry = force || hasMissingTelemetry
            || lastTelemetryFetch.map { Date().timeIntervalSince($0) >= telemetryInterval } ?? true
        // RVS 冷却窗口内跳过（车级 token 必败场景，详见 rvsBlockedUntil 注释）
        if Date() < (rvsBlockedUntil ?? .distantPast) { shouldRefreshTelemetry = false }
        var rvsStatus: NIOVehicleStatus? = nil
        if shouldRefreshTelemetry {
            let rvsStatuses = await withTaskGroup(of: NIOVehicleStatus?.self) { group in
                for rvsURL in buildRvsTargetURLs() {
                    group.addTask { [weak self] in
                        guard let self else { return nil }
                        return await self.fetchRvsData(url: rvsURL, token: token)
                    }
                }
                var values: [NIOVehicleStatus] = []
                for await value in group {
                    if let value { values.append(value) }
                }
                return values
            }
            rvsStatus = mergeRVSStatuses(rvsStatuses)
            if rvsStatus != nil { lastTelemetryFetch = Date() }
        }

        // 3. 智能融合两路 API 数据与持久化落盘缓存 (Smart Merge)
        if widgetStatus != nil || rvsStatus != nil {
            // 数据变化检测：以融合前旧状态为基线，显著内容指纹一致 = 本次拉取无新数据。
            // 只有真实变化才更新主界面"更新时间"，避免无变化轮次把时间伪刷成"现在"。
            let previousFingerprint = NIOVehicleLib.statusFingerprint(self.vehicleData?.data?.status)
            let merged = mergeVehicleStatus(widget: widgetStatus, rvs: rvsStatus)
            let newFingerprint = NIOVehicleLib.statusFingerprint(merged.data?.status)
            let dataChanged = newFingerprint != previousFingerprint

            self.vehicleData = merged
            if dataChanged || lastVehicleFetch == nil {
                self.lastVehicleFetch = Date()
            }
            self.lastFetchTimestamp = Date()
            self.lastError = nil
            self.is403Detected = false

            if announce {
                publishTransientNotice(
                    dataChanged ? .success : .neutral,
                    dataChanged ? "当前记录数据已更新" : "当前记录无数据更新"
                )
            }

            // 同步刷新 iOS 灵动岛与锁屏实时活动（携带刷新结果标签，Widget 同步下发）
            self.updateLiveActivity(notice: dataChanged ? "已更新" : "无数据更新")

            // 异步持久化到本地
            saveJSONAsync(merged, to: vehicleFile)
            appendSnapshot(merged)
        } else {
            if self.vehicleData == nil {
                self.lastError = "车辆数据拉取失败，请在蔚来 App 爱车页下拉刷新后重新嗅探"
            }
            if announce {
                publishTransientNotice(.warn, "车况拉取失败 · 稍后自动重试")
            }
        }
    }

    private func buildWidgetTargetURL() -> URL? {
        // md5_full（Android/iOS 通用逆向算法）实测打通 widget/info：
        // app_id=10001 + 车级 vehicle_token + md5(GET+path+?+canon+secret+Bearer头值) → 200 全量车况。
        // 旧算法（md5_append 等）沿用 iOS 抓包语境：app_id=10002 + iOS secret。
        let algo = nioVehicleSignAlgo.isEmpty ? "md5_append" : nioVehicleSignAlgo
        let isFullAlgo = algo == "md5_full"
        if !nioVehicleId.isEmpty {
            let devId = nioDeviceId.isEmpty ? "iOS_Device_\(nioVehicleId.prefix(6))" : nioDeviceId
            if let built = NIOVehicleLib.buildWidgetURL(
                vehicleId: nioVehicleId,
                deviceId: devId,
                secret: nioVehicleSignSecret.isEmpty ? NIOVehicleLib.builtinSignSecret : nioVehicleSignSecret,
                algo: algo,
                appId: isFullAlgo ? "10001" : "10002",
                authorization: isFullAlgo ? normalizeBearer(nioVehicleAccessToken) : nil
            ) {
                return built.url
            }
        }
        // 若未填 vehicleId，但有 nioVehicleApiURL，尝试从中提取 vehicleId 与 deviceId
        if !nioVehicleApiURL.isEmpty {
            if let vid = NIOVehicleLib.extractQueryParam(from: nioVehicleApiURL, key: "vehicle_id"), !vid.isEmpty {
                let devId = NIOVehicleLib.extractQueryParam(from: nioVehicleApiURL, key: "device_id") ?? "iOS_Device_\(vid.prefix(6))"
                let sgn = NIOVehicleLib.extractQueryParam(from: nioVehicleApiURL, key: "sign")
                let ts = NIOVehicleLib.extractQueryParam(from: nioVehicleApiURL, key: "timestamp") ?? "\(Int(Date().timeIntervalSince1970))"
                if let built = NIOVehicleLib.buildWidgetURL(
                    vehicleId: vid, deviceId: devId,
                    secret: nioVehicleSignSecret.isEmpty ? NIOVehicleLib.builtinSignSecret : nioVehicleSignSecret,
                    algo: algo,
                    appId: isFullAlgo ? "10001" : "10002",
                    authorization: isFullAlgo ? normalizeBearer(nioVehicleAccessToken) : nil
                ) {
                    return built.url
                }
                if let sgn = sgn, !sgn.isEmpty {
                    let wStr = "https://app.nio.com/app/api/icar/v2/widget/info?widget_size=large&app_id=10002&widget_functions=rvs_set_doorlock%2Crvs_set_air_conditioner%2Crvs_set_tailgate%2Crvs_exe_findme&lang=zh-CN&region=cn&device_id=\(devId)&timestamp=\(ts)&vehicle_id=\(vid)&app_ver=6.7.15&sign=\(sgn)"
                    return URL(string: wStr)
                }
            }
        }
        return nil
    }

    private func buildRvsTargetURLs() -> [URL] {
        var urls: [URL] = []
        let vid = nioVehicleId.isEmpty ? (NIOVehicleLib.extractQueryParam(from: nioVehicleApiURL, key: "vehicle_id") ?? "") : nioVehicleId
        let devId = nioDeviceId.isEmpty ? (NIOVehicleLib.extractQueryParam(from: nioVehicleApiURL, key: "device_id") ?? "iOS_Device_\(vid.prefix(6))") : nioDeviceId
        let ts = String(Int(Date().timeIntervalSince1970))

        // 1. User-captured URLs are replayed verbatim. Multiple newline-separated
        // captures are supported so narrow, signed requests can complement each
        // other (for example `field=tyre` and `field=fota`).
        let capturedURLs = nioVehicleApiURL
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { $0.contains("icar.nio.com") && $0.contains("/status") }
        for captured in capturedURLs {
            let trimmed = captured.trimmingCharacters(in: .whitespacesAndNewlines)
            var fullUrl = trimmed
            if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
                fullUrl = "https://\(trimmed)"
            }
            if let resigned = NIOVehicleLib.autoResignRvsURL(
                    fullUrl,
                    secret: nioVehicleSignSecret,
                    algo: nioVehicleSignAlgo,
                    authorization: normalizeBearer(nioVehicleAccessToken)),
               let u = URL(string: resigned) {
                urls.append(u)
            }
            if let u = URL(string: fullUrl), !urls.contains(u) {
                urls.append(u)
            }
        }

        // 2. 基于 vehicleId 动态构建 RVS 遥测候选 URL
        if !vid.isEmpty {
            // 仅保留实测存活的两个 RVS 基座（签名通过、返回 auth_failed 层错误）：
            // app.nio.com/.../v2/vehicle 与 gateway-front-external/moat 已实测 404（路径不存在），剔除。
            let baseCandidates = [
                "https://icar.nio.com/api/2/rvs/vehicle/\(vid)/status",
                "https://icar.nio.com/api/1/vehicle/\(vid)/status"
            ]

            for base in baseCandidates {
                var params: [String: String] = [
                    "region": "cn",
                    "lang": "zh-CN",
                    "app_ver": "6.5.3",
                    "app_id": NIOVehicleLib.androidAppID,
                    "device_id": devId,
                    "timestamp": ts
                ]
                // 空值回落内置 Android 密钥：用户清空字段也不退化为无签名请求
                let effectiveSecret = nioVehicleSignSecret.isEmpty ? NIOVehicleLib.builtinSignSecret : nioVehicleSignSecret
                if !effectiveSecret.isEmpty {
                    if nioVehicleSignAlgo == "md5_full",
                       let basePath = URL(string: base)?.path {
                        // Android 客户端真实算法：METHOD+path 参与签名，Authorization 完整头值作尾串
                        params["sign"] = NIOVehicleLib.computeAndroidSign(
                            method: "GET",
                            path: basePath,
                            params: params,
                            secret: effectiveSecret,
                            authorization: normalizeBearer(nioVehicleAccessToken))
                    } else {
                        params["sign"] = NIOVehicleLib.computeWidgetSign(params: params, secret: effectiveSecret, algo: nioVehicleSignAlgo)
                    }
                } else if !nioVehicleApiSign.isEmpty {
                    params["sign"] = nioVehicleApiSign
                }
                var comp = URLComponents(string: base)
                comp?.queryItems = params.keys.sorted().map { URLQueryItem(name: $0, value: params[$0]) }
                if let u = comp?.url, !urls.contains(u) {
                    urls.append(u)
                }
            }
        }

        return urls
    }

    /// Combines independently captured, signed RVS responses by status block.
    /// Encoding back through the model keeps new/unknown blocks forward-compatible.
    private func mergeRVSStatuses(_ statuses: [NIOVehicleStatus]) -> NIOVehicleStatus? {
        guard !statuses.isEmpty else { return nil }
        var merged: [String: Any] = [:]
        for status in statuses {
            guard let data = try? JSONEncoder().encode(status),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for (key, value) in object where !(value is NSNull) { merged[key] = value }
        }
        guard !merged.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: merged) else { return statuses.first }
        return try? JSONDecoder().decode(NIOVehicleStatus.self, from: data)
    }

    // MARK: - 凭证失效上报 (401/403)

    /// Token 过期/失效提醒：点亮"凭证失效"状态 + 明确文案 + 警示触感。
    /// 此前 401/403 只写入拉取日志即静默返回，状态点/退避/横幅全部不触发；
    /// 修复成功后由 fetchVehicle 成功分支自动复位（is403Detected = false + lastError = nil）。
    ///
    /// 403 ≠ Token 失效：签名/时间戳过期、风控拦截同样返回 403，而 Token 实际仍有效
    /// （佐证：蔚来 App 刷新后 SR 抓到的 Token 未变化）。这里按响应体关键词分类：
    /// - 签名/时间戳类 → 不点亮失效状态，提示补抓 sign_secret
    /// - 风控/WAF 拦截类 → 不点亮失效状态，提示稍后自动恢复
    /// - 鉴权类 / 无响应体 → 按 Token 失效处理（保持统一 401/403 检测约定）
    private func noteAuthFailure(_ statusCode: Int, body: String? = nil) {
        guard statusCode == 401 || statusCode == 403 else { return }
        let blob = (body ?? "").lowercased()
        let detail = extractErrorDetail(from: body)

        if blob.contains("sign") || blob.contains("timestamp") || blob.contains("签名") || blob.contains("时间戳") {
            lastError = "接口签名/时间戳校验被拒（HTTP \(statusCode)）· Token 仍有效，补抓 sign_secret 后自动恢复\(detail)"
            return
        }
        // "app_id not login <uid>"：Token 可被服务端解析（已还原 user），但该 Token 的类型与会话
        // 绑定不匹配当前接口——车级 vehicle_token（小组件体系）对 RVS 遥测接口必然报此错，
        // 只有用户级 access_token（App 登录会话）能调 RVS；widget/info 两类均可。
        if blob.contains("app_id not login") || blob.contains("no access found") {
            lastError = "Token 与接口不匹配（HTTP \(statusCode)）· 车级 vehicle_token 仅支持 widget/info 接口，RVS 遥测需用户级 access_token · 当前已自动切换 widget/info 数据源\(detail)"
            return
        }
        if blob.contains("<html") || blob.contains("<!doctype") {
            lastError = "请求被网关/WAF 拦截（HTTP \(statusCode)）· Token 仍有效，稍后自动重试\(detail)"
            return
        }
        if blob.contains("risk") || blob.contains("captcha") || blob.contains("风控") {
            lastError = "请求被风控拦截（HTTP \(statusCode)）· Token 仍有效，稍后自动重试\(detail)"
            return
        }
        guard !is403Detected else { return }
        is403Detected = true
        lastError = "蔚来 Token 已失效（HTTP \(statusCode)），自动刷新已降频为 15 分钟重试 · 打开蔚来 App 爱车页下拉刷新即可自动更新，无需重新登录\(detail)"
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// 从 401/403 响应体提取 resultCode / errorMsg 供诊断展示；无法解析时展示原文前 80 字符
    private func extractErrorDetail(from body: String?) -> String {
        guard let body, !body.isEmpty else { return "" }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return " · 响应: \(body.prefix(80))"
        }
        let code = (json["resultCode"] as? String) ?? ""
        let msg = (json["errorMsg"] as? String) ?? (json["message"] as? String) ?? ""
        var parts: [String] = []
        if !code.isEmpty { parts.append("code=\(code)") }
        if !msg.isEmpty { parts.append("msg=\(msg)") }
        return parts.isEmpty ? "" : " · \(parts.joined(separator: " "))"
    }

    private func fetchWidgetData(url: URL, token: String) async -> NIOVehicleStatus? {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh-Hans;q=0.9", forHTTPHeaderField: "Accept-Language")
        applyDeviceFingerprint(to: &req, url: url)
        req.setValue(token, forHTTPHeaderField: "Authorization")

        let logEntry = NIOFetchLogEntry(
            category: "vehicle_widget", level: "info",
            message: "Widget 动态接口 · 开始拉取实时状态…",
            detail: nil, timestamp: Date(),
            requestURL: url.absoluteString, requestMethod: "GET",
            requestBody: nil, responsePreview: nil, statusCode: nil
        )
        appendLog(logEntry)

        do {
            var (data, response) = try await urlSession.data(for: req)
            var text = String(data: data, encoding: .utf8) ?? ""

            // 时间戳过期自愈：部分蔚来网关只校验时间戳新鲜度、不校验 sign 与 timestamp 绑定
            // （ha-nio 实证）。401/403 且 URL 带时间戳时，本地刷新 timestamp 保留原 sign 重试一次；
            // 若服务端同时校验绑定则重试仍被拒，回退为原失败上报，无额外副作用。
            if let http = response as? HTTPURLResponse,
               http.statusCode == 401 || http.statusCode == 403,
               let freshStr = NIOVehicleLib.refreshTimestampParam(in: url.absoluteString),
               let freshURL = URL(string: freshStr) {
                var retryReq = req
                retryReq.url = freshURL
                applyDeviceFingerprint(to: &retryReq, url: freshURL)
                let (rData, rResponse) = try await urlSession.data(for: retryReq)
                if let rHttp = rResponse as? HTTPURLResponse {
                    data = rData
                    response = rHttp
                    text = String(data: rData, encoding: .utf8) ?? ""
                }
            }

            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 200, let rawJson = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let norm = RVSRormalizer.normalize(rawJson)
                let normData = try JSONSerialization.data(withJSONObject: norm)
                let decoded = try JSONDecoder().decode(NIOVehicleResponse.self, from: normData)
                updateLog(logEntry, statusCode: 200, preview: String(text.prefix(200)))
                return decoded.data?.status
            } else {
                updateLog(logEntry, statusCode: http.statusCode, preview: String(text.prefix(200)))
                noteAuthFailure(http.statusCode, body: text)
            }
        } catch {
            updateLog(logEntry, statusCode: nil, preview: error.localizedDescription)
        }
        return nil
    }

    private func fetchRvsData(url: URL, token: String) async -> NIOVehicleStatus? {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json,text/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh-Hans;q=0.9", forHTTPHeaderField: "Accept-Language")
        applyDeviceFingerprint(to: &req, url: url)
        if url.host?.lowercased().contains("icar.nio.com") == true {
            req.setValue("tsp.nio.com", forHTTPHeaderField: "Host")
        }
        req.setValue(token, forHTTPHeaderField: "Authorization")

        let logEntry = NIOFetchLogEntry(
            category: "vehicle_rvs", level: "info",
            message: "RVS 全量接口 · 开始拉取遥测车况…",
            detail: nil, timestamp: Date(),
            requestURL: url.absoluteString, requestMethod: "GET",
            requestBody: nil, responsePreview: nil, statusCode: nil
        )
        appendLog(logEntry)

        do {
            var (data, response) = try await urlSession.data(for: req)
            var text = String(data: data, encoding: .utf8) ?? ""

            // 时间戳过期自愈（同 Widget 链路）：刷新 timestamp 保留原 sign 重试一次，
            // 仅当服务端不校验 sign 与 timestamp 绑定时生效，否则回退原失败上报。
            if let http = response as? HTTPURLResponse,
               http.statusCode == 401 || http.statusCode == 403,
               let freshStr = NIOVehicleLib.refreshTimestampParam(in: url.absoluteString),
               let freshURL = URL(string: freshStr) {
                var retryReq = req
                retryReq.url = freshURL
                let (rData, rResponse) = try await urlSession.data(for: retryReq)
                if let rHttp = rResponse as? HTTPURLResponse {
                    data = rData
                    response = rHttp
                    text = String(data: rData, encoding: .utf8) ?? ""
                }
            }

            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 200, let rawJson = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let norm = RVSRormalizer.normalize(rawJson)
                let normData = try JSONSerialization.data(withJSONObject: norm)
                let decoded = try JSONDecoder().decode(NIOVehicleResponse.self, from: normData)
                updateLog(logEntry, statusCode: 200, preview: String(text.prefix(200)))
                return decoded.data?.status
            } else {
                updateLog(logEntry, statusCode: http.statusCode, preview: String(text.prefix(200)))
                noteAuthFailure(http.statusCode, body: text)
                // RVS 鉴权失败 → 进入冷却，避免后续轮询反复白发请求
                if text.contains("app_id not login") || text.contains("no access found") {
                    rvsBlockedUntil = Date().addingTimeInterval(30 * 60)
                }
            }
        } catch {
            updateLog(logEntry, statusCode: nil, preview: error.localizedDescription)
        }
        return nil
    }

    private func mergeVehicleStatus(widget: NIOVehicleStatus?, rvs: NIOVehicleStatus?) -> NIOVehicleResponse {
        var base = self.vehicleData ?? NIOVehicleResponse(
            resultCode: "success",
            data: NIOVehicleData(
                status: NIOVehicleStatus(vehicleId: self.nioVehicleId)
            )
        )
        if base.data == nil { base.data = NIOVehicleData(status: NIOVehicleStatus(vehicleId: self.nioVehicleId)) }
        if base.data?.status == nil { base.data?.status = NIOVehicleStatus(vehicleId: self.nioVehicleId) }

        // --- 1. 实时动态状态 (优先取 Widget 动态最新，其次取 RVS) ---
        if let wSoc = widget?.socStatus ?? rvs?.socStatus {
            base.data?.status?.socStatus = wSoc
        }
        if let wConn = widget?.connectionStatus ?? rvs?.connectionStatus {
            base.data?.status?.connectionStatus = wConn
        }
        if let wPos = widget?.positionStatus ?? rvs?.positionStatus {
            base.data?.status?.positionStatus = wPos
        }
        if let wExt = widget?.exteriorStatus ?? rvs?.exteriorStatus {
            base.data?.status?.exteriorStatus = wExt
        }
        if let wHvac = widget?.hvacStatus ?? rvs?.hvacStatus {
            var finalHvac = wHvac
            if finalHvac.outsideTemperature == nil {
                finalHvac.outsideTemperature = rvs?.hvacStatus?.outsideTemperature ?? self.vehicleData?.data?.status?.hvacStatus?.outsideTemperature
            }
            base.data?.status?.hvacStatus = finalHvac
        }

        // --- 2. 全量遥测状态 (优先取 RVS 全量，其次取持久化缓存，再次取已有数据) ---
        // 2.1 4 轮胎压/胎温
        if let rTyre = rvs?.tyreStatus, NIOVehicleLib.extractTyreInfo(rTyre).hasData {
            base.data?.status?.tyreStatus = rTyre
            self.cachedTyreStatus = rTyre
            saveJSONAsync(rTyre, to: cachedTyreFile)
        } else if let cTyre = self.cachedTyreStatus, NIOVehicleLib.extractTyreInfo(cTyre).hasData {
            base.data?.status?.tyreStatus = cTyre
        }

        // 2.2 车机固件版本 FOTA
        if let rFota = rvs?.fotaStatus, !(rFota.currentVersion ?? "").isEmpty {
            base.data?.status?.fotaStatus = rFota
            self.cachedFotaStatus = rFota
            saveJSONAsync(rFota, to: cachedFotaFile)
        } else if let cFota = self.cachedFotaStatus {
            base.data?.status?.fotaStatus = cFota
        }

        // 2.3 12V 辅助蓄电池
        if let rLv = rvs?.lvBattStatus, !rLv.isEmpty {
            base.data?.status?.lvBattStatus = rLv
            self.cachedLvBattStatus = rLv
            saveJSONAsync(rLv, to: cachedLvBattFile)
        } else if let cLv = self.cachedLvBattStatus, !cLv.isEmpty {
            base.data?.status?.lvBattStatus = cLv
        }

        // 2.4 车门与车锁 (融合 Widget 实时车锁与 RVS 详细车门)
        var mergedDoors = rvs?.doorStatus ?? self.cachedDoorStatus ?? self.vehicleData?.data?.status?.doorStatus ?? [:]
        if let wDoors = widget?.doorStatus {
            for (k, v) in wDoors { mergedDoors[k] = v }
        }
        if !mergedDoors.isEmpty {
            base.data?.status?.doorStatus = mergedDoors
            self.cachedDoorStatus = mergedDoors
            saveJSONAsync(mergedDoors, to: cachedDoorFile)
        }

        // 2.5 车窗与天窗
        if let rWin = rvs?.windowStatus, !rWin.isEmpty {
            base.data?.status?.windowStatus = rWin
            self.cachedWindowStatus = rWin
            saveJSONAsync(rWin, to: cachedWindowFile)
        } else if let cWin = self.cachedWindowStatus, !cWin.isEmpty {
            base.data?.status?.windowStatus = cWin
        }

        // 2.6 车外灯光
        if let rLight = rvs?.lightStatus, !rLight.isEmpty {
            base.data?.status?.lightStatus = rLight
            self.cachedLightStatus = rLight
            saveJSONAsync(rLight, to: cachedLightFile)
        } else if let cLight = self.cachedLightStatus, !cLight.isEmpty {
            base.data?.status?.lightStatus = cLight
        }

        // 2.7 座椅加热与方向盘加热
        if let rHeat = rvs?.heatingStatus, !rHeat.isEmpty {
            base.data?.status?.heatingStatus = rHeat
            self.cachedHeatingStatus = rHeat
            saveJSONAsync(rHeat, to: cachedHeatingFile)
        } else if let cHeat = self.cachedHeatingStatus, !cHeat.isEmpty {
            base.data?.status?.heatingStatus = cHeat
        }

        // 2.8 冰箱与尾箱
        if let rFrdg = rvs?.frdgStatus, !rFrdg.isEmpty {
            base.data?.status?.frdgStatus = rFrdg
            self.cachedFrdgStatus = rFrdg
            saveJSONAsync(rFrdg, to: cachedFrdgFile)
        } else if let cFrdg = self.cachedFrdgStatus, !cFrdg.isEmpty {
            base.data?.status?.frdgStatus = cFrdg
        }
        if let rBox = rvs?.boxStatus, !rBox.isEmpty {
            base.data?.status?.boxStatus = rBox
            self.cachedBoxStatus = rBox
            saveJSONAsync(rBox, to: cachedBoxFile)
        } else if let cBox = self.cachedBoxStatus, !cBox.isEmpty {
            base.data?.status?.boxStatus = cBox
        }

        // 2.9 离车模式 (守卫/露营/宠物/不下电)
        if let rOffcar = rvs?.offcarModeStatus, !rOffcar.isEmpty {
            base.data?.status?.offcarModeStatus = rOffcar
            self.cachedOffcarStatus = rOffcar
            saveJSONAsync(rOffcar, to: cachedOffcarFile)
        } else if let cOffcar = self.cachedOffcarStatus, !cOffcar.isEmpty {
            base.data?.status?.offcarModeStatus = cOffcar
        }

        // 2.10 保养与其它
        if let rMaint = rvs?.maintainStatus {
            base.data?.status?.maintainStatus = rMaint
        }

        if let vid = widget?.vehicleId ?? rvs?.vehicleId ?? base.data?.status?.vehicleId, !vid.isEmpty {
            base.data?.status?.vehicleId = vid
        }

        return base
    }

    // MARK: - 换电服务拉取

    /// 服务订单/换电拉取。轮询调用 force=false（10 分钟节流），手动刷新 force=true 直通。
    /// 高频拉取会触发风控，导致 token 被判定异常设备而过快失效。
    func fetchChange(force: Bool = false) async {
        guard isConfigured else { return }
        guard !isLoadingChange else { return }
        if !force, let last = lastChangeFetch, Date().timeIntervalSince(last) < 600 { return }
        lastChangeFetch = Date()
        isLoadingChange = true
        defer { isLoadingChange = false }

        let token = normalizeBearer(nioChangeAccessToken.isEmpty ? nioVehicleAccessToken : nioChangeAccessToken)
        guard !token.isEmpty else { return }

        // 多链路候选 URL（解决 404 及旧版网关失效问题）
        let primaryGateway = "https://gateway-front-external.nio.com/moat/1100367/api/v1/otd/car/ext/general/serviceOrder/getTabOrder?offset=0&limit=200&orderTypes=pe_shaman,pe_shaman_change,service_pe_discharge,battery_flexible_upgrade,nsom_so_maintenance,nsom_so_chauffeur,chauffeur_vehicle_delivery,so_case_accident&hash_type=sha256&lang=zh&region=US&tz_offset=28800&app_ver=6.5.3"
        let shortGateway = "https://gateway-front-external.nio.com/moat/1100367/api/v1/otd/car/ext/general/serviceOrder/getTabOrder?offset=0&limit=50&orderTypes=pe_shaman_change,pe_shaman"
        let appNioQueryList = "https://app.nio.com/app/api/service_charge/v2/order/query_list?status=all&app_id=10002"
        let appNioSwapList = "https://app.nio.com/app/api/charge/power_swap/order/list"

        var candidates: [String] = []
        if !nioChangeApiURL.isEmpty {
            let sanitized = nioChangeApiURL.trimmingCharacters(in: .whitespacesAndNewlines)
            candidates.append(sanitized)
        }
        for u in [primaryGateway, shortGateway, appNioQueryList, appNioSwapList] {
            if !candidates.contains(u) { candidates.append(u) }
        }

        for targetChangeURL in candidates {
            guard let url = URL(string: targetChangeURL) else { continue }
            let isAppNio = targetChangeURL.contains("app.nio.com")

            // 尝试 POST 请求
            do {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("zh-CN,zh-Hans;q=0.9", forHTTPHeaderField: "Accept-Language")
                applyDeviceFingerprint(to: &req, url: url)
                req.setValue(token, forHTTPHeaderField: "Authorization")
                req.httpBody = try? JSONSerialization.data(withJSONObject: isAppNio ? ["page_num": 1, "page_size": 20] : ["offset": 0, "limit": 200])

                let (data, response) = try await urlSession.data(for: req)
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 200 {
                        if let decoded = try? JSONDecoder().decode(NIOChangeResponse.self, from: data) {
                            // 空响应保护：接口抖动返回空集时保留旧数据，避免看板突然空白
                            if let newOrders = decoded.resultData?.data, !newOrders.isEmpty {
                                self.serviceSummary = NIOOrderLib.analyzeServiceOrders(decoded)
                                storeRecentOrders(newOrders)
                            }
                            return
                        }
                    } else {
                        noteAuthFailure(http.statusCode, body: String(data: data, encoding: .utf8))
                    }
                }
            } catch {
                print("[NIOService] fetchChange POST 失败: \(error.localizedDescription)")
            }

            // 若 POST 404/405 则尝试 GET 请求
            if isAppNio {
                do {
                    var req = URLRequest(url: url)
                    req.httpMethod = "GET"
                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                    applyDeviceFingerprint(to: &req, url: url)
                    req.setValue(token, forHTTPHeaderField: "Authorization")

                    let (data, response) = try await urlSession.data(for: req)
                    if let http = response as? HTTPURLResponse {
                        if http.statusCode == 200 {
                            if let decoded = try? JSONDecoder().decode(NIOChangeResponse.self, from: data) {
                                if let newOrders = decoded.resultData?.data, !newOrders.isEmpty {
                                    self.serviceSummary = NIOOrderLib.analyzeServiceOrders(decoded)
                                    storeRecentOrders(newOrders)
                                }
                                return
                            }
                        } else {
                            noteAuthFailure(http.statusCode, body: String(data: data, encoding: .utf8))
                        }
                    }
                } catch {
                    print("[NIOService] fetchChange GET 兜底失败: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 签到拉取

    /// 签到状态拉取。轮询调用 force=false（30 分钟节流），手动刷新 force=true 直通。
    func fetchCheckin(force: Bool = false) async {
        guard isConfigured else { return }
        guard !isLoadingCheckin else { return }
        if !force, let last = lastCheckinFetch, Date().timeIntervalSince(last) < 1800 { return }
        lastCheckinFetch = Date()
        isLoadingCheckin = true
        defer { isLoadingCheckin = false }

        let token = normalizeBearer(nioCheckinAccessToken.isEmpty ? nioVehicleAccessToken : nioCheckinAccessToken)
        guard !token.isEmpty else { return }

        // 多链路候选 URL（彻底消除双斜杠 //n/c 导致的 404 Bug）
        let primaryGateway = "https://gateway-front-external.nio.com/moat/10086/n/c/award/square?event=checkin&collection_id=1843940587332317185"
        let fallbackGateway = "https://gateway-front-external.nio.com/moat/10086/n/c/award/square?event=checkin"
        let appNioCheckin = "https://app.nio.com/app/api/users/checkin"
        let appNioStatus = "https://app.nio.com/app/api/users/checkin/status"

        var candidates: [String] = []
        if !nioCheckinApiURL.isEmpty {
            // 自动修复双斜杠 //n/c 历史错误
            let sanitized = nioCheckinApiURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "//n/c", with: "/n/c")
            candidates.append(sanitized)
        }
        for u in [primaryGateway, fallbackGateway, appNioCheckin, appNioStatus] {
            if !candidates.contains(u) { candidates.append(u) }
        }

        for targetCheckinURL in candidates {
            guard let url = URL(string: targetCheckinURL) else { continue }
            do {
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                req.setValue("zh-CN,zh-Hans;q=0.9", forHTTPHeaderField: "Accept-Language")
                applyDeviceFingerprint(to: &req, url: url)
                req.setValue(token, forHTTPHeaderField: "Authorization")

                let (data, response) = try await urlSession.data(for: req)
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 200 {
                        if let rawJson = try? JSONSerialization.jsonObject(with: data) {
                            if let ci = NIOOrderLib.extractCheckinData(from: rawJson) {
                                self.checkinData = ci
                                saveJSONAsync(ci, to: checkinFile)
                                return
                            }
                        }
                    } else {
                        noteAuthFailure(http.statusCode, body: String(data: data, encoding: .utf8))
                    }
                }
            } catch {
                print("[NIOService] fetchCheckin 失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 智能识别与一键填充

    func smartParseInput(_ input: String) -> Bool {
        // 清洗手工粘贴内容：markdown 反引号 / 包裹引号 / 空白（URL 常被 ``` 包裹）
        var trimmed = input
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }

        let parsed = NIOVehicleLib.smartParseInput(trimmed)
        // 解析过程备注（过滤了什么 / 识别到什么），供设置页智能识别卡展示
        lastParseNotes = parsed.notes
        var updated = false

        if let mode = parsed.mode, !mode.isEmpty {
            self.nioVehicleApiMode = mode
            updated = true
        }
        if let vid = parsed.vehicleId, !vid.isEmpty {
            self.nioVehicleId = vid
            updated = true
        }
        if let did = parsed.deviceId, !did.isEmpty {
            self.nioDeviceId = did
            updated = true
        }
        if let sec = parsed.signSecret, !sec.isEmpty {
            self.nioVehicleSignSecret = sec
            self.nioVehicleApiMode = "widget"
            updated = true
        }
        if let algo = parsed.signAlgo, !algo.isEmpty {
            self.nioVehicleSignAlgo = algo
        }
        if let u = parsed.vehicleURL, !u.isEmpty {
            self.nioVehicleApiURL = u
            updated = true
        }
        if let t = parsed.vehicleToken, !t.isEmpty {
            self.nioVehicleAccessToken = t
            updated = true
        }
        if let ut = parsed.userToken, !ut.isEmpty {
            self.nioUserAccessToken = ut
            updated = true
        }
        if let cu = parsed.changeURL, !cu.isEmpty {
            self.nioChangeApiURL = cu
        }
        if let ct = parsed.changeToken, !ct.isEmpty {
            self.nioChangeAccessToken = ct
        }
        if let ku = parsed.checkinURL, !ku.isEmpty {
            self.nioCheckinApiURL = ku
        }
        if let kt = parsed.checkinToken, !kt.isEmpty {
            self.nioCheckinAccessToken = kt
        }
        // 设备指纹落库（防多端登录：统一 UA 构造与诊断用）
        if let av = parsed.appVer, !av.isEmpty {
            UserDefaults.standard.set(av, forKey: "nio_captured_app_ver")
        }
        if let ua = parsed.userAgent, !ua.isEmpty {
            UserDefaults.standard.set(ua, forKey: "nio_captured_user_agent")
        }
        if let ug = parsed.userGuid, !ug.isEmpty {
            UserDefaults.standard.set(ug, forKey: "nio_captured_user_guid")
            // device_id 缺失时用 User-Guid 兜底
            if self.nioDeviceId.isEmpty { self.nioDeviceId = ug }
        }

        if updated {
            startScheduling()
        }
        return updated
    }

    // MARK: - 辅助

    private func normalizeBearer(_ token: String) -> String {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        if t.lowercased().hasPrefix("bearer ") {
            return t
        }
        return "Bearer \(t)"
    }

    private func appendSnapshot(_ resp: NIOVehicleResponse) {
        guard let snap = try? NIOVehicleLib.snapshotFromResponse(resp) else { return }
        guard snap.isValidGPS || snap.ts > 0 else { return }
        if history.contains(where: { $0.snapshotKey == snap.snapshotKey }) { return }
        history.append(snap)
        if history.count > 2000 { history = Array(history.suffix(2000)) }

        let snapshotList = self.history
        updateDerivedMetrics(from: snapshotList)
        saveJSONAsync(snapshotList, to: historyFile)
    }

    private func updateDerivedMetrics(from snapshots: [NIOVehicleSnapshot]) {
        let copy = snapshots
        Task.detached(priority: .userInitiated) {
            let paths = NIOVehicleLib.buildDailyPaths(history: copy)
            let deltas = NIOVehicleLib.computeDailyMileageDeltas(history: copy)
            await MainActor.run {
                NIOService.shared.dailyPaths = paths
                NIOService.shared.dailyMileageDeltas = deltas
            }
        }
    }

    /// 存储最近服务订单（换电/维保等），供维保追踪卡使用；调用方已做空集过滤
    private func storeRecentOrders(_ orders: [NIOServiceOrder]) {
        guard !orders.isEmpty else { return }
        self.recentOrders = orders
        saveJSONAsync(orders, to: ordersFile)
    }

    func appendLog(_ entry: NIOFetchLogEntry) {
        var logs = fetchLogs
        logs.insert(entry, at: 0)
        if logs.count > 50 { logs = Array(logs.prefix(50)) }
        self.fetchLogs = logs
        saveJSONAsync(logs, to: logsFile)
    }

    private func updateLog(_ entry: NIOFetchLogEntry, statusCode: Int?, preview: String?) {
        var updated = entry
        updated.statusCode = statusCode
        updated.responsePreview = preview
        if let idx = fetchLogs.firstIndex(where: { $0.id == entry.id }) {
            fetchLogs[idx] = updated
            saveJSONAsync(fetchLogs, to: logsFile)
        }
    }

    private func loadPersistedData() {
        // 冷启动 IO + 大 JSON 解码全部移出主线程，避免启动掉帧；完成后回主线程发布
        let vFile = vehicleFile
        let tFile = cachedTyreFile
        let lvFile = cachedLvBattFile
        let fotaFile = cachedFotaFile
        let doorFile = cachedDoorFile
        let kFile = cachedKeyFile
        let htFile = cachedHeatingFile
        let wFile = cachedWindowFile
        let fFile = cachedFrdgFile
        let bFile = cachedBoxFile
        let ltFile = cachedLightFile
        let offFile = cachedOffcarFile
        let hFile = historyFile
        let cFile = checkinFile
        let lFile = logsFile
        let oFile = ordersFile
        Task.detached(priority: .userInitiated) { [weak self] in
            var fetchedAt: Date? = nil
            var vehicle: NIOVehicleResponse? = nil
            var cachedTyre: [String: NIOJSONValue]? = nil
            var cachedLv: [String: NIOJSONValue]? = nil
            var cachedFota: NIOFotaStatus? = nil
            var cachedDoor: [String: NIOJSONValue]? = nil
            var cachedKey: [String: NIOJSONValue]? = nil
            var cachedHt: [String: NIOJSONValue]? = nil
            var cachedWin: [String: NIOJSONValue]? = nil
            var cachedFrdg: [String: NIOJSONValue]? = nil
            var cachedBox: [String: NIOJSONValue]? = nil
            var cachedLt: [String: NIOJSONValue]? = nil
            var cachedOff: [String: NIOJSONValue]? = nil
            var history: [NIOVehicleSnapshot] = []
            var checkin: NIOCheckinData? = nil
            var logs: [NIOFetchLogEntry] = []

            func readDict(_ url: URL) -> [String: NIOJSONValue]? {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode([String: NIOJSONValue].self, from: data)
            }

            cachedTyre = readDict(tFile)
            cachedLv = readDict(lvFile)
            cachedDoor = readDict(doorFile)
            cachedKey = readDict(kFile)
            cachedHt = readDict(htFile)
            cachedWin = readDict(wFile)
            cachedFrdg = readDict(fFile)
            cachedBox = readDict(bFile)
            cachedLt = readDict(ltFile)
            cachedOff = readDict(offFile)

            if let data = try? Data(contentsOf: fotaFile) {
                cachedFota = try? JSONDecoder().decode(NIOFotaStatus.self, from: data)
            }

            if let data = try? Data(contentsOf: vFile),
               let decoded = try? JSONDecoder().decode(NIOVehicleResponse.self, from: data) {
                var v = decoded
                if v.data?.status?.tyreStatus == nil || !NIOVehicleLib.extractTyreInfo(v.data?.status?.tyreStatus).hasData {
                    if let cTyre = cachedTyre { v.data?.status?.tyreStatus = cTyre }
                }
                if v.data?.status?.lvBattStatus == nil || v.data?.status?.lvBattStatus?.isEmpty == true {
                    if let cLv = cachedLv { v.data?.status?.lvBattStatus = cLv }
                }
                if v.data?.status?.fotaStatus == nil {
                    if let cFota = cachedFota { v.data?.status?.fotaStatus = cFota }
                }
                if v.data?.status?.doorStatus == nil || v.data?.status?.doorStatus?.isEmpty == true {
                    if let cDoor = cachedDoor { v.data?.status?.doorStatus = cDoor }
                }
                if v.data?.status?.keyStatus == nil || v.data?.status?.keyStatus?.isEmpty == true {
                    if let cKey = cachedKey { v.data?.status?.keyStatus = cKey }
                }
                if v.data?.status?.heatingStatus == nil || v.data?.status?.heatingStatus?.isEmpty == true {
                    if let cHt = cachedHt { v.data?.status?.heatingStatus = cHt }
                }
                if v.data?.status?.windowStatus == nil || v.data?.status?.windowStatus?.isEmpty == true {
                    if let cWin = cachedWin { v.data?.status?.windowStatus = cWin }
                }
                if v.data?.status?.frdgStatus == nil || v.data?.status?.frdgStatus?.isEmpty == true {
                    if let cFrdg = cachedFrdg { v.data?.status?.frdgStatus = cFrdg }
                }
                if v.data?.status?.boxStatus == nil || v.data?.status?.boxStatus?.isEmpty == true {
                    if let cBox = cachedBox { v.data?.status?.boxStatus = cBox }
                }
                if v.data?.status?.lightStatus == nil || v.data?.status?.lightStatus?.isEmpty == true {
                    if let cLt = cachedLt { v.data?.status?.lightStatus = cLt }
                }
                if v.data?.status?.offcarModeStatus == nil || v.data?.status?.offcarModeStatus?.isEmpty == true {
                    if let cOff = cachedOff { v.data?.status?.offcarModeStatus = cOff }
                }
                vehicle = v
                if let ts = decoded.data?.status?.socStatus?.sampleTime, ts > 0 {
                    let sec = ts > 1_000_000_000_000 ? (ts / 1000) : ts
                    fetchedAt = Date(timeIntervalSince1970: TimeInterval(sec))
                } else if let attr = try? FileManager.default.attributesOfItem(atPath: vFile.path),
                          let modDate = attr[.modificationDate] as? Date {
                    fetchedAt = modDate
                }
            }
            if let data = try? Data(contentsOf: hFile) {
                history = (try? JSONDecoder().decode([NIOVehicleSnapshot].self, from: data)) ?? []
            }
            if let data = try? Data(contentsOf: cFile) {
                checkin = try? JSONDecoder().decode(NIOCheckinData.self, from: data)
            }
            if let data = try? Data(contentsOf: lFile) {
                logs = (try? JSONDecoder().decode([NIOFetchLogEntry].self, from: data)) ?? []
            }
            var orders: [NIOServiceOrder] = []
            if let data = try? Data(contentsOf: oFile) {
                orders = (try? JSONDecoder().decode([NIOServiceOrder].self, from: data)) ?? []
            }

            let finalVehicle = vehicle
            let finalCachedTyre = cachedTyre
            let finalCachedLv = cachedLv
            let finalCachedFota = cachedFota
            let finalCachedDoor = cachedDoor
            let finalCachedKey = cachedKey
            let finalCachedHt = cachedHt
            let finalCachedWin = cachedWin
            let finalCachedFrdg = cachedFrdg
            let finalCachedBox = cachedBox
            let finalCachedLt = cachedLt
            let finalCachedOff = cachedOff
            let finalFetchedAt = fetchedAt
            let finalHistory = history
            let finalCheckin = checkin
            let finalLogs = logs
            let finalOrders = orders

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                // 冷启动竞态保护：网络刷新若已先一步写入（对应状态非空），
                // 磁盘快照不再覆盖，避免慢盘读到的旧数据覆盖刚拉取的新数据
                if self.cachedTyreStatus == nil { self.cachedTyreStatus = finalCachedTyre }
                if self.cachedLvBattStatus == nil { self.cachedLvBattStatus = finalCachedLv }
                if self.cachedFotaStatus == nil { self.cachedFotaStatus = finalCachedFota }
                if self.cachedDoorStatus == nil { self.cachedDoorStatus = finalCachedDoor }
                if self.cachedKeyStatus == nil { self.cachedKeyStatus = finalCachedKey }
                if self.cachedHeatingStatus == nil { self.cachedHeatingStatus = finalCachedHt }
                if self.cachedWindowStatus == nil { self.cachedWindowStatus = finalCachedWin }
                if self.cachedFrdgStatus == nil { self.cachedFrdgStatus = finalCachedFrdg }
                if self.cachedBoxStatus == nil { self.cachedBoxStatus = finalCachedBox }
                if self.cachedLightStatus == nil { self.cachedLightStatus = finalCachedLt }
                if self.cachedOffcarStatus == nil { self.cachedOffcarStatus = finalCachedOff }
                if let v = finalVehicle, self.vehicleData == nil {
                    self.vehicleData = v
                    self.lastVehicleFetch = finalFetchedAt
                    // 冷启动兜底：即使网络拉取失败（如 Token 失效），桌面 Widget 也能立即
                    // 显示最近缓存车况，不再停留在"打开 App 同步车况"空状态
                    self.updateLiveActivity()
                }
                if !finalHistory.isEmpty, self.history.isEmpty {
                    self.history = finalHistory
                    self.updateDerivedMetrics(from: finalHistory)
                }
                if let c = finalCheckin, self.checkinData == nil { self.checkinData = c }
                if !finalLogs.isEmpty, self.fetchLogs.isEmpty { self.fetchLogs = finalLogs }
                if !finalOrders.isEmpty, self.recentOrders.isEmpty { self.recentOrders = finalOrders }
            }
        }
    }

    private func saveJSONAsync<T: Encodable>(_ value: T, to url: URL) {
        // JSON 编码与写盘均在后台线程执行，避免大对象编码阻塞主线程
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 车控/钥匙/实时流用 token：用户级 access_token（主 App 会话）优先，
    /// 未配置时回退车级 vehicle_token（只能查询，车控会返回 no access found）
    private var effectiveCommandAuth: String {
        let user = normalizeBearer(nioUserAccessToken)
        if !user.isEmpty { return user }
        return normalizeBearer(nioVehicleAccessToken)
    }

    // MARK: - WebSocket 实时流（/api/2/ws/command/connect，哨兵/召车/车控事件推送通道，逆向实验功能）

    @Published var isCommandStreamConnected = false
    @Published var commandStreamLog: [String] = []
    private var commandStreamTask: URLSessionWebSocketTask?
    private var isCommandStreamClosedByUser = false

    /// 连接命令实时流：wss://tsp.nio.com/api/2/ws/command/connect?签名字段（md5_full，同 REST 通道）
    func connectCommandStream() {
        guard commandStreamTask == nil else { return }
        let vid = nioVehicleId
        let auth = effectiveCommandAuth
        let secret = nioVehicleSignSecret.isEmpty ? NIOVehicleLib.builtinSignSecret : nioVehicleSignSecret
        guard !vid.isEmpty, !auth.isEmpty else {
            appendLog(NIOFetchLogEntry(category: "ws_stream", level: "error", message: "实时流连接失败：缺少 vehicle_id / Token", detail: nil, timestamp: Date(), requestURL: nil, requestMethod: nil, requestBody: nil, responsePreview: nil, statusCode: nil))
            return
        }
        let path = "/api/2/ws/command/connect"
        var params: [String: String] = [
            "app_id": NIOVehicleLib.androidAppID,
            "app_ver": "6.5.3",
            "device_id": nioDeviceId.isEmpty ? "iOS_Device_\(vid.prefix(6))" : nioDeviceId,
            "vehicle_id": vid,
            "lang": "zh-CN",
            "region": "cn",
            "timestamp": String(Int(Date().timeIntervalSince1970))
        ]
        let sign = NIOVehicleLib.computeAndroidSign(method: "GET", path: path, params: params, secret: secret, authorization: auth)
        params["sign"] = sign
        let canon = params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        guard let url = URL(string: "wss://tsp.nio.com\(path)?\(canon)") else { return }

        isCommandStreamClosedByUser = false
        var req = URLRequest(url: url)
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("NextevCar/6.5.3 (iPhone; iOS 18.0)", forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.webSocketTask(with: req)
        commandStreamTask = task
        task.resume()
        streamReceiveLoop(task)
        // 5s 内未收到任何帧则视为连接失败
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !isCommandStreamClosedByUser && commandStreamTask === task && !isCommandStreamConnected {
                streamLog("⏱️ 5s 无响应（握手参数可能不符，详见诊断日志）")
            }
        }
        streamLog("🔌 正在连接 wss://tsp.nio.com\(path) …")
    }

    func disconnectCommandStream() {
        isCommandStreamClosedByUser = true
        commandStreamTask?.cancel(with: .normalClosure, reason: nil)
        commandStreamTask = nil
        isCommandStreamConnected = false
        streamLog("📴 已断开实时流")
    }

    private func streamReceiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                guard self.commandStreamTask === task else { return }
                switch result {
                case .success(let msg):
                    self.isCommandStreamConnected = true
                    switch msg {
                    case .string(let s): self.streamLog("📨 \(String(s.prefix(500)))")
                    case .data(let d): self.streamLog("📦 [\(d.count)B] \(String(data: d.prefix(500), encoding: .utf8) ?? "hex:\(d.prefix(32).map { String(format: "%02x", $0) }.joined())")")
                    @unknown default: break
                    }
                    self.streamReceiveLoop(task)
                case .failure(let err):
                    self.isCommandStreamConnected = false
                    if !self.isCommandStreamClosedByUser {
                        self.streamLog("❌ 连接断开：\(err.localizedDescription)")
                    }
                }
            }
        }
    }

    private func streamLog(_ line: String) {
        commandStreamLog.append("\(NIOFormatters.clockShort.string(from: Date())) \(line)")
        if commandStreamLog.count > 60 { commandStreamLog.removeFirst(commandStreamLog.count - 60) }
        appendLog(NIOFetchLogEntry(category: "ws_stream", level: "info", message: line, detail: nil, timestamp: Date(), requestURL: nil, requestMethod: nil, requestBody: nil, responsePreview: nil, statusCode: nil))
    }

    // MARK: - 蓝牙钥匙（virtual_key v3 接口逆向：GET /api/1/vehicle/virtual_key/list_by_vehicle_v3，需用户级 token）

    @Published var virtualKeys: [[String: Any]] = []
    @Published var isLoadingVirtualKeys = false
    @Published var virtualKeysError: String?

    /// 拉取蓝牙钥匙列表（宽容解码：字段结构未完全逆向，保留原始字典供 UI 渐进渲染）
    func fetchVirtualKeys() async {
        let vid = nioVehicleId
        guard !vid.isEmpty else { virtualKeysError = "未配置 vehicle_id"; return }
        let secret = nioVehicleSignSecret.isEmpty ? NIOVehicleLib.builtinSignSecret : nioVehicleSignSecret
        let auth = effectiveCommandAuth
        guard !auth.isEmpty else { virtualKeysError = "未配置 Token"; return }

        isLoadingVirtualKeys = true
        defer { isLoadingVirtualKeys = false }
        let path = "/api/1/vehicle/virtual_key/list_by_vehicle_v3"
        var params: [String: String] = [
            "app_id": NIOVehicleLib.androidAppID,
            "app_ver": "6.5.3",
            "device_id": nioDeviceId.isEmpty ? "iOS_Device_\(vid.prefix(6))" : nioDeviceId,
            "vehicle_id": vid,
            "lang": "zh-CN",
            "region": "cn",
            "timestamp": String(Int(Date().timeIntervalSince1970))
        ]
        let sign = NIOVehicleLib.computeAndroidSign(method: "GET", path: path, params: params, secret: secret, authorization: auth)
        params["sign"] = sign
        let canon = params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        guard let url = URL(string: "https://tsp.nio.com\(path)?\(canon)") else { virtualKeysError = "URL 构建失败"; return }

        var req = URLRequest(url: url)
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("NextevCar/6.5.3 (iPhone; iOS 18.0)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if (obj["result_code"] as? String) == "success" {
                let d = obj["data"] as? [String: Any] ?? [:]
                // 容忍多种包装：data.list / data.keys / data 直接数组
                if let list = (d["list"] ?? d["keys"] ?? d["key_list"]) as? [[String: Any]] {
                    virtualKeys = list
                    virtualKeysError = nil
                } else if let arr = obj["data"] as? [[String: Any]] {
                    virtualKeys = arr
                    virtualKeysError = nil
                } else {
                    virtualKeys = []
                    virtualKeysError = "响应结构未识别：\(String(data: data, encoding: .utf8)?.prefix(200) ?? "")"
                }
            } else {
                let msg = obj["result_msg"] as? String ?? obj["debug_msg"] as? String ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                virtualKeys = []
                virtualKeysError = String(msg)
            }
        } catch {
            virtualKeysError = "网络错误：\(error.localizedDescription)"
        }
    }

    // MARK: - 灵动岛 / 实时活动 (Live Activity) 管理

    @Published var isLiveActivityActive = false
    private var currentActivity: Activity<WheaterAttributes>?
    /// 上一次推送的"显著数据"指纹，用于无变化时跳过系统刷新
    private var lastActivityFingerprint: String?
    /// 上一次写入桌面 Widget 快照的内容指纹（含里程/限充等 Widget 可见但灵动岛去重不敏感的字段）
    private var lastWidgetFingerprint: String?
    /// 最近一次刷新结果标签（"已更新"/"无数据更新"），粘性保留：
    /// Widget 与锁屏实时活动持续展示，直到下一轮拉取给出新结果
    private var lastRefreshNotice: String?

    /// 依据满电 CLTC 续航推算电池包容量 (kWh)：75 度 <600 / 100 度 <850 / 150 度
    func estimateBatteryCapacityKwh(socStatus: NIOSocStatus?) -> Double {
        guard let soc = socStatus?.soc, soc > 0, let cltc = socStatus?.remainingRange, cltc > 0 else { return 75.0 }
        let fullRange = cltc / soc * 100.0
        if fullRange >= 850 { return 150.0 }
        if fullRange >= 600 { return 100.0 }
        return 75.0
    }

    /// 桌面 Widget 快照写入失败诊断标志：App Group 不可用（免费账号签名剥离等）时只在首次失败记录，
    /// 恢复成功后记录复位日志，避免每轮轮询刷屏
    private var widgetSyncFailureLogged = false

    /// 从设置页首页标题读取车名（与 Dashboard homeTitle 一致）
    private func resolveVehicleName() -> String {
        UserDefaults.standard.string(forKey: "nio_home_title") ?? "兔可可·蔚来"
    }

    /// notice 非空时更新粘性刷新结果标签（"已更新"/"无数据更新"），
    /// 随 ContentState 一路下发到锁屏实时活动与桌面 Widget 展示
    func updateLiveActivity(force: Bool = false, notice: String? = nil) {
        if let notice { lastRefreshNotice = notice }
        guard let resp = vehicleData, let status = resp.data?.status else { return }

        let socStatus = status.socStatus
        let soc = socStatus?.soc ?? 0
        let cltcKm = socStatus?.remainingRange
        let actKm = socStatus?.remainingActualRange
        let hasAct = (actKm ?? 0) > 0
        let stdRange = (cltcKm ?? 0).rounded().safeInt ?? 0
        let preferActual = UserDefaults.standard.bool(forKey: "nio_prefer_actual_range")

        // bestRange: 有实估用实估，没有则 CLTC × 0.795 推算
        let best = NIOVehicleLib.bestRange(cltcKm: cltcKm, actualKm: actKm)
        let mainRange = (preferActual && hasAct) ? (actKm ?? 0).rounded().safeInt ?? 0 : (hasAct ? stdRange : (best?.km ?? stdRange))
        let subRange: Int? = {
            // 实估优先时主续航已是实估，副续航不下发 CLTC（置 nil 确保各端不显示，
            // 避免"CLTC 被误标为实估"的语义混乱）；非实估优先时副续航为真实实估值
            if preferActual && hasAct { return nil }
            if hasAct { return (actKm ?? 0).rounded().safeInt }
            if let b = best, b.isEstimated { return b.km }
            return nil
        }()
        let displayRange = mainRange

        let isCharging = NIOVehicleLib.isRealCharging(socStatus: socStatus, offcarStatus: status.offcarModeStatus)
        let chargeText = NIOVehicleLib.smartChargeStateDescription(socStatus: socStatus, offcarStatus: status.offcarModeStatus)
        let power = socStatus?.chargingPower.map { $0 / 1000.0 }

        let doors = status.doorStatus ?? [:]
        let lockSts = doors["vehicle_lock_status"]?.intValue ?? 1
        let isLocked = lockSts == 1
        let isDriving = (status.exteriorStatus?.vehicleState == 1)
        let mileage = status.exteriorStatus?.mileage.flatMap { $0.rounded().safeInt }
        let win = status.windowStatus ?? [:]
        let winOpen = (win["win_posn_fl"]?.intValue ?? 0) > 0 || (win["win_posn_fr"]?.intValue ?? 0) > 0 || (win["win_posn_rl"]?.intValue ?? 0) > 0 || (win["win_posn_rr"]?.intValue ?? 0) > 0 || (win["sun_roof_posn"]?.intValue ?? 0) > 0
        let anyDoorOpen = (doors["door_ajar_front_left_status"]?.intValue ?? 1) == 0 || (doors["door_ajar_front_right_status"]?.intValue ?? 1) == 0 || (doors["door_ajar_rear_left_status"]?.intValue ?? 1) == 0 || (doors["door_ajar_rear_right_status"]?.intValue ?? 1) == 0

        let tyre = NIOVehicleLib.extractTyreInfo(from: status)
        let offcar = status.offcarModeStatus ?? [:]
        let defInfo = NIOVehicleLib.defenderModeActive(offcar)
        let pet = NIOVehicleLib.modeActive(offcar["pet_mode_status"] ?? offcar["pet_mode"])
        let camp = NIOVehicleLib.modeActive(offcar["camping_mode_status"] ?? offcar["camping_mode"] ?? offcar["camp_mode_status"])
        let powerHold = NIOVehicleLib.modeActive(offcar["power_hold_mode_status"] ?? offcar["power_hold_mode"] ?? offcar["offcar_power_hold"])

        let frdg = status.frdgStatus ?? [:]
        let frdgPwr = (frdg["frdg_pwr_sts"]?.intValue == 1)
        let frdgTemp = frdg["frdg_cur_t"]?.doubleValue ?? frdg["frdg_tar_t"]?.doubleValue
        let v2l = (socStatus?.v2lStatus == 1)
        // 特殊模式：超强干燥 / 极速除霜 / 座舱过热保护（hvac 状态位，1=进行中）
        let hvac = status.hvacStatus
        let hiDry = (hvac?.cbnHiTDrySts ?? 0) == 1
        let defrost = (hvac?.ccuMaxDefrstSts ?? 0) == 1
        let overheat = (hvac?.cbnOvrHtActSts ?? 0) == 1
        let lvBatt = status.lvBattStatus ?? [:]
        let lvSoc = lvBatt["lv_batt_soc"]?.intValue
        let lvVolt = lvBatt["lv_batt_volt"]?.doubleValue

        // 车机固件短版本号（取不到或仅有占位文案时不显示）
        let rawFotaVer = status.fotaStatus?.currentVersion ?? ""
        let fotaInfo = NIOVehicleLib.parseFotaInfo(version: rawFotaVer)
        let vehicleVersion = fotaInfo.shortVer.isEmpty ? nil : fotaInfo.fullDisplay

        // 充电目标（上限）：target_soc_percentage 为用户设定的限充值（与看板"目标电量"同源）。
        // 注意：max_soc 与 lock_soc 都是服务端常驻默认 90 的非限充字段（实测恒显 90%），
        // 一律不参与兜底；无用户设定值时按 100 展示。
        let rawTarget = socStatus?.targetSocPercentage ?? 0
        let targetSoc = (rawTarget > 1 && rawTarget <= 100) ? rawTarget : 100.0
        let capacityKwh = estimateBatteryCapacityKwh(socStatus: socStatus)
        var etaDate: Date? = nil
        if isCharging {
            // 剩余充电时间：只用服务端 estimate_charge_end_time（车机侧真实预估，含 CV 段降功率非线性），
            // 服务端未给出时保持 nil 不展示——不做本地推算兜底（功率线性外推误差大，宁缺毋假）
            if let serverEta = socStatus?.estimateChargeEndTime, serverEta > 0 {
                let eta = Date(timeIntervalSince1970: TimeInterval(serverEta))
                if eta.timeIntervalSinceNow > -60 && eta.timeIntervalSinceNow < 24 * 3600 {
                    etaDate = eta
                }
            }
        }

        let state = WheaterAttributes.ContentState(
            vehicleName: resolveVehicleName(),
            soc: soc,
            remainingRangeKm: displayRange,
            actualRangeKm: subRange,
            mileageKm: mileage,
            isCharging: isCharging,
            chargeStateText: chargeText,
            chargingPowerKw: power,
            isDriving: isDriving,
            isLocked: isLocked,
            anyDoorOpen: anyDoorOpen,
            anyWindowOpen: winOpen,
            tyrePressFL: tyre.fl.press,
            tyrePressFR: tyre.fr.press,
            tyrePressRL: tyre.rl.press,
            tyrePressRR: tyre.rr.press,
            insideTemp: status.hvacStatus?.temperature,
            outsideTemp: status.hvacStatus?.outsideTemperature,
            defenderActive: defInfo.isActive,
            defenderWarnCount: defInfo.warnCount,
            petModeActive: pet,
            campModeActive: camp,
            powerHoldActive: powerHold,
            frdgActive: frdgPwr,
            frdgTemp: frdgTemp,
            v2lActive: v2l,
            hiDryActive: hiDry,
            defrostActive: defrost,
            overheatProtectActive: overheat,
            updateTimestamp: lastVehicleFetch ?? Date(),
            themeRaw: AnimeThemeService.shared.currentStyle.rawValue,
            chargingTargetSoc: targetSoc,
            batteryCapacityKwh: capacityKwh,
            chargeEtaDate: etaDate,
            lvBattSoc: lvSoc,
            lvBattVolt: lvVolt,
            vehicleVersion: vehicleVersion,
            preferActualRange: preferActual,
            refreshNotice: lastRefreshNotice
        )

        // 桌面 Widget 同步：仅当快照可见内容变化（或 force 主题换装）时才落盘并触发时间线刷新。
        // 此前每轮轮询（含数据完全未变的去重早退路径）都会 reloadAllTimelines，
        // 反复唤醒 Widget Extension 进程白耗电；现在以指纹节流。
        let widgetFingerprint = [
            state.significantFingerprint,
            String(format: "%.0f", targetSoc),
            "\(mileage ?? -1)",
            String(format: "%.1f", frdgTemp ?? -99),
            String(format: "%.1f", lvVolt ?? -1)
        ].joined(separator: "#")
        if force || widgetFingerprint != lastWidgetFingerprint {
            if WheaterVehicleSnapshot.save(from: state) {
                WidgetCenter.shared.reloadAllTimelines()
                if widgetSyncFailureLogged {
                    widgetSyncFailureLogged = false
                    appendLog(NIOFetchLogEntry(
                        category: "widget_sync", level: "info",
                        message: "桌面 Widget 快照恢复写入成功",
                        detail: "App Group 容器已可用，Widget 数据恢复正常同步",
                        timestamp: Date(), requestURL: nil, requestMethod: nil,
                        requestBody: nil, responsePreview: nil, statusCode: nil
                    ))
                }
            } else if !widgetSyncFailureLogged {
                widgetSyncFailureLogged = true
                appendLog(NIOFetchLogEntry(
                    category: "widget_sync", level: "error",
                    message: "桌面 Widget 快照写入失败（App Group 容器不可用），Widget 将一直显示空状态",
                    detail: "通常因安装包缺少 App Group 权限。Xcode 直装：已修复（entitlements 已挂回 target，重新 Run 注册）；TrollStore/CI 包：重新走 CI 打包（ldid 已嵌入）",
                    timestamp: Date(), requestURL: nil, requestMethod: nil,
                    requestBody: nil, responsePreview: nil, statusCode: nil
                ))
            }
            lastWidgetFingerprint = widgetFingerprint
        }

        // 灵动岛 / 实时活动仅在系统允许时进行（Widget 快照同步不受此开关影响，见上）
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // 失效引用自愈（必须在去重早退之前）：被用户长按强制下岛后系统已移除活动，
        // 残留引用 + 未变化的指纹会导致永远无法重新上岛。
        // activities 跨进程查询有开销，本轮只取一次复用。
        let systemActivities = Activity<WheaterAttributes>.activities
        if let stale = currentActivity {
            let gone = !systemActivities.contains(where: { $0.id == stale.id })
            let ended = stale.activityState == .dismissed || stale.activityState == .ended
            // 被用户长按强制下岛（活动已移除或状态 ended/dismissed）→ 清残留引用，
            // 否则残留引用 + 未变化指纹会永远阻止重新上岛
            if gone || ended {
                currentActivity = nil
                lastActivityFingerprint = nil
            }
        }

        // 去重节流：显著数据无变化时跳过更新，降低 ActivityKit 系统刷新频率与功耗
        // force = true 时绕过（如切换主题需要立即换装）
        let fingerprint = state.significantFingerprint
        if !force, fingerprint == lastActivityFingerprint {
            self.isLiveActivityActive = isLiveActivityActive || currentActivity != nil || !systemActivities.isEmpty
            return
        }

        if let activity = currentActivity ?? systemActivities.first {
            lastActivityFingerprint = fingerprint
            Task {
                await activity.update(using: state)
            }
            self.isLiveActivityActive = true
        } else {
            do {
                let attr = WheaterAttributes(vehicleId: "NIO_VEHICLE")
                let activity = try Activity<WheaterAttributes>.request(
                    attributes: attr,
                    contentState: state,
                    pushType: nil
                )
                self.currentActivity = activity
                self.lastActivityFingerprint = fingerprint
                self.isLiveActivityActive = true
            } catch {
                // 启动失败不再静默：写入 lastError 让侧栏告警卡可见（如灵动岛开关被系统关闭）
                self.lastError = "灵动岛上岛失败：\(error.localizedDescription)"
                print("[LiveActivity] 启动失败: \(error)")
            }
        }
    }

    func stopLiveActivity() {
        Task {
            for activity in Activity<WheaterAttributes>.activities {
                await activity.end(dismissalPolicy: .immediate)
            }
            self.currentActivity = nil
            self.lastActivityFingerprint = nil
            self.lastWidgetFingerprint = nil
            self.isLiveActivityActive = false
            // 灵动岛已手动结束，复位控制胶囊常亮状态，避免按钮卡在绿色"常亮中"
            self.resetControlKeepAlive()
        }
    }

    /// 复位控制胶囊常亮状态：清 App Group 标志并通知系统重渲染按钮。
    /// 所有无法继续上岛的路径（未配置、实时活动被关、请求过期、手动结束灵动岛）都必须调用，
    /// 否则锁屏/控制中心按钮会永远停在绿色"常亮中"。
    func resetControlKeepAlive() {
        UserDefaults(suiteName: "group.com.YumikoToysRR.wheater")?
            .removeObject(forKey: "nio_island_keep_alive")
        // ControlWidget 注册 kind（与 IslandControlWidget.swift 的 WheaterIslandControl.controlKind
        // 一致；该文件仅编译进扩展 target，App 侧此处直接用字面量）
        ControlCenter.shared.reloadControls(ofKind: "com.YumikoToysRR.wheater.IslandRaise")
    }

    /// 控制胶囊 / 快捷指令触发的快速上岛：清除失效引用并立即重建实时活动
    func raiseLiveActivityFromControl() {
        // 无论后续能否成功上岛，先复位按钮状态（扩展侧点击时已置常亮标志，
        // 若此处因未配置/授权关闭提前 return，按钮会卡在绿色"常亮中"）
        resetControlKeepAlive()
        guard isConfigured else { return }
        // 重装 App（换签名/换账号）后系统会重置"实时活动"授权——此前此处静默 return，
        // 胶囊点了毫无反应且无任何提示；现在明确告知用户去系统设置打开
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = "实时活动已被系统关闭，无法上岛：请在 系统设置 → 隐私与安全性 → 实时活动（或本 App 设置页）中允许"
            return
        }
        if vehicleData != nil {
            updateLiveActivity(force: true)
            return
        }
        // 冷启动尚无数据：拉取空闲时主动拉一轮（正在跑的拉取轮次会自行上岛，勿重复触发），
        // 并在后台等待数据就绪后强制上岛——fetchVehicle 的 isLoadingVehicle 防并发 guard
        // 会吞掉直接发起的拉取，等待兜底确保请求不被静默丢弃（20s 内每秒探测一次）。
        if !isLoadingVehicle {
            refreshAll(force: true)
        }
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self else { return }
                if self.vehicleData != nil {
                    self.updateLiveActivity(force: true)
                    return
                }
            }
        }
    }

    /// 控制胶囊上岛请求的跨进程接力：Control Widget 的 intent 在 Widget 扩展进程执行，
    /// 通过 App Group 标志位 + 容器文件双通道请求主 App 上岛；主 App 回前台激活时消费。
    /// 五次探测（立即 / 0.5 / 1.2 / 2.5 / 4s）覆盖扩展写标志晚于 App 激活及冷启动动画的竞态；
    /// App 运行中场景由 Darwin 通知实时触发（见 setupIslandRaiseObserver）。
    func checkPendingIslandRaise() {
        guard isConfigured else { return }
        Task { @MainActor in
            for delay in [0.0, 0.5, 1.2, 2.5, 4.0] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                // 主通道：App Group UserDefaults
                if let defaults = UserDefaults(suiteName: "group.com.YumikoToysRR.wheater"),
                   let timestamp = defaults.object(forKey: "nio_raise_island_request") as? Double {
                    defaults.removeObject(forKey: "nio_raise_island_request")
                    guard Date().timeIntervalSince1970 - timestamp < 60 else {
                        // 请求已过期（点击后 App 迟迟未消费，如用户上滑杀掉 App），
                        // 上岛不会发生，复位控制胶囊常亮状态避免按钮卡绿
                        self.resetControlKeepAlive()
                        return
                    }
                    self.raiseLiveActivityFromControl()
                    return
                }
                // 备份通道：App Group 容器文件（UserDefaults 跨进程同步有秒级延迟时兜底）
                if let containerURL = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: "group.com.YumikoToysRR.wheater"
                ) {
                    let flagURL = containerURL.appendingPathComponent("raise_island_flag")
                    if let data = try? String(contentsOf: flagURL, encoding: .utf8),
                       let timestamp = Double(data.trimmingCharacters(in: .whitespacesAndNewlines)),
                       Date().timeIntervalSince1970 - timestamp < 60 {
                        try? FileManager.default.removeItem(at: flagURL)
                        self.raiseLiveActivityFromControl()
                        return
                    }
                }
            }
        }
    }

    // MARK: - 后台刷新 (BGTaskScheduler)：App 退后台后仍定期拉取车况并刷新灵动岛

    static let backgroundRefreshTaskID = "com.YumikoToysRR.wheater.refresh"

    /// App 启动时注册（必须在 didFinishLaunching 返回前完成，由 wheaterApp.init 调用）
    nonisolated static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundRefreshTaskID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleBackgroundRefreshTask(refreshTask)
        }
    }

    /// 预约下一次后台刷新（退到后台时调用，iOS 约 15 分钟起择机执行）
    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    nonisolated private static func handleBackgroundRefreshTask(_ task: BGAppRefreshTask) {
        // 先预约下一次，保证后台刷新链条不断
        scheduleBackgroundRefresh()

        // setTaskCompleted 只允许调用一次：过期回调与正常完成路径谁先到谁生效，
        // 二次调用会触发系统异常
        let completionGuard = BGTaskCompletionGuard()

        let work = Task { @MainActor in
            let service = NIOService.shared
            guard service.isConfigured else {
                completionGuard.finish(task, success: false)
                return
            }
            await service.fetchVehicle(force: false) // 成功后内部自动 updateLiveActivity
            await service.fetchChange(force: false)
            completionGuard.finish(task, success: true)
        }
        task.expirationHandler = {
            work.cancel()
            // Apple 要求过期时必须上报完成；缺失会导致 watchdog 直接杀进程（0x8badf00d），
            // 后台刷新链条就此中断
            completionGuard.finish(task, success: false)
        }
    }
}

/// BGTask 完成防重入闸门：expirationHandler（任意线程）与正常完成路径（主线程）
/// 只允许第一次调用生效
private final class BGTaskCompletionGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish(_ task: BGAppRefreshTask, success: Bool) {
        lock.lock()
        let shouldFinish = !finished
        finished = true
        lock.unlock()
        if shouldFinish {
            task.setTaskCompleted(success: success)
        }
    }
}

// MARK: - 后台定位保活 + 同行智能监测（自用方案）

/// 持续低精度定位让进程在后台存活，前台轮询 Timer 因此在后台继续跑（车况准实时刷新）。
/// 定位数据同时供 NIOProximityMonitor 做「手机与车同行」判定：位置仅本地比对、不存储不上传。
/// 纯自用方案：若上架 App Store 需移除（指南 2.5.4 要求后台定位与用户可见的核心功能直接相关）。
@MainActor
final class NIOLocationKeepAlive: NSObject, ObservableObject {
    static let shared = NIOLocationKeepAlive()

    @Published private(set) var isKeepingAlive = false
    /// 当前定位授权状态（设置页据此展示"主动触发授权 / 跳系统设置"入口）
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    /// 总开关（UserDefaults，默认开）：需要关闭时 `defaults write nio_location_keepalive 0`
    private static let toggleKey = "nio_location_keepalive"

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.toggleKey) as? Bool ?? true
    }

    private override init() {
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
        // 百米级精度 + 50m 距离阈值：既保住进程后台存活，又能支撑同行监测
        // （手机与车辆位置接近判定 + 速度判定，见 NIOProximityMonitor）
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.activityType = .automotiveNavigation
        // 关键：不允许系统自动暂停定位服务，否则后台仍会被挂起
        manager.pausesLocationUpdatesAutomatically = false
        // 后台持续收回调 = 进程不被挂起（需 Info.plist UIBackgroundModes 含 location）
        manager.allowsBackgroundLocationUpdates = true
    }

    /// 幂等启动：已配置凭证才需要保活；权限未决时先发起系统授权请求
    func requestAndStart() {
        guard isEnabled, NIOService.shared.isConfigured else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            start()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break // 用户已拒绝：静默放弃，不影响任何前台功能
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        isKeepingAlive = false
    }

    private func start() {
        guard !isKeepingAlive else { return }
        manager.startUpdatingLocation()
        isKeepingAlive = true
    }
}

extension NIOLocationKeepAlive: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            NIOLocationKeepAlive.shared.authorizationStatus = status
            guard NIOLocationKeepAlive.shared.isEnabled, NIOService.shared.isConfigured else { return }
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                NIOLocationKeepAlive.shared.start()
            }
        }
    }

    /// 定位数据用途：① 保活信号（后台进程存活）② 同行智能监测（位置/速度仅本地比对，不存储不上传）
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            NIOProximityMonitor.shared.ingest(locations: locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - 手机与爱车同行智能监测

/// 依据手机定位（由 NIOLocationKeepAlive 转发）与车辆最近上报位置做本地比对：
/// 手机与车位置重合/接近 且 快速移动 → 疑似人在车内，进入"同行会话"，
/// 以 30s 高频间隔拉取车况，判定 行驶中 / 等灯低速 / 到达目的地，并确认落锁状态。
/// 判定主要依赖手机速度（人在车内 = 车速），不依赖车辆 speed 字段的具体单位。
/// 状态变化经 NIOService.publishTransientNotice 弹横幅；位置仅本地计算，不存储不上传。
@MainActor
final class NIOProximityMonitor: ObservableObject {
    static let shared = NIOProximityMonitor()

    enum TripPhase: Equatable {
        case idle                    // 未检测到同行
        case driving                 // 行驶中
        case atLight                 // 等灯 / 低速蠕行
        case arrived(locked: Bool)   // 已到达目的地（附带落锁状态）
    }

    @Published private(set) var phase: TripPhase = .idle
    /// 手机当前是否处于车辆附近（供调试与未来 UI 使用）
    @Published private(set) var isNearCar = false

    // MARK: 判定阈值

    /// 手机与车"重合或接近"判定半径（覆盖双端 GPS 定位误差）
    private let nearDistance: CLLocationDistance = 400
    /// 已接近状态下判"离开"的半径（滞回防抖：进入 400m / 离开 1000m）
    private let awayDistance: CLLocationDistance = 1000
    /// 手机快速移动阈值 m/s（≈7.2 km/h，步行速度以下不触发同行判定）
    private let movingSpeed: CLLocationSpeed = 2.0
    /// 车辆位置样本最大可信时长：超时说明车位置过期，跳过接近判定避免误判
    private let carPositionMaxAge: TimeInterval = 15 * 60
    /// 同行会话内高频拉取间隔：比保活轮询密，仍留足接口风控安全边距
    private let smartInterval: TimeInterval = 30
    /// 到达后降频轮询间隔（仅跟踪落锁状态变化）
    private let arrivedInterval: TimeInterval = 120
    /// 连续驻车拉取次数达到该值才判"到达"（单次驻车可能是等灯采样巧合）
    private let arrivalStreakNeeded = 2
    /// 连续低速观察次数达到该值才从"行驶中"转入"等灯"（防止蠕行误报横幅）
    private let atLightStreakNeeded = 2

    private var lastPhoneLocation: CLLocation?
    private var lastSmartFetch: Date = .distantPast
    private var parkedStreak = 0
    private var lowSpeedStreak = 0
    private var sessionTimer: Timer?

    private init() {}

    // MARK: - 定位入口（NIOLocationKeepAlive 转发）

    func ingest(locations: [CLLocation]) {
        guard NIOService.shared.isConfigured else { return }
        guard let loc = locations.last else { return }
        lastPhoneLocation = loc
        updateProximity(at: loc)
        // 接近车辆且快速移动 → 疑似在车内，发起一次同行检测拉取
        if isNearCar, loc.speed > movingSpeed {
            smartFetchIfNeeded()
        }
    }

    // MARK: - 接近判定

    private func updateProximity(at loc: CLLocation) {
        guard let pos = NIOService.shared.vehicleData?.data?.status?.positionStatus,
              let lat = pos.latitude, let lng = pos.longitude, lat != 0 || lng != 0 else {
            endSession()
            isNearCar = false
            return
        }
        // 车位置过期：不可信（车可能早已离开），结束会话等待下一次拉取刷新位置
        if let ts = pos.sampleTime, ts > 0 {
            let sec = ts > 1_000_000_000_000 ? TimeInterval(ts) / 1000.0 : TimeInterval(ts)
            if Date().timeIntervalSince1970 - sec > carPositionMaxAge {
                endSession()
                isNearCar = false
                return
            }
        }
        let carLoc = CLLocation(latitude: lat, longitude: lng)
        let dist = loc.distance(from: carLoc)
        isNearCar = isNearCar ? dist < awayDistance : dist < nearDistance
        if !isNearCar { endSession() }
    }

    // MARK: - 同行会话与拉取调度

    private func smartFetchIfNeeded() {
        // 到达后只跟踪落锁变化，降频到 120s；同行进行中 30s 高频
        let gate = isArrived ? arrivedInterval : smartInterval
        guard Date().timeIntervalSince(lastSmartFetch) >= gate else { return }
        lastSmartFetch = Date()
        beginSessionIfNeeded()
        Task { [weak self] in
            await NIOService.shared.fetchVehicle(force: false)
            self?.classifyAfterFetch()
        }
    }

    private var isArrived: Bool {
        if case .arrived = phase { return true }
        return false
    }

    /// 会话期间由 Timer 兜底驱动：手机静止时无定位回调（distanceFilter 未达），
    /// 等灯/到达判定必须靠定时拉取推进，否则会卡在上一个状态
    private func beginSessionIfNeeded() {
        guard sessionTimer == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isNearCar else {
                    self.endSession()
                    return
                }
                self.smartFetchIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sessionTimer = timer
    }

    private func endSession() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        parkedStreak = 0
        lowSpeedStreak = 0
        if phase != .idle { phase = .idle }
    }

    // MARK: - 行驶状态判定（拉取后）

    private func classifyAfterFetch() {
        guard isNearCar, let status = NIOService.shared.vehicleData?.data?.status else { return }
        let phoneSpeed = lastPhoneLocation?.speed ?? 0
        let vehicleState = status.exteriorStatus?.vehicleState ?? 0

        switch vehicleState {
        case 1:
            // 行驶挡位：车机在 D 档。手机快速移动 = 行驶中；手机低速/静止 = 等灯或蠕行
            parkedStreak = 0
            if phoneSpeed > movingSpeed {
                lowSpeedStreak = 0
                transition(to: .driving)
            } else {
                lowSpeedStreak += 1
                if lowSpeedStreak >= atLightStreakNeeded {
                    transition(to: .atLight)
                }
            }
        case 2, 3, 4:
            // 驻车 / 充电 / 换电：连续两轮即判到达，附落锁状态
            lowSpeedStreak = 0
            parkedStreak += 1
            if parkedStreak >= arrivalStreakNeeded {
                let doors = status.doorStatus ?? [:]
                let locked = (doors["vehicle_lock_status"]?.intValue
                    ?? doors["lock_status"]?.intValue
                    ?? doors["lock"]?.intValue ?? 1) == 1
                transition(to: .arrived(locked: locked))
            }
        default:
            // 0 = 未知：保持当前状态，等待下一轮
            break
        }
    }

    /// 状态变迁：仅变化时弹横幅；回到 idle（人车分离）静默结束
    private func transition(to newPhase: TripPhase) {
        guard newPhase != phase else { return }
        phase = newPhase
        switch newPhase {
        case .driving:
            NIOService.shared.publishTransientNotice(.info, "🚗 检测到与爱车同行 · 行驶中，车况高频同步")
        case .atLight:
            NIOService.shared.publishTransientNotice(.info, "🚥 等灯 / 低速中 · 到达后将确认落锁")
        case .arrived(let locked):
            parkedStreak = 0
            if locked {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                NIOService.shared.publishTransientNotice(.success, "🏁 已到达目的地 · 车辆已上锁 ✓")
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                NIOService.shared.publishTransientNotice(.warn, "🏁 已到达目的地 · 车辆未上锁 🔓 请留意")
            }
        case .idle:
            break
        }
    }
}
import Foundation

// MARK: - 车控指令（iOS 6.5.3 包逆向：REST 异步命令通道 + 服务密码 PIN 验证）
//
// 通道：POST https://tsp.nio.com/api/1/vehicle/command/{function} → data.command_id
//       → GET  /api/1/vehicle/command/{command_id} 轮询 result_status（≤15s）。
// 签名：与车况同套 md5_full（Android/iOS 通用 secret，POST + path + sorted_query + secret + Authorization）。
// 敏感指令：服务端要求服务密码时返回 PIN 相关错误 → UI 弹输入框 →
//       RSA/PKCS1 加密后 POST /api/1/poseidon/verify_pin → 成功后重发原指令。
extension NIOService {

    enum VehicleCommandResult {
        case success(String)
        case needPin
        case failure(String)
    }

    /// 发送车控指令（进度/结果通过 publishTransientNotice 横幅反馈）
    /// 签名档位重试：档位A（body 键值并入 query 签名）→ 疑似签名错误时档位B（body 原文拼接）重试。
    /// 每次尝试均写入 fetchLogs（category=vehicle_command），失败原因可在诊断页查看。
    @MainActor
    func sendVehicleCommand(function: String, title: String, parameters: [String: Any] = [:]) async -> VehicleCommandResult {
        let vid = nioVehicleId
        guard !vid.isEmpty else { return .failure("车控不可用：未配置 vehicle_id") }
        guard nioVehicleSignAlgo.isEmpty || nioVehicleSignAlgo == "md5_full" else {
            return .failure("车控需要 md5_full 签名算法（配置页切换）")
        }
        let secret = nioVehicleSignSecret.isEmpty ? NIOVehicleLib.builtinSignSecret : nioVehicleSignSecret
        let auth = effectiveCommandAuth
        guard !auth.isEmpty else { return .failure("车控不可用：未配置 Token") }

        publishTransientNotice(.info, "⌚️ \(title)：指令发送中…")

        var body = parameters
        if body["vehicle_id"] == nil { body["vehicle_id"] = vid }
        let bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let bodyJSON = String(data: bodyData, encoding: .utf8) ?? ""

        // 档位A → 档位B 重试梯
        for mode in [NIOVehicleLib.CommandSignMode.mergedIntoQuery, .rawAppend] {
            guard let built = NIOVehicleLib.buildCommandRequest(
                function: function, vehicleId: vid, deviceId: nioDeviceId,
                secret: secret, authorization: auth, bodyJSON: bodyJSON, signMode: mode
            ) else { return .failure("车控请求构建失败") }

            var request = URLRequest(url: built.url)
            request.httpMethod = "POST"
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("NextevCar/6.5.3 (iPhone; iOS 18.0)", forHTTPHeaderField: "User-Agent")
            request.httpBody = bodyData

            let data: Data
            let http: HTTPURLResponse?
            do {
                let (d, r) = try await URLSession.shared.data(for: request)
                data = d; http = r as? HTTPURLResponse
            } catch {
                return .failure("网络错误：\(error.localizedDescription)")
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            let status = http?.statusCode ?? 0

            // 服务端要求服务密码 → 交由 UI 弹 PIN 输入框
            if isPinRequired(text, status) { return .needPin }

            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["result_code"] as? String) == "success" else {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result_msg"] as? String
                    ?? "HTTP \(status) \(String(text.prefix(160)))"
                appendLog(NIOFetchLogEntry(
                    category: "vehicle_command", level: "error",
                    message: "车控 \(function) 被拒绝（签名档位 \(mode == .mergedIntoQuery ? "A" : "B")）",
                    detail: "HTTP \(status) · \(msg) · body=\(bodyJSON)",
                    timestamp: Date(), requestURL: built.url.absoluteString, requestMethod: "POST",
                    requestBody: bodyJSON, responsePreview: String(text.prefix(400)), statusCode: status
                ))
                // 疑似签名错误才换档重试；鉴权/参数类错误换档无意义
                let looksLikeSignError = status == 403
                    || msg.lowercased().contains("sign")
                    || msg.lowercased().contains("鉴权")
                let looksLikeAuthError = msg.lowercased().contains("not login")
                    || msg.lowercased().contains("unauthorized") || status == 401
                if looksLikeAuthError {
                    return .failure("车控被拒绝：\(msg)\n车控指令需要用户级 access_token（App 登录会话），车级 vehicle_token 仅能查询车况。请到设置页录入用户级 Token")
                }
                if looksLikeSignError && mode == .mergedIntoQuery { continue }
                return .failure("服务端拒绝：\(msg)")
            }

            guard let cmdID = (obj["data"] as? [String: Any])?["command_id"] as? String, !cmdID.isEmpty else {
                appendLog(NIOFetchLogEntry(
                    category: "vehicle_command", level: "info",
                    message: "车控 \(function) 已受理（无 command_id）",
                    detail: "签名档位 \(mode == .mergedIntoQuery ? "A" : "B") · \(String(text.prefix(200)))",
                    timestamp: Date(), requestURL: built.url.absoluteString, requestMethod: "POST",
                    requestBody: bodyJSON, responsePreview: String(text.prefix(400)), statusCode: status
                ))
                return .success("\(title)：指令已受理")
            }

            // 轮询执行结果
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let pollURL = NIOVehicleLib.buildCommandPollRequest(
                    commandID: cmdID, vehicleId: vid, deviceId: nioDeviceId,
                    secret: secret, authorization: auth
                ) else { continue }
                var preq = URLRequest(url: pollURL)
                preq.setValue(auth, forHTTPHeaderField: "Authorization")
                preq.setValue("NextevCar/6.5.3 (iPhone; iOS 18.0)", forHTTPHeaderField: "User-Agent")
                guard let (pdata, presp) = try? await URLSession.shared.data(for: preq),
                      let pobj = try? JSONSerialization.jsonObject(with: pdata) as? [String: Any],
                      let pd = pobj["data"] as? [String: Any] else { continue }
                let st = (pd["result_status"] as? String) ?? (pd["status"] as? String) ?? ""
                if st.lowercased() == "success" {
                    appendLog(NIOFetchLogEntry(
                        category: "vehicle_command", level: "info",
                        message: "车控 \(function) 执行成功",
                        detail: "command_id=\(cmdID) · 签名档位 \(mode == .mergedIntoQuery ? "A" : "B")",
                        timestamp: Date(), requestURL: pollURL.absoluteString, requestMethod: "GET",
                        requestBody: nil, responsePreview: String((String(data: pdata, encoding: .utf8) ?? "").prefix(400)), statusCode: (presp as? HTTPURLResponse)?.statusCode
                    ))
                    return .success("\(title)：执行成功 ✓")
                }
                if st.lowercased().contains("fail") || st.lowercased().contains("error") {
                    return .failure("\(title)：车辆执行失败（\(st)）")
                }
            }
            return .success("\(title)：已受理，车辆执行中")
        }
        return .failure("服务端拒绝：签名双档位均被拒（详见诊断日志）")
    }

    /// 服务端是否要求服务密码（PIN）
    private func isPinRequired(_ body: String, _ status: Int) -> Bool {
        let low = body.lowercased()
        return low.contains("pin_required") || low.contains("need_pin") || low.contains("pin_code")
            || low.contains("verify_pin") || low.contains("pin_error") || status == 428
    }

    /// 验证服务密码（RSA/PKCS1 加密 → /api/1/poseidon/verify_pin），成功后重发原指令
    /// POST body 参与签名（双档位，与车控通道一致）
    @MainActor
    func verifyPinAndRetry(_ pin: String, function: String, title: String, parameters: [String: Any] = [:]) async -> VehicleCommandResult {
        guard !pin.isEmpty else { return .failure("请输入服务密码") }
        guard let enc = NIOVehicleLib.encryptPinCode(pin) else { return .failure("PIN 加密失败") }

        let vid = nioVehicleId
        let secret = nioVehicleSignSecret.isEmpty ? NIOVehicleLib.builtinSignSecret : nioVehicleSignSecret
        let auth = effectiveCommandAuth
        let path = "/api/1/poseidon/verify_pin"
        let bodyJSON: String = {
            let d = (try? JSONSerialization.data(withJSONObject: ["pin_code": enc])) ?? Data()
            return String(data: d, encoding: .utf8) ?? ""
        }()

        // 双档位：A = body 键值并入 query 签名；B = body 原文拼入签名输入串
        for rawAppendMode in [false, true] {
            var params: [String: String] = [
                "app_id": NIOVehicleLib.androidAppID,
                "app_ver": "6.5.3",
                "device_id": nioDeviceId.isEmpty ? "iOS_Device_\(vid.prefix(6))" : nioDeviceId,
                "vehicle_id": vid,
                "lang": "zh-CN",
                "region": "cn",
                "timestamp": String(Int(Date().timeIntervalSince1970))
            ]
            if !rawAppendMode { params["pin_code"] = enc }
            let sign = rawAppendMode
                ? NIOVehicleLib.md5("POST\(path)?\(NIOVehicleLib.sortedQuery(params))\(bodyJSON)\(secret)\(auth)")
                : NIOVehicleLib.computeAndroidSign(method: "POST", path: path, params: params, secret: secret, authorization: auth)
            params["sign"] = sign
            let canon = params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            guard let url = URL(string: "https://tsp.nio.com\(path)?\(canon)") else { return .failure("PIN 请求构建失败") }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("NextevCar/6.5.3 (iPhone; iOS 18.0)", forHTTPHeaderField: "User-Agent")
            request.httpBody = Data(bodyJSON.utf8)

            let data: Data
            do {
                let (d, _) = try await URLSession.shared.data(for: request)
                data = d
            } catch {
                return .failure("PIN 验证网络错误：\(error.localizedDescription)")
            }
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let resultMsg = obj["result_msg"] as? String ?? ""
            if (obj["result_code"] as? String) == "success" {
                publishTransientNotice(.success, "🔑 服务密码验证通过，重发指令…")
                return await sendVehicleCommand(function: function, title: title, parameters: parameters)
            }
            // 疑似签名错误且还有档位 → 换档重试
            let looksLikeSignError = resultMsg.lowercased().contains("sign")
            if looksLikeSignError && !rawAppendMode { continue }
            return .failure("服务密码错误：\(resultMsg.isEmpty ? "验证被拒绝" : resultMsg)")
        }
        return .failure("服务密码验证被拒绝（签名双档位均失败）")
    }
}

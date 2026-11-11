//
//  NIOCredentialReceiver.swift
//  wheater
//
//  本地凭证接收服务器 — Shadowrocket 脚本直推模式
//  监听 127.0.0.1:8997，接收 Shadowrocket / Surge 脚本 POST 过来的蔚来凭证 JSON，
//  自动回填并触发系统通知与震动，无需用户手动操作。
//

import Foundation
import Network
import UIKit
import UserNotifications

@MainActor
final class NIOCredentialReceiver: ObservableObject {
    static let shared = NIOCredentialReceiver()

    @Published var isListening = false
    @Published var lastReceivedAt: Date?
    @Published var receiveCount: Int = 0
    @Published var statusMessage: String = "未启动"
    /// 最近一次推送的完整载荷（收件箱 UI 数据源，含凭证字段与抓包样本；持久化到 UserDefaults 支持重启恢复）
    @Published var inboxPayload: [String: Any]?
    static let inboxStoreKey = "nio_last_push_payload"
    /// 上次成功应用的完整凭证指纹（token+vehicleId+deviceId），用于去重：
    /// 相同凭证重复推送时静默忽略，不再震动/覆盖剪贴板/弹提示
    private var lastAppliedFingerprint: String = ""
    /// 上次「Token 失效状态下重推相同凭证」触发强制重验的时间（60 秒冷却，
    /// 防止 Shadowrocket 脚本随 NIO App 每次请求重推相同凭证时连环触发刷新）
    private var lastInvalidRepushRefreshAt: Date = .distantPast

    private let port: UInt16 = 8997
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.yumikotoys.credential-receiver", qos: .userInitiated)
    /// 后台推送时暂存的剪贴板凭证（iOS 后台写剪贴板会被静默丢弃，回前台补写）
    private static let pendingClipKey = "nio_pending_clip_credentials"

    private init() {
        loadPersistedInbox()
        // 后台推送暂存的剪贴板凭证：回前台第一时间补写，保证"剪贴板读取并识别"可用
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushPendingClipboard()
            }
        }
    }

    @MainActor
    private func flushPendingClipboard() {
        guard let pending = UserDefaults.standard.string(forKey: Self.pendingClipKey) else { return }
        UIPasteboard.general.string = pending
        UserDefaults.standard.removeObject(forKey: Self.pendingClipKey)
        statusMessage = "📋 已补写剪贴板（后台推送时暂存的凭证）"
    }

    // MARK: - 收件箱持久化（重启后仍可在收件箱查看/复制最近推送）

    private func loadPersistedInbox() {
        guard let str = UserDefaults.standard.string(forKey: Self.inboxStoreKey),
              let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        inboxPayload = json
    }

    /// 非隔离写入（网络接收线程调用）：UserDefaults 线程安全，@Published 回主线程更新
    nonisolated private func persistInbox(_ json: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: Self.inboxStoreKey)
        }
        Task { @MainActor [weak self] in
            self?.inboxPayload = json
        }
    }

    /// 清空收件箱（UI 手动操作）
    func clearInbox() {
        inboxPayload = nil
        UserDefaults.standard.removeObject(forKey: Self.inboxStoreKey)
        statusMessage = "🧹 收件箱已清空"
    }

    // MARK: - 启动接收服务器

    func startListening() {
        guard listener == nil else { return }
        statusMessage = "🟡 正在启动端口 8997…"
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))

            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        self?.isListening = true
                        self?.statusMessage = "🟢 等待 Shadowrocket 推送凭证…"
                    case .failed(let err):
                        self?.isListening = false
                        self?.listener = nil
                        self?.statusMessage = "🔴 启动失败: \(err)"
                    case .cancelled:
                        self?.isListening = false
                        self?.statusMessage = "⚪️ 已停止"
                    default: break
                    }
                }
            }

            l.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }

            l.start(queue: queue)
            self.listener = l
        } catch {
            statusMessage = "🔴 NWListener 创建失败: \(error)"
        }
    }

    func stopListening() {
        listener?.cancel()
        listener = nil
        isListening = false
        statusMessage = "⚪️ 已停止"
    }

    // MARK: - 处理入连接

    nonisolated private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        // 累积读取直到 HTTP 头 + Content-Length 声明的 body 收全：
        // 单次 64KB receive 在 body 分包到达时会静默丢数据，导致推送"成功"却无反应
        accumulateRequest(conn, buffer: Data(), gate: ParseGate())
    }

    /// 一次性解析闸门：EOF / 静默超时 / Content-Length 收全三条路径谁先到谁解析
    private final class ParseGate: @unchecked Sendable {
        private let lock = NSLock()
        private var parsed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if parsed { return false }
            parsed = true
            return true
        }
    }

    nonisolated private func accumulateRequest(_ conn: NWConnection, buffer: Data, gate: ParseGate) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let chunk = data, !chunk.isEmpty, error == nil else {
                // EOF（脚本"发完即关"）/ 错误：已积累到完整请求则解析，此前这里会直接丢弃
                self?.finish(conn, buffer: buffer, gate: gate)
                return
            }
            var accumulated = buffer
            accumulated.append(chunk)
            let raw = String(decoding: accumulated, as: UTF8.self)

            // 1) 头未收全 → 继续读（上限 1MB 防异常膨胀）
            guard let headerEnd = raw.range(of: "\r\n\r\n").map({ raw.distance(from: raw.startIndex, to: $0.upperBound) }) else {
                if isComplete || accumulated.count > 1024 * 1024 {
                    self.finish(conn, buffer: accumulated, gate: gate)
                } else {
                    self.accumulateRequest(conn, buffer: accumulated, gate: gate)
                }
                return
            }
            // 2) 头已收全且 Content-Length 满足 → 完成
            if let expected = Self.contentLength(of: raw), accumulated.count >= headerEnd + expected {
                self.finish(conn, buffer: accumulated, gate: gate)
                return
            }
            // 3) 无 Content-Length（或 body 未收全）：等 EOF；为防客户端保持连接不关，
            //    静默 800ms 后用已有内容直接解析（脚本推送为一次性请求，通常随即关闭）
            if !isComplete, accumulated.count <= 1024 * 1024 {
                self.queue.asyncAfter(deadline: .now() + 0.8) { [weak self, weak conn] in
                    guard let conn = conn, let self = self else { return }
                    self.finish(conn, buffer: accumulated, gate: gate)
                }
                self.accumulateRequest(conn, buffer: accumulated, gate: gate)
                return
            }
            self.finish(conn, buffer: accumulated, gate: gate)
        }
    }

    nonisolated private func finish(_ conn: NWConnection, buffer: Data, gate: ParseGate) {
        defer { conn.cancel() }
        guard gate.claim() else { return }
        let raw = String(decoding: buffer, as: UTF8.self)
        guard raw.contains("\r\n\r\n") else { return } // 连 HTTP 头都没有：无从解析
        parseHTTPAndApply(raw)
    }

    nonisolated private static func contentLength(of raw: String) -> Int? {
        guard let line = raw.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("content-length:") }) else { return nil }
        return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
    }

    // MARK: - 解析 HTTP 请求并提取 JSON body

    /// 清洗手工粘贴/脚本推送字段的常见杂质：markdown 反引号、包裹引号、首尾空白；
    /// 数组形态（如 ["/app/web/..."] 伪 token）视为无效
    nonisolated static func clean(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.count >= 2, (v.hasPrefix("`") && v.hasSuffix("`"))
            || (v.hasPrefix("\"") && v.hasSuffix("\"")) {
            v = String(v.dropFirst().dropLast())
        }
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("[") { return "" }
        return v
    }

    nonisolated private func parseHTTPAndApply(_ raw: String) {
        // 分离 HTTP header 和 body（\r\n\r\n 分隔）
        let separator = "\r\n\r\n"
        guard let sepRange = raw.range(of: separator) else {
            Task { @MainActor [weak self] in
                self?.statusMessage = "⚠️ 收到请求但缺少 HTTP 头（分包异常）"
            }
            return
        }
        let body = String(raw[sepRange.upperBound...])

        guard !body.isEmpty,
              let jsonData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            Task { @MainActor [weak self] in
                self?.statusMessage = "⚠️ 收到请求但 JSON 解析失败（body 不完整或格式异常）"
            }
            return
        }

        let token      = Self.clean(json["vehicle_token"] as? String ?? json["token"] as? String ?? "")
        let vehicleId  = Self.clean(json["vehicle_id"]    as? String ?? "")
        let deviceId   = Self.clean(json["device_id"]     as? String ?? "")
        let vehicleUrl = Self.clean(json["vehicle_url"]   as? String ?? "")
        let rvsUrl     = Self.clean(json["rvs_url"]       as? String ?? "")
        let sign       = Self.clean(json["sign"]          as? String ?? "")
        let timestamp  = Self.clean(json["timestamp"]     as? String ?? "")
        // 防多端登录指纹字段（shadowrocket / mitmproxy 脚本同步推送）
        let userGuid   = Self.clean(json["user_guid"]     as? String ?? "")
        let appVer     = Self.clean(json["app_ver"]       as? String ?? "")
        let userAgent  = Self.clean(json["user_agent"]    as? String ?? "")
        // 用户级 access_token（主 App 会话，车控/钥匙/RVS 必需，区别于小组件车级 token）
        let userToken  = Self.clean(json["user_token"]    as? String ?? "")
        // 车控指令抓包样本（官方 App 点车控时脚本捕获的完整请求原文）
        let commandSamples = json["command_samples"] as? [[String: Any]] ?? []
        // 车机扫码授权链路样本（poseidon：工程模式/扫码授权的服务端权限判定原文，含响应）
        let poseidonSamples = json["poseidon_samples"] as? [[String: Any]] ?? []

        // 收件箱存档（重启可查；无论凭证是否去重都更新，保证样本区始终最新）
        persistInbox(json)

        Task { @MainActor [weak self] in
            self?.applyCredentials(
                token: token, vehicleId: vehicleId,
                deviceId: deviceId, vehicleUrl: !rvsUrl.isEmpty ? rvsUrl : vehicleUrl,
                sign: sign, timestamp: timestamp,
                userGuid: userGuid, appVer: appVer, userAgent: userAgent,
                userToken: userToken, commandSamples: commandSamples,
                poseidonSamples: poseidonSamples
            )
        }
    }

    /// 导入凭证载荷（收件箱「从文件导入」的统一入口）：
    /// 与直推完全同一条回填管线（存档收件箱 → 字段提取 → applyCredentials 去重回填）
    /// 返回 false 表示 JSON 解析失败（UI 提示）
    @discardableResult
    func importPayload(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            statusMessage = "⚠️ 导入失败：不是有效的凭证 JSON"
            return false
        }
        persistInbox(json)
        let token      = Self.clean(json["vehicle_token"] as? String ?? json["token"] as? String ?? "")
        let vehicleId  = Self.clean(json["vehicle_id"]    as? String ?? "")
        let deviceId   = Self.clean(json["device_id"]     as? String ?? "")
        let vehicleUrl = Self.clean(json["vehicle_url"]   as? String ?? "")
        let rvsUrl     = Self.clean(json["rvs_url"]       as? String ?? "")
        let sign       = Self.clean(json["sign"]          as? String ?? "")
        let timestamp  = Self.clean(json["timestamp"]     as? String ?? "")
        let userGuid   = Self.clean(json["user_guid"]     as? String ?? "")
        let appVer     = Self.clean(json["app_ver"]       as? String ?? "")
        let userAgent  = Self.clean(json["user_agent"]    as? String ?? "")
        let userToken  = Self.clean(json["user_token"]    as? String ?? "")
        let commandSamples  = json["command_samples"]  as? [[String: Any]] ?? []
        let poseidonSamples = json["poseidon_samples"] as? [[String: Any]] ?? []
        // 全量导出（export_version 2）附加字段：换电/签到 API 与 Token、签名密钥（可选）
        let changeURL    = Self.clean(json["change_url"]    as? String ?? "")
        let changeToken  = Self.clean(json["change_token"]  as? String ?? "")
        let checkinURL   = Self.clean(json["checkin_url"]   as? String ?? "")
        let checkinToken = Self.clean(json["checkin_token"] as? String ?? "")
        let signSecret   = Self.clean(json["sign_secret"]   as? String ?? "")

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.receiveCount += 1
            self.lastReceivedAt = Date()
            self.statusMessage = "📄 已从文件导入并回填"
            // 换电/签到/密钥等不走直推去重，先于 applyCredentials 直接回填
            let service = NIOService.shared
            if !changeURL.isEmpty    { service.nioChangeApiURL = changeURL }
            if !changeToken.isEmpty  { service.nioChangeAccessToken = changeToken }
            if !checkinURL.isEmpty   { service.nioCheckinApiURL = checkinURL }
            if !checkinToken.isEmpty { service.nioCheckinAccessToken = checkinToken }
            if !signSecret.isEmpty   { service.nioVehicleSignSecret = signSecret }
            self.applyCredentials(
                token: token, vehicleId: vehicleId,
                deviceId: deviceId, vehicleUrl: !rvsUrl.isEmpty ? rvsUrl : vehicleUrl,
                sign: sign, timestamp: timestamp,
                userGuid: userGuid, appVer: appVer, userAgent: userAgent,
                userToken: userToken, commandSamples: commandSamples,
                poseidonSamples: poseidonSamples
            )
        }
        return true
    }

    // MARK: - 回填凭证

    @MainActor
    private func applyCredentials(token: String, vehicleId: String,
                                  deviceId: String, vehicleUrl: String,
                                  sign: String, timestamp: String = "",
                                  userGuid: String = "", appVer: String = "", userAgent: String = "",
                                  userToken: String = "", commandSamples: [[String: Any]] = [],
                                  poseidonSamples: [[String: Any]] = []) {
        let service = NIOService.shared
        var applied: [String] = []
        // 设备标识：device_id 优先，User-Guid 兜底（网关请求无 query device_id）
        let effectiveDeviceId = deviceId.isEmpty ? userGuid : deviceId

        // 去重：核心要素（token+vehicleId+deviceId+用户级token+车控样本摘要）与上次完全相同 → 静默忽略。
        // 重复推送不再震动、不覆盖剪贴板、不弹横幅，只轻量记录时间。
        // 例外：当前 Token 已被判定失效（401/403）时不能静默——重推相同凭证说明
        // 用户在尝试恢复，需明确警示"凭证未变化但已失效"，并强制重验一次；
        // 服务端仍返回 403 则保持红色警示，已恢复则横幅自动复位。
        let samplesDigest = commandSamples.prefix(5).map { "\($0["url"] ?? "")|\($0["body"] ?? "")" }.joined(separator: ";")
        let poseidonDigest = poseidonSamples.prefix(5).map { "\($0["url"] ?? "")|\($0["status"] ?? "")|\(($0["resp_body"] as? String ?? "").prefix(120))" }.joined(separator: ";")
        let fingerprint = "\(token)|\(vehicleId)|\(effectiveDeviceId)|\(userToken)|\(samplesDigest)|\(poseidonDigest)"
        if fingerprint == lastAppliedFingerprint {
            lastReceivedAt = Date()
            if service.is403Detected {
                statusMessage = "🚨 凭证未变化但 Token 已失效（403）· 打开蔚来 App 爱车页下拉刷新即可"
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                // 冷却 60 秒：脚本会随 NIO App 每次请求重推相同凭证，避免连环触发刷新撞接口
                if Date().timeIntervalSince(lastInvalidRepushRefreshAt) >= 60 {
                    lastInvalidRepushRefreshAt = Date()
                    service.refreshAll(force: true)
                }
            } else {
                statusMessage = "🔁 重复推送已忽略（凭证未变化）"
            }
            return
        }

        if !token.isEmpty     { service.nioVehicleAccessToken = token;  applied.append("Token") }
        // 用户级 token：单独存档，车控/钥匙/实时流优先使用（不覆盖车级 token，保证 widget/info 查询路径不受影响）
        if !userToken.isEmpty {
            service.nioUserAccessToken = userToken
            applied.append("用户级Token🎯")
        }
        // 车控指令抓包样本 → 诊断日志（逆向对照官方请求格式：端点/body/签名参与方式）
        for sample in commandSamples.prefix(5) {
            let fn = (sample["function"] as? String) ?? ""
            let url = (sample["url"] as? String) ?? ""
            let method = (sample["method"] as? String) ?? "POST"
            let body = (sample["body"] as? String) ?? ""
            let time = (sample["time"] as? String) ?? ""
            service.appendLog(NIOFetchLogEntry(
                category: "command_capture", level: "info",
                message: "🎯 官方车控样本\(fn.isEmpty ? "" : "·\(fn)") \(time)",
                detail: "\(method) \(url)\nbody=\(body)",
                timestamp: Date(), requestURL: url, requestMethod: method,
                requestBody: body, responsePreview: nil, statusCode: nil
            ))
        }
        if !commandSamples.isEmpty { applied.append("车控样本×\(commandSamples.count)") }
        // 车机扫码授权链路样本 → 诊断日志（含服务端响应原文：权限判定/错误码/暂无权限出处）
        for sample in poseidonSamples.prefix(5) {
            let url = (sample["url"] as? String) ?? ""
            let method = (sample["method"] as? String) ?? "GET"
            let reqBody = (sample["req_body"] as? String) ?? ""
            let status = sample["status"] as? Int ?? 0
            let respBody = (sample["resp_body"] as? String) ?? ""
            let time = (sample["time"] as? String) ?? ""
            let pathTail = URL(string: url)?.pathComponents.suffix(2).joined(separator: "/") ?? url
            service.appendLog(NIOFetchLogEntry(
                category: "scan_capture", level: "info",
                message: "🔬 扫码授权链路样本·\(pathTail) \(time)",
                detail: "\(method) \(url)\nreq=\(reqBody)\nstatus=\(status)\nresp=\(respBody)",
                timestamp: Date(), requestURL: url, requestMethod: method,
                requestBody: reqBody, responsePreview: String(respBody.prefix(800)), statusCode: status
            ))
        }
        if !poseidonSamples.isEmpty { applied.append("扫码链路×\(poseidonSamples.count)") }
        if !vehicleId.isEmpty { service.nioVehicleId         = vehicleId; applied.append("VehicleID") }
        if !effectiveDeviceId.isEmpty { service.nioDeviceId = effectiveDeviceId; applied.append("DeviceID") }
        if !sign.isEmpty      { service.nioVehicleApiSign    = sign }
        if !timestamp.isEmpty { service.nioVehicleApiTimestamp = timestamp }
        if !vehicleUrl.isEmpty, vehicleUrl.contains("nio.com") {
            service.nioVehicleApiURL = vehicleUrl
            applied.append("API URL")
        }
        // 防多端登录指纹：存 UserDefaults 供统一 UA 构造与诊断
        if !appVer.isEmpty {
            UserDefaults.standard.set(appVer, forKey: "nio_captured_app_ver")
            applied.append("AppVer")
        }
        if !userAgent.isEmpty {
            UserDefaults.standard.set(userAgent, forKey: "nio_captured_user_agent")
        }

        guard !applied.isEmpty else {
            statusMessage = "⚠️ 收到推送但未找到有效凭证"
            return
        }

        receiveCount += 1
        lastAppliedFingerprint = fingerprint
        lastReceivedAt = Date()
        let summary = applied.joined(separator: " · ")
        statusMessage = "✅ 已回填: \(summary)"

        // 自动复制精简凭证 JSON 到剪贴板。
        // 注意：iOS 会静默丢弃后台 App 的剪贴板写入——保活上线后推送多发生在后台
        // （用户正在用 Shadowrocket），此时先暂存，回前台第一时间补写，
        // 保证设置页"剪贴板读取并识别"始终能读到最新凭证。
        var clipDict: [String: String] = [:]
        if !token.isEmpty     { clipDict["vehicle_token"] = token }
        if !userToken.isEmpty { clipDict["user_token"]    = userToken }
        if !vehicleId.isEmpty { clipDict["vehicle_id"]    = vehicleId }
        if !effectiveDeviceId.isEmpty { clipDict["device_id"] = effectiveDeviceId }
        if !vehicleUrl.isEmpty { clipDict["vehicle_url"]  = vehicleUrl }
        if !sign.isEmpty      { clipDict["sign"]          = sign }
        if !appVer.isEmpty    { clipDict["app_ver"]       = appVer }
        if !userGuid.isEmpty  { clipDict["user_guid"]     = userGuid }
        if !clipDict.isEmpty,
           let clipData = try? JSONSerialization.data(withJSONObject: clipDict, options: [.prettyPrinted, .sortedKeys]),
           let clipStr = String(data: clipData, encoding: .utf8) {
            if UIApplication.shared.applicationState == .active {
                UIPasteboard.general.string = clipStr
                UserDefaults.standard.removeObject(forKey: Self.pendingClipKey)
            } else {
                UserDefaults.standard.set(clipStr, forKey: Self.pendingClipKey)
            }
        }

        // 震动
        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(.success)

        // 系统通知横幅
        let content = UNMutableNotificationContent()
        content.title = "🌸 蔚来凭证已自动回填！"
        content.body  = "Shadowrocket 推送成功: \(summary)"
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )

        // 应用内横幅（修复：此前直推回填走 refreshAll 静默路径导致横幅从不出现）
        service.publishTransientNotice(.success, "🌸 凭证已回填: \(summary)")

        // 广播刷新（announce=true 让本次拉取结果也弹横幅反馈）
        NotificationCenter.default.post(name: NSNotification.Name("NIO_SNIFF_SUCCESS"), object: nil)
        service.refreshAll(force: true, announce: true)
    }
}

//
//  NIOMitmEngine.swift
//  wheater
//
//  蔚来专有域名 HTTPS MITM 嗅探与凭证自动提取引擎
//  v2 — 绑定 0.0.0.0 全网卡 · 全量连接日志 · 宽松嗅探 · Token 单独触发通知
//

import Foundation
import Network
import UIKit
import UserNotifications

public struct NIOSniffedCredentials: Sendable {
    public var vehicleId: String?
    public var deviceId: String?
    public var signSecret: String?
    public var authToken: String?
    public var fullUrl: String?
    public var appVer: String?
    public var timestamp: Date = Date()
}

/// 活跃连接登记表：代理队列与主线程并发登记/注销（锁保护），
/// stopProxy 时统一 cancel，避免静默 TCP 连接永久滞留
private final class MITMConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func track(_ conn: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(conn)] = conn
        lock.unlock()
    }

    func untrack(_ conn: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(conn))
        lock.unlock()
    }

    /// 关停全部登记中的连接，返回数量（诊断用）
    func cancelAll() -> Int {
        lock.lock()
        let all = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        all.forEach { $0.cancel() }
        return all.count
    }
}

@MainActor
final class NIOMitmEngine: ObservableObject {
    static let shared = NIOMitmEngine()

    @Published var isRunning = false
    @Published var proxyPort: UInt16 = 8998
    @Published var lastSniffed: NIOSniffedCredentials?
    @Published var sniffCount: Int = 0
    @Published var connectionCount: Int = 0       // 总连接计数（诊断用）
    @Published var recentSniffLogs: [String] = []

    private var listener: NWListener?
    private let proxyQueue = DispatchQueue(label: "com.yumikotoys.mitmproxy", qos: .userInitiated, attributes: .concurrent)
    /// 活跃连接登记：stopProxy 时统一关停，防止中继中的连接泄漏
    private let connectionRegistry = MITMConnectionRegistry()

    private init() {}

    // MARK: - 启动本地 MITM 代理服务（绑定 0.0.0.0 全网卡）

    func startProxy() {
        guard listener == nil else { return }
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true
            // 关键：监听全部网络接口，确保 Wi-Fi 代理从 en0 IP 进来的连接也能被接收
            params.requiredInterfaceType = .wifi

            let newListener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: proxyPort))
            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.addLog("🟢 抓包代理已启动，端口 \(self?.proxyPort ?? 8998) · 监听 Wi-Fi 接口 · 等待蔚来流量…")
                    case .failed(let err):
                        self?.isRunning = false
                        self?.listener = nil
                        self?.addLog("🔴 代理启动失败: \(err) — 请确认 App 有本地网络权限")
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] clientConn in
                self?.handleClientConnection(clientConn)
            }

            newListener.start(queue: proxyQueue)
            self.listener = newListener
        } catch {
            addLog("🔴 NWListener 创建失败: \(error)")
        }
    }

    func stopProxy() {
        listener?.cancel()
        listener = nil
        isRunning = false
        // 关停所有仍在中继的连接（原实现只关 listener，已建立的连接会继续收发流量）
        let closed = connectionRegistry.cancelAll()
        addLog(closed > 0 ? "⚪️ 抓包代理已关闭（断开 \(closed) 条连接）" : "⚪️ 抓包代理已关闭")
    }

    // MARK: - 处理客户端代理连接

    nonisolated private func handleClientConnection(_ clientConn: NWConnection) {
        // 记录连接到达（诊断用）
        Task { @MainActor [weak self] in
            self?.connectionCount += 1
            self?.addLog("📡 收到新连接 #\(self?.connectionCount ?? 0)")
        }

        clientConn.start(queue: proxyQueue)
        connectionRegistry.track(clientConn)
        // 累积读取直到 HTTP 头结束（\r\n\r\n）：单次 16KB receive 会截断大请求/分包请求
        accumulateClientRequest(clientConn, buffer: Data())
    }

    /// 累积读取客户端请求，头部收全后按 CONNECT / 明文 HTTP 分发；
    /// 头部之后同段到达的 body 随首包转发，余量由双向中继继续读取
    nonisolated private func accumulateClientRequest(_ clientConn: NWConnection, buffer: Data) {
        clientConn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let chunk = data, !chunk.isEmpty, error == nil else {
                self?.teardown(clientConn)
                return
            }
            var accumulated = buffer
            accumulated.append(chunk)
            let requestStr = String(decoding: accumulated, as: UTF8.self)

            // 头未收全且连接仍在：继续累积（上限 512KB 防异常膨胀）
            if !requestStr.contains("\r\n\r\n"), !isComplete, accumulated.count < 512 * 1024 {
                self.accumulateClientRequest(clientConn, buffer: accumulated)
                return
            }

            // 记录请求首行（诊断用）
            let firstLine = requestStr.components(separatedBy: "\r\n").first ?? requestStr.prefix(80).description
            Task { @MainActor [weak self] in
                self?.addLog("→ \(firstLine.prefix(120))")
            }

            self.inspectAndSniffTraffic(requestStr)

            // HTTPS CONNECT 隧道
            if requestStr.hasPrefix("CONNECT ") {
                let parts = requestStr.components(separatedBy: "\r\n").first?.components(separatedBy: " ") ?? []
                if parts.count >= 2 {
                    self.handleConnectTunnel(clientConn, target: parts[1])
                    return
                }
            }

            // 普通 HTTP 请求
            self.handlePlainHttpRelay(clientConn, initialData: accumulated, requestStr: requestStr)
        }
    }

    // MARK: - 连接关停与登记清理

    nonisolated private func teardown(_ conn: NWConnection) {
        connectionRegistry.untrack(conn)
        conn.cancel()
    }

    nonisolated private func teardownPair(_ a: NWConnection, _ b: NWConnection) {
        teardown(a)
        teardown(b)
    }

    // MARK: - 流量特征嗅探与凭证自动提取（宽松模式）

    nonisolated func inspectAndSniffTraffic(_ text: String) {
        // 宽松过滤：只要包含任意蔚来特征或 Authorization 头
        let isNioRelated = text.contains("nio.com")
            || text.contains("icar.")
            || text.contains("vehicle")
            || text.contains("device_id")
            || text.contains("Authorization")
            || text.contains("app_ver")
            || text.contains("sign=")
        guard isNioRelated else { return }

        var creds = NIOSniffedCredentials()
        var foundFields: [String] = []

        // 1. Authorization: Bearer <Token>
        let textLower = text
        for prefix in ["Authorization: Bearer ", "authorization: bearer "] {
            if let tokenRange = textLower.range(of: prefix, options: .caseInsensitive) {
                // 与 range 同源字符串取子串，避免 String index 错位
                let sub = textLower[tokenRange.upperBound...]
                if let end = sub.firstIndex(of: "\r") ?? sub.firstIndex(of: "\n") {
                    let token = String(sub[..<end]).trimmingCharacters(in: .whitespaces)
                    if !token.isEmpty && token.count > 10 {
                        creds.authToken = token
                        foundFields.append("Token(\(token.prefix(8))…)")
                    }
                }
                break
            }
        }

        // 2. 全行扫描 URL 参数
        let lines = text.components(separatedBy: "\r\n")
        for line in lines {
            let hasMethod = line.hasPrefix("GET ") || line.hasPrefix("POST ") || line.hasPrefix("PUT ") || line.hasPrefix("DELETE ")
            let hasUrl = line.contains("https://") || line.contains("http://")
            guard hasMethod || hasUrl || line.contains("nio.com") || line.contains("vehicle") || line.contains("device_id") || line.contains("sign=") else { continue }

            // 记录完整 URL
            if let urlRange = line.range(of: "http") {
                let urlSub = String(line[urlRange.lowerBound...]).components(separatedBy: " ").first ?? ""
                if !urlSub.isEmpty { creds.fullUrl = urlSub }
            }

            // vehicle_id
            if creds.vehicleId == nil {
                if let vid = extractParam(from: line, key: "vehicle_id") {
                    creds.vehicleId = vid
                    foundFields.append("VehicleID(\(vid.prefix(6))…)")
                } else if line.contains("/vehicle/") {
                    let parts = line.components(separatedBy: "/vehicle/")
                    if parts.count > 1 {
                        let vid = parts[1].components(separatedBy: "/").first?.components(separatedBy: "?").first ?? ""
                        if vid.count >= 6 {
                            creds.vehicleId = vid
                            foundFields.append("VehicleID(\(vid.prefix(6))…)")
                        }
                    }
                }
            }

            // device_id
            if creds.deviceId == nil, let did = extractParam(from: line, key: "device_id") {
                creds.deviceId = did
                foundFields.append("DeviceID")
            }

            // app_ver
            if creds.appVer == nil, let ver = extractParam(from: line, key: "app_ver") {
                creds.appVer = ver
            }

            // sign
            if creds.signSecret == nil, let sign = extractParam(from: line, key: "sign") {
                creds.signSecret = sign
                foundFields.append("Sign")
            }
        }

        if !foundFields.isEmpty {
            let capturedCreds = creds
            let summary = foundFields.joined(separator: ", ")
            Task { @MainActor [weak self] in
                self?.applySniffedCredentials(capturedCreds, fieldSummary: summary)
            }
        }
    }

    nonisolated private func extractParam(from str: String, key: String) -> String? {
        let pattern = "\(key)=([^&\\s\"']+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: str, options: [], range: NSRange(str.startIndex..., in: str)),
              let range = Range(match.range(at: 1), in: str) else {
            return nil
        }
        return String(str[range])
    }

    // MARK: - 应用凭证并通知

    @MainActor
    private func applySniffedCredentials(_ creds: NIOSniffedCredentials, fieldSummary: String) {
        self.lastSniffed = creds
        self.sniffCount += 1

        let service = NIOService.shared
        var appliedFields: [String] = []

        if let vid = creds.vehicleId, !vid.isEmpty {
            service.nioVehicleId = vid
            appliedFields.append("Vehicle ID")
        }
        if let did = creds.deviceId, !did.isEmpty {
            service.nioDeviceId = did
            appliedFields.append("Device ID")
        }
        if let token = creds.authToken, !token.isEmpty {
            service.nioVehicleAccessToken = token
            appliedFields.append("Token")
        }
        if let url = creds.fullUrl, !url.isEmpty, url.contains("nio.com") {
            service.nioVehicleApiURL = url
            appliedFields.append("API URL")
        }

        let msg = appliedFields.isEmpty
            ? "🔍 检测到蔚来流量 (\(fieldSummary))，未发现可回填凭证"
            : "🎉 成功回填: \(appliedFields.joined(separator: " · ")) [\(fieldSummary)]"

        addLog(msg)

        // 震动
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(appliedFields.isEmpty ? .warning : .success)

        // 系统通知横幅
        let content = UNMutableNotificationContent()
        content.title = appliedFields.isEmpty ? "🔍 YumikoToys 检测到蔚来流量" : "🌸 NIO 凭证已自动回填！"
        content.body = msg
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil),
            withCompletionHandler: nil
        )

        // 广播刷新
        NotificationCenter.default.post(name: NSNotification.Name("NIO_SNIFF_SUCCESS"), object: nil)
        if !appliedFields.isEmpty {
            service.refreshAll(force: true)
        }
    }

    // MARK: - 内部日志

    private func addLog(_ log: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        recentSniffLogs.insert("[\(ts)] \(log)", at: 0)
        if recentSniffLogs.count > 100 {
            recentSniffLogs.removeLast()
        }
    }

    // MARK: - HTTPS CONNECT 隧道转发

    nonisolated private func handleConnectTunnel(_ clientConn: NWConnection, target: String) {
        let parts = target.components(separatedBy: ":")
        let hostStr = parts.first ?? ""
        let portInt = UInt16(parts.count > 1 ? parts[1] : "443") ?? 443

        // 记录 CONNECT 目标（诊断）
        Task { @MainActor [weak self] in
            self?.addLog("🔒 CONNECT → \(target)")
        }

        let serverConn = NWConnection(
            host: NWEndpoint.Host(hostStr),
            port: NWEndpoint.Port(rawValue: portInt) ?? .https,
            using: .tcp
        )
        serverConn.start(queue: proxyQueue)
        connectionRegistry.track(serverConn)

        let okResp = "HTTP/1.1 200 Connection Established\r\n\r\n".data(using: .utf8) ?? Data()
        clientConn.send(content: okResp, completion: .contentProcessed({ [weak self] err in
            if err == nil {
                self?.bridgeConnections(client: clientConn, server: serverConn)
            } else {
                self?.teardownPair(clientConn, serverConn)
            }
        }))
    }

    // MARK: - HTTP 明文请求中继

    nonisolated private func handlePlainHttpRelay(_ clientConn: NWConnection, initialData: Data, requestStr: String) {
        var targetHost = "app.nio.com"
        var targetPort: UInt16 = 80
        if let hostRange = requestStr.range(of: "Host: ", options: .caseInsensitive) {
            let sub = requestStr[hostRange.upperBound...]
            if let end = sub.firstIndex(of: "\r") ?? sub.firstIndex(of: "\n") {
                let h = String(sub[..<end]).trimmingCharacters(in: .whitespaces)
                let hp = h.components(separatedBy: ":")
                targetHost = hp.first ?? targetHost
                if hp.count > 1, let p = UInt16(hp[1]) { targetPort = p }
            }
        }

        let serverConn = NWConnection(
            host: NWEndpoint.Host(targetHost),
            port: NWEndpoint.Port(rawValue: targetPort) ?? .http,
            using: .tcp
        )
        serverConn.start(queue: proxyQueue)
        connectionRegistry.track(serverConn)
        serverConn.send(content: initialData, completion: .contentProcessed({ [weak self] err in
            if err == nil {
                self?.bridgeConnections(client: clientConn, server: serverConn)
            } else {
                self?.teardownPair(clientConn, serverConn)
            }
        }))
    }

    // MARK: - 双向数据中继

    nonisolated private func bridgeConnections(client: NWConnection, server: NWConnection) {
        relayLoop(from: client, to: server, isFromClient: true)
        relayLoop(from: server, to: client, isFromClient: false)
    }

    nonisolated private func relayLoop(from source: NWConnection, to destination: NWConnection, isFromClient: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let chunk = data, !chunk.isEmpty, error == nil else {
                // weak self 已释放也必须关停两端，否则连接在无主状态泄漏
                self?.teardownPair(source, destination)
                return
            }

            if isFromClient {
                let str = String(decoding: chunk, as: UTF8.self)
                self.inspectAndSniffTraffic(str)
            }

            destination.send(content: chunk, completion: .contentProcessed({ [weak self] sendErr in
                if sendErr == nil && !isComplete {
                    self?.relayLoop(from: source, to: destination, isFromClient: isFromClient)
                } else {
                    self?.teardownPair(source, destination)
                }
            }))
        }
    }
}

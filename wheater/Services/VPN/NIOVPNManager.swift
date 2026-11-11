//
//  NIOVPNManager.swift
//  wheater
//
//  iOS 系统 VPN 隧道管理器与生命周期调度
//

import Foundation
import NetworkExtension
import UIKit

public enum NIOVPNStatus: String {
    case disconnected = "待命关闭"
    case connecting = "正在启动…"
    case connected = "抓包运行中"
    case disconnecting = "正在断开…"
    case captured = "已成功捕获 ✨"
}

@MainActor
final class NIOVPNManager: ObservableObject {
    static let shared = NIOVPNManager()

    @Published var status: NIOVPNStatus = .disconnected
    @Published var isVPNActive: Bool = false
    @Published var lastCapturedTime: Date?
    @Published var lastCapturedSummary: String?

    private var tunnelManager: NETunnelProviderManager?
    private var statusObserver: Any?
    private var sniffObserver: Any?
    private var autoStopTimer: Timer?

    private init() {
        setupObservers()
        loadTunnelManager()
    }

    deinit {
        if let obs = statusObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = sniffObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - 初始化与观察者

    private func setupObservers() {
        sniffObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NIO_SNIFF_SUCCESS"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSniffSuccess()
            }
        }
    }

    private func loadTunnelManager() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let mgr = managers?.first {
                    self.tunnelManager = mgr
                } else {
                    let newMgr = NETunnelProviderManager()
                    let proto = NETunnelProviderProtocol()
                    proto.providerBundleIdentifier = Bundle.main.bundleIdentifier.map { "\($0).PacketTunnel" } ?? "com.yumikotoys.nio.tunnel"
                    proto.serverAddress = "127.0.0.1"
                    newMgr.protocolConfiguration = proto
                    newMgr.localizedDescription = "YumikoToys NIO 自动抓包"
                    newMgr.isEnabled = true
                    newMgr.saveToPreferences { [weak self] saveErr in
                        // 回调由 NetworkExtension 派发、无主线程保证：
                        // 写 @MainActor 状态必须跳回主隔离
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            if saveErr == nil {
                                self.tunnelManager = newMgr
                            }
                            // 新建分支补挂状态监听（否则此时 tunnelManager 仍为 nil，
                            // observeVPNStatus 直接 return，NEVPNStatusDidChange 永不生效）
                            self.observeVPNStatus()
                        }
                    }
                }
                self.observeVPNStatus()
            }
        }
    }

    private func observeVPNStatus() {
        guard let connection = tunnelManager?.connection else { return }
        if let obs = statusObserver { NotificationCenter.default.removeObserver(obs) }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusFromConnection()
            }
        }
        updateStatusFromConnection()
    }

    private func updateStatusFromConnection() {
        guard let state = tunnelManager?.connection.status else {
            self.status = .disconnected
            self.isVPNActive = false
            return
        }

        switch state {
        case .connected:
            self.status = .connected
            self.isVPNActive = true
        case .connecting, .reasserting:
            self.status = .connecting
            self.isVPNActive = true
        case .disconnecting:
            self.status = .disconnecting
            self.isVPNActive = false
        case .disconnected, .invalid:
            if self.status != .captured {
                self.status = .disconnected
            }
            self.isVPNActive = false
        @unknown default:
            self.status = .disconnected
            self.isVPNActive = false
        }
    }

    // MARK: - 启动与停止 VPN 抓包

    func startCaptureVPN() {
        // 1. 启动本地 MITM 代理与证书分发服务
        NIOMitmEngine.shared.startProxy()
        NIOVPNCertManager.shared.startLocalCertServer()

        // 2. 启动系统 VPN 隧道
        if let manager = tunnelManager {
            manager.loadFromPreferences { [weak self] _ in
                manager.isEnabled = true
                manager.saveToPreferences { saveErr in
                    guard saveErr == nil else {
                        // 若无法保存 VPN 首选项，使用本地代理模式
                        Task { @MainActor [weak self] in
                            self?.status = .connected
                            self?.isVPNActive = true
                        }
                        return
                    }
                    do {
                        try manager.connection.startVPNTunnel()
                    } catch {
                        // 在免 VPN 巨魔/越狱模式下回退为本地监听代理
                        Task { @MainActor [weak self] in
                            self?.status = .connected
                            self?.isVPNActive = true
                        }
                    }
                }
            }
        } else {
            // 本地代理模式直接就绪
            self.status = .connected
            self.isVPNActive = true
        }

        // 3. 3 分钟超时自动停止守护
        autoStopTimer?.invalidate()
        autoStopTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.isVPNActive == true {
                    self?.stopCaptureVPN()
                }
            }
        }
    }

    func stopCaptureVPN() {
        autoStopTimer?.invalidate()
        autoStopTimer = nil

        tunnelManager?.connection.stopVPNTunnel()
        NIOMitmEngine.shared.stopProxy()
        NIOVPNCertManager.shared.stopLocalCertServer()

        self.status = .disconnected
        self.isVPNActive = false
    }

    // MARK: - 成功捕获处理

    private func handleSniffSuccess() {
        self.status = .captured
        self.lastCapturedTime = Date()

        let creds = NIOMitmEngine.shared.lastSniffed
        var summaryParts: [String] = []
        if let vid = creds?.vehicleId { summaryParts.append("车辆 ID: \(vid.prefix(6))…") }
        if creds?.authToken != nil { summaryParts.append("Token 已就绪") }
        self.lastCapturedSummary = summaryParts.joined(separator: " · ")

        // 5 秒后自动关闭 VPN 节约电量
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.stopCaptureVPN()
        }
    }
}

//
//  NIOVPNCertManager.swift
//  wheater
//
//  内置抓包 Root CA 证书与 Safari 描述文件分发服务
//

import Foundation
import Network
import UIKit

@MainActor
final class NIOVPNCertManager: ObservableObject {
    static let shared = NIOVPNCertManager()

    @Published var isServerRunning = false
    @Published var serverPort: UInt16 = 8999
    @Published var certInstalledHint = false

    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "com.yumikotoys.certserver", qos: .userInitiated)

    // 内置本地专有自签名根证书（PEM / DER Base64）
    // 内置本地专有自签名根证书（标准 X.509 v3 DER Base64，有效期至 2036 年）
    nonisolated static let rootCertBase64: String = {
        let rawCert = """
        MIIDkTCCAnmgAwIBAgIUSDfzJOyNgYCKTIQH5n9gLyPjWWowDQYJKoZIhvcNAQELBQAwWDELMAkG
        A1UEBhMCQ04xGjAYBgNVBAoMEVl1bWlrb1RveXMgU3R1ZGlvMQwwCgYDVQQLDANOSU8xHzAdBgNV
        BAMMFll1bWlrb1RveXMgTklPIFJvb3QgQ0EwHhcNMjYwODMxMTExNTU0WhcNMzYwODI4MTExNTU0
        WjBYMQswCQYDVQQGEwJDTjEaMBgGA1UECgwRWXVtaWtvVG95cyBTdHVkaW8xDDAKBgNVBAsMA05J
        TzEfMB0GA1UEAwwWWXVtaWtvVG95cyBOSU8gUm9vdCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEP
        ADCCAQoCggEBALlIZGMp1y87uSGmq5Zwn24fPtOm3y+//l4r+VmuEA/9imT4Hbf5bzpMA21zOCIX
        Jhw8zU4ObyAHxX0r9J0C/ItUW6HDtgnyl99is5YLXlbzmjHeumKa/Ma+GCac3u04qPFVVYNYTPkI
        5AzGNJKNSxxqy+x3vZ3WFv5YdDPhW5mxbSApTx/Tqw6Zl8RYo1LEAN3S1f1fFlaMZoI0tN/G7gs4
        4K1JRUMGWTlFl0u2wz2XR6K/NbHhBzDA3UyrnqIGZnx8VdyztJV2/nvckiORHKpd8uETmbR+wWpG
        BI1D/TRMT1ISWrlXcT8PP2pI5X/hNCBxd4b0urNsaVW4OmifVdECAwEAAaNTMFEwHQYDVR0OBBYE
        FOT6QgOLcYailp3E/89xYxnvl0chMB8GA1UdIwQYMBaAFOT6QgOLcYailp3E/89xYxnvl0chMA8G
        A1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBABpU3SKmv/QpojAQrYyM+qdfAWsnrwJW
        B9JXWRdeL0uiE5p9IoRWbLyxTCsVWPl9rqvoaq6FIoR47duEZ+/8RIEoC7B+y9FMJKjsUqOOpOD2
        k8WX4eMNWUWxXaRlHq7ZznsS/E01OJk0/Jg6PACBU1B78S1SpF+fDvLSmNxhayS05Rk5JxJxU/OY
        zHTu2Mrk3eX8jCFOAbSNQj8zHWCCBnb1XvBwqGDL+khg4qfR4R0VVzPBNzYmX5wH7tBR3qSXH1Ou
        3uJIt85s4pY+g/KQzfn4Wc31OK+AYYc3GdUWiki0gsSLcISFS1rnjBKZ1qDMn/LyZi0EjYhaVKw/
        PEK2dEE=
        """.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "")
        return rawCert
    }()

    private init() {}

    // MARK: - 启动本地描述文件分发 HTTP 服务

    func startLocalCertServer() {
        guard listener == nil else { return }
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true

            let newListener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: serverPort))
            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        self?.isServerRunning = true
                    case .failed, .cancelled:
                        self?.isServerRunning = false
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }

            newListener.start(queue: serverQueue)
            self.listener = newListener
            self.isServerRunning = true
        } catch {
            print("[NIOVPNCertManager] 启动本地证书服务失败: \(error)")
        }
    }

    func stopLocalCertServer() {
        listener?.cancel()
        listener = nil
        isServerRunning = false
    }

    // MARK: - 调起 Safari 安装描述文件

    func openInstallProfileInSafari() {
        startLocalCertServer()
        let urlStr = "http://127.0.0.1:\(serverPort)/ca.mobileconfig"
        if let url = URL(string: urlStr) {
            UIApplication.shared.open(url, options: [:]) { success in
                if success {
                    self.certInstalledHint = true
                }
            }
        }
    }

    // MARK: - HTTP 请求处理

    nonisolated private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: serverQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, isComplete, error in
            guard let self = self, let data = content, error == nil else {
                connection.cancel()
                return
            }

            let requestStr = String(data: data, encoding: .utf8) ?? ""
            if requestStr.contains("GET /ca.mobileconfig") || requestStr.contains("GET /") {
                let profileXml = self.generateMobileConfigXml()
                let responseData = profileXml.data(using: .utf8) ?? Data()

                let header = """
                HTTP/1.1 200 OK\r
                Content-Type: application/x-apple-aspen-config\r
                Content-Disposition: attachment; filename="YumikoToys_NIO_CA.mobileconfig"\r
                Content-Length: \(responseData.count)\r
                Connection: close\r
                \r\n
                """

                var fullData = header.data(using: .utf8) ?? Data()
                fullData.append(responseData)

                connection.send(content: fullData, completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            } else {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: notFound.data(using: .utf8), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            }
        }
    }

    // MARK: - 生成 .mobileconfig XML

    nonisolated private func generateMobileConfigXml() -> String {
        let certUUID = UUID().uuidString
        let profileUUID = UUID().uuidString

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadContent</key>
            <array>
                <dict>
                    <key>PayloadCertificateFileName</key>
                    <string>YumikoToysRootCA.cer</string>
                    <key>PayloadContent</key>
                    <data>
                    \(Self.rootCertBase64)
                    </data>
                    <key>PayloadDescription</key>
                    <string>用于 YumikoToysRR 蔚来看板内置抓包嗅探与凭证自动回填</string>
                    <key>PayloadDisplayName</key>
                    <string>YumikoToys NIO Root CA</string>
                    <key>PayloadIdentifier</key>
                    <string>com.yumikotoys.nio.ca.cert</string>
                    <key>PayloadType</key>
                    <string>com.apple.security.root</string>
                    <key>PayloadUUID</key>
                    <string>\(certUUID)</string>
                    <key>PayloadVersion</key>
                    <integer>1</integer>
                </dict>
            </array>
            <key>PayloadDescription</key>
            <string>YumikoToysRR 蔚来看板 HTTPS 抓包根证书配置文件</string>
            <key>PayloadDisplayName</key>
            <string>YumikoToys NIO 抓包根证书</string>
            <key>PayloadIdentifier</key>
            <string>com.yumikotoys.nio.ca.profile</string>
            <key>PayloadOrganization</key>
            <string>YumikoToys Studio</string>
            <key>PayloadRemovalDisallowed</key>
            <false/>
            <key>PayloadType</key>
            <string>Configuration</string>
            <key>PayloadUUID</key>
            <string>\(profileUUID)</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
        </plist>
        """
    }
}

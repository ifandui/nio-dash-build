//
//  NIOCredentialInboxView.swift
//  wheater
//
//  凭证收件箱：展示 / 复制 Shadowrocket 直推过来的每一个字段与抓包样本。
//  数据源 NIOCredentialReceiver.inboxPayload（最近一次推送的完整 JSON，持久化）。
//

import SwiftUI
import UniformTypeIdentifiers

/// 收件箱导出文档（fileExporter 用）：内容即直推载荷原样 JSON
struct NIOInboxDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(json: [String: Any]) {
        data = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// 收件箱样本条目模型
struct NIOInboxSample: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let copyText: String
    let detail: String
}

struct NIOCredentialInboxView: View {
    @ObservedObject private var receiver = NIOCredentialReceiver.shared
    @ObservedObject private var themeService = AnimeThemeService.shared
    @State private var revealSecrets = false
    @State private var expandedSampleIDs: Set<String> = []
    @State private var includeSecretInExport = false
    // 导出 / 导入（文件 App）
    @State private var isExporting = false
    @State private var exportDocument: NIOInboxDocument?
    @State private var isImporting = false
    @State private var importResultText: String?

    private var accent: Color { themeService.accentColor() }

    /// 导出默认文件名：nio_credentials_20261102-1930.json
    private var defaultExportFileName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return "nio_credentials_\(f.string(from: Date()))"
    }

    /// 全量导出载荷 = 收件箱直推载荷 + 当前手动配置的换电/签到 API 与 Token
    /// （签名密钥仅在开关打开时包含，默认不含）
    private func buildExportPayload(includeSecret: Bool) -> [String: Any] {
        var payload = receiver.inboxPayload ?? [:]
        let service = NIOService.shared
        if !service.nioChangeApiURL.isEmpty { payload["change_url"] = service.nioChangeApiURL }
        if !service.nioChangeAccessToken.isEmpty { payload["change_token"] = service.nioChangeAccessToken }
        if !service.nioCheckinApiURL.isEmpty { payload["checkin_url"] = service.nioCheckinApiURL }
        if !service.nioCheckinAccessToken.isEmpty { payload["checkin_token"] = service.nioCheckinAccessToken }
        if includeSecret, !service.nioVehicleSignSecret.isEmpty { payload["sign_secret"] = service.nioVehicleSignSecret }
        let f = ISO8601DateFormatter()
        payload["exported_at"] = f.string(from: Date())
        payload["export_version"] = 2
        return payload
    }

    /// 凭证字段展示清单（key → 中文名）
    private static let fieldLabels: [(key: String, label: String)] = [
        ("vehicle_token", "车级 Token（小组件）"),
        ("user_token",    "用户级 Token（车控/钥匙）"),
        ("vehicle_id",    "Vehicle ID"),
        ("device_id",     "Device ID"),
        ("user_guid",     "User-Guid 指纹"),
        ("app_ver",       "App 版本指纹"),
        ("user_agent",    "User-Agent"),
        ("sign",          "签名（抓包快照）"),
        ("timestamp",     "时间戳（抓包快照）"),
        ("vehicle_url",   "车辆 API URL"),
        ("rvs_url",       "RVS URL"),
        ("widget_url",    "Widget URL")
    ]

    var body: some View {
        NavigationView {
            Group {
                if let payload = receiver.inboxPayload {
                    inboxList(payload)
                } else {
                    emptyState
                }
            }
            .background(themeService.backgroundPrimary().ignoresSafeArea())
            .navigationTitle("📥 凭证收件箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 2) {
                        // 导出：全量凭证快照（收件箱载荷 + 换电/签到 Token）存到「文件」App
                        Button {
                            exportDocument = NIOInboxDocument(json: buildExportPayload(includeSecret: includeSecretInExport))
                            isExporting = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(receiver.inboxPayload == nil)

                        // 导入：从「文件」App 选择凭证 JSON 回填
                        Button {
                            isImporting = true
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        receiver.clearInbox()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(receiver.inboxPayload == nil)
                }
            }
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: defaultExportFileName
            ) { result in
                if case .success = result {
                    importResultText = "✅ 已导出到「文件」"
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let secured = url.startAccessingSecurityScopedResource()
                    defer { if secured { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try Data(contentsOf: url)
                        if receiver.importPayload(data) {
                            importResultText = "✅ 导入成功，凭证已回填"
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        } else {
                            importResultText = "⚠️ 文件不是有效的凭证 JSON"
                            UINotificationFeedbackGenerator().notificationOccurred(.error)
                        }
                    } catch {
                        importResultText = "⚠️ 读取文件失败：\(error.localizedDescription)"
                    }
                case .failure:
                    break // 用户取消
                }
            }
            .alert("收件箱", isPresented: Binding(
                get: { importResultText != nil },
                set: { if !$0 { importResultText = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importResultText ?? "")
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("收件箱为空")
                .font(.headline)
            Text("在 Shadowrocket 导入模块后，打开蔚来 App\n任意页面，推送会自动出现在这里")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - 列表

    private func inboxList(_ payload: [String: Any]) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                metaCard(payload)
                credentialFieldsCard(payload)
                sampleCard(title: "🎯 官方车控样本", emptyHint: "在官方 App 点车控按钮后自动捕获", samples: buildCommandSamples(payload))
                sampleCard(title: "🔬 扫码授权链路样本", emptyHint: "车机工程模式扫码（用官方 App 扫）后自动捕获", samples: buildPoseidonSamples(payload))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func metaCard(_ payload: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("推送信息", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
                Spacer()
                Button {
                    UIPasteboard.general.string = rawJSONString(payload)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label("复制全部 JSON", systemImage: "doc.on.doc")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.borderless)
            }
            if let t = receiver.lastReceivedAt {
                Text("最近接收：\(t.formatted(date: .abbreviated, time: .standard)) · 共 \(receiver.receiveCount) 次")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: $includeSecretInExport) {
                Text("导出包含签名密钥（换机迁移用，谨慎开启）")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .tint(includeSecretInExport ? .orange : .secondary)
            .scaleEffect(0.8, anchor: .trailing)
            .frame(height: 22)
        }
        .padding(12)
        .background(NIOThemePaint.well)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 凭证字段

    private func credentialFieldsCard(_ payload: [String: Any]) -> some View {
        let presentFields = Self.fieldLabels.filter { field in
            let v = payload[field.key] as? String ?? ""
            return !v.isEmpty
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("凭证字段（点行复制）", systemImage: "key.horizontal.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
                Spacer()
                Button {
                    revealSecrets.toggle()
                } label: {
                    Label(revealSecrets ? "隐藏明文" : "显示明文", systemImage: revealSecrets ? "eye.slash" : "eye")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.borderless)
            }

            if presentFields.isEmpty {
                Text("本次推送不含凭证字段（可能仅为样本推送）")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ForEach(presentFields, id: \.key) { field in
                let value = (payload[field.key] as? String) ?? ""
                fieldRow(label: field.label, value: value)
            }
        }
        .padding(12)
        .background(NIOThemePaint.well)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func fieldRow(label: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NIOThemePaint.text.opacity(0.75))
                    .frame(width: 128, alignment: .leading)
                Text(displayValue(value))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(NIOThemePaint.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(accent.opacity(0.7))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(NIOThemePaint.text.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.borderless)
    }

    private func displayValue(_ value: String) -> String {
        guard !revealSecrets, value.count > 16 else { return value }
        return value.prefix(8) + "••••••••" + value.suffix(6)
    }

    // MARK: - 样本构建（与视图分离，降低类型检查负担）

    private func buildCommandSamples(_ payload: [String: Any]) -> [NIOInboxSample] {
        let raw = (payload["command_samples"] as? [[String: Any]]) ?? []
        return raw.enumerated().map { index, s in
            let fn = (s["function"] as? String) ?? ""
            let url = (s["url"] as? String) ?? ""
            let body = (s["body"] as? String) ?? ""
            let time = (s["time"] as? String) ?? ""
            let method = (s["method"] as? String) ?? "POST"
            let title = fn.isEmpty ? URL(string: url)?.lastPathComponent ?? url : fn
            return NIOInboxSample(
                id: "cmd-\(index)-\(time)",
                title: title,
                subtitle: "\(method) · \(time)",
                copyText: "\(method) \(url)\nbody=\(body)",
                detail: "URL: \(url)\nbody=\(body)"
            )
        }
    }

    private func buildPoseidonSamples(_ payload: [String: Any]) -> [NIOInboxSample] {
        let raw = (payload["poseidon_samples"] as? [[String: Any]]) ?? []
        return raw.enumerated().map { index, s in
            let url = (s["url"] as? String) ?? ""
            let status = s["status"] as? Int ?? 0
            let resp = (s["resp_body"] as? String) ?? ""
            let req = (s["req_body"] as? String) ?? ""
            let time = (s["time"] as? String) ?? ""
            let method = (s["method"] as? String) ?? "GET"
            let pathTail = URL(string: url)?.pathComponents.suffix(2).joined(separator: "/") ?? url
            return NIOInboxSample(
                id: "pose-\(index)-\(time)",
                title: pathTail.isEmpty ? url : pathTail,
                subtitle: "\(method) · status \(status) · \(time)",
                copyText: "\(method) \(url)\nreq=\(req)\nstatus=\(status)\nresp=\(resp)",
                detail: "URL: \(url)\nreq=\(req)\n\n── 响应 ──\n\(resp)"
            )
        }
    }

    // MARK: - 样本分区卡

    private func sampleCard(title: String, emptyHint: String, samples: [NIOInboxSample]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(title)（\(samples.count)）", systemImage: "shippingbox.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accent)

            if samples.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ForEach(samples) { sample in
                sampleRow(sample)
            }
        }
        .padding(12)
        .background(NIOThemePaint.well)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func sampleRow(_ sample: NIOInboxSample) -> some View {
        let isExpanded = expandedSampleIDs.contains(sample.id)
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedSampleIDs.remove(sample.id)
                    } else {
                        expandedSampleIDs.insert(sample.id)
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sample.title)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(NIOThemePaint.text)
                            .lineLimit(1)
                        Text(sample.subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)

            if isExpanded {
                Text(sample.detail)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(NIOThemePaint.text.opacity(0.85))
                    .lineLimit(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(NIOThemePaint.text.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Button {
                UIPasteboard.general.string = sample.copyText
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Label("复制原文", systemImage: "doc.on.doc.fill")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(NIOThemePaint.text.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func rawJSONString(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

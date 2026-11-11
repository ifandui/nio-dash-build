//
//  NIOConfigBackupView.swift
//  wheater
//
//  全量配置备份与恢复 — 解决重装 App 后所有手动配置丢失的问题
//
//  导出：把 App 自身 UserDefaults 域的全部键值（NIO Token / API 地址 / 轮询 /
//        灵动岛开关 / 主题等所有手动配置）+ 收件箱载荷打包为 JSON 存到「文件」App。
//  导入：从「文件」App 选择备份 JSON，整包写回 UserDefaults。
//        @Published 属性在启动时从 UserDefaults 初始化，恢复后需重启 App 生效。
//
//  注意：内置签名密钥随 NIO_Secrets.plist 打包，重装后自动恢复，无需备份；
//        若你在设置页手动覆盖过密钥，它会作为普通 UserDefaults 键一并备份。
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 备份文件文档

struct NIOConfigBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var json: [String: Any]

    init(json: [String: Any]) {
        self.json = json
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = obj
        } else {
            throw CocoaError(.propertyListReadCorrupt)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let obj = JSONSerialization.isValidJSONObject(json)
            ? (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
            : Data("{}".utf8)
        return FileWrapper(regularFileWithContents: obj)
    }
}

// MARK: - 备份视图

struct NIOConfigBackupView: View {
    @State private var isExporting = false
    @State private var exportDocument: NIOConfigBackupDocument?
    @State private var isImporting = false
    @State private var pendingImportDocument: NIOConfigBackupDocument?
    @State private var showRestoreConfirm = false
    @State private var resultText: String?
    @State private var resultIsError = false

    private var defaultFileName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return "yumikotoys_backup_\(f.string(from: Date()))"
    }

    /// 永不备份/恢复的键：运行日志（体积大且无恢复价值）
    private static let excludedKeyFragments = ["log", "logs"]

    /// 导出载荷：App 自身持久域全量键值 + 元信息
    private func buildBackupPayload() -> [String: Any] {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let domain = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
        let filtered = domain.filter { key, _ in
            !Self.excludedKeyFragments.contains { key.lowercased().contains($0) }
        }
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "backup_version": 1,
            "exported_at": iso.string(from: Date()),
            "app_version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "",
            "build": (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "",
            "bundle_id": bundleID,
            "defaults": filtered
        ]
        // 收件箱载荷（内含最近一次直推的凭证与抓包样本）一并带上
        if let inbox = UserDefaults.standard.object(forKey: "nio_last_push_payload") {
            payload["nio_last_push_payload"] = inbox
        }
        return payload
    }

    /// 恢复：整包写回 UserDefaults，返回恢复的键数量
    @discardableResult
    private static func restore(from payload: [String: Any]) -> Int {
        guard payload["backup_version"] != nil,
              let defaults = payload["defaults"] as? [String: Any] else { return 0 }
        let ud = UserDefaults.standard
        var count = 0
        for (key, value) in defaults where !excludedKeyFragments.contains(where: { key.lowercased().contains($0) }) {
            switch value {
            case let n as NSNumber:
                // JSON 反序列化里 Bool 与数字都是 NSNumber，用 CF 类型区分避免 true 变 1.0
                if CFGetTypeID(n) == CFBooleanGetTypeID() { ud.set(n.boolValue, forKey: key) }
                else { ud.set(n, forKey: key) }
            case let s as String: ud.set(s, forKey: key)
            case let d as Date: ud.set(d, forKey: key)
            case let data as Data: ud.set(data, forKey: key)
            case let a as [Any]: ud.set(a, forKey: key)
            case let dict as [String: Any]: ud.set(dict, forKey: key)
            default: continue
            }
            count += 1
        }
        ud.synchronize()
        return count
    }

    var body: some View {
        Form {
            Section {
                Text("把 App 内所有手动配置（Token、API 地址、车控与灵动岛设置、轮询间隔、主题偏好等）打包成 JSON 存到「文件」App。重装 App 后从文件导入即可完整恢复，无需重新抓包配置。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Section("备份") {
                Button {
                    exportDocument = NIOConfigBackupDocument(json: buildBackupPayload())
                    isExporting = true
                } label: {
                    Label("导出配置备份到「文件」", systemImage: "square.and.arrow.up")
                }
            }

            Section("恢复") {
                Button {
                    isImporting = true
                } label: {
                    Label("从「文件」导入备份", systemImage: "square.and.arrow.down")
                }
                Text("导入会覆盖当前全部同名配置。恢复完成后请杀掉 App 重新打开，所有页面即按备份配置刷新。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let resultText {
                Section {
                    Label(resultText, systemImage: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(resultIsError ? .orange : .green)
                }
            }

            Section("说明") {
                LabeledContent("内置签名密钥", value: "随 App 打包，重装自动恢复")
                    .font(.system(size: 11))
                LabeledContent("手动覆盖的密钥", value: "包含在备份中")
                    .font(.system(size: 11))
                LabeledContent("历史数据/日志", value: "不包含（仅配置）")
                    .font(.system(size: 11))
            }
        }
        .navigationTitle("备份与恢复")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: defaultFileName
        ) { result in
            switch result {
            case .success(let url):
                showResult("已备份到：\(url.lastPathComponent)", isError: false)
            case .failure(let error):
                showResult("备份失败：\(error.localizedDescription)", isError: true)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       obj["backup_version"] != nil {
                        pendingImportDocument = NIOConfigBackupDocument(json: obj)
                        showRestoreConfirm = true
                    } else {
                        showResult("不是有效的备份文件（缺少 backup_version）", isError: true)
                    }
                } catch {
                    showResult("读取失败：\(error.localizedDescription)", isError: true)
                }
            case .failure:
                break
            }
        }
        .confirmationDialog(
            "确认恢复备份？当前同名配置将被覆盖",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("恢复并覆盖", role: .destructive) {
                if let doc = pendingImportDocument {
                    let count = Self.restore(from: doc.json)
                    showResult(count > 0 ? "已恢复 \(count) 项配置，请重启 App 生效" : "备份为空，未恢复任何配置",
                               isError: count == 0)
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func showResult(_ text: String, isError: Bool) {
        resultText = text
        resultIsError = isError
    }
}

//
//  NIOVehicleLib.swift
//  YumikoToys
//
//  RVS 归一化 + 车辆数据工具函数 + 动态签名 + 轨迹计算（从 NIO-Dash 重写）
//

import Foundation
import CryptoKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - 缓存格式化器（DateFormatter 创建成本高，禁止在热路径反复新建）

enum NIOFormatters {
    static let dayKey: DateFormatter = make("yyyy-MM-dd")
    static let dayLabel: DateFormatter = make("MM月dd日 EEE", locale: "zh_CN")
    static let dayShort: DateFormatter = make("MM/dd")
    static let clockShort: DateFormatter = make("HH:mm")
    static let dateTime: DateFormatter = make("MM/dd HH:mm", locale: "zh_CN")
    static let dateTimeFull: DateFormatter = make("MM/dd HH:mm:ss", locale: "zh_CN")

    private static func make(_ format: String, locale: String? = nil) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        if let locale = locale { f.locale = Locale(identifier: locale) }
        return f
    }
}

// MARK: - 智能解析返回结果

struct NIOSmartParseResult {
    var mode: String?              // "url" | "widget"
    var vehicleURL: String?
    var vehicleToken: String?
    var userToken: String?
    var vehicleId: String?
    var deviceId: String?
    var sign: String?
    var signSecret: String?
    var signAlgo: String?
    var timestamp: String?
    var changeURL: String?
    var changeToken: String?
    var checkinURL: String?
    var checkinToken: String?
    // 防多端登录设备指纹（sniff.sh / Shadowrocket 抓包捕获）
    var appVer: String?
    var userAgent: String?
    var userGuid: String?
    var notes: [String] = []
}

enum NIOVehicleLib {

    static let widgetBaseURL = "https://app.nio.com/app/api/icar/v2/widget/info"

    // MARK: - GPS 校验

    static func isValidGPS(lat: Double, lng: Double) -> Bool {
        guard lat.isFinite, lng.isFinite else { return false }
        return !(abs(lat) < 0.01 && abs(lng) < 0.01)
    }

    // MARK: - MD5 签名计算

    static func md5(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sortedQuery(_ params: [String: String]) -> String {
        params.keys.sorted().map { key in
            "\(key)=\(params[key] ?? "")"
        }.joined(separator: "&")
    }

    static func computeWidgetSign(params: [String: String], secret: String, algo: String = "md5_append") -> String {
        let base = sortedQuery(params)
        switch algo {
        case "md5_prepend":
            return md5(secret + base)
        case "md5_append_key":
            return md5("\(base)&key=\(secret)")
        case "md5_append":
            fallthrough
        default:
            return md5(base + secret)
        }
    }

    /// 蔚来 Android 客户端真实签名算法（HttpUtils.d + CryptoUtils.z 逆向，抓包双样本实测）：
    /// sign = md5_hex( METHOD + path + "?" + sorted("k=v"&...) + appSecret + Authorization完整头值 )
    /// 空值参数与 sig/sign 前缀参数不参与；Authorization 为请求实际发送的完整头值（如 "Bearer 2.0..."），
    /// 无鉴权头的接口（如离线包上报）该段为空串。
    static func computeAndroidSign(
        method: String,
        path: String,
        params: [String: String],
        secret: String,
        authorization: String?
    ) -> String {
        let canonical = params
            .filter { !$0.value.isEmpty }
            .filter { !$0.key.lowercased().hasPrefix("sig") }
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "&")
        let auth = authorization ?? ""
        return md5("\(method)\(path)?\(canonical)\(secret)\(auth)")
    }

    // MARK: - 动态 Widget URL 构建

    static func buildWidgetURL(
        vehicleId: String,
        deviceId: String,
        secret: String?,
        algo: String = "md5_append",
        fixedSign: String? = nil,
        fixedTimestamp: String? = nil,
        appVer: String = "6.5.3",
        region: String = "cn",
        lang: String = "zh-CN",
        appId: String = "10002",
        functions: String = "rvs_run_frequent_appointment,rvs_set_defender_mode,rvs_rpa_out,rvs_exe_findme",
        size: String = "medium",
        authorization: String? = nil
    ) -> (url: URL, timestamp: String, sign: String)? {
        guard !vehicleId.isEmpty, !deviceId.isEmpty else { return nil }

        var params: [String: String] = [
            "region": region,
            "app_id": appId,
            "lang": lang,
            "vehicle_id": vehicleId,
            "app_ver": appVer,
            "device_id": deviceId,
            "widget_functions": functions,
            "widget_size": size
        ]

        let currentTs = fixedTimestamp?.isEmpty == false ? fixedTimestamp! : String(Int(Date().timeIntervalSince1970))
        params["timestamp"] = currentTs

        let signValue: String
        if let sec = secret, !sec.isEmpty {
            // md5_full（Android/iOS 通用逆向算法）需要 METHOD+path 与 Authorization 完整头值；
            // 实测（iOS 6.5.3 抓包三重验证）：widget/info 用 app_id=10001 + vehicle_token 命中。
            if algo == "md5_full" {
                signValue = computeAndroidSign(
                    method: "GET",
                    path: "/app/api/icar/v2/widget/info",
                    params: params,
                    secret: sec,
                    authorization: authorization
                )
            } else {
                signValue = computeWidgetSign(params: params, secret: sec, algo: algo)
            }
        } else if let fs = fixedSign, !fs.isEmpty {
            signValue = fs
        } else {
            return nil
        }
        params["sign"] = signValue

        var components = URLComponents(string: widgetBaseURL)
        components?.queryItems = params.keys.sorted().map { URLQueryItem(name: $0, value: params[$0]) }
        guard let url = components?.url else { return nil }
        return (url, currentTs, signValue)
    }

    // MARK: - 智能 URL / cURL 解析器

    static func smartParseInput(_ input: String) -> NIOSmartParseResult {
        var res = NIOSmartParseResult()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return res }

        // 供模糊扫描（URL/Token 正则）的文本：JSON 载荷会剔除抓包样本字段，
        // 避免 command_samples / poseidon_samples 里的车控/扫码 URL 与 token 被误填进凭证
        var scanText = trimmed

        // 0. 支持直接粘贴 auto_sniff 生成的 JSON 格式
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            if let data = trimmed.data(using: .utf8),
               var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let mode = json["mode"] as? String, !mode.isEmpty { res.mode = mode }
                if let vUrl = json["vehicle_url"] as? String, !vUrl.isEmpty { res.vehicleURL = vUrl }
                if let wUrl = json["widget_url"] as? String, !wUrl.isEmpty {
                    if res.mode == "widget" || res.vehicleURL == nil {
                        res.vehicleURL = wUrl
                    }
                }
                if let vTok = json["vehicle_token"] as? String, !vTok.isEmpty {
                    res.vehicleToken = vTok.replacingOccurrences(of: "Bearer ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let uTok = json["user_token"] as? String, !uTok.isEmpty {
                    res.userToken = uTok.replacingOccurrences(of: "Bearer ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let vId = json["vehicle_id"] as? String, !vId.isEmpty { res.vehicleId = vId }
                if let dId = json["device_id"] as? String, !dId.isEmpty { res.deviceId = dId }
                if let s = json["sign"] as? String, !s.isEmpty { res.sign = s }
                if let sSec = (json["sign_secret"] as? String) ?? (json["secret"] as? String), !sSec.isEmpty { res.signSecret = sSec }
                if let sAlgo = (json["sign_algo"] as? String) ?? (json["algo"] as? String), !sAlgo.isEmpty { res.signAlgo = sAlgo }
                if let ts = json["timestamp"] as? String, !ts.isEmpty { res.timestamp = ts }
                if let cUrl = json["change_url"] as? String, !cUrl.isEmpty { res.changeURL = cUrl }
                if let cTok = json["change_token"] as? String, !cTok.isEmpty {
                    res.changeToken = cTok.replacingOccurrences(of: "Bearer ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let kUrl = json["checkin_url"] as? String, !kUrl.isEmpty { res.checkinURL = kUrl }
                if let kTok = json["checkin_token"] as? String, !kTok.isEmpty {
                    res.checkinToken = kTok.replacingOccurrences(of: "Bearer ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // 设备指纹三件套（数组伪 token 走 as? String 自然失败，天然免疫）
                if let av = json["app_ver"] as? String, !av.isEmpty { res.appVer = av }
                if let ua = json["user_agent"] as? String, !ua.isEmpty { res.userAgent = ua }
                if let ug = json["user_guid"] as? String, !ug.isEmpty { res.userGuid = ug }

                // 过滤抓包样本：剔除车控/扫码链路样本与非凭证杂项后重新序列化，
                // 让后续模糊扫描只看凭证字段，样本里的 URL/token 不会污染填充
                let noiseKeys = ["command_samples", "poseidon_samples", "source", "sniffed_at"]
                let removed = noiseKeys.filter { json[$0] != nil }
                if !removed.isEmpty {
                    for key in removed { json.removeValue(forKey: key) }
                    if let cleanedData = try? JSONSerialization.data(withJSONObject: json),
                       let cleanedText = String(data: cleanedData, encoding: .utf8) {
                        scanText = cleanedText
                        res.notes.append("已过滤抓包样本字段（\(removed.joined(separator: "/"))），不影响凭证填充")
                    }
                }
            }
        }

        // 1. 尝试抽取 Authorization Bearer Token (支持 base64 中的 +, /, =)
        if res.vehicleToken == nil || res.vehicleToken?.isEmpty == true {
            if let match = scanText.range(of: #"(?:Bearer\s+|Authorization:\s*Bearer\s*|\"vehicle_token\":\s*\"(?:Bearer\s*)?)([A-Za-z0-9\-_./+=]+)"#, options: .regularExpression) {
                let tokenSubstring = scanText[match]
                let cleanToken = tokenSubstring
                    .replacingOccurrences(of: "Authorization:", with: "")
                    .replacingOccurrences(of: "Bearer", with: "")
                    .replacingOccurrences(of: "\"vehicle_token\":", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanToken.isEmpty {
                    res.vehicleToken = cleanToken
                    res.notes.append("已自动提取 Bearer Token")
                }
            }
        }

        // 2. 检查是否为完整 URL / cURL
        let urlStrings = scanText.components(separatedBy: .whitespacesAndNewlines).filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
        for rawUrl in urlStrings {
            let initialUrl = rawUrl.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,;"))
            guard let components = URLComponents(string: initialUrl) else { continue }
            let path = components.path.lowercased()
            let host = components.host?.lowercased() ?? ""

            // 无论任何接口，尝试从路径中抽取 /vehicle/{vid}/status
            if res.vehicleId == nil || res.vehicleId?.isEmpty == true {
                if components.path.contains("/vehicle/") {
                    let parts = components.path.components(separatedBy: "/vehicle/")
                    if parts.count > 1 {
                        let candidate = parts[1].components(separatedBy: "/")[0]
                        if !candidate.isEmpty {
                            res.vehicleId = candidate
                        }
                    }
                }
            }

            // 从 queryItems 中抽取 device_id, vehicle_id, sign, timestamp
            if let items = components.queryItems {
                for item in items {
                    switch item.name.lowercased() {
                    case "vehicle_id", "vehicleid", "vid":
                        if res.vehicleId == nil || res.vehicleId?.isEmpty == true {
                            res.vehicleId = item.value
                        }
                    case "device_id", "deviceid", "did":
                        if res.deviceId == nil || res.deviceId?.isEmpty == true {
                            res.deviceId = item.value
                        }
                    case "sign":
                        if res.sign == nil || res.sign?.isEmpty == true {
                            res.sign = item.value
                        }
                    case "timestamp", "ts":
                        if res.timestamp == nil || res.timestamp?.isEmpty == true {
                            res.timestamp = item.value
                        }
                    default: break
                    }
                }
            }

            var normalizedComponents = components
            // 自动修复抓包抓到直连 IP (如 101.42.114.130) 导致的 HTTPS TLS 证书域名不匹配问题
            if !host.contains("nio.com") {
                if path.contains("rvs") || path.contains("status") {
                    normalizedComponents.host = "icar.nio.com"
                    normalizedComponents.scheme = "https"
                } else if path.contains("widget") || path.contains("charge") || path.contains("checkin") || path.contains("order") {
                    normalizedComponents.host = "app.nio.com"
                    normalizedComponents.scheme = "https"
                }
            }
            let cleanUrl = normalizedComponents.url?.absoluteString ?? rawUrl.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,;"))
            if path.contains("widget") || (host.contains("app.nio.com") && !path.contains("status")) {
                res.vehicleURL = cleanUrl
                if res.mode == nil { res.mode = "widget" }
                res.notes.append("识别到车辆 Widget 模式接口，已提取 vehicle_id 与 device_id")
            } else if path.contains("rvs/vehicle") || path.contains("status") || host.contains("icar.nio.com") {
                res.vehicleURL = cleanUrl
                if res.mode == nil { res.mode = "url" }
                res.notes.append("识别到车辆 RVS 直连接口，已提取 Vehicle ID 与 Device ID")
            } else if path.contains("gettaborder") || path.contains("serviceorder") || path.contains("service-order") {
                var cUrl = cleanUrl
                if cUrl.contains("app.nio.com/app/api/service_charge") {
                    cUrl = "https://gateway-front-external.nio.com/moat/1100367/api/v1/otd/car/ext/general/serviceOrder/getTabOrder?offset=0&limit=200&orderTypes=pe_shaman,pe_shaman_change,service_pe_discharge,battery_flexible_upgrade,nsom_so_maintenance,nsom_so_chauffeur,chauffeur_vehicle_delivery,so_case_accident&hash_type=sha256&lang=zh&region=US&tz_offset=28800&app_ver=6.5.3"
                }
                res.changeURL = cUrl
                res.notes.append("识别到换电 / 服务订单接口")
            } else if path.contains("award/square") || path.contains("checkin") {
                var ckUrl = cleanUrl
                if ckUrl.contains("app.nio.com/app/api/users/checkin") {
                    ckUrl = "https://gateway-front-external.nio.com/moat/10086//n/c/award/square?event=checkin&collection_id=1843940587332317185"
                }
                res.checkinURL = ckUrl
                res.notes.append("识别到签到接口")
            }
        }

        // 3. 纯 Token 粘贴容错
        if res.vehicleURL == nil && res.changeURL == nil && res.checkinURL == nil {
            if scanText.hasPrefix("eyJ") || scanText.count > 40 {
                let token = scanText.replacingOccurrences(of: "Bearer ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                res.vehicleToken = token
                res.notes.append("识别为纯 Token 文本")
            }
        }

        return res
    }

    /// 从 URL 字符串中提取指定 Query 参数（纯文本匹配，避免 URLComponents 重新编解码破坏签名）
    static func extractQueryParam(from urlString: String, key: String) -> String? {
        guard let queryStart = urlString.firstIndex(of: "?") else { return nil }
        let queryString = String(urlString[urlString.index(after: queryStart)...])
        let pairs = queryString.split(separator: "&")
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count >= 2, parts[0] == key {
                return String(parts[1])
            }
        }
        return nil
    }

    /// RVS 重签自校验档位缓存：host+path → (secret, 算法名, 原始顺序, auth 参与)。
    /// 仅在主线程读写（buildRvsTargetURLs 调用链）。
    private static var rvsSignProfiles: [String: (secret: String, name: String, raw: Bool, auth: Bool)] = [:]

    // MARK: - 逆向内置常量（Android 客户端 6.9.6 堆挖 + CryptoUtils.z 反编译实测）

    /// Android 客户端签名密钥（app_id=10001）。服务端按请求 app_id 参数选择对应 secret 验签；
    /// 该值静态存储于服务端与客户端，永不过期。
    /// 安全策略：真实密钥不进 git 仓库——本地构建从 Bundle 的 NIO_Secrets.plist（已 gitignore）读取；
    /// 仓库构建返回空串，需在设置页「签名密钥」手动填入（UserDefaults 持久化，与手动录入一致）。
    static let builtinSignSecret: String = {
        guard let url = Bundle.main.url(forResource: "NIO_Secrets", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any],
              let sec = dict["sign_secret"] as? String else { return "" }
        return sec
    }()
    /// Android 客户端 app_id（与 builtinSignSecret 配对）
    static let androidAppID = "10001"
    /// iOS 客户端 app_id（独立 secret，未知；抓包到 10002 时需转换为 Android 身份）
    static let iOSAppID = "10002"

    // MARK: - 车控指令（iOS 6.5.3 包逆向：REST 异步命令通道 + PIN 服务密码）

    /// 车控 REST 命令基座（iOS 包 strings 逆向：POST /api/1/vehicle/command/{function} → command_id → 轮询）
    static let commandBaseURL = "https://tsp.nio.com/api/1/vehicle/command/"
    /// 服务密码（PIN）验证端点（iOS 包 strings 逆向）
    static let verifyPinURL = "https://tsp.nio.com/api/1/poseidon/verify_pin"
    /// PIN 加密公钥（iOS 包 strings 逆向，SPKI PEM；App 内 encrypt(pinCode:) 用 RSA/PKCS1 加密后提交）
    static let pinRSAPublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MIIBIDANBgkqhkiG9w0BAQEFAAOCAQ0AMIIBCAKCAQEAqSIG46xubZbe766XQeYM
    qivtL61CerAhW05LTd3jAxliYUej+SHSyOY2soHszqfC3FHAPe7H1N0MrXPE3w08
    DNodFc2GWolnECA3gRHOu2ILcsYnviwO9XO6DpQmpRWojiXpBlF5ysmXG4EHFaJ1
    8TzQOzew3zWixAY/bef5BJU5L+KOhK5yO16JCgUIvhw+cykF7/mXjMujMWiara6M
    azHuS642QLd93DzdrvAU8doF0DOX5ZOSuE/tkl3FXTBjZ4DkMCL22iJivHK9nrdB
    uHizxMp32zCVJIpDF4cF79PBEjTGml6IvM/ftqty96edoBCCHGDZUETA/8bZCS2E
    EwIBAw==
    -----END PUBLIC KEY-----
    """

    /// 车控指令元数据（UI 展示 + 敏感级标记）
    struct CommandEntry {
        let function: String
        let title: String
        let icon: String
        let sensitive: Bool
    }

    /// 车控指令全集（iOS 包 rvs 指令名逆向）
    static let vehicleCommandEntries: [CommandEntry] = [
        CommandEntry(function: "rvs_set_doorlock", title: "锁车", icon: "lock.fill", sensitive: false),
        CommandEntry(function: "rvs_set_air_conditioner", title: "空调", icon: "fanblades.fill", sensitive: false),
        CommandEntry(function: "rvs_set_windows_sunroof", title: "车窗", icon: "square.split.2x1.fill", sensitive: true),
        CommandEntry(function: "rvs_set_tailgate", title: "尾门", icon: "car.rear.fill", sensitive: true),
        CommandEntry(function: "rvs_exe_findme", title: "寻车", icon: "light.beacon.max.fill", sensitive: false),
        CommandEntry(function: "rvs_set_chrg", title: "充电", icon: "bolt.fill", sensitive: true),
        CommandEntry(function: "rvs_set_lamp", title: "大灯", icon: "lightbulb.fill", sensitive: false),
        CommandEntry(function: "rvs_set_defender_mode", title: "守卫", icon: "shield.lefthalf.filled", sensitive: false),
        // 扩展指令集（iOS 包 strings 逆向二次挖掘）
        CommandEntry(function: "rvs_set_rearview_mirror", title: "后视镜", icon: "rectangle.landscape.rotate", sensitive: true),
        CommandEntry(function: "rvs_set_sunblind", title: "遮阳帘", icon: "blinds.horizontal.closed", sensitive: false),
        CommandEntry(function: "rvs_set_glove_box", title: "手套箱", icon: "shippingbox.fill", sensitive: true),
        CommandEntry(function: "rvs_seats_heating", title: "座椅加热", icon: "flame.fill", sensitive: false),
        CommandEntry(function: "rvs_set_btry_warm", title: "电池预热", icon: "battery.100.bolt", sensitive: false),
        CommandEntry(function: "rvs_set_poweroutlet", title: "对外放电", icon: "powerplug.fill", sensitive: true),
        CommandEntry(function: "rvs_set_engine_hood", title: "前舱盖", icon: "car.front.waves.up.fill", sensitive: true),
        CommandEntry(function: "rvs_set_immobilizer", title: "发动机禁用", icon: "engine.combustion.badge.exclamationmark", sensitive: true),
    ]

    /// 车控 POST body 参与签名的两种档位（逆向实测：POST 的 JSON body 必须参与签名，
    /// 未签 body 服务端返回 403 invalid sign；车控通道的具体并入手法无抓包样本，双档位重试覆盖）
    enum CommandSignMode {
        case mergedIntoQuery   // 档位A：body JSON 键值对（字符串化）并入 sorted query 参与签名
        case rawAppend         // 档位B：原始 JSON body 字符串整体拼在 query 串后参与签名
    }

    /// 构建车控 POST 命令请求（md5_full 签名；POST body 参与签名，档位由 signMode 指定）
    static func buildCommandRequest(
        function: String,
        vehicleId: String,
        deviceId: String,
        secret: String,
        authorization: String?,
        bodyJSON: String = "",
        extraQuery: [String: String] = [:],
        signMode: CommandSignMode = .mergedIntoQuery
    ) -> (url: URL, sign: String, timestamp: String)? {
        guard !vehicleId.isEmpty else { return nil }
        let path = "/api/1/vehicle/command/\(function)"
        var params: [String: String] = [
            "app_id": androidAppID,
            "app_ver": "6.5.3",
            "device_id": deviceId.isEmpty ? "iOS_Device_\(vehicleId.prefix(6))" : deviceId,
            "vehicle_id": vehicleId,
            "lang": "zh-CN",
            "region": "cn"
        ]
        for (k, v) in extraQuery { params[k] = v }
        let ts = String(Int(Date().timeIntervalSince1970))
        params["timestamp"] = ts

        // 档位A：把 body JSON 的键值对（转为字符串）并入待签名参数表
        if signMode == .mergedIntoQuery,
           let data = bodyJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in obj {
                let strVal: String
                switch v {
                case let s as String: strVal = s
                case let n as NSNumber: strVal = n.stringValue
                case let b as Bool: strVal = b ? "true" : "false"
                default: continue
                }
                if !strVal.isEmpty { params[k] = strVal }
            }
        }

        let sign = computeAndroidSign(method: "POST", path: path, params: params, secret: secret, authorization: authorization)
        params["sign"] = sign
        let canon = params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")

        // 档位B：原始 JSON body 整体拼进签名输入串（在 secret 之前）
        let finalSign: String
        if signMode == .rawAppend, !bodyJSON.isEmpty {
            finalSign = md5("POST\(path)?\(canon)\(bodyJSON)\(secret)\(authorization ?? "")")
        } else {
            finalSign = sign
        }
        if signMode == .rawAppend {
            params["sign"] = finalSign
        }

        guard let url = URL(string: "https://tsp.nio.com\(path)?\(canon)") else { return nil }
        return (url, signMode == .rawAppend ? finalSign : sign, ts)
    }

    /// 构建车控命令结果轮询 GET（同一签名体系）
    static func buildCommandPollRequest(
        commandID: String,
        vehicleId: String,
        deviceId: String,
        secret: String,
        authorization: String?
    ) -> URL? {
        let path = "/api/1/vehicle/command/\(commandID)"
        var params: [String: String] = [
            "app_id": androidAppID,
            "app_ver": "6.5.3",
            "device_id": deviceId.isEmpty ? "iOS_Device_\(vehicleId.prefix(6))" : deviceId,
            "vehicle_id": vehicleId,
            "lang": "zh-CN",
            "region": "cn",
            "timestamp": String(Int(Date().timeIntervalSince1970))
        ]
        let sign = computeAndroidSign(method: "GET", path: path, params: params, secret: secret, authorization: authorization)
        params["sign"] = sign
        let canon = params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return URL(string: "https://tsp.nio.com\(path)?\(canon)")
    }

    /// RSA/PKCS1 加密服务密码（iOS 包 encrypt(pinCode:) 逆向）：
    /// PEM(SPKI) → 内层 PKCS#1 RSAPublicKey DER → SecKey 加密 → base64。
    static func encryptPinCode(_ pin: String) -> String? {
        // 1. PEM → SPKI DER
        let b64 = pinRSAPublicKeyPEM
            .split(separator: "\n")
            .filter { !$0.contains("-----") }
            .joined()
        guard var der = Data(base64Encoded: b64) else { return nil }
        // 2. SPKI 剥壳：外层 SEQUENCE + AlgorithmIdentifier SEQUENCE + BIT STRING 头 → 内层 PKCS#1
        func tlv(_ data: Data, _ offset: inout Int) -> (tag: UInt8, content: Data)? {
            guard offset + 2 <= data.count else { return nil }
            let tag = data[data.startIndex + offset]; offset += 1
            var len = Int(data[data.startIndex + offset]); offset += 1
            if len & 0x80 != 0 {
                let n = len & 0x7F
                guard n <= 4, offset + n <= data.count else { return nil }
                len = 0
                for _ in 0..<n { len = (len << 8) | Int(data[data.startIndex + offset]); offset += 1 }
            }
            guard offset + len <= data.count else { return nil }
            let content = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + len))
            offset += len
            return (tag, content)
        }
        var off = 0
        guard let outer = tlv(der, &off), outer.tag == 0x30 else { return nil } // SubjectPublicKeyInfo SEQUENCE
        off = 0
        guard let alg = tlv(outer.content, &off), alg.tag == 0x30 else { return nil } // AlgorithmIdentifier
        guard let bits = tlv(outer.content, &off), bits.tag == 0x03, bits.content.count > 1 else { return nil } // BIT STRING
        // BIT STRING content: [unused-bit-count byte][PKCS#1 RSAPublicKey DER]
        let pkcs1 = bits.content.subdata(in: (bits.content.startIndex + 1)..<bits.content.endIndex)
        // 3. SecKey（PKCS#1 DER → SecKey）
        guard let key = SecKeyCreateWithData(pkcs1 as CFData,
                                             [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary,
                                             nil) else { return nil }
        // 4. RSA/PKCS1v1.5 加密
        var err: Unmanaged<CFError>?
        guard let enc = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(pin.utf8) as CFData, &err) as Data? else { return nil }
        return enc.base64EncodedString()
    }


    /// 对抓包的完整 RVS URL 动态重签名（与 Widget 模式同一套密钥体系）：
    /// 先用 secret/algo 对抓包参数（含原 timestamp、不含 sign）重算签名，与 URL 内 sign 比对自校验；
    /// 校验通过说明该密钥适用于 RVS 接口，随后每次拉取都换新 timestamp 并重算 sign——
    /// 既保留 field=tyre 等完整状态块参数（胎压不丢），又不会再因 sign/timestamp 过期而失效。
    /// 校验不通过（未配置密钥或算法/拼串方式不符）返回 nil，调用方回退为原样重放抓包 URL。
    static func autoResignRvsURL(_ urlString: String, secret: String, algo: String, authorization: String? = nil) -> String? {
        let sec = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sec.isEmpty, let qStart = urlString.firstIndex(of: "?") else { return nil }

        let base = String(urlString[..<qStart])
        let query = String(urlString[urlString.index(after: qStart)...])

        var pairs: [(key: String, value: String)] = []
        var capturedSign: String? = nil
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = kv.first else { continue }
            let key = String(first)
            let value = kv.count > 1 ? String(kv[1]) : ""
            if key == "sign" {
                capturedSign = value
            } else {
                pairs.append((key, value))
            }
        }
        guard let originSign = capturedSign?.lowercased(), !pairs.isEmpty else { return nil }

        // iOS 抓包（app_id=10002）自动伪装成 Android：iOS secret 未知、旧 sign 必然无法自校验，
        // 实测服务端先按请求 app_id 参数选 secret 验签、再验 token 会话——故直接切换 app_id=10001
        // 并强制 md5_full（Android 真实算法）重签，无需比对旧 sign。
        let isIOSCapture = pairs.contains { $0.key == "app_id" && $0.value == iOSAppID }
        if isIOSCapture, let idx = pairs.firstIndex(where: { $0.key == "app_id" }) {
            pairs[idx].value = androidAppID
        }
        let forceAndroidResign = isIOSCapture

        func canonicalSorted(_ list: [(key: String, value: String)]) -> String {
            list.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&")
        }
        // 服务端签名可能覆盖参数的抓包原始顺序（ha-nio 注释确认 field 顺序参与签名），因此同时尝试原始顺序拼串
        func canonicalRaw(_ list: [(key: String, value: String)]) -> String {
            list.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        }
        // md5_full（Android 客户端真实算法）需要 path 与 Authorization 完整头值参与
        let method = "GET"
        let path = base.replacingOccurrences(of: "^https?://[^/]+", with: "", options: .regularExpression)
        let authValue = authorization?.isEmpty == false ? authorization! : ""
        func compute(_ canonical: String, _ algoName: String, withAuth: Bool) -> String {
            switch algoName {
            case "md5_prepend": return md5(sec + canonical)
            case "md5_append_key": return md5("\(canonical)&key=\(sec)")
            case "md5_full": return md5("\(method)\(path)?\(canonical)\(sec)\(withAuth ? authValue : "")")
            default: return md5(canonical + sec)
            }
        }

        // md5_full 的签名含 Authorization 尾串，token 轮换后旧抓包 sign 无法复现——
        // 首次自校验通过后缓存该 host+path 的签名档（含所用 secret），后续直接复用重签。
        var verifiedName: String? = nil
        var verifiedRaw = false
        var verifiedAuth = false
        let profileKey = forceAndroidResign ? base + "#ios" : base
        if let cached = rvsSignProfiles[profileKey], cached.secret == sec {
            verifiedName = cached.name; verifiedRaw = cached.raw; verifiedAuth = cached.auth
        } else {
            rvsSignProfiles[profileKey] = nil
            if forceAndroidResign {
                verifiedName = "md5_full"
                verifiedRaw = false
                verifiedAuth = !authValue.isEmpty
            } else {
                let candidates = [algo, "md5_append", "md5_prepend", "md5_append_key", "md5_full"]
                var seen = Set<String>()
                outer: for a in candidates {
                    let name = a.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, seen.insert(name).inserted else { continue }
                    for withAuth in [true, false] {
                        if compute(canonicalSorted(pairs), name, withAuth: withAuth) == originSign {
                            verifiedName = name; verifiedRaw = false; verifiedAuth = withAuth
                            break outer
                        }
                        if compute(canonicalRaw(pairs), name, withAuth: withAuth) == originSign {
                            verifiedName = name; verifiedRaw = true; verifiedAuth = withAuth
                            break outer
                        }
                    }
                }
            }
            if let n = verifiedName {
                rvsSignProfiles[profileKey] = (secret: sec, name: n, raw: verifiedRaw, auth: verifiedAuth)
            }
        }
        guard let useName = verifiedName else { return nil }

        // 换新 timestamp 重算 sign；其余参数（field= 等）保持逐字节不变，避免重新编码破坏签名。
        // timestamp 位数沿用抓包原值（10 位秒级 / 13 位毫秒级），防止格式不一致被判过期。
        let now: String
        let originalTs = pairs.first(where: { $0.key == "timestamp" })?.value ?? ""
        if originalTs.count >= 13 {
            now = String(Int(Date().timeIntervalSince1970 * 1000))
        } else {
            now = String(Int(Date().timeIntervalSince1970))
        }
        var fresh = pairs
        if let idx = fresh.firstIndex(where: { $0.key == "timestamp" }) {
            fresh[idx].value = now
        } else {
            fresh.append(("timestamp", now))
        }
        let canonical = verifiedRaw ? canonicalRaw(fresh) : canonicalSorted(fresh)
        let newSign = compute(canonical, useName, withAuth: verifiedAuth)
        let newQuery = fresh.map { "\($0.key)=\($0.value)" }.joined(separator: "&") + "&sign=\(newSign)"
        return "\(base)?\(newQuery)"
    }

    /// 仅刷新 URL 中的 timestamp 参数为当前时间，其余参数与既有 sign 逐字节保留。
    /// 用于「服务端只校验时间戳新鲜度、不校验 sign 与 timestamp 绑定」的接口自愈重试
    /// （ha-nio 实证蔚来部分网关不验签）：若服务端同时校验绑定，该 URL 仍会被拒绝，
    /// 调用方回退为原样重放，无额外副作用。无 timestamp 参数时返回 nil。
    static func refreshTimestampParam(in urlString: String) -> String? {
        guard urlString.contains("timestamp=") else { return nil }
        // timestamp 位数沿用原值（10 位秒级 / 13 位毫秒级），防止格式不一致
        let isMillisecond = urlString.range(of: "timestamp=1[3-9]\\d{11}") != nil
        let now = isMillisecond ? String(Int(Date().timeIntervalSince1970 * 1000))
                                : String(Int(Date().timeIntervalSince1970))
        let replaced = urlString.replacingOccurrences(
            of: "timestamp=\\d+",
            with: "timestamp=\(now)",
            options: .regularExpression
        )
        return replaced == urlString ? nil : replaced
    }

    /// 车况"显著内容"指纹：两次拉取结果一致 ⟺ 指纹一致。
    /// 用于「数据无变化时不刷新主界面更新时间」与刷新横幅的 已更新/无更新 判定。
    /// 刻意排除 sample_time 等采样时间戳（车辆持续遥测采样，值恒变，会误判为更新），
    /// 位置取 3 位小数（≈110 m，吸收驻车 GPS 抖动），速度取整数（行驶中每轮都在变，属真实数据更新）。
    static func statusFingerprint(_ status: NIOVehicleStatus?) -> String {
        guard let s = status else { return "" }
        var parts: [String] = []

        let soc = s.socStatus
        parts.append(String(format: "%.1f/%.0f/%.0f/c%@/p%.1f/v%d/t%.0f",
                            soc?.soc ?? -1,
                            soc?.remainingRange ?? -1,
                            soc?.remainingActualRange ?? -1,
                            soc?.chargeState.map(String.init) ?? "-",
                            soc?.chargingPower ?? -1,
                            soc?.v2lStatus ?? -1,
                            soc?.targetSocPercentage ?? -1))

        let doors = s.doorStatus ?? [:]
        // 整车车锁（与看板同源：缺字段按未上锁 -1 记，避免默认 1 掩盖真实变化）
        parts.append("\(doors["vehicle_lock_status"]?.intValue ?? doors["lock_status"]?.intValue ?? doors["lock"]?.intValue ?? -1)")
        for key in ["door_ajar_front_left_status", "door_ajar_front_right_status",
                    "door_ajar_rear_left_status", "door_ajar_rear_right_status"] {
            parts.append("\(doors[key]?.intValue ?? -1)")
        }

        let win = s.windowStatus ?? [:]
        for key in ["win_posn_fl", "win_posn_fr", "win_posn_rl", "win_posn_rr", "sun_roof_posn",
                    "win_front_left_posn", "win_front_right_posn", "win_rear_left_posn", "win_rear_right_posn"] {
            parts.append("\(win[key]?.intValue ?? -1)")
        }

        let ext = s.exteriorStatus
        parts.append("\(ext?.vehicleState ?? -1)/\(String(format: "%.0f", ext?.mileage ?? -1))/\(String(format: "%.0f", ext?.speed ?? -1))")

        let pos = s.positionStatus
        parts.append(String(format: "%.3f/%.3f", pos?.latitude ?? -1, pos?.longitude ?? -1))

        parts.append(String(format: "%.1f/%.1f", s.hvacStatus?.temperature ?? -99, s.hvacStatus?.outsideTemperature ?? -99))

        let tyre = extractTyreInfo(from: s)
        parts.append(String(format: "%.1f/%.1f/%.1f/%.1f", tyre.fl.press ?? -1, tyre.fr.press ?? -1, tyre.rl.press ?? -1, tyre.rr.press ?? -1))

        parts.append(s.fotaStatus?.currentVersion ?? "-")

        let off = s.offcarModeStatus ?? [:]
        let offSig = [
            modeActive(off["defender_mode_status"] ?? off["defender_mode"]),
            modeActive(off["pet_mode_status"] ?? off["pet_mode"]),
            modeActive(off["camping_mode_status"] ?? off["camping_mode"] ?? off["camp_mode_status"]),
            modeActive(off["power_hold_mode_status"] ?? off["power_hold_mode"] ?? off["offcar_power_hold"])
        ].map { $0 ? "1" : "0" }.joined()
        parts.append(offSig)

        let lv = s.lvBattStatus ?? [:]
        parts.append(String(format: "%d/%.1f", lv["lv_batt_soc"]?.intValue ?? -1, lv["lv_batt_volt"]?.doubleValue ?? -1))

        let frdg = s.frdgStatus ?? [:]
        parts.append(String(format: "%d/%.1f", frdg["frdg_pwr_sts"]?.intValue ?? -1, (frdg["frdg_cur_t"]?.doubleValue ?? frdg["frdg_tar_t"]?.doubleValue ?? -99)))

        return parts.joined(separator: "|")
    }

    // MARK: - 路径测距与按天轨迹计算

    static func segmentMeters(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        let r = 6371000.0 // 地球半径（米）
        let toRad = { (d: Double) in d * .pi / 180.0 }
        let dLat = toRad(lat2 - lat1)
        let dLng = toRad(lng2 - lng1)
        let a = sin(dLat / 2.0) * sin(dLat / 2.0) +
                cos(toRad(lat1)) * cos(toRad(lat2)) * sin(dLng / 2.0) * sin(dLng / 2.0)
        return 2.0 * r * asin(min(1.0, sqrt(a)))
    }

    static func buildDailyPaths(history: [NIOVehicleSnapshot]) -> [NIODailyPath] {
        let validPoints = history.filter { $0.isValidGPS && $0.ts > 0 }
        guard !validPoints.isEmpty else { return [] }

        var byDay: [String: [NIOVehicleSnapshot]] = [:]
        let dayFmt = NIOFormatters.dayKey
        let labelFmt = NIOFormatters.dayLabel

        for snap in validPoints {
            let date = Date(timeIntervalSince1970: TimeInterval(snap.ts) / 1000.0)
            let key = dayFmt.string(from: date)
            byDay[key, default: []].append(snap)
        }

        var results: [NIODailyPath] = []
        for (dayKey, points) in byDay {
            let sorted = points.sorted { $0.ts < $1.ts }
            var distance = 0.0
            if sorted.count > 1 {
                for i in 0..<(sorted.count - 1) {
                    let m = segmentMeters(lat1: sorted[i].lat, lng1: sorted[i].lng, lat2: sorted[i+1].lat, lng2: sorted[i+1].lng)
                    if m > 10.0 { // 过滤微小漂移
                        distance += m
                    }
                }
            }
            let firstDate = Date(timeIntervalSince1970: TimeInterval(sorted.first?.ts ?? 0) / 1000.0)
            let label = labelFmt.string(from: firstDate)
            results.append(NIODailyPath(
                day: dayKey,
                label: label,
                points: sorted,
                distanceKm: distance / 1000.0,
                startTime: sorted.first?.ts ?? 0,
                endTime: sorted.last?.ts ?? 0
            ))
        }

        return results.sorted { $0.day > $1.day }
    }

    static func computeDailyMileageDeltas(history: [NIOVehicleSnapshot]) -> [NIODailyDelta] {
        let dayFmt = NIOFormatters.dayKey
        let labelFmt = NIOFormatters.dayShort

        var byDay: [String: [NIOVehicleSnapshot]] = [:]
        for snap in history where snap.mileage > 0 && snap.ts > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(snap.ts) / 1000.0)
            let key = dayFmt.string(from: date)
            byDay[key, default: []].append(snap)
        }

        var results: [NIODailyDelta] = []
        for (day, points) in byDay {
            let sorted = points.sorted { $0.ts < $1.ts }
            if let first = sorted.first, let last = sorted.last {
                let diff = max(0.0, last.mileage - first.mileage)
                let date = Date(timeIntervalSince1970: TimeInterval(first.ts) / 1000.0)
                results.append(NIODailyDelta(day: day, label: labelFmt.string(from: date), delta: diff))
            }
        }
        return results.sorted { $0.day < $1.day }
    }

    // MARK: - 标签与格式化函数

    static func vehicleStateLabel(_ state: Int) -> String {
        switch state {
        case 0: return "未知"
        case 1: return "行驶中"
        case 2: return "已驻车"
        case 3: return "充电中"
        case 4: return "换电中"
        default: return "状态\(state)"
        }
    }

    static func isRealCharging(socStatus: NIOSocStatus?, offcarStatus: [String: NIOJSONValue]?) -> Bool {
        // charge_state 缺失或滞后时，用充电功率兜底判定（部分数据源不含该字段，导致充电状态不显示）
        let chargeState = socStatus?.chargeState ?? 0
        let powerW = socStatus?.chargingPower ?? 0
        guard chargeState == 1 || (chargeState == 0 && powerW > 0) else { return false }

        // 露营模式排查：开启露营模式时，车辆维持座舱放电，非插枪充电
        if let offcar = offcarStatus {
            let camping = modeActive(offcar["camping_mode_status"] ?? offcar["camping_mode"])
            if camping { return false }

            let powerHold = modeActive(offcar["power_hold_mode_status"] ?? offcar["power_hold_mode"])
            if powerHold && (socStatus?.chargerType ?? 0) == 0 {
                return false
            }
        }

        // 对外放电（V2L）排查
        if let v2l = socStatus?.v2lStatus, v2l == 1 {
            return false
        }

        return true
    }

    static func smartChargeStateDescription(socStatus: NIOSocStatus?, offcarStatus: [String: NIOJSONValue]?) -> String {
        if let offcar = offcarStatus {
            let camping = modeActive(offcar["camping_mode_status"] ?? offcar["camping_mode"])
            if camping { return "露营模式 ⛺️" }

            let powerHold = modeActive(offcar["power_hold_mode_status"] ?? offcar["power_hold_mode"])
            if powerHold && (socStatus?.chargerType ?? 0) == 0 {
                return "离车不下电 🔋"
            }
        }

        if let v2l = socStatus?.v2lStatus, v2l == 1 {
            return "对外放电 ⚡️"
        }

        let state = socStatus?.chargeState ?? 0
        switch state {
        case 0: return "未充电"
        case 1: return "充电中 ⚡️"
        case 2: return "充电完成 🌸"
        case 3: return "充电故障 ⚠️"
        default: return "状态\(state)"
        }
    }

    static func chargeStateLabel(_ state: Int) -> String {
        switch state {
        case 0: return "未充电"
        case 1: return "充电中"
        case 2: return "充电完成"
        case 3: return "充电故障"
        default: return "状态\(state)"
        }
    }

    /// GCJ-02 火星坐标转 WGS-84（解决地图几百米偏差问题，移植自 ha-nio）
    static func gcj02ToWgs84(lat: Double, lng: Double) -> (lat: Double, lng: Double) {
        let pi = Double.pi
        let a = 6378245.0
        let ee = 0.00669342162296594323

        func transformLat(x: Double, y: Double) -> Double {
            var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
            ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
            ret += (20.0 * sin(y * pi) + 40.0 * sin(y / 3.0 * pi)) * 2.0 / 3.0
            ret += (160.0 * sin(y / 12.0 * pi) + 320.0 * sin(y * pi / 30.0)) * 2.0 / 3.0
            return ret
        }

        func transformLng(x: Double, y: Double) -> Double {
            var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
            ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
            ret += (20.0 * sin(x * pi) + 40.0 * sin(x / 3.0 * pi)) * 2.0 / 3.0
            ret += (150.0 * sin(x / 12.0 * pi) + 300.0 * sin(x / 30.0 * pi)) * 2.0 / 3.0
            return ret
        }

        var dLat = transformLat(x: lng - 105.0, y: lat - 35.0)
        var dLng = transformLng(x: lng - 105.0, y: lat - 35.0)
        let radLat = lat / 180.0 * pi
        var magic = sin(radLat)
        magic = 1.0 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1.0 - ee)) / (magic * sqrtMagic) * pi)
        dLng = (dLng * 180.0) / (a / sqrtMagic * cos(radLat) * pi)
        return (lat: lat - dLat, lng: lng - dLng)
    }

    /// 续航达成率推算（实际估算 / 标准续航，返回如 79.5 表示 79.5%）
    static func rangeAchievementRatio(actual: Double?, standard: Double?) -> Double? {
        guard let s = standard, s > 0 else { return nil }
        if let a = actual, a > 0 {
            return (a / s) * 100.0
        }
        // 当车机休眠未上报 actual 时，采用 CLTC 推算实估 (0.795)
        let estimated = Double(cltcToEstimatedRange(s))
        return (estimated / s) * 100.0
    }

    static func chargerTypeLabel(_ type: Int) -> String {
        switch type {
        case 1: return "交流慢充"
        case 2: return "直流快充"
        case 3: return "换电中"
        case 4: return "超充桩"
        default: return type > 0 ? "充电类型\(type)" : "未接入"
        }
    }

    static func windowPosLabel(_ val: Int) -> String {
        switch val {
        case 1: return "全关"
        case 2: return "微开"
        case 3: return "半开"
        case 4: return "全开"
        default: return val == 0 ? "全关" : "\(val)%"
        }
    }

    static func vehlModeLabel(_ val: Int) -> String {
        switch val {
        case 1: return "舒适"
        case 2: return "节能"
        case 3: return "运动"
        case 4: return "运动+"
        case 5: return "个性化"
        case 6: return "雪地"
        case 7: return "沙地"
        case 8: return "湿地"
        default: return "标准舒适"
        }
    }

    static func doorLabel(closed: Int) -> String {
        closed == 1 ? "关闭" : "开启"
    }

    static func heatLevelLabel(_ sts: Int) -> String {
        if sts <= 0 { return "关闭" }
        if sts == 1 { return "低" }
        if sts == 2 { return "中" }
        return "高"
    }

    struct TyreWheelInfo {
        var press: Double?
        var temp: Int?

        var displayPress: String {
            guard let p = press else { return "—" }
            if p > 50 {
                return String(format: "%.1f bar", p / 100.0)
            } else if p > 10 {
                return String(format: "%.1f bar", p / 10.0)
            } else {
                return String(format: "%.1f bar", p)
            }
        }

        var displayTemp: String {
            guard let t = temp else { return "" }
            return "\(t)℃"
        }
    }

    struct TyreStatusInfo {
        var fl: TyreWheelInfo = .init()
        var fr: TyreWheelInfo = .init()
        var rl: TyreWheelInfo = .init()
        var rr: TyreWheelInfo = .init()
        var hasData: Bool {
            fl.press != nil || fr.press != nil || rl.press != nil || rr.press != nil ||
            fl.temp != nil || fr.temp != nil || rl.temp != nil || rr.temp != nil
        }
    }

    static func extractTyreInfo(_ block: [String: NIOJSONValue]?) -> TyreStatusInfo {
        guard let b = block, !b.isEmpty else {
            return TyreStatusInfo()
        }
        func findDouble(_ keys: [String]) -> Double? {
            for k in keys {
                if let val = b[k] {
                    if let d = val.doubleValue, d > 0 {
                        if d > 50.0 { return d / 100.0 }
                        if d > 10.0 { return d / 10.0 }
                        return d
                    }
                }
                for (bk, bv) in b {
                    if bk.caseInsensitiveCompare(k) == .orderedSame || bk.lowercased().replacingOccurrences(of: "_", with: "") == k.lowercased().replacingOccurrences(of: "_", with: "") {
                        if let d = bv.doubleValue, d > 0 {
                            if d > 50.0 { return d / 100.0 }
                            if d > 10.0 { return d / 10.0 }
                            return d
                        }
                    }
                }
            }
            return nil
        }
        func findInt(_ keys: [String]) -> Int? {
            for k in keys {
                if let val = b[k], let i = val.intValue {
                    return i
                }
                for (bk, bv) in b {
                    if bk.caseInsensitiveCompare(k) == .orderedSame || bk.lowercased().replacingOccurrences(of: "_", with: "") == k.lowercased().replacingOccurrences(of: "_", with: "") {
                        if let i = bv.intValue {
                            return i
                        }
                    }
                }
            }
            return nil
        }

        let flPress = findDouble([
            "front_left_wheel_press_bar", "front_left_wheel_press", "front_left_tire_pressure", "front_left_tire_press",
            "fl_pressure_bar", "fl_pressure", "fl_tyre_press", "fl_tire_press", "fl_wheel_press", "fl_press",
            "press_fl", "pressure_fl", "realtime_tyre_press_frnt_le", "realtime_tire_press_frnt_le", "realtime_tyre_press_fl",
            "tyre_press_fl", "tire_press_fl", "tyre_pressure_front_left", "tire_pressure_front_left", "front_left_press",
            "fl_tpms_press", "tpms_fl_press", "tpms_front_left_press", "tyre_press_front_left"
        ])
        let flTemp = findInt([
            "front_left_wheel_temp", "front_left_tire_temperature", "front_left_tire_temp", "front_left_temp",
            "fl_temp", "temp_fl", "fl_tyre_temp", "fl_tire_temp", "fl_wheel_temp",
            "realtime_tyre_temp_frnt_le", "realtime_tire_temp_frnt_le", "realtime_tyre_temp_fl",
            "tyre_temp_fl", "tire_temp_fl", "tyre_temperature_front_left", "tire_temperature_front_left",
            "fl_tpms_temp", "tpms_fl_temp"
        ])

        let frPress = findDouble([
            "front_right_wheel_press_bar", "front_right_wheel_press", "front_right_tire_pressure", "front_right_tire_press",
            "fr_pressure_bar", "fr_pressure", "fr_tyre_press", "fr_tire_press", "fr_wheel_press", "fr_press",
            "press_fr", "pressure_fr", "realtime_tyre_press_frnt_ri", "realtime_tire_press_frnt_ri", "realtime_tyre_press_fr",
            "tyre_press_fr", "tire_press_fr", "tyre_pressure_front_right", "tire_pressure_front_right", "front_right_press",
            "fr_tpms_press", "tpms_fr_press", "tpms_front_right_press", "tyre_press_front_right"
        ])
        let frTemp = findInt([
            "front_right_wheel_temp", "front_right_tire_temperature", "front_right_tire_temp", "front_right_temp",
            "fr_temp", "temp_fr", "fr_tyre_temp", "fr_tire_temp", "fr_wheel_temp",
            "realtime_tyre_temp_frnt_ri", "realtime_tire_temp_frnt_ri", "realtime_tyre_temp_fr",
            "tyre_temp_fr", "tire_temp_fr", "tyre_temperature_front_right", "tire_temperature_front_right",
            "fr_tpms_temp", "tpms_fr_temp"
        ])

        let rlPress = findDouble([
            "rear_left_wheel_press_bar", "rear_left_wheel_press", "rear_left_tire_pressure", "rear_left_tire_press",
            "rl_pressure_bar", "rl_pressure", "rl_tyre_press", "rl_tire_press", "rl_wheel_press", "rl_press",
            "press_rl", "pressure_rl", "realtime_tyre_press_re_le", "realtime_tire_press_re_le", "realtime_tyre_press_rl",
            "tyre_press_rl", "tire_press_rl", "tyre_pressure_rear_left", "tire_pressure_rear_left", "rear_left_press",
            "rl_tpms_press", "tpms_rl_press", "tpms_rear_left_press", "tyre_press_rear_left"
        ])
        let rlTemp = findInt([
            "rear_left_wheel_temp", "rear_left_tire_temperature", "rear_left_tire_temp", "rear_left_temp",
            "rl_temp", "temp_rl", "rl_tyre_temp", "rl_tire_temp", "rl_wheel_temp",
            "realtime_tyre_temp_re_le", "realtime_tire_temp_re_le", "realtime_tyre_temp_rl",
            "tyre_temp_rl", "tire_temp_rl", "tyre_temperature_rear_left", "tire_temperature_rear_left",
            "rl_tpms_temp", "tpms_rl_temp"
        ])

        let rrPress = findDouble([
            "rear_right_wheel_press_bar", "rear_right_wheel_press", "rear_right_tire_pressure", "rear_right_tire_press",
            "rr_pressure_bar", "rr_pressure", "rr_tyre_press", "rr_tire_press", "rr_wheel_press", "rr_press",
            "press_rr", "pressure_rr", "realtime_tyre_press_re_ri", "realtime_tire_press_re_ri", "realtime_tyre_press_rr",
            "tyre_press_rr", "tire_press_rr", "tyre_pressure_rear_right", "tire_pressure_rear_right", "rear_right_press",
            "rr_tpms_press", "tpms_rr_press", "tpms_rear_right_press", "tyre_press_rear_right"
        ])
        let rrTemp = findInt([
            "rear_right_wheel_temp", "rear_right_tire_temperature", "rear_right_tire_temp", "rear_right_temp",
            "rr_temp", "temp_rr", "rr_tyre_temp", "rr_tire_temp", "rr_wheel_temp",
            "realtime_tyre_temp_re_ri", "realtime_tire_temp_re_ri", "realtime_tyre_temp_rr",
            "tyre_temp_rr", "tire_temp_rr", "tyre_temperature_rear_right", "tire_temperature_rear_right",
            "rr_tpms_temp", "tpms_rr_temp"
        ])

        return TyreStatusInfo(
            fl: TyreWheelInfo(press: flPress, temp: flTemp),
            fr: TyreWheelInfo(press: frPress, temp: frTemp),
            rl: TyreWheelInfo(press: rlPress, temp: rlTemp),
            rr: TyreWheelInfo(press: rrPress, temp: rrTemp)
        )
    }

    static func extractTyreInfo(from status: NIOVehicleStatus?) -> TyreStatusInfo {
        if let s = status {
            let direct = extractTyreInfo(s.tyreStatus)
            if direct.hasData { return direct }

            if let maint = s.maintainStatus, let encoded = try? JSONEncoder().encode(maint), let dict = try? JSONDecoder().decode([String: NIOJSONValue].self, from: encoded) {
                let fromMaint = extractTyreInfo(dict)
                if fromMaint.hasData { return fromMaint }
            }
        }

        // 默认标准胎压预览（防止空展示）
        return TyreStatusInfo(
            fl: TyreWheelInfo(press: 2.5, temp: 25),
            fr: TyreWheelInfo(press: 2.5, temp: 25),
            rl: TyreWheelInfo(press: 2.5, temp: 25),
            rr: TyreWheelInfo(press: 2.5, temp: 25)
        )
    }

    struct FotaDisplayInfo {
        let osName: String
        let shortVer: String
        let fullDisplay: String
        let rawVersion: String
    }

    static func parseFotaInfo(version: String?, model: String? = nil) -> FotaDisplayInfo {
        let raw = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty {
            return FotaDisplayInfo(osName: "", shortVer: "", fullDisplay: "待抓取", rawVersion: "")
        }

        var verNum = ""

        // 1. 如果包含 * 分隔（如 20240815*Banyan 2.6.5*2.6.5），从各段中优先匹配纯数字版本号
        if raw.contains("*") {
            let parts = raw.components(separatedBy: "*")
            for part in parts.reversed() {
                if let match = part.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) {
                    verNum = String(part[match])
                    break
                }
            }
        }

        // 2. 正则提取标准版本号 (如 2.6.5, 3.0.0, 1.2.0)
        if verNum.isEmpty {
            let pattern = #"\d+(\.\d+)+"#
            if let match = raw.range(of: pattern, options: .regularExpression) {
                verNum = String(raw[match])
            }
        }

        // 3. 提取整数版本 (如 v2, 3)
        if verNum.isEmpty {
            let intPattern = #"(?:v|ver|version|V)?\s*(\d{1,2})\b"#
            if let match = raw.range(of: intPattern, options: .regularExpression) {
                verNum = String(raw[match])
            }
        }

        if verNum.isEmpty {
            verNum = raw
        }

        return FotaDisplayInfo(osName: "", shortVer: verNum, fullDisplay: verNum, rawVersion: raw)
    }

    static func shortFotaVersion(_ version: String?) -> String {
        return parseFotaInfo(version: version).shortVer
    }

    /// 一键唤起已安装的蔚来官方 App (若未安装则自动跳转 App Store 蔚来官方国区页面 id1116095987)
    static func openNIOApp() {
        #if os(iOS)
        let candidateSchemes = [
            "weilai://",
            "nio://",
            "do1://",
            "nioapp://",
            "weilaiapp://"
        ]
        for scheme in candidateSchemes {
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return
            }
        }
        if let defaultUrl = URL(string: "weilai://") {
            UIApplication.shared.open(defaultUrl, options: [:]) { success in
                if !success {
                    if let appStoreUrl = URL(string: "itms-apps://apps.apple.com/app/id1116095987") {
                        UIApplication.shared.open(appStoreUrl, options: [:], completionHandler: nil)
                    }
                }
            }
        }
        #elseif os(macOS)
        if let url = URL(string: "weilai://") {
            NSWorkspace.shared.open(url)
        } else if let appStoreUrl = URL(string: "https://apps.apple.com/cn/app/%E8%94%9A%E6%9D%A5/id1116095987") {
            NSWorkspace.shared.open(appStoreUrl)
        }
        #endif
    }

    static func defenderModeActive(_ offcar: [String: NIOJSONValue]?) -> (isActive: Bool, warnCount: Int) {
        guard let o = offcar else { return (false, 0) }
        let warnCount = o["defender_mode_warn_count"]?.intValue ?? 0
        if let mode = o["defender_mode"]?.intValue {
            return (mode >= 2, warnCount)
        }
        if let status = o["defender_mode_status"]?.intValue {
            return (status >= 2, warnCount)
        }
        if let b = o["defender_mode"]?.boolValue ?? o["defender_mode_status"]?.boolValue {
            return (b, warnCount)
        }
        return (false, warnCount)
    }

    static func modeActive(_ value: NIOJSONValue?, activeValue: Int = 1) -> Bool {
        guard let v = value else { return false }
        if let i = v.intValue { return i >= activeValue }
        if let b = v.boolValue { return b }
        return false
    }

    static func modeActive(_ value: Int?, activeValue: Int = 1) -> Bool {
        guard let v = value else { return false }
        return v >= activeValue
    }

    static func formatVehicleId(_ id: String?) -> String {
        guard let id = id, !id.isEmpty else { return "—" }
        if id.count <= 9 { return id }
        let start = id.prefix(4)
        let end = id.suffix(5)
        return "\(start)…\(end)"
    }

    static func fullChargeRangeKm(remainingRange: Double, soc: Double) -> Int? {
        guard soc > 0, soc.isFinite, remainingRange.isFinite else { return nil }
        return (remainingRange / soc * 100).rounded().safeInt
    }

    /// 将 CLTC 工况续航估算为实际可用续航（实估）
    /// 蔚来实测换算系数约 0.795（740km CLTC ≈ 588km 实估）
    /// 若 API 直接返回 remaining_actual_range，优先使用真实值；本函数用于无实估数据时的推算
    static func cltcToEstimatedRange(_ cltcKm: Double, factor: Double = 0.795) -> Int {
        return (cltcKm * factor).rounded().safeInt ?? 0
    }

    /// 获取最佳可用续航：优先实估，无实估则用 CLTC 推算
    static func bestRange(cltcKm: Double?, actualKm: Double?) -> (km: Int, isEstimated: Bool)? {
        if let act = actualKm, act > 0, let km = act.rounded().safeInt {
            return (km, false)
        }
        if let cltc = cltcKm, cltc > 0 {
            return (cltcToEstimatedRange(cltc), true)
        }
        return nil
    }

    static func batteryPackLabel(fullRangeKm: Int) -> String {
        // fullRangeKm 是基于 remaining_range（CLTC 工况续航）倒推的满电 CLTC 续航
        // 蔚来各电池包 CLTC 满电续航实测区间：
        // 75kWh ≈ 500~599km CLTC / 100kWh ≈ 600~849km CLTC / 150kWh ≈ 850km+
        switch fullRangeKm {
        case ..<500:
            return "（数据估算中）"
        case 500..<600:
            return "（75度电池）"
        case 600..<850:
            return "（100度电池）"
        case 850...:
            return "（150度电池）"
        default:
            return ""
        }
    }

    static func mapsUrl(lat: Double, lng: Double) -> String {
        "https://www.openstreetmap.org/?mlat=\(lat)&mlon=\(lng)#map=16/\(lat)/\(lng)"
    }

    static func fmtTime(_ ms: Int) -> String {
        guard ms > 0 else { return "—" }
        return NIOFormatters.dateTime.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    static func fmtClock(_ ms: Int) -> String {
        guard ms > 0 else { return "—" }
        return NIOFormatters.clockShort.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    static func fmtDay(_ ms: Int) -> String {
        guard ms > 0 else { return "—" }
        return NIOFormatters.dayShort.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    static func chargeRemainingTimeText(estimateEndTimeMs: Int?) -> String? {
        guard let ms = estimateEndTimeMs, ms > 0 else { return nil }
        let end = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let diff = end.timeIntervalSinceNow
        if diff <= 0 {
            return "即将充满 ✨"
        }
        let totalMinutes = Int(ceil(diff / 60.0))
        if totalMinutes < 60 {
            return "预计还需 \(totalMinutes) 分钟"
        } else {
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            return mins > 0 ? "预计还需 \(hours)小时\(mins)分" : "预计还需 \(hours)小时"
        }
    }

    // MARK: - 快照提取

    static func snapshotFromResponse(_ resp: NIOVehicleResponse) throws -> NIOVehicleSnapshot {
        guard let status = extractVehicleStatus(resp) else {
            throw NIOError.missingStatus
        }
        let lat = status.positionStatus?.latitude ?? 0
        let lng = status.positionStatus?.longitude ?? 0
        let posTs = status.positionStatus?.sampleTime ?? 0
        let socTs = status.socStatus?.sampleTime ?? 0
        let hasPos = isValidGPS(lat: lat, lng: lng)
        let ts = (hasPos && posTs > 0) ? posTs : (socTs > 0 ? socTs : Int(Date().timeIntervalSince1970 * 1000))
        return NIOVehicleSnapshot(
            ts: ts,
            soc: status.socStatus?.soc ?? 0,
            range: status.socStatus?.remainingRange ?? 0,
            actualRange: status.socStatus?.remainingActualRange ?? 0,
            mileage: status.exteriorStatus?.mileage ?? 0,
            lat: lat,
            lng: lng,
            insideTemp: status.hvacStatus?.temperature ?? 0,
            outsideTemp: status.hvacStatus?.outsideTemperature ?? 0
        )
    }

    static func extractVehicleStatus(_ resp: NIOVehicleResponse) -> NIOVehicleStatus? {
        guard let data = resp.data, let status = data.status else { return nil }
        if hasMinimalStatus(status) { return status }
        return nil
    }

    static func hasMinimalStatus(_ s: NIOVehicleStatus) -> Bool {
        return s.socStatus != nil || s.exteriorStatus != nil || s.positionStatus != nil
    }

    // MARK: - 车门与部件动态解析（仅展示车辆实际返回存在的传感器部件，防止出现不存在的内容）

    struct ParsedDoorItem: Identifiable, Hashable {
        let id: String
        let title: String
        let isClosed: Bool
        let customClosedLabel: String
        let customOpenLabel: String
        let icon: String
    }

    /// - Parameter isCharging: 充电中时充电口盖开启属正常插枪状态，不判为告警
    static func parseAvailableDoors(doorStatus: [String: NIOJSONValue]?, windowStatus: [String: NIOJSONValue]?, isCharging: Bool = false) -> [ParsedDoorItem] {
        let doors = doorStatus ?? [:]
        var items: [ParsedDoorItem] = []

        // 1. 左前门
        let fl = doors["door_ajar_front_left_status"]?.intValue ?? doors["front_left_door_ajar_status"]?.intValue ?? doors["door_ajr_sts_fl"]?.intValue ?? doors["door_fl"]?.intValue ?? 1
        items.append(ParsedDoorItem(id: "door_fl", title: "左前门", isClosed: fl == 1, customClosedLabel: "关好 🐾", customOpenLabel: "未关好 ⚠️", icon: fl == 1 ? "car.side.fill" : "car.side.front.open.fill"))

        // 2. 前机盖 / 机舱盖 (蔚来 ET5 等车型为机舱盖，官方仪表显示为前机盖)
        let hood = doors["engine_hood_ajar_status"]?.intValue ?? doors["engine_hood_sts"]?.intValue ?? doors["hood"]?.intValue ?? 1
        items.append(ParsedDoorItem(id: "hood", title: "前机盖", isClosed: hood == 1, customClosedLabel: "关好 🔒", customOpenLabel: "未关好 ⚠️", icon: hood == 1 ? "car.side.fill" : "car.side.front.open.fill"))

        // 3. 右前门
        let fr = doors["door_ajar_front_right_status"]?.intValue ?? doors["front_right_door_ajar_status"]?.intValue ?? doors["door_ajr_sts_fr"]?.intValue ?? doors["door_fr"]?.intValue ?? 1
        items.append(ParsedDoorItem(id: "door_fr", title: "右前门", isClosed: fr == 1, customClosedLabel: "关好 🐾", customOpenLabel: "未关好 ⚠️", icon: fr == 1 ? "car.side.fill" : "car.side.front.open.fill"))

        // 4. 左后门
        let rl = doors["door_ajar_rear_left_status"]?.intValue ?? doors["rear_left_door_ajar_status"]?.intValue ?? doors["door_ajr_sts_rl"]?.intValue ?? doors["door_rl"]?.intValue ?? 1
        items.append(ParsedDoorItem(id: "door_rl", title: "左后门", isClosed: rl == 1, customClosedLabel: "关好 🐾", customOpenLabel: "未关好 ⚠️", icon: rl == 1 ? "car.side.fill" : "car.side.rear.open.fill"))

        // 5. 后尾门 / 后备箱
        let trunk = doors["tailgate_ajar_status"]?.intValue ?? doors["tailgate_sts"]?.intValue ?? doors["trunk"]?.intValue ?? 1
        items.append(ParsedDoorItem(id: "trunk", title: "后备箱", isClosed: trunk == 1, customClosedLabel: "关好 🔒", customOpenLabel: "未关好 ⚠️", icon: trunk == 1 ? "car.side.fill" : "car.side.rear.open.fill"))

        // 6. 右后门
        let rr = doors["door_ajar_rear_right_status"]?.intValue ?? doors["rear_right_door_ajar_status"]?.intValue ?? doors["door_ajr_sts_rr"]?.intValue ?? doors["door_rr"]?.intValue ?? 1
        items.append(ParsedDoorItem(id: "door_rr", title: "右后门", isClosed: rr == 1, customClosedLabel: "关好 🐾", customOpenLabel: "未关好 ⚠️", icon: rr == 1 ? "car.side.fill" : "car.side.rear.open.fill"))

        // 7. 充电口盖 (如果存在字段)；充电插枪时口盖开启是正常状态，按正常显示
        if let chrg = doors["second_charge_port_ajar_status"]?.intValue ?? doors["second_charge_port_cap"]?.intValue ?? doors["charge_port_status"]?.intValue ?? doors["charge_port"]?.intValue {
            let portNormal = chrg == 1 || isCharging
            items.append(ParsedDoorItem(id: "charge_port", title: "充电口盖", isClosed: portNormal, customClosedLabel: isCharging && chrg != 1 ? "充电中 🔌" : "闭好 🐾", customOpenLabel: "开启 ⚠️", icon: portNormal ? "powerplug.fill" : "bolt.badge.automatic.fill"))
        }

        // 8. 整车车锁
        let lock = doors["vehicle_lock_status"]?.intValue ?? doors["lock_status"]?.intValue ?? doors["lock"]?.intValue ?? 1
        items.append(ParsedDoorItem(id: "vehicle_lock", title: "整车车锁", isClosed: lock == 1, customClosedLabel: "雪豹守护 🐆", customOpenLabel: "未上锁 🔓", icon: lock == 1 ? "lock.shield.fill" : "lock.open.fill"))

        // 9. 车窗天窗 (仅当 windowStatus 存在或默认解析)
        let win = windowStatus ?? [:]
        let winFL = win["win_front_left_posn"]?.intValue ?? win["win_posn_fl"]?.intValue ?? 0
        let winFR = win["win_front_right_posn"]?.intValue ?? win["win_posn_fr"]?.intValue ?? 0
        let winRL = win["win_rear_left_posn"]?.intValue ?? win["win_posn_rl"]?.intValue ?? 0
        let winRR = win["win_rear_right_posn"]?.intValue ?? win["win_posn_rr"]?.intValue ?? 0
        let sunRoof = win["sun_roof_posn"]?.intValue ?? 0
        let anyOpen = winFL > 0 || winFR > 0 || winRL > 0 || winRR > 0 || sunRoof > 0
        items.append(ParsedDoorItem(id: "windows", title: "车窗天窗", isClosed: !anyOpen, customClosedLabel: "海獭抱紧 🦦", customOpenLabel: "开启中 ⚠️", icon: !anyOpen ? "square.split.2x2.fill" : "square.split.2x2"))

        return items
    }
}

// MARK: - RVS 归一化器

enum RVSRormalizer {

    /// 将 RVS 平铺响应归一化为 data.status 结构
    static func normalize(_ raw: [String: Any]) -> [String: Any] {
        guard let data = raw["data"] as? [String: Any] else { return raw }

        var status: [String: Any] = [:]
        if let existing = data["status"] as? [String: Any] {
            status = existing
        }

        let fieldMap: [(from: String, to: String)] = [
            ("soc", "soc_status"),
            ("position", "position_status"),
            ("exterior", "exterior_status"),
            ("hvac", "hvac_status"),
            ("door", "door_status"),
            ("window", "window_status"),
            ("connection", "connection_status"),
            ("heating", "heating_status"),
            ("maintain", "maintain_status"),
            ("fota", "fota_status"),
            ("offcar_mode_status", "offcar_mode_status"),
            ("tyre", "tyre_status"),
            ("tire", "tyre_status"),
            ("tyres", "tyre_status"),
            ("tires", "tyre_status"),
            ("tire_status", "tyre_status"),
            ("lv_batt", "lv_batt_status"),
            ("device_status", "device_status"),
            ("charge_status_order", "charge_status_order"),
            ("light", "light_status"),
            ("key", "key_status"),
            ("special", "special_status"),
            ("trip_share", "trip_share_status"),
            ("remote_operate", "remote_operate_status"),
            ("offcar_power_swap", "offcar_power_swap_status"),
            ("box", "box_status"),
            ("frdg", "frdg_status"),
        ]

        for (from, to) in fieldMap {
            if let v = data[from] as? [String: Any], status[to] == nil {
                status[to] = v
            }
            if let v = data[to] as? [String: Any], status[to] == nil {
                status[to] = v
            }
        }

        let directKeys = [
            "light_status", "key_status", "special_status", "trip_share_status",
            "nearby_car_ctrl", "power_swap_order", "remote_operate_status",
            "offcar_power_swap_status", "box_status", "frdg_status",
            "mix_auth_status", "tyre_status", "tire_status", "window_status",
            "maintain_status", "lv_batt_status", "device_status",
            "charge_status_order",
        ]
        for key in directKeys {
            if let v = data[key] as? [String: Any], status[key] == nil {
                status[key] = v
            }
        }

        // 内部别名归一化（如 status["tire_status"] 或 status["tyre"] 映射到 status["tyre_status"]）
        if status["tyre_status"] == nil {
            for alt in ["tire_status", "tyre", "tire", "tyres", "tires", "tyre_pressure", "tire_pressure", "tpms_status", "tyre_press_status"] {
                if let v = status[alt] as? [String: Any] {
                    status["tyre_status"] = v
                    break
                }
            }
        }

        // 如果 tyre_status 依然为空，收集扁平 tyre / tire 键或 maintain_status 中的胎压数据
        if status["tyre_status"] == nil {
            var extractedTyres: [String: Any] = [:]
            for (k, v) in status {
                let lk = k.lowercased()
                if lk.contains("tyre") || lk.contains("tire") || lk.contains("wheel_press") || lk.contains("wheel_temp") || lk.contains("press_bar") || lk.contains("press_fl") || lk.contains("press_fr") || lk.contains("press_rl") || lk.contains("press_rr") {
                    extractedTyres[k] = v
                }
            }
            if let maint = status["maintain_status"] as? [String: Any] {
                for (k, v) in maint {
                    let lk = k.lowercased()
                    if lk.contains("tyre") || lk.contains("tire") || lk.contains("wheel_press") || lk.contains("wheel_temp") || lk.contains("press_bar") || lk.contains("press_fl") || lk.contains("press_fr") || lk.contains("press_rl") || lk.contains("press_rr") {
                        extractedTyres[k] = v
                    }
                }
            }
            if let ext = status["exterior_status"] as? [String: Any] {
                for (k, v) in ext {
                    let lk = k.lowercased()
                    if lk.contains("tyre") || lk.contains("tire") || lk.contains("wheel_press") || lk.contains("wheel_temp") || lk.contains("press_bar") {
                        extractedTyres[k] = v
                    }
                }
            }
            if !extractedTyres.isEmpty {
                status["tyre_status"] = extractedTyres
            }
        }

        if let vid = data["vehicle_id"] as? String, !vid.isEmpty, status["vehicle_id"] == nil {
            status["vehicle_id"] = vid
        }

        guard !status.isEmpty else { return raw }

        var result = raw
        var newData = data
        newData["status"] = status
        result["data"] = newData
        return result
    }
}

// MARK: - 错误

enum NIOError: LocalizedError {
    case missingStatus
    case emptyResponse
    case htmlResponse
    case invalidJSON
    case httpError(Int, String)
    case configError(String)
    case unauthorized403(String)

    var errorDescription: String? {
        switch self {
        case .missingStatus: return "车辆数据缺少 data.status"
        case .emptyResponse: return "API 返回空内容"
        case .htmlResponse: return "API 返回 HTML 而非 JSON，请检查 Authorization / sign / timestamp"
        case .invalidJSON: return "API 不是合法 JSON"
        case .httpError(let code, let text): return "API \(code): \(text)"
        case .configError(let msg): return msg
        case .unauthorized403(let msg): return "HTTP 403 鉴权失败：\(msg)"
        }
    }
}

// MARK: - 蔚来全系车型与官方配色库（移植自 ha-nio 官方渲染图库）

public struct NIOCarColor: Identifiable, Hashable {
    public var id: String { slug }
    public let slug: String
    public let name: String
    public let fileName: String

    public init(slug: String, name: String, fileName: String) {
        self.slug = slug
        self.name = name
        self.fileName = fileName
    }
}

public struct NIOCarModel: Identifiable, Hashable {
    public var id: String { slug }
    public let slug: String
    public let name: String
    public let defaultColorSlug: String
    public let colors: [NIOCarColor]

    public init(slug: String, name: String, defaultColorSlug: String, colors: [NIOCarColor]) {
        self.slug = slug
        self.name = name
        self.defaultColorSlug = defaultColorSlug
        self.colors = colors
    }
}

public enum NIOVehicleModelLib {

    /// 蔚来官方 9 大车型与全配色库
    public static let models: [NIOCarModel] = [
        NIOCarModel(
            slug: "et5",
            name: "ET5",
            defaultColorSlug: "cloud_dawn_yellow",
            colors: [
                NIOCarColor(slug: "cloud_dawn_yellow", name: "云初黄", fileName: "et5_cloud_dawn_yellow.webp"),
                NIOCarColor(slug: "mirror_pink", name: "镜空粉", fileName: "et5_mirror_pink.webp"),
                NIOCarColor(slug: "far_sky_purple", name: "远空紫", fileName: "et5_far_sky_purple.webp"),
                NIOCarColor(slug: "stratosphere_blue", name: "同温层蓝", fileName: "et5_stratosphere_blue.webp"),
                NIOCarColor(slug: "cloud_white", name: "云白", fileName: "et5_cloud_white.webp"),
                NIOCarColor(slug: "star_gray", name: "星灰", fileName: "et5_star_gray.webp"),
                NIOCarColor(slug: "deep_black", name: "深空黑", fileName: "et5_deep_black.webp"),
                NIOCarColor(slug: "moon_silver", name: "月辉银", fileName: "et5_moon_silver.webp")
            ]
        ),
        NIOCarModel(
            slug: "et5t",
            name: "ET5 Touring",
            defaultColorSlug: "cloud_dawn_yellow",
            colors: [
                NIOCarColor(slug: "cloud_dawn_yellow", name: "云初黄", fileName: "et5t_cloud_dawn_yellow.webp"),
                NIOCarColor(slug: "sunlight_gold", name: "日光金", fileName: "et5t_sunlight_gold.webp"),
                NIOCarColor(slug: "mirror_pink", name: "镜空粉", fileName: "et5t_mirror_pink.webp"),
                NIOCarColor(slug: "stratosphere_blue", name: "同温层蓝", fileName: "et5t_stratosphere_blue.webp"),
                NIOCarColor(slug: "cloud_white", name: "云白", fileName: "et5t_cloud_white.webp"),
                NIOCarColor(slug: "star_gray", name: "星灰", fileName: "et5t_star_gray.webp"),
                NIOCarColor(slug: "deep_black", name: "深空黑", fileName: "et5t_deep_black.webp"),
                NIOCarColor(slug: "moon_silver", name: "月辉银", fileName: "et5t_moon_silver.webp")
            ]
        ),
        NIOCarModel(
            slug: "es6",
            name: "ES6",
            defaultColorSlug: "stratosphere_blue",
            colors: [
                NIOCarColor(slug: "stratosphere_blue", name: "同温层蓝", fileName: "es6_stratosphere_blue.webp"),
                NIOCarColor(slug: "galaxy_purple", name: "银河紫", fileName: "es6_galaxy_purple.webp"),
                NIOCarColor(slug: "southern_star_blue", name: "南极星蓝", fileName: "es6_southern_star_blue.webp"),
                NIOCarColor(slug: "dawn_gold", name: "曙光金", fileName: "es6_dawn_gold.webp"),
                NIOCarColor(slug: "cloud_white", name: "云白", fileName: "es6_cloud_white.webp"),
                NIOCarColor(slug: "star_gray", name: "星灰", fileName: "es6_star_gray.webp"),
                NIOCarColor(slug: "deep_black", name: "深空黑", fileName: "es6_deep_black.webp"),
                NIOCarColor(slug: "moon_silver", name: "月辉银", fileName: "es6_moon_silver.webp")
            ]
        ),
        NIOCarModel(
            slug: "ec6",
            name: "EC6",
            defaultColorSlug: "mirage_purple",
            colors: [
                NIOCarColor(slug: "mirage_purple", name: "灵境紫", fileName: "ec6_mirage_purple.webp"),
                NIOCarColor(slug: "radiant_silver", name: "辉银", fileName: "ec6_radiant_silver.webp"),
                NIOCarColor(slug: "southern_star_blue", name: "南极星蓝", fileName: "ec6_southern_star_blue.webp"),
                NIOCarColor(slug: "stratosphere_blue", name: "同温层蓝", fileName: "ec6_stratosphere_blue.webp"),
                NIOCarColor(slug: "dawn_gold", name: "曙光金", fileName: "ec6_dawn_gold.webp"),
                NIOCarColor(slug: "cloud_white", name: "云白", fileName: "ec6_cloud_white.webp"),
                NIOCarColor(slug: "star_gray", name: "星灰", fileName: "ec6_star_gray.webp"),
                NIOCarColor(slug: "deep_black", name: "深空黑", fileName: "ec6_deep_black.webp")
            ]
        ),
        NIOCarModel(
            slug: "es8",
            name: "ES8",
            defaultColorSlug: "southern_star_blue",
            colors: [
                NIOCarColor(slug: "southern_star_blue", name: "南极星蓝", fileName: "es8_southern_star_blue.webp"),
                NIOCarColor(slug: "star_ripple_gray", name: "星澜灰", fileName: "es8_star_ripple_gray.webp"),
                NIOCarColor(slug: "dawn_gold", name: "曙光金", fileName: "es8_dawn_gold.webp"),
                NIOCarColor(slug: "cloud_white", name: "云白", fileName: "es8_cloud_white.webp"),
                NIOCarColor(slug: "polar_night_black", name: "极夜黑", fileName: "es8_polar_night_black.webp"),
                NIOCarColor(slug: "moon_silver", name: "月辉银", fileName: "es8_moon_silver.webp"),
                NIOCarColor(slug: "nebula_red", name: "星云红", fileName: "es8_nebula_red.webp")
            ]
        ),
        NIOCarModel(
            slug: "et7",
            name: "ET7",
            defaultColorSlug: "southern_star_blue",
            colors: [
                NIOCarColor(slug: "southern_star_blue", name: "南极星蓝", fileName: "et7_southern_star_blue.webp"),
                NIOCarColor(slug: "aurora_green", name: "极光绿", fileName: "et7_aurora_green.webp"),
                NIOCarColor(slug: "dawn_gold", name: "曙光金", fileName: "et7_dawn_gold.webp"),
                NIOCarColor(slug: "cloud_white", name: "云白", fileName: "et7_cloud_white.webp"),
                NIOCarColor(slug: "star_gray", name: "星灰", fileName: "et7_star_gray.webp"),
                NIOCarColor(slug: "deep_black", name: "深空黑", fileName: "et7_deep_black.webp"),
                NIOCarColor(slug: "moon_silver", name: "月辉银", fileName: "et7_moon_silver.webp")
            ]
        ),
        NIOCarModel(
            slug: "ec7",
            name: "EC7",
            defaultColorSlug: "nebula_red",
            colors: [
                NIOCarColor(slug: "nebula_red", name: "星云红", fileName: "ec7_nebula_red.webp"),
                NIOCarColor(slug: "southern_star_blue", name: "南极星蓝", fileName: "ec7_southern_star_blue.webp"),
                NIOCarColor(slug: "stratosphere_blue", name: "同温层蓝", fileName: "ec7_stratosphere_blue.webp"),
                NIOCarColor(slug: "dawn_gold", name: "曙光金", fileName: "ec7_dawn_gold.webp"),
                NIOCarColor(slug: "cloud_white", name: "云白", fileName: "ec7_cloud_white.webp"),
                NIOCarColor(slug: "star_gray", name: "星灰", fileName: "ec7_star_gray.webp"),
                NIOCarColor(slug: "deep_black", name: "深空黑", fileName: "ec7_deep_black.webp")
            ]
        ),
        NIOCarModel(
            slug: "es7",
            name: "ES7",
            defaultColorSlug: "stratosphere_blue",
            colors: [
                NIOCarColor(slug: "stratosphere_blue", name: "同温层蓝", fileName: "es7_stratosphere_blue.webp"),
                NIOCarColor(slug: "southern_star_blue", name: "南极星蓝", fileName: "es7_southern_star_blue.webp"),
                NIOCarColor(slug: "dawn_gold", name: "曙光金", fileName: "es7_dawn_gold.webp"),
                NIOCarColor(slug: "cloud_white", name: "云白", fileName: "es7_cloud_white.webp"),
                NIOCarColor(slug: "star_gray", name: "星灰", fileName: "es7_star_gray.webp"),
                NIOCarColor(slug: "deep_black", name: "深空黑", fileName: "es7_deep_black.webp"),
                NIOCarColor(slug: "moon_silver", name: "月辉银", fileName: "es7_moon_silver.webp")
            ]
        ),
        NIOCarModel(
            slug: "et9",
            name: "ET9",
            defaultColorSlug: "deep_black",
            colors: [
                NIOCarColor(slug: "deep_black", name: "深空黑", fileName: "et9_deep_black.webp"),
                NIOCarColor(slug: "cloud_white", name: "云白", fileName: "et9_cloud_white.webp"),
                NIOCarColor(slug: "morning_gold", name: "晨金", fileName: "et9_morning_gold.webp"),
                NIOCarColor(slug: "moon_silver", name: "月辉银", fileName: "et9_moon_silver.webp")
            ]
        )
    ]

    public static func findModel(by slug: String) -> NIOCarModel? {
        models.first { $0.slug.lowercased() == slug.lowercased() }
    }

    public static func loadCarImage(named name: String) -> UIImage? {
        #if canImport(UIKit)
        if let direct = UIImage(named: name) {
            return direct
        }
        let baseName = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.isEmpty ? "webp" : (name as NSString).pathExtension
        if let path = Bundle.main.path(forResource: baseName, ofType: ext, inDirectory: "Cars") ?? Bundle.main.path(forResource: baseName, ofType: ext) {
            return UIImage(contentsOfFile: path)
        }
        return nil
        #else
        return nil
        #endif
    }
}

// MARK: - Color Hex 扩展

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 255, 255, 255)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }
}

// MARK: - 主题系统 v2（二次元 / 简洁 / 酷 · 支持浅色与深色）
// 主题令牌本体定义在 WheaterAttributes.swift（App 与 Widget 共享）。

public enum AnimeThemeCategory: String, CaseIterable, Sendable, Identifiable {
    case anime  // 二次元
    case clean  // 简洁
    case cool   // 酷

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anime: return "二次元"
        case .clean: return "简洁"
        case .cool:  return "酷"
        }
    }

    public var categoryIcon: String {
        switch self {
        case .anime: return "heart.fill"
        case .clean: return "square.grid.2x2"
        case .cool:  return "bolt.horizontal.fill"
        }
    }
}

public enum AnimeThemeStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    // 二次元
    case kawaiiLight  // 蜜桃兔兔 · 浅色（默认，参考 YumikoToys 浅藕荷粉紫）
    case kawaii       // 樱夜粉兔 · 深色
    case healing      // 抹茶奶盖 · 浅色
    // 简洁
    case minimalLight // 云石膏 · 浅色
    case minimalDark  // 曜石灰 · 深色
    // 酷
    case cyber        // 赛博霓虹 · 深色
    case makoto       // 暮光星野 · 深色

    public var id: String { rawValue }

    public var category: AnimeThemeCategory {
        switch self {
        case .kawaiiLight, .kawaii, .healing: return .anime
        case .minimalLight, .minimalDark:     return .clean
        case .cyber, .makoto:                 return .cool
        }
    }

    public var displayName: String {
        switch self {
        case .kawaiiLight:  return "蜜桃兔兔"
        case .kawaii:       return "樱夜粉兔"
        case .healing:      return "抹茶奶盖"
        case .minimalLight: return "云石膏"
        case .minimalDark:  return "曜石灰"
        case .cyber:        return "赛博霓虹"
        case .makoto:       return "暮光星野"
        }
    }

    public var themeIcon: String {
        switch self {
        case .kawaiiLight:  return "carrot.fill"
        case .kawaii:       return "moon.stars.fill"
        case .healing:      return "leaf.fill"
        case .minimalLight: return "sun.max.fill"
        case .minimalDark:  return "circle.lefthalf.filled"
        case .cyber:        return "cpu.fill"
        case .makoto:       return "cloud.sun.fill"
        }
    }

    public var description: String {
        switch self {
        case .kawaiiLight:  return "浅藕荷粉紫 · 白卡奶霜，兔可可的午后小屋"
        case .kawaii:       return "草莓樱夜 · 粉紫辉光，甜而不腻的梦幻夜"
        case .healing:      return "抹茶奶盖 · 晨光草绿，日系治愈的清新感"
        case .minimalLight: return "云石膏白 · 单点靛蓝，克制干净的极简风"
        case .minimalDark:  return "曜石炭黑 · 一抹冰蓝，专注纯粹的暗色极简"
        case .cyber:        return "电光青 × 品红 · 深空霓虹赛博机能"
        case .makoto:       return "暮蓝 × 落日玫瑰 · 新海诚式电影光影"
        }
    }

    /// 主题选择卡片上的双色预览
    public var previewColors: (start: String, end: String) {
        let token = AnimeThemeToken.preset(named: rawValue)
        return (token.gradientStart, token.gradientEnd)
    }

    public var token: AnimeThemeToken {
        AnimeThemeToken.preset(named: rawValue)
    }
}

@MainActor
public final class AnimeThemeService: ObservableObject {
    public static let shared = AnimeThemeService()

    @Published public var currentStyle: AnimeThemeStyle = .kawaiiLight

    private init() {
        let saved = UserDefaults.standard.string(forKey: "nio_app_anime_theme") ?? AnimeThemeStyle.kawaiiLight.rawValue
        self.currentStyle = AnimeThemeStyle(rawValue: saved) ?? .kawaiiLight
    }

    public func setStyle(_ style: AnimeThemeStyle) {
        withAnimation(.easeInOut(duration: 0.28)) {
            self.currentStyle = style
        }
        UserDefaults.standard.set(style.rawValue, forKey: "nio_app_anime_theme")
        // 异步后台同步灵动岛 / 锁屏实时活动主题换装，杜绝主线程卡顿
        Task.detached(priority: .background) {
            await MainActor.run {
                NIOService.shared.updateLiveActivity(force: true)
            }
        }
    }

    public var currentToken: AnimeThemeToken {
        currentStyle.token
    }

    public func backgroundPrimary() -> Color { Color(hex: currentToken.backgroundPrimary) }
    public func backgroundSecondary() -> Color { Color(hex: currentToken.backgroundSecondary) }
    public func accentColor() -> Color { Color(hex: currentToken.accentColor) }
    public func glowColor() -> Color { Color(hex: currentToken.glowColor) }
    public func warmAccentColor() -> Color { Color(hex: currentToken.warmAccent) }
    public func gradient() -> [Color] { [Color(hex: currentToken.gradientStart), Color(hex: currentToken.gradientEnd)] }
    public func cardBackground() -> Color { Color(hex: currentToken.cardBackground) }
    public func cardBorder() -> Color { Color(hex: currentToken.cardBorder) }
    public func textPrimary() -> Color { Color(hex: currentToken.textPrimary) }
    public func textSecondary() -> Color { Color(hex: currentToken.textSecondary) }
}

// MARK: - 语义色画笔（视图层按主题深浅自动切换玻璃拟态）
// 视图内不再硬编码 Color.white / Color.black，统一经由此处取色，
// 浅色主题（蜜桃兔兔 / 抹茶奶盖 / 云石膏）下自动映射为墨色文字与白卡。

@MainActor
public enum NIOThemePaint {
    public static var token: AnimeThemeToken { AnimeThemeService.shared.currentToken }
    public static var isDark: Bool { token.isDark }

    // ── 主题令牌直取（视图层禁止再写 Color(hex: token.xxx)，统一走这里）──

    /// 页面主背景
    public static var background: Color { Color(hex: token.backgroundPrimary) }
    /// 页面次背景 / 侧栏染底
    public static var backgroundSoft: Color { Color(hex: token.backgroundSecondary) }
    /// 主题强调色（图标、按钮、高亮）
    public static var accent: Color { Color(hex: token.accentColor) }
    /// 主题辉光色（阴影、光晕、图表辅色）
    public static var glow: Color { Color(hex: token.glowColor) }
    /// 暖点缀色
    public static var warm: Color { Color(hex: token.warmAccent) }
    /// 渐变起点
    public static var gradientStart: Color { Color(hex: token.gradientStart) }
    /// 渐变终点
    public static var gradientEnd: Color { Color(hex: token.gradientEnd) }

    /// 主题强调渐变（进度条 / 标题条 / 图表统一走这套）
    public static var accentGradient: LinearGradient {
        LinearGradient(colors: [gradientStart, gradientEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 正文主色
    public static var text: Color { Color(hex: token.textPrimary) }
    /// 正文弱化色
    public static var textSoft: Color { Color(hex: token.textSecondary) }

    /// 卡片 / 徽章的弱填充（深色: white 6% / 浅色: white 90%）
    public static var fill: Color { isDark ? Color.white.opacity(0.06) : Color.white.opacity(0.88) }
    /// 顶部导航胶囊等小件的柔和填充（深色: white 8% / 浅色: 主题次背景色，避免纯白过曝）
    public static var chipFill: Color { isDark ? Color.white.opacity(0.08) : Color(hex: token.backgroundSecondary) }
    /// 更强一档的填充（深色: white 14% / 浅色: white）
    public static var fillStrong: Color { isDark ? Color.white.opacity(0.14) : Color.white }
    /// 描边 / 分隔线（深色: white 12% / 浅色: black 8%）
    public static var stroke: Color { isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08) }
    /// 输入框 / 代码井（深色: black 25% / 浅色: 主题色调底，可辨识的内凹输入区）
    public static var well: Color { isDark ? Color.black.opacity(0.25) : Color(hex: token.backgroundSecondary) }
    /// 底部状态条 / 深底横条（深色: black 35% / 浅色: black 5%）
    public static var bar: Color { isDark ? Color.black.opacity(0.35) : Color.black.opacity(0.05) }
    /// 强调色按钮上的文字（始终白色，保证饱和底上的对比度）
    public static var onAccent: Color { .white }
}

// MARK: - 能耗达成率与百公里电耗评分 (range_achievement_rate)

enum NIOEfficiencyLib {
    struct EfficiencyScore {
        var achievementRate: Double      // 达成率 (e.g. 85.2%)
        var grade: String                // "S" / "A" / "B" / "C"
        var title: String                // "黄金脚法 · 超强续航"
        var subtitle: String             // "电耗控制极佳，超越90%车主"
        var icon: String                 // "crown.fill"
        var estimatedKwhPer100Km: Double // 推算百公里电耗 e.g. 15.6 kWh/100km
    }

    static func computeScore(nominalRange: Double?, actualRange: Double?, batteryCapacityKwh: Double = 75.0) -> EfficiencyScore? {
        guard let nominal = nominalRange, nominal > 0 else { return nil }
        let act = (actualRange != nil && actualRange! > 0) ? actualRange! : Double(NIOVehicleLib.cltcToEstimatedRange(nominal))
        let rate = min(150.0, max(10.0, (act / nominal) * 100.0))
        let kwh100 = round((16.5 / (rate / 100.0)) * 10.0) / 10.0

        if rate >= 90.0 {
            return EfficiencyScore(
                achievementRate: rate,
                grade: "S 级",
                title: "黄金脚法 · 超强续航 ✨",
                subtitle: "百公里电耗极低，动能回收与匀速巡航大师",
                icon: "crown.fill",
                estimatedKwhPer100Km: kwh100
            )
        } else if rate >= 80.0 {
            return EfficiencyScore(
                achievementRate: rate,
                grade: "A 级",
                title: "节能先锋 · 高效巡航 🍃",
                subtitle: "日常驾驶平顺，电能利用效率优异",
                icon: "leaf.fill",
                estimatedKwhPer100Km: kwh100
            )
        } else if rate >= 70.0 {
            return EfficiencyScore(
                achievementRate: rate,
                grade: "B 级",
                title: "从容自若 · 标准表现 🚗",
                subtitle: "兼顾舒适与电耗，符合城市综合工况",
                icon: "car.fill",
                estimatedKwhPer100Km: kwh100
            )
        } else {
            return EfficiencyScore(
                achievementRate: rate,
                grade: "C 级",
                title: "澎湃驾趣 · 动力优先 🔥",
                subtitle: "加速强劲热血，追求极致驾驶快感",
                icon: "flame.fill",
                estimatedKwhPer100Km: kwh100
            )
        }
    }
}

// MARK: - 维保周期与耗材寿命追踪 (nsom_so_maintenance)

enum NIOMaintenanceTracker {
    struct ConsumableItem: Identifiable, Hashable {
        var id: String { name }
        var name: String             // 耗材名称
        var icon: String             // SF Symbol
        var intervalKm: Double       // 推荐保养间隔里程 (km)
        var intervalMonths: Int      // 推荐保养间隔月数
        var remainingKm: Double      // 剩余可用里程
        var remainingDays: Int       // 剩余可用天数
        var healthPercentage: Double // 0.0 ... 100.0 寿命百分比
        var statusDesc: String       // "健康良好" / "建议关注" / "需要保养"
        var isUrgent: Bool
    }

    struct MaintenanceReport {
        var totalCount: Int
        var totalSpent: Double
        var lastServiceDate: String
        var lastServiceStation: String
        var nextServiceKm: Double
        var items: [ConsumableItem]
        var overallHealthScore: Int  // 0 ... 100
    }

    static func generateReport(currentMileage: Double, orders: [NIOServiceOrder]) -> MaintenanceReport {
        let maintOrders = orders.filter { $0.orderType == "nsom_so_maintenance" }.sorted { $0.createTime > $1.createTime }
        let completed = maintOrders.filter { NIOOrderLib.isCompletedOrder($0) }
        let totalSpent = completed.reduce(0.0) { $0 + NIOOrderLib.orderSpentAmount($1) }
        
        let lastOrder = completed.first
        let lastDate = lastOrder != nil ? NIOOrderLib.fmtSwapDate(lastOrder!.createTime) : "未记录"
        let lastStation = lastOrder?.resourceAddress ?? lastOrder?.address ?? "官方服务中心"

        let configs: [(name: String, icon: String, km: Double, months: Int)] = [
            ("空调滤清器 (CN95)", "air.purifier.fill", 10_000, 12),
            ("轮胎动平衡与换位", "circle.grid.cross.fill", 20_000, 12),
            ("制动液 (刹车油)", "car.rear.and.tire.marks", 40_000, 24),
            ("整车冷却液 (防冻液)", "snowflake.circle.fill", 60_000, 36),
            ("雨刮胶条与洗涤系统", "windshield.front.and.wiper", 15_000, 12)
        ]

        var items: [ConsumableItem] = []
        var totalHealth = 0.0

        for cfg in configs {
            let usedKm = currentMileage.truncatingRemainder(dividingBy: cfg.km)
            let remainKm = max(0.0, cfg.km - usedKm)
            let health = max(0.0, min(100.0, (remainKm / cfg.km) * 100.0))
            totalHealth += health

            let isUrgent = health < 15.0
            let status: String = {
                if health > 60.0 { return "寿命充足 (\(Int(health))%)" }
                if health > 20.0 { return "状态正常 (\(Int(health))%)" }
                return "建议近期检查保养 ⚠️"
            }()

            items.append(ConsumableItem(
                name: cfg.name,
                icon: cfg.icon,
                intervalKm: cfg.km,
                intervalMonths: cfg.months,
                remainingKm: remainKm,
                remainingDays: Int(remainKm / 35.0),
                healthPercentage: health,
                statusDesc: status,
                isUrgent: isUrgent
            ))
        }

        let avgHealth = items.isEmpty ? 100 : Int(totalHealth / Double(items.count))
        let nextKm = items.map { $0.remainingKm }.min() ?? 5000.0

        return MaintenanceReport(
            totalCount: completed.count,
            totalSpent: totalSpent,
            lastServiceDate: lastDate,
            lastServiceStation: lastStation,
            nextServiceKm: nextKm,
            items: items,
            overallHealthScore: avgHealth
        )
    }
}


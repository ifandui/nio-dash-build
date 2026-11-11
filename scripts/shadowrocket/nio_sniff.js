/**
 * 🐰 YumikoToys NIO-Dash — 蔚来凭证全自动提取脚本 v2
 *
 * 新增：直推模式
 *   若手机上已打开 YumikoToys App 且点击了「开始接收」，
 *   脚本会将凭证 POST 到 http://127.0.0.1:8997/credentials，
 *   App 立即自动回填 + 震动通知，全程不需要手动复制粘贴。
 *
 * 兜底：BoxJS 看板
 *   若直推失败（App 未打开），凭证仍写入 $persistentStore，
 *   Safari 打开 http://boxjs.com 即可手动复制。
 *
 * 安装方法（Shadowrocket）:
 *   配置 → 脚本 → 新建，粘贴此文件。
 *   类型: 请求，触发 URL 规则: ^https?://(.*\.)?nio\.com
 */

const DEFAULT_CHANGE_URL  = "https://gateway-front-external.nio.com/moat/1100367/api/v1/otd/car/ext/general/serviceOrder/getTabOrder?offset=0&limit=200&orderTypes=pe_shaman,pe_shaman_change,service_pe_discharge,battery_flexible_upgrade,nsom_so_maintenance,nsom_so_chauffeur,chauffeur_vehicle_delivery,so_case_accident&hash_type=sha256&lang=zh&region=US&tz_offset=28800&app_ver=6.5.3";
const DEFAULT_CHECKIN_URL = "https://gateway-front-external.nio.com/moat/10086/n/c/award/square?event=checkin&collection_id=1843940587332317185";

// ── 本地直推端口（须与 App 内「接收服务器端口」一致）──
const LOCAL_PUSH_URL = "http://127.0.0.1:8997/credentials";

(function main() {
    const url     = $request.url;
    const headers = $request.headers || {};

    // ① 本机 Web 看板（Safari 打开 http://boxjs.com 或 http://boxjs.net）
    if (url.includes("boxjs.com") || url.includes("boxjs.net") ||
        url.includes("/dash") || url.includes("nio.toys") || url.includes("nio.local")) {

        let storedData = {};
        try {
            const raw = $persistentStore.read("nio_sniff_data");
            if (raw) storedData = JSON.parse(raw);
        } catch (e) { storedData = {}; }

        const jsonStr = JSON.stringify(storedData, null, 2);
        const hasData = !!storedData.vehicle_token || !!storedData.vehicle_url;
        const html = buildHtml(jsonStr, hasData);

        $done({ response: { status: 200, headers: { "Content-Type": "text/html;charset=utf-8" }, body: html } });
        return;
    }

    // ② 捕获蔚来 API 请求头
    let token = headers["Authorization"] || headers["authorization"] || "";
    if (token.startsWith("Bearer ")) token = token.replace("Bearer ", "").trim();

    // 防多端登录：同步捕获真实设备指纹。服务器把 token 与登录设备绑定，
    // App 端回放时使用同一 User-Guid / User-Agent / app_ver，才不会被判定
    // 为多端登录而快速踢下线。
    const userGuid  = headers["User-Guid"] || headers["user-guid"] || "";
    const userAgent = headers["User-Agent"] || headers["user-agent"] || "";

    const qp = parseQueryParams(url);
    const isFullRvs = url.includes("icar.nio.com") && url.includes("/status");
    const isWidget  = url.includes("/widget/info");
    const appVer    = qp.app_ver || (url.match(/app_ver=([\d.]+)/) || [])[1] || "";

    // UA 策略：主 App 的 UA（NextevCar/WeiLaiApp，非 Widget）优先——
    // 回放五类请求应以「主 App 指纹」为准，Widget UA 只是兜底
    const isMainAppUA = userAgent.includes("WeiLaiApp") && !userAgent.includes("WidgetExtension");

    // 读取已存数据
    let stored = {};
    try {
        const raw = $persistentStore.read("nio_sniff_data");
        if (raw) stored = JSON.parse(raw);
    } catch (e) { stored = {}; }

    // 更新字段
    if (token)          stored.vehicle_token = token;
    if (qp.vehicle_id)  stored.vehicle_id    = qp.vehicle_id;
    if (qp.device_id)   stored.device_id     = qp.device_id;
    else if (!stored.device_id && userGuid) stored.device_id = userGuid; // 订单/签到网关请求无 query device_id，用请求头 User-Guid 兜底
    if (qp.sign)        stored.sign          = qp.sign;
    if (qp.timestamp)   stored.timestamp     = qp.timestamp;
    if (qp.sign_secret) stored.sign_secret   = qp.sign_secret;
    if (appVer)         stored.app_ver       = appVer;
    if (userAgent && (isMainAppUA || !stored.user_agent)) stored.user_agent = userAgent;
    if (userGuid)       stored.user_guid     = userGuid;

    // ── v3 新增①：用户级 access_token 识别 ──
    // 主 App（非 Widget 小组件）会话的 token 才有车控 / RVS / 蓝牙钥匙权限；
    // 小组件 VehicleWidgetExtension 抓到的车级 token 调车控会返回 no access found。
    const isCommandReq = url.includes("/api/1/vehicle/command/") ||
                         url.includes("/api/2/ws/command/connect") ||
                         url.includes("/api/1/sec/iot/platform/thing/commands");
    if (token && isMainAppUA) stored.user_token = token;

    // ── v3 新增②：官方车控指令原文捕获（逆向对照端点 + body 格式 + 签名参与方式）──
    // 在官方蔚来 App 里点任意车控按钮（锁车/空调/寻车…），此处记录完整请求
    if (isCommandReq) {
        const sample = {
            time:   new Date().toLocaleTimeString("zh-CN", { hour12: false }),
            method: ($request.method || "POST").toUpperCase(),
            url:    url,
            body:   typeof $request.body === "string" ? $request.body : ($request.body ? JSON.stringify($request.body) : "")
        };
        stored.command_samples = [sample].concat(stored.command_samples || []).slice(0, 5);
    }

    stored.change_url  = appVer ? DEFAULT_CHANGE_URL.replace(/app_ver=[\d.]+/, "app_ver=" + appVer) : DEFAULT_CHANGE_URL;
    stored.checkin_url = DEFAULT_CHECKIN_URL;
    if (token) { stored.change_token = token; stored.checkin_token = token; }

    if (isFullRvs) {
        stored.mode       = "url";
        stored.vehicle_url = url;
        stored.tyre_ready = true;
    } else if (isWidget) {
        stored.widget_url = url;
        if (!stored.vehicle_url || stored.mode === "widget") {
            stored.vehicle_url = url;
            stored.mode        = "widget";
        }
    }

    // 持久化
    $persistentStore.write(JSON.stringify(stored, null, 2), "nio_sniff_data");
    if (stored.vehicle_token) $persistentStore.write(stored.vehicle_token, "nio_vehicle_token");
    if (stored.vehicle_id)    $persistentStore.write(stored.vehicle_id,    "nio_vehicle_id");
    if (stored.device_id)     $persistentStore.write(stored.device_id,     "nio_device_id");
    if (stored.vehicle_url)   $persistentStore.write(stored.vehicle_url,   "nio_vehicle_url");

    // ③ 【核心新功能】直推凭证到 App 本地服务器 (127.0.0.1:8997)
    // 只要有 token 或 vehicle_id 就尝试推送，无论 isFullRvs
    if (stored.vehicle_token || stored.vehicle_id) {
        const pushBody = JSON.stringify({
            vehicle_token: stored.vehicle_token || "",
            vehicle_id:    stored.vehicle_id    || "",
            device_id:     stored.device_id     || "",
            vehicle_url:   stored.vehicle_url   || "",
            sign:          stored.sign          || "",
            timestamp:     stored.timestamp     || "",
            app_ver:       stored.app_ver       || "",
            user_agent:    stored.user_agent    || "",
            user_guid:     stored.user_guid     || "",
            user_token:    stored.user_token    || "",
            command_samples: stored.command_samples || [],
            source:        "shadowrocket"
        });

        $httpClient.post({
            url:  LOCAL_PUSH_URL,
            headers: { "Content-Type": "application/json" },
            body: pushBody
        }, function(error, response, data) {
            if (!error && response && response.status === 200) {
                console.log("[YumikoToys] ✅ 凭证已直推到 App");
            } else {
                // App 未开启直推接收模式，走通知兜底
                console.log("[YumikoToys] App 未监听，凭证已存入 BoxJS，请手动复制");
            }
        });
    }

    // ④ 系统通知兜底
    try {
        if (typeof $notification !== "undefined") {
            if (isCommandReq) {
                const fn = (stored.command_samples && stored.command_samples[0] && stored.command_samples[0].body || "").match(/"function"\s*:\s*"([^"]+)"/);
                $notification.post(
                    "🎯 已捕获官方车控指令原文" + (fn ? "·" + fn[1] : ""),
                    "端点+body+签名已存档并直推 App 诊断",
                    "在 YumikoToys 诊断页 category=command_capture 查看"
                );
            } else if (isFullRvs) {
                $notification.post(
                    "🎉 蔚来【爱车主页】凭证已捕获！",
                    "Token + 4 轮胎压全部就绪",
                    "若 App 在前台则已自动回填；否则请点击「剪贴板读取并识别」"
                );
            } else if (stored.vehicle_token && !stored.tyre_ready) {
                $notification.post(
                    "ℹ️ Token 已捕获",
                    "请在蔚来 App【爱车】主页下拉刷新获取完整凭证",
                    ""
                );
            }
        }
    } catch (err) {
        console.log("Notification error: " + err);
    }

    $done({});
})();

// ────────────────── 工具函数 ──────────────────

function parseQueryParams(urlString) {
    const params = {};
    const qIdx = urlString.indexOf("?");
    if (qIdx === -1) return params;
    const query = urlString.substring(qIdx + 1);
    query.split("&").forEach(function(pair) {
        const kv = pair.split("=");
        if (kv.length >= 2) {
            try { params[decodeURIComponent(kv[0])] = decodeURIComponent(kv.slice(1).join("=")); }
            catch (e) { params[kv[0]] = kv.slice(1).join("="); }
        }
    });
    return params;
}

function buildHtml(jsonStr, hasData) {
    return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <title>🐰 蔚来看板配置提取器</title>
    <style>
        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background: #0f172a; color: #f8fafc; margin: 0; padding: 20px;
            display: flex; flex-direction: column; align-items: center; min-height: 100vh;
        }
        .card {
            background: #1e293b; border-radius: 20px; padding: 24px; width: 100%; max-width: 480px;
            box-shadow: 0 10px 25px -5px rgba(0,0,0,.4); border: 1px solid #334155; margin-top: 10px;
        }
        h2 { margin: 0 0 8px; font-size: 20px; color: #38bdf8; display: flex; align-items: center; gap: 8px; }
        p { color: #94a3b8; font-size: 13px; margin: 0 0 16px; line-height: 1.5; }
        .badge {
            display: inline-block; padding: 6px 12px; border-radius: 99px; font-size: 13px; font-weight: 700;
            background: ${hasData ? "rgba(34,197,94,.2)" : "rgba(234,179,8,.2)"};
            color: ${hasData ? "#4ade80" : "#facc15"}; margin-bottom: 16px;
            border: 1px solid ${hasData ? "rgba(34,197,94,.3)" : "rgba(234,179,8,.3)"};
        }
        textarea {
            width: 100%; height: 220px; background: #090d16; color: #38bdf8; border: 1px solid #334155;
            border-radius: 12px; padding: 12px; font-family: monospace; font-size: 12px; resize: none; outline: none;
        }
        button {
            width: 100%; background: linear-gradient(135deg, #0284c7, #0ea5e9); color: white; border: none;
            padding: 15px; border-radius: 14px; font-size: 16px; font-weight: 700; margin-top: 16px;
            cursor: pointer; transition: all .2s; box-shadow: 0 4px 12px rgba(14,165,233,.3);
        }
        button:active { transform: scale(.98); opacity: .9; }
        .tip { margin-top: 16px; font-size: 12px; color: #64748b; text-align: center; }
    </style>
</head>
<body>
    <div class="card">
        <h2>🐰 蔚来看板配置提取器</h2>
        <p>免电脑提取车辆 RVS 车况、4 轮胎压与鉴权 Token</p>
        <div class="badge">${hasData ? "✅ 已捕获车况凭证" : "⏳ 暂未捕获，请进入蔚来 App 下拉刷新"}</div>
        <textarea id="jsonBox" readonly>${jsonStr}</textarea>
        <button onclick="copyConfig()">📋 一键复制配置到剪贴板</button>
        <div class="tip">复制后回到 YumikoToys App 设置点击「剪贴板读取并识别」即可</div>
    </div>
    <script>
        function copyConfig() {
            const text = document.getElementById('jsonBox').value;
            if (!navigator.clipboard) {
                document.getElementById('jsonBox').select();
                document.execCommand('copy');
            } else {
                navigator.clipboard.writeText(text);
            }
            const btn = document.querySelector('button');
            btn.innerText = '✅ 复制成功！请切换回 YumikoToys App';
            btn.style.background = 'linear-gradient(135deg,#16a34a,#22c55e)';
            setTimeout(() => {
                btn.innerText = '📋 一键复制配置到剪贴板';
                btn.style.background = 'linear-gradient(135deg,#0284c7,#0ea5e9)';
            }, 3000);
        }
    </script>
</body>
</html>`;
}

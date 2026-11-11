/**
 * 🔬 YumikoToys NIO-Dash — 车机扫码授权链路捕获（http-response）
 * 配合 YumikoToys-NIO.sgmodule 使用
 *
 * 逆向背景（来自官方 App 二进制分析）：
 *   车机屏幕出的二维码（含工程模式/扫码授权）→ 手机蔚来 App 扫码 →
 *   走 /api/1/sec/poseidon/vehicle/qrcode/ 与 /api/1/sec/poseidon/owner_vehicle_perms
 *   （RCScanResultController.checkPassengerCer / requestVehiclePerms），
 *   权限判定在服务端（"暂无权限"是服务端返回的，不是本地判定）。
 *
 * 本脚本拦截 poseidon 域所有响应，把 请求方法/URL/body + 响应状态/响应原文
 * 存档并直推 YumikoToys App 诊断（127.0.0.1:8997/credentials，category=scan_capture），
 * 用于安全研究时观察服务端权限判定链路。
 */

const LOCAL_PUSH_URL = "http://127.0.0.1:8997/credentials";
const STORE_KEY      = "nio_poseidon_samples";
const MAX_SAMPLES    = 5;
const MAX_BODY_LEN   = 2500;

(function main() {
    const url = ($request && $request.url) || "";
    // 只关心 poseidon（车机座舱授权域）与车机登录扫码
    if (!/poseidon|in-car|scan/i.test(url)) { $done({}); return; }

    const method = (($request && $request.method) || "GET").toUpperCase();
    const reqBody = ($request && typeof $request.body === "string") ? $request.body : "";

    let status = 0, respBody = "";
    if ($response) {
        status = $response.status || 0;
        respBody = typeof $response.body === "string" ? $response.body : "";
    }
    if (respBody.length > MAX_BODY_LEN) respBody = respBody.slice(0, MAX_BODY_LEN) + "…(截断)";

    const sample = {
        time:     new Date().toLocaleTimeString("zh-CN", { hour12: false }),
        method:   method,
        url:      url,
        req_body: reqBody.slice(0, MAX_BODY_LEN),
        status:   status,
        resp_body: respBody
    };

    let samples = [];
    try { samples = JSON.parse($persistentStore.read(STORE_KEY) || "[]"); } catch (_) {}
    // 相同 URL+响应去重，避免每次轮询重复推送
    const fp = sample.method + "|" + sample.url + "|" + sample.status + "|" + respBody.slice(0, 200);
    if (samples.length && samples[0]._fp === fp) { $done({}); return; }
    sample._fp = fp;
    samples = [sample].concat(samples).slice(0, MAX_SAMPLES);
    $persistentStore.write(JSON.stringify(samples), STORE_KEY);

    // 直推 App（fire-and-forget，不阻塞响应）
    $httpClient.post({
        url: LOCAL_PUSH_URL,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ poseidon_samples: samples, source: "shadowrocket_poseidon" })
    }, function(err, resp, _) {
        console.log(err ? "[YumikoToys] App 未在前台，扫码样本已存 BoxJS" : "[YumikoToys] ✅ 扫码链路样本已直推 App");
    });

    try {
        if (typeof $notification !== "undefined") {
            const path = (url.split("?")[0].split("/").slice(-2).join("/")) || url;
            $notification.post("🔬 已捕获扫码授权链路", path + " · status " + status, "已直推 App 诊断（scan_capture）");
        }
    } catch (_) {}

    $done({});
})();

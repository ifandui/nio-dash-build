#!/usr/bin/env bash
# ==============================================================================
#  sniff_3d_model.sh - 蔚来 3D 车模资产一键抓取
#  用法: ./sniff_3d_model.sh [mac|iphone|all]
#  抓到 model3d_url 后自动下载 .unity3d 资产到 sniff_3d_out/
# ==============================================================================

set -e

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PORT=8080
TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$TARGET_DIR/sniff_3d_model.py"

get_local_ip() {
    for iface in en0 en1 en2 en3; do
        local ip=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
        if [[ -n "$ip" && "$ip" != "127.0.0.1" ]]; then echo "$ip"; return; fi
    done
    echo "127.0.0.1"
}
LOCAL_IP=$(get_local_ip)

if ! command -v mitmdump &> /dev/null; then
    echo -e "${YELLOW}[!] 未安装 mitmproxy: brew install mitmproxy${NC}"; exit 1
fi

MODE="${1:-all}"

ACTIVE_SERVICES=()
while IFS= read -r line; do
    [[ -n "$line" ]] && ACTIVE_SERVICES+=("$line")
done < <(networksetup -listallnetworkservices | grep -v '\*' | grep -E 'Wi-Fi|Ethernet|LAN' || true)
[[ ${#ACTIVE_SERVICES[@]} -eq 0 ]] && ACTIVE_SERVICES=("Wi-Fi")

if lsof -i :$PORT >/dev/null 2>&1; then
    kill -9 $(lsof -ti :$PORT | head -n 1) 2>/dev/null || true; sleep 0.5
fi

cleanup() {
    if [[ "$MODE" == "mac" || "$MODE" == "all" ]]; then
        echo -e "\n${YELLOW}==> 还原 Mac 系统代理...${NC}"
        for srv in "${ACTIVE_SERVICES[@]}"; do
            networksetup -setwebproxystate "$srv" off 2>/dev/null || true
            networksetup -setsecurewebproxystate "$srv" off 2>/dev/null || true
        done
    fi
}
trap cleanup EXIT INT TERM

if [[ "$MODE" == "mac" || "$MODE" == "all" ]]; then
    for srv in "${ACTIVE_SERVICES[@]}"; do
        networksetup -setwebproxy "$srv" 127.0.0.1 $PORT 2>/dev/null || true
        networksetup -setsecurewebproxy "$srv" 127.0.0.1 $PORT 2>/dev/null || true
    done
    echo -e "${GREEN}[✓] Mac 系统代理已指向 127.0.0.1:$PORT${NC}"
fi

clear
echo -e "${CYAN}${BOLD}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║        🚗 蔚来 3D 车模资产抓取助手 (自动下载 unity3d)          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
if [[ "$MODE" == "iphone" || "$MODE" == "all" ]]; then
    echo -e "${BOLD}iPhone 抓包步骤：${NC}"
    echo -e "  1. iPhone 与本机同一 Wi-Fi，设置代理 → 手动："
    echo -e "     服务器 ${BOLD}${LOCAL_IP}${NC}  端口 ${BOLD}${PORT}${NC}"
    echo -e "  2. 打开蔚来 App → 爱车 → 切到【3D 车模视图】（或选配器 3D）"
    echo -e "  3. 等待提示音，结果在 ${BOLD}nio_3d_model.json${NC}，资产在 ${BOLD}sniff_3d_out/${NC}"
    echo ""
fi
echo -e "${GREEN}${BOLD}🚀 监听中 (0.0.0.0:$PORT)... 打开 App 的 3D 视图即可${NC}\n"

mitmdump --listen-host 0.0.0.0 -p $PORT -s "$TARGET_SCRIPT"

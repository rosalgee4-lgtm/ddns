#!/bin/bash
# =============================================================
#  VPS1 - IP 监控脚本（IPv4 + IPv6）
#  同时检测公网 IPv4 和 IPv6，变化时分别通知 VPS2
#  用法：sudo bash vps1_monitor.sh          # 首次部署
#        sudo bash vps1_monitor.sh --uninstall  # 卸载
# =============================================================
set -euo pipefail

# 最优先处理 --uninstall，避免被 set -e 或 self_install 干扰
if [ "${1:-}" = "--uninstall" ]; then
    SERVICE_NAME="ddns-monitor"
    INSTALL_PATH="/opt/ddns-monitor/monitor.sh"
    LOG_FILE="/var/log/ddns-monitor.log"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 开始卸载 $SERVICE_NAME..."
    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f /tmp/.ddns_last_ipv4 /tmp/.ddns_last_ipv6
    rm -rf "$(dirname "$INSTALL_PATH")"
    systemctl daemon-reload
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] ✅ 卸载完成"
    echo "日志文件保留在 $LOG_FILE，如需删除：rm $LOG_FILE"
    exit 0
fi


# ★ VPS2 地址
VPS2_URL="http://69.12.74.54:43300/update"

# ★ 安全令牌（与 VPS2 一致）
SECRET_TOKEN="2ad4e8a4-a404-4ead-9d6f-547540db6ba1"

CHECK_INTERVAL=10
LOG_FILE="/var/log/ddns-monitor.log"
CACHE_V4="/tmp/.ddns_last_ipv4"
CACHE_V6="/tmp/.ddns_last_ipv6"
INSTALL_PATH="/opt/ddns-monitor/monitor.sh"
SERVICE_NAME="ddns-monitor"

# IPv4 查询服务
IPV4_SERVICES=(
    "https://api.ipify.org"
    "https://ifconfig.me/ip"
    "https://myip.ipip.net"
    "https://ddns.oray.com/checkip"
    "https://ip.3322.net"
    "https://4.ipw.cn"
    "https://v4.yinghualuo.cn/bejson"
    "https://myexternalip.com/raw"
)

# IPv6 查询服务
IPV6_SERVICES=(
    "https://api6.ipify.org"
    "https://speed.neu6.edu.cn/getIP.php"
    "https://v6.ident.me"
    "https://6.ipw.cn"
    "https://v6.yinghualuo.cn/bejson"
)

# =============================================================
log() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" \
        | tee -a "$LOG_FILE"
}

check_and_install_deps() {
    command -v curl &>/dev/null && return 0
    log WARN "curl 未安装，自动安装..."
    if   command -v apt-get &>/dev/null; then
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl
    elif command -v yum &>/dev/null; then yum install -y -q curl
    elif command -v dnf &>/dev/null; then dnf install -y -q curl
    elif command -v apk &>/dev/null; then apk add --no-cache curl
    fi
    command -v curl &>/dev/null || { log ERROR "curl 安装失败"; exit 1; }
    log INFO "依赖安装完成"
}

# =============================================================
#  获取 IP
# =============================================================
get_ipv4() {
    local ip=""
    for url in "${IPV4_SERVICES[@]}"; do
        ip=$(curl -4 -s --max-time 5 --retry 2 "$url" 2>/dev/null \
             | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && echo "$ip" && return 0
    done
    echo ""
}

get_ipv6() {
    local ip=""
    for url in "${IPV6_SERVICES[@]}"; do
        ip=$(curl -6 -s --max-time 5 --retry 2 "$url" 2>/dev/null \
             | grep -oE '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' | head -1)
        [ -n "$ip" ] && echo "$ip" && return 0
    done
    echo ""
}

# =============================================================
#  通知 VPS2
# =============================================================
notify_vps2() {
    local ip="$1" type="$2"
    local resp
    resp=$(curl -s --max-time 10 \
        -X POST "$VPS2_URL" \
        -H "Content-Type: application/json" \
        -H "X-Secret-Token: $SECRET_TOKEN" \
        -d "{\"ip\":\"$ip\",\"type\":\"$type\"}")
    if echo "$resp" | grep -q '"status":"ok"'; then
        log INFO "[$type] VPS2 通知成功 → $ip"
        return 0
    else
        log ERROR "[$type] VPS2 通知失败，响应：$resp"
        return 1
    fi
}

# =============================================================
#  卸载
# =============================================================
uninstall() {
    log INFO "开始卸载 $SERVICE_NAME..."
    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f "$CACHE_V4" "$CACHE_V6"
    rm -rf "$(dirname "$INSTALL_PATH")"
    systemctl daemon-reload
    log INFO "✅ 卸载完成"
    echo "日志文件保留在 $LOG_FILE，如需删除：rm $LOG_FILE"
}

# =============================================================
#  自部署
# =============================================================
self_install() {
    mkdir -p "$(dirname "$LOG_FILE")"
    log INFO "========================================"
    log INFO "VPS1 监控脚本自部署..."
    check_and_install_deps
    local script_path; script_path=$(realpath "$0")
    mkdir -p "$(dirname "$INSTALL_PATH")"
    [ "$script_path" != "$INSTALL_PATH" ] && cp "$script_path" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=DDNS IP Monitor (VPS1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash ${INSTALL_PATH} --run
Restart=always
RestartSec=10
StartLimitIntervalSec=120
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    log INFO "✅ 部署完成"
    log INFO "查看日志：tail -f $LOG_FILE"
    log INFO "========================================"
}

# =============================================================
#  主循环
# =============================================================
run_loop() {
    mkdir -p "$(dirname "$LOG_FILE")"
    log INFO "========================================"
    log INFO "VPS1 IP 监控启动（IPv4 + IPv6），间隔 ${CHECK_INTERVAL}s"
    log INFO "通知地址：$VPS2_URL"
    log INFO "========================================"
    check_and_install_deps

    local last_v4="" last_v6="" cur_v4="" cur_v6=""

    while true; do
        # ── IPv4 ──
        cur_v4=$(get_ipv4)
        [ -f "$CACHE_V4" ] && last_v4=$(cat "$CACHE_V4") || last_v4=""
        if [ -n "$cur_v4" ] && [ "$cur_v4" != "$last_v4" ]; then
            log INFO "[A] IP 变化：${last_v4:-首次} → $cur_v4"
            if notify_vps2 "$cur_v4" "A"; then
                echo "$cur_v4" > "$CACHE_V4"
            fi
        fi

        # ── IPv6 ──
        cur_v6=$(get_ipv6)
        [ -f "$CACHE_V6" ] && last_v6=$(cat "$CACHE_V6") || last_v6=""
        if [ -n "$cur_v6" ] && [ "$cur_v6" != "$last_v6" ]; then
            log INFO "[AAAA] IP 变化：${last_v6:-首次} → $cur_v6"
            if notify_vps2 "$cur_v6" "AAAA"; then
                echo "$cur_v6" > "$CACHE_V6"
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

# =============================================================
#  入口
# =============================================================
case "${1:-}" in
    --run)       run_loop ;;
    --uninstall) uninstall ;;
    *)
        [ "$EUID" -ne 0 ] && { echo "请用 sudo 运行"; exit 1; }
        self_install
        ;;
esac
#!/bin/bash
# =============================================================
#  VPS3 - 一键无人值守安装脚本
#  顺序：SSH 配置 -> DDNS 监控服务 -> nyanpass 安装 -> BBR 优化
#  用法：sudo bash awsjp_c5n_2c_install.sh
#        sudo bash awsjp_c5n_2c_install.sh --uninstall
# =============================================================
set -euo pipefail

# 避免未生成 en_US.UTF-8 时 bash/工具链反复输出 setlocale 警告。
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

VPS2_URL="http://69.12.74.54:43301/update"
SECRET_TOKEN="d6da3d47-b000-4b50-8a44-044bd45ee5f8"

CHECK_INTERVAL=10
LOG_FILE="/var/log/ddns-monitor.log"
CACHE_V4="/tmp/.ddns_last_ipv4"
CACHE_V6="/tmp/.ddns_last_ipv6"
INSTALL_DIR="/opt/ddns-monitor"
INSTALL_PATH="${INSTALL_DIR}/monitor.sh"
SERVICE_NAME="ddns-monitor"

ROOT_PASSWORD='>Qx$qpG>1.KF3TWHv>Z='

NYANPASS_URL="https://ny.nypassline.top"
NYANPASS_INSTALL_URL="https://dl.nyafw.com/download/nyanpass-install.sh"
NYANPASS_TIMEOUT=600
NYANPASS1_NAME="awsjp1"
NYANPASS1_TOKEN="2f3b9c5c-271d-455e-b0a3-bb01e60c2163"
NYANPASS2_NAME="awsjp2"
NYANPASS2_TOKEN="7ef35a04-1bf7-4dcf-a769-e67be1d907df"

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

IPV6_SERVICES=(
    "https://api6.ipify.org"
    "https://speed.neu6.edu.cn/getIP.php"
    "https://v6.ident.me"
    "https://6.ipw.cn"
    "https://v6.yinghualuo.cn/bejson"
)

log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" | tee -a "$LOG_FILE"
}

need_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "请用 sudo/root 运行"
        exit 1
    fi
}

fix_locale() {
    if locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
        return 0
    fi

    if command -v locale-gen >/dev/null 2>&1; then
        log INFO "生成 en_US.UTF-8 locale..."
        sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
        locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
        update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 >/dev/null 2>&1 || true
    fi
}

install_deps() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v timeout >/dev/null 2>&1 || missing+=("coreutils")

    [[ ${#missing[@]} -eq 0 ]] && return 0

    log INFO "安装依赖：${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "${missing[@]}"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "${missing[@]}"
    else
        log ERROR "未找到支持的包管理器，请手动安装：${missing[*]}"
        exit 1
    fi
}

configure_bbr() {
    log INFO "配置 BBR + fq（AWS 日本 c5.large）..."

    if [[ -f /etc/sysctl.conf ]]; then
        cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null || true
    fi

    modprobe tcp_bbr 2>/dev/null || true

    cat > /etc/sysctl.conf <<'EOF'
fs.file-max = 6815744
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_max=10000000
net.core.wmem_max=10000000
net.ipv4.tcp_rmem=4096 131072 10000000
net.ipv4.tcp_wmem=4096 131072 10000000
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl -p >/dev/null 2>&1 || log WARN "sysctl -p 应用可能未完全成功"
    sysctl --system >/dev/null 2>&1 || true

    local cc qdisc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    log INFO "当前拥塞控制算法：$cc"
    log INFO "当前队列算法：$qdisc"
}

configure_ssh() {
    log INFO "配置 SSH root 登录和密码登录..."

    if echo "root:${ROOT_PASSWORD}" | chpasswd 2>/dev/null; then
        log INFO "root 密码设置完成"
    else
        log WARN "root 密码设置可能失败"
    fi

    local sshd_config="/etc/ssh/sshd_config"
    if [[ ! -f "$sshd_config" ]]; then
        log WARN "未找到 $sshd_config，跳过 SSH 配置"
        return 0
    fi

    cp "$sshd_config" "${sshd_config}.bak.$(date +%s)" 2>/dev/null || true
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' "$sshd_config" 2>/dev/null || true
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' "$sshd_config" 2>/dev/null || true
    rm -rf /etc/ssh/sshd_config.d 2>/dev/null || true

    if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
        log INFO "SSH 服务重启完成"
    else
        log WARN "SSH 服务重启可能失败"
    fi
}

install_nyanpass() {
    local instance_num="$1"
    local service_name="$2"
    local install_args="$3"
    local install_cmd

    log INFO "无人值守安装 nyanpass 实例${instance_num}：${service_name}"
    install_cmd="printf '${service_name}\nn\ny\n' | timeout ${NYANPASS_TIMEOUT} bash <(curl -fLSs ${NYANPASS_INSTALL_URL}) rel_nodeclient \"${install_args}\""

    if eval "$install_cmd" 2>&1 | tee -a "$LOG_FILE"; then
        log INFO "nyanpass 实例${instance_num}安装完成：${service_name}"
    else
        log WARN "nyanpass 实例${instance_num}安装可能未完全成功：${service_name}"
    fi
}

install_nyanpass_all() {
    install_nyanpass 1 "$NYANPASS1_NAME" "-t ${NYANPASS1_TOKEN} -u ${NYANPASS_URL}"
    install_nyanpass 2 "$NYANPASS2_NAME" "-o -t ${NYANPASS2_TOKEN} -u ${NYANPASS_URL}"
}

get_ipv4() {
    local ip=""
    for url in "${IPV4_SERVICES[@]}"; do
        ip=$(curl -4 -s --max-time 5 --retry 2 "$url" 2>/dev/null \
            | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && echo "$ip" && return 0
    done
    echo ""
}

get_ipv6() {
    local ip=""
    for url in "${IPV6_SERVICES[@]}"; do
        ip=$(curl -6 -s --max-time 5 --retry 2 "$url" 2>/dev/null \
            | grep -oE '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' | head -1 || true)
        [[ -n "$ip" ]] && echo "$ip" && return 0
    done
    echo ""
}

notify_vps2() {
    local ip="$1"
    local type="$2"
    local resp

    resp=$(curl -s --max-time 10 \
        -X POST "$VPS2_URL" \
        -H "Content-Type: application/json" \
        -H "X-Secret-Token: $SECRET_TOKEN" \
        -d "{\"ip\":\"$ip\",\"type\":\"$type\"}" || true)

    if echo "$resp" | grep -q '"status":"ok"'; then
        log INFO "[$type] VPS2 通知成功 -> $ip"
        return 0
    fi

    log ERROR "[$type] VPS2 通知失败，响应：$resp"
    return 1
}

install_ddns_service() {
    log INFO "安装 DDNS 监控 systemd 服务..."

    mkdir -p "$INSTALL_DIR"
    local script_path
    script_path=$(realpath "$0")
    [[ "$script_path" != "$INSTALL_PATH" ]] && cp "$script_path" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=DDNS IP Monitor (VPS3)
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
    log INFO "DDNS 服务安装完成：systemctl status $SERVICE_NAME"
}

run_loop() {
    log INFO "VPS3 DDNS 监控启动，间隔 ${CHECK_INTERVAL}s，通知地址：$VPS2_URL"
    install_deps

    local last_v4="" last_v6="" cur_v4="" cur_v6=""
    while true; do
        cur_v4=$(get_ipv4)
        [[ -f "$CACHE_V4" ]] && last_v4=$(<"$CACHE_V4") || last_v4=""
        if [[ -n "$cur_v4" && "$cur_v4" != "$last_v4" ]]; then
            log INFO "[A] IP 变化：${last_v4:-首次} -> $cur_v4"
            notify_vps2 "$cur_v4" "A" && echo "$cur_v4" > "$CACHE_V4"
        fi

        cur_v6=$(get_ipv6)
        [[ -f "$CACHE_V6" ]] && last_v6=$(<"$CACHE_V6") || last_v6=""
        if [[ -n "$cur_v6" && "$cur_v6" != "$last_v6" ]]; then
            log INFO "[AAAA] IP 变化：${last_v6:-首次} -> $cur_v6"
            notify_vps2 "$cur_v6" "AAAA" && echo "$cur_v6" > "$CACHE_V6"
        fi

        sleep "$CHECK_INTERVAL"
    done
}

uninstall() {
    need_root
    log INFO "卸载 DDNS 监控服务..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -rf "$INSTALL_DIR"
    rm -f "$CACHE_V4" "$CACHE_V6"
    systemctl daemon-reload
    log INFO "卸载完成；BBR、SSH、nyanpass 配置不会自动回滚"
}

install_all() {
    need_root
    log INFO "开始 VPS3 一键无人值守安装..."
    fix_locale
    configure_ssh
    install_ddns_service
    install_deps
    install_nyanpass_all
    configure_bbr
    log INFO "全部安装完成"
    log INFO "查看 DDNS 日志：tail -f $LOG_FILE"
}

case "${1:-}" in
    --run) run_loop ;;
    --uninstall) uninstall ;;
    *) install_all ;;
esac
#!/bin/bash
# 兼容入口：保持旧文件名，实际执行同目录的一体化安装脚本。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/vps3_all_in_one_install.sh"

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    echo "未找到 ${TARGET_SCRIPT}"
    echo "请把 vps3_all_in_one_install.sh 和 awsjp_c5n_2c_install.sh 放在同一目录后再执行。"
    exit 1
fi

exec bash "$TARGET_SCRIPT" "$@"
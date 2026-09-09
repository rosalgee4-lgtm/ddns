#!/bin/bash
# =============================================================
#  VPS3 - 一键无人值守安装脚本
#  环境：使用 systemd 的 Linux；自动安装 curl、timeout、python3
#  顺序：依赖安装 -> SSH 配置 -> DDNS 监控服务 -> nyanpass 安装 -> BBR 优化
#  用法：sudo bash awssg_c6in_2c_install.sh
#        sudo bash awssg_c6in_2c_install.sh --uninstall
# =============================================================
set -euo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

VPS2_URL="http://69.12.74.54:43302/update"
SECRET_TOKEN="d6da3d47-b000-4b50-8a44-044bd45ee5f8"

CHECK_INTERVAL=10
LOG_FILE="/var/log/ddns-monitor.log"
INSTALL_DIR="/opt/ddns-monitor"
INSTALL_PATH="${INSTALL_DIR}/monitor.sh"
CACHE_V4="${INSTALL_DIR}/.ddns_last_ipv4"
CACHE_V6="${INSTALL_DIR}/.ddns_last_ipv6"
SERVICE_NAME="ddns-monitor"

# 密码中的 $ 必须按原文保留。
# shellcheck disable=SC2016
ROOT_PASSWORD='>Qx$qpG>1.KF3TWHv>Z='

NYANPASS_INSTALL_URL="https://dl.nyafw.com/download/nyanpass-install.sh"
NYANPASS_TIMEOUT=600
NYANPASS_URL2="https://ny.nypassline.top"

NYANPASS3_NAME="awssg3"
NYANPASS3_TOKEN="23eceb88-4a68-4f53-a0e9-3b0736591481"

NYANPASS4_NAME="awssg4"
NYANPASS4_TOKEN="2f3b9c5c-271d-455e-b0a3-bb01e60c2163"

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

need_systemd() {
    if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
        log ERROR "本脚本需要以 systemd 启动的 Linux 系统"
        return 1
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
    command -v python3 >/dev/null 2>&1 || missing+=("python3")

    [[ ${#missing[@]} -eq 0 ]] && return 0
    missing+=("ca-certificates")

    log INFO "安装依赖：${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "${missing[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "${missing[@]}"
    else
        log ERROR "未找到支持的包管理器，请手动安装：${missing[*]}"
        exit 1
    fi
}

configure_bbr() {
    log INFO "配置 BBR + fq（AWS SG c6in.large）..."

    if ! command -v sysctl >/dev/null 2>&1; then
        log WARN "未找到 sysctl，跳过 BBR 配置"
        return 0
    fi
    modprobe tcp_bbr 2>/dev/null || true
    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        log WARN "当前内核不支持 BBR，跳过网络参数配置"
        return 0
    fi

    local sysctl_file="/etc/sysctl.d/99-ddns-monitor.conf"
    mkdir -p /etc/sysctl.d
    if [[ -f "$sysctl_file" ]]; then
        cp -p "$sysctl_file" "${sysctl_file}.bak.$(date +%s%N)"
    fi

    cat > "$sysctl_file" <<'EOF'
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

    sysctl -p "$sysctl_file" >/dev/null 2>&1 || log WARN "部分网络参数未能应用，请检查内核支持情况"

    local cc qdisc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    log INFO "当前拥塞控制算法：$cc"
    log INFO "当前队列算法：$qdisc"
}

configure_ssh() {
    log INFO "配置 SSH root 登录和密码登录..."

    local sshd_config="/etc/ssh/sshd_config"
    if [[ ! -f "$sshd_config" ]]; then
        log WARN "未找到 $sshd_config，跳过 SSH 配置"
        return 0
    fi

    local sshd_bin backup temp_config
    sshd_bin=$(command -v sshd || true)
    if [[ -z "$sshd_bin" || ! -x "$sshd_bin" ]]; then
        log ERROR "未找到 sshd，无法验证 SSH 配置"
        return 1
    fi
    backup="${sshd_config}.bak.$(date +%s%N)"
    cp -p "$sshd_config" "$backup"
    temp_config=$(mktemp "${sshd_config}.tmp.XXXXXX")
    # sshd 采用首先读取到的值；在 Include 和 Match 之前放置全局配置。
    {
        printf '%s\n' '# BEGIN ddns-monitor SSH' 'PermitRootLogin yes' 'PasswordAuthentication yes' '# END ddns-monitor SSH'
        sed '/^# BEGIN ddns-monitor SSH$/,/^# END ddns-monitor SSH$/d' "$backup"
    } > "$temp_config"
    if ! "$sshd_bin" -t -f "$temp_config"; then
        rm -f "$temp_config"
        log ERROR "SSH 配置验证失败，原配置已保留：$backup"
        return 1
    fi
    if ! printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd; then
        rm -f "$temp_config"
        log ERROR "root 密码设置失败"
        return 1
    fi
    log INFO "root 密码设置完成"
    cat "$temp_config" > "$sshd_config"
    rm -f "$temp_config"

    if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null; then
        log INFO "SSH 配置重载完成"
    else
        cp -p "$backup" "$sshd_config"
        log ERROR "SSH 重载失败，已恢复原配置；root 密码已更新"
        return 1
    fi
}

install_nyanpass() {
    local instance_num="$1"
    local service_name="$2"
    local install_args="$3"
    local installer status=0

    log INFO "无人值守安装 nyanpass 实例${instance_num}：${service_name}"
    installer=$(mktemp)
    if ! curl -fLSs --connect-timeout 10 --max-time 60 --retry 2 "$NYANPASS_INSTALL_URL" -o "$installer"; then
        rm -f "$installer"
        log ERROR "nyanpass 安装器下载失败：${service_name}"
        return 1
    fi
    if [[ ! -s "$installer" ]] || ! bash -n "$installer"; then
        rm -f "$installer"
        log ERROR "nyanpass 安装器为空或语法无效：${service_name}"
        return 1
    fi
    # 官方安装器的 S 支持静默安装；REINSTALL 允许保留配置重复安装。
    if S="$service_name" REINSTALL=1 OPTIMIZE='' INSTALL_TOOLS='' \
        timeout --kill-after=10 "$NYANPASS_TIMEOUT" bash "$installer" rel_nodeclient "$install_args" \
        </dev/null 2>&1 | tee -a "$LOG_FILE"; then
        log INFO "nyanpass 实例${instance_num}安装完成：${service_name}"
    else
        status=1
        log ERROR "nyanpass 实例${instance_num}安装失败或超时：${service_name}"
    fi
    rm -f "$installer"
    return "$status"
}

install_nyanpass_all() {
    install_nyanpass 3 "$NYANPASS3_NAME" "-o -t ${NYANPASS3_TOKEN} -u ${NYANPASS_URL2}"
    install_nyanpass 4 "$NYANPASS4_NAME" "-t ${NYANPASS4_TOKEN} -u ${NYANPASS_URL2}"
}

extract_ip() {
    python3 -c '
import ipaddress
import re
import sys

version = int(sys.argv[1])
text = sys.stdin.read()
pattern = r"(?<![\w.:])[0-9]+(?:\.[0-9]+){3}(?![\w.:])" if version == 4 else r"(?<![\w.:])[0-9a-fA-F]*:[0-9a-fA-F:.]+(?![\w.:])"
for candidate in re.findall(pattern, text):
    try:
        address = ipaddress.ip_address(candidate)
    except ValueError:
        continue
    if address.version == version:
        print(address)
        break
' "$1"
}

get_ip() {
    local family="$1" url response ip
    shift
    for url in "$@"; do
        if response=$(curl "-$family" -fsS --connect-timeout 3 --max-time 5 "$url" 2>/dev/null); then
            ip=$(printf '%s' "$response" | extract_ip "$family")
            if [[ -n "$ip" ]]; then
                printf '%s\n' "$ip"
                return 0
            fi
        fi
    done
    return 0
}

get_ipv4() {
    get_ip 4 "${IPV4_SERVICES[@]}"
}

get_ipv6() {
    get_ip 6 "${IPV6_SERVICES[@]}"
}

notify_vps2() {
    local ip="$1"
    local type="$2"
    local resp

    if ! resp=$(curl -fsS --connect-timeout 3 --max-time 10 \
        -X POST "$VPS2_URL" \
        -H "Content-Type: application/json" \
        -H "X-Secret-Token: $SECRET_TOKEN" \
        -d "{\"ip\":\"$ip\",\"type\":\"$type\"}"); then
        log ERROR "[$type] VPS2 请求失败 -> $ip"
        return 1
    fi

    if printf '%s' "$resp" | python3 -c '
import json
import sys
try:
    response = json.load(sys.stdin)
except (ValueError, UnicodeError):
    sys.exit(1)
sys.exit(0 if isinstance(response, dict) and response.get("status") == "ok" else 1)
'; then
        log INFO "[$type] VPS2 通知成功 -> $ip"
        return 0
    fi

    log ERROR "[$type] VPS2 通知失败，响应：$resp"
    return 1
}

install_ddns_service() {
    log INFO "安装 DDNS 监控 systemd 服务..."

    install -d -m 700 "$INSTALL_DIR"
    local script_path
    script_path=$(realpath "$0")
    if [[ "$script_path" != "$INSTALL_PATH" ]]; then
        install -m 700 "$script_path" "$INSTALL_PATH"
    fi
    chmod 700 "$INSTALL_PATH"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=DDNS IP Monitor (VPS3)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
ExecStart=/bin/bash ${INSTALL_PATH} --run
Restart=always
RestartSec=10
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    log INFO "DDNS 服务安装完成：systemctl status $SERVICE_NAME"
}

run_loop() {
    need_root
    umask 077
    log INFO "VPS3 DDNS 监控启动，间隔 ${CHECK_INTERVAL}s，通知地址：$VPS2_URL"
    local dependency
    for dependency in curl python3; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            log ERROR "缺少 $dependency，请重新运行安装脚本"
            return 1
        fi
    done
    install -d -m 700 "$INSTALL_DIR"

    local last_v4="" last_v6="" cur_v4="" cur_v6=""
    while true; do
        cur_v4=$(get_ipv4)
        last_v4=""
        if [[ -f "$CACHE_V4" ]]; then
            last_v4=$(<"$CACHE_V4")
        fi
        if [[ -n "$cur_v4" && "$cur_v4" != "$last_v4" ]]; then
            log INFO "[A] IP 变化：${last_v4:-首次} -> $cur_v4"
            if notify_vps2 "$cur_v4" "A"; then
                printf '%s\n' "$cur_v4" > "$CACHE_V4"
            fi
        fi

        cur_v6=$(get_ipv6)
        last_v6=""
        if [[ -f "$CACHE_V6" ]]; then
            last_v6=$(<"$CACHE_V6")
        fi
        if [[ -n "$cur_v6" && "$cur_v6" != "$last_v6" ]]; then
            log INFO "[AAAA] IP 变化：${last_v6:-首次} -> $cur_v6"
            if notify_vps2 "$cur_v6" "AAAA"; then
                printf '%s\n' "$cur_v6" > "$CACHE_V6"
            fi
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
    need_systemd
    umask 077
    log INFO "开始 VPS3 一键无人值守安装..."
    install_deps
    fix_locale
    configure_ssh
    install_ddns_service
    install_nyanpass_all
    configure_bbr
    log INFO "全部安装完成"
    log INFO "查看 DDNS 日志：tail -f $LOG_FILE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --run) run_loop ;;
        --uninstall) uninstall ;;
        "") install_all ;;
        -h|--help) printf '用法：sudo bash %s [--run|--uninstall]\n' "$0" ;;
        *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
    esac
fi

#!/usr/bin/env bash
# Proxy/VPN server optimize
# - 所有配置走 drop-in 文件 (99-zzz-proxy.conf)
# - /etc/sysctl.conf 会被清空，因为 `sysctl --system` 把它作为最后加载的文件会覆盖 drop-in
# 用法:
#   bash optimize.sh                 # v2node 节点机调优（默认）
#   bash optimize.sh --relay         # 中转机调优（额外加 conntrack 优化）
#   bash optimize.sh --upgrade       # 同时升级系统（会动内核/SSH）
#   bash optimize.sh --lock-dns      # chattr +i /etc/resolv.conf（谨慎）
#   bash optimize.sh --skip-dns      # 不改 DNS
#   bash optimize.sh --skip-ntp      # 不改 NTP
#
# 注意：--relay 仅在做 NAT MASQUERADE 的中转机用，纯 v2node 节点别加

set -uo pipefail

LOG_FILE="/var/log/server-optimization.log"
BACKUP_DIR="/root/system_backup/$(date +%Y%m%d-%H%M%S)"
DROPIN="99-zzz-proxy.conf"

DO_UPGRADE=0; LOCK_DNS=0; SKIP_DNS=0; SKIP_NTP=0; RELAY_MODE=0
for a in "$@"; do
    case "$a" in
        --upgrade)  DO_UPGRADE=1 ;;
        --lock-dns) LOCK_DNS=1 ;;
        --skip-dns) SKIP_DNS=1 ;;
        --skip-ntp) SKIP_NTP=1 ;;
        --relay)    RELAY_MODE=1 ;;
    esac
done

CSI=$'\033['; CEND="${CSI}0m"
CRED="${CSI}1;31m"; CGREEN="${CSI}1;32m"
CYELLOW="${CSI}1;33m"; CCYAN="${CSI}1;36m"

_log()        { echo -e "$1" | tee -a "$LOG_FILE"; }
OUT_ALERT()   { _log "${CYELLOW}$1${CEND}"; }
OUT_ERROR()   { _log "${CRED}$1${CEND}"; }
OUT_INFO()    { _log "${CCYAN}$1${CEND}"; }
OUT_SUCCESS() { _log "${CGREEN}$1${CEND}"; }

release=""
is_in_china="false"
server_country="UNKNOWN"
PM_INSTALL=""
PM_UPDATE=""
CC="cubic"; QDISC="fq_codel"

check_root() {
    [[ $EUID -eq 0 ]] || { OUT_ERROR "[错误] 需要 root"; exit 1; }
}

check_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "${ID:-}" in
            debian|raspbian)                    release="debian" ;;
            ubuntu)                             release="ubuntu" ;;
            centos|rhel|fedora|rocky|almalinux) release="centos" ;;
            *)
                case "${ID_LIKE:-}" in
                    *debian*)        release="debian" ;;
                    *rhel*|*fedora*) release="centos" ;;
                esac ;;
        esac
    fi
    [[ -z "$release" ]] && { OUT_ERROR "[错误] 不支持的系统"; exit 1; }
    OUT_INFO "[信息] 识别系统：${release} (${PRETTY_NAME:-unknown})"
}

detect_pm() {
    if [[ "$release" == "centos" ]]; then
        if command -v dnf >/dev/null; then
            PM_UPDATE="dnf makecache"; PM_INSTALL="dnf install -y"
        else
            PM_UPDATE="yum makecache"; PM_INSTALL="yum install -y"
        fi
    else
        PM_UPDATE="apt-get update"
        PM_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y"
    fi
}

check_location() {
    OUT_INFO "[信息] 检测服务器位置..."
    local info="" url
    for url in \
        "https://www.cloudflare.com/cdn-cgi/trace" \
        "https://ipapi.co/json/" \
        "https://ipinfo.io"; do
        info=$(curl -fsSL --max-time 5 "$url" 2>/dev/null) && [[ -n "$info" ]] && break
        info=""
    done
    if [[ -z "$info" ]]; then
        OUT_ALERT "[警告] 无法获取位置信息，按海外配置继续"
        return 0
    fi
    server_country=$(echo "$info" \
        | grep -oE 'loc=[A-Z]{2}|"country(_code)?"[^,}]*' \
        | grep -oE '[A-Z]{2}' | head -1)
    server_country="${server_country:-UNKNOWN}"
    if [[ "$server_country" == "CN" ]]; then
        is_in_china="true"
        OUT_INFO "[信息] 检测到服务器位于中国"
    else
        OUT_INFO "[信息] 服务器位置：${server_country}"
    fi
}

install_requirements() {
    OUT_INFO "[信息] 安装必要工具..."
    eval "$PM_UPDATE" >/dev/null 2>&1 || true

    # 核心包：必须装上（缺一报错继续）
    if [[ "$release" == "centos" ]]; then
        eval "$PM_INSTALL epel-release ca-certificates curl wget chrony" \
            || OUT_ALERT "[警告] 核心包安装失败，继续"
    else
        eval "$PM_INSTALL ca-certificates curl wget chrony" \
            || OUT_ALERT "[警告] 核心包安装失败，继续"
    fi

    # 优化包：分开装，任一失败不影响其他
    # irqbalance：硬件中断分散到多 CPU
    eval "$PM_INSTALL irqbalance" >/dev/null 2>&1 \
        && OUT_SUCCESS "[成功] irqbalance 安装完成" \
        || OUT_ALERT "[警告] irqbalance 安装失败"

    # cpufrequtils：CPU 频率管理（仅 Debian 系，且部分发行版可能没有）
    if [[ "$release" != "centos" ]]; then
        eval "$PM_INSTALL cpufrequtils" >/dev/null 2>&1 \
            && OUT_SUCCESS "[成功] cpufrequtils 安装完成" \
            || OUT_ALERT "[警告] cpufrequtils 安装失败（可能仓库无此包，仍可手动设 CPU governor）"
    fi
    if (( DO_UPGRADE == 1 )); then
        OUT_ALERT "[信息] 执行系统升级..."
        if [[ "$release" == "centos" ]]; then
            eval "${PM_INSTALL/install -y/update -y}" || true
        else
            DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y || true
            apt-get autoremove --purge -y || true
        fi
    fi
}

install_haveged_if_needed() {
    local kver
    kver=$(uname -r | awk -F. '{printf "%d%02d\n",$1,$2}')
    if (( kver < 506 )); then
        OUT_INFO "[信息] 内核 $(uname -r) 较旧，安装 haveged"
        eval "$PM_INSTALL haveged" 2>/dev/null || return 0
        systemctl enable --now haveged 2>/dev/null || true
    else
        OUT_INFO "[信息] 内核 $(uname -r) 熵池充足，跳过 haveged"
    fi
}

configure_resolved_dns() {
    mkdir -p /etc/systemd/resolved.conf.d
    if [[ "$is_in_china" == "true" ]]; then
        cat > "/etc/systemd/resolved.conf.d/${DROPIN}" << 'EOF'
[Resolve]
DNS=223.5.5.5 119.29.29.29 2400:3200::1
FallbackDNS=180.76.76.76
EOF
    else
        cat > "/etc/systemd/resolved.conf.d/${DROPIN}" << 'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8 2606:4700:4700::1111
FallbackDNS=9.9.9.9 208.67.222.222
EOF
    fi
    systemctl restart systemd-resolved 2>/dev/null || true
}

configure_dns() {
    (( SKIP_DNS == 1 )) && { OUT_INFO "[信息] 跳过 DNS 配置"; return 0; }
    OUT_INFO "[信息] 配置 DNS..."
    if [[ -L /etc/resolv.conf ]]; then
        local target; target=$(readlink -f /etc/resolv.conf 2>/dev/null || true)
        if [[ "$target" == *systemd* ]]; then
            OUT_INFO "[信息] 检测到 systemd-resolved，改写 resolved.conf.d"
            configure_resolved_dns
            OUT_SUCCESS "[成功] DNS 配置完成"
            return 0
        fi
        rm -f /etc/resolv.conf
    fi
    if [[ -f /etc/resolv.conf ]]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cp -a /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
    fi
    if [[ "$is_in_china" == "true" ]]; then
        cat > /etc/resolv.conf << 'EOF'
options timeout:2 attempts:3 rotate
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 2400:3200::1
EOF
    else
        cat > /etc/resolv.conf << 'EOF'
options timeout:2 attempts:3 rotate
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    fi
    if (( LOCK_DNS == 1 )); then
        chattr +i /etc/resolv.conf && OUT_ALERT "[警告] /etc/resolv.conf 已 chattr +i"
    fi
    OUT_SUCCESS "[成功] DNS 配置完成"
}

configure_ntp() {
    (( SKIP_NTP == 1 )) && { OUT_INFO "[信息] 跳过 NTP 配置"; return 0; }
    OUT_INFO "[信息] 配置 chrony 时间同步..."
    local conf=/etc/chrony.conf
    [[ -f /etc/chrony/chrony.conf ]] && conf=/etc/chrony/chrony.conf
    [[ -f "$conf" ]] && cp -a "$conf" "$BACKUP_DIR/$(basename "$conf").bak"
    if [[ "$is_in_china" == "true" ]]; then
        cat > "$conf" << 'EOF'
server ntp.aliyun.com iburst
server ntp.tencent.com iburst
server cn.ntp.org.cn iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
    else
        cat > "$conf" << 'EOF'
pool time.cloudflare.com iburst
pool time.google.com iburst
pool pool.ntp.org iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
    fi
    chmod 644 "$conf"
    systemctl enable --now chrony  2>/dev/null \
        || systemctl enable --now chronyd 2>/dev/null || true
    systemctl restart chrony  2>/dev/null \
        || systemctl restart chronyd 2>/dev/null || true
    OUT_SUCCESS "[成功] NTP 配置完成"
}

detect_bbr() {
    modprobe tcp_bbr 2>/dev/null || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        CC="bbr"; QDISC="fq"
        # 持久化：开机自动加载 tcp_bbr，避免重启后 sysctl 应用 bbr 失败回退 cubic
        mkdir -p /etc/modules-load.d
        echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf
        OUT_INFO "[信息] BBR 可用，使用 bbr + fq（已加入开机自动加载）"
    else
        OUT_ALERT "[警告] 内核不支持 BBR，使用 cubic + fq_codel"
    fi
}

# 配置 CPU governor = performance（让 CPU 不降频，减少 RTT 抖动）
configure_cpu_governor() {
    OUT_INFO "[信息] 配置 CPU governor = performance..."

    # 部分 VM（如 LXC）没有 cpufreq 子系统
    if [[ ! -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        OUT_ALERT "[警告] 系统不支持 cpufreq（VM 可能无 CPU 频率控制权），跳过"
        return 0
    fi

    # 持久化（cpufrequtils 启动时会读这个）
    if [[ -d /etc/default ]]; then
        cat > /etc/default/cpufrequtils <<'EOF'
GOVERNOR="performance"
EOF
    fi

    # 立即应用所有 CPU 核（[[ -f ]] 防 glob 没匹配时的字面路径问题）
    local applied=0
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$cpu" ]] || continue
        echo performance > "$cpu" 2>/dev/null && applied=$((applied+1))
    done

    # 重启 cpufrequtils 服务（如果存在）让设置在下次启动也生效
    systemctl enable cpufrequtils 2>/dev/null || true
    systemctl restart cpufrequtils 2>/dev/null || true

    local current
    current=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    if [[ "$current" == "performance" ]]; then
        OUT_SUCCESS "[成功] CPU governor = performance（共 $applied 核）"
    else
        OUT_ALERT "[警告] CPU governor 未生效，当前: $current"
    fi
}

# 配置 conntrack（仅 --relay 模式：中转机/NAT MASQUERADE 机器）
configure_conntrack() {
    OUT_INFO "[信息] 配置 conntrack（中转机模式）..."

    # 1. 加载 nf_conntrack 模块
    modprobe nf_conntrack 2>/dev/null || {
        OUT_ALERT "[警告] 无法加载 nf_conntrack 模块（可能内核不支持），跳过"
        return 0
    }

    # 2. 持久化模块加载
    mkdir -p /etc/modules-load.d
    echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf

    # 3. 写 sysctl drop-in（独立文件，方便单独管理）
    cat > /etc/sysctl.d/99-zzz-conntrack.conf <<'EOF'
# === conntrack 中转机优化 ===
# 表上限：1M 条目，约 300MB 内存（按需调整）
net.netfilter.nf_conntrack_max = 1048576

# TCP 已建立超时：默认 5 天太离谱，改 2 小时（与代理 keepalive 配合）
net.netfilter.nf_conntrack_tcp_timeout_established = 7440

# TIME_WAIT / FIN 超时：缩短，更快释放
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30

# UDP 流超时
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120

# 通用流超时
net.netfilter.nf_conntrack_generic_timeout = 600
EOF

    # 4. 设哈希桶大小（max/4，提升查找性能）
    # 这个不能 sysctl 改，要写 /sys/module/
    if [[ -f /sys/module/nf_conntrack/parameters/hashsize ]]; then
        echo 262144 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
    fi

    # 5. 持久化 hashsize（开机加载模块时生效）
    mkdir -p /etc/modprobe.d
    cat > /etc/modprobe.d/nf_conntrack.conf <<'EOF'
options nf_conntrack hashsize=262144
EOF

    # 6. 应用 sysctl
    sysctl --system >/dev/null 2>&1 || true

    # 验证
    local cur_max
    cur_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "0")
    if [[ "$cur_max" == "1048576" ]]; then
        OUT_SUCCESS "[成功] conntrack 调优已生效（max=$cur_max）"
    else
        OUT_ALERT "[警告] conntrack 配置可能未生效，当前 max=$cur_max"
    fi
}

# 配置 initcwnd / initrwnd（TCP 初始拥塞窗口）
# 默认 Linux=10（约 14KB），跨太平洋链路前几个 RTT 都在慢启动爬升
# 改 30 = Cloudflare/Google/Akamai 等主流 CDN 标准值，启动加速 30-40%
# GFW 角度：30 在合法 CDN 流量分布内，不会单独成为检测特征
#
# 实现：不在 systemd ExecStart 内嵌复杂 shell（避免 $VAR / $$ / 转义混淆）
# 改用独立 helper 脚本 /usr/local/sbin/set-initcwnd.sh，systemd 只负责调用它
configure_initcwnd() {
    OUT_INFO "[信息] 配置 initcwnd / initrwnd = 30..."

    # 探测默认路由（仅用于本次启动时的"立即生效"）
    local DEV GW
    DEV=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    GW=$(ip route show default 2>/dev/null | awk '/^default/ {print $3; exit}')

    if [[ -z "$DEV" || -z "$GW" ]]; then
        OUT_ALERT "[警告] 找不到 IPv4 默认路由（DEV=$DEV GW=$GW），跳过 initcwnd 配置"
        return 0
    fi

    OUT_INFO "[信息] 默认路由：${DEV} via ${GW}"

    # 立刻应用（重启前生效）
    if ip route change default via "$GW" dev "$DEV" initcwnd 30 initrwnd 30 2>/dev/null; then
        OUT_SUCCESS "[成功] 立即生效：initcwnd=30 initrwnd=30"
    else
        OUT_ALERT "[警告] ip route change 失败（可能 hypervisor 限制），仍继续持久化"
    fi

    # === 写 helper 脚本 ===（重启时 systemd 调用它，自动重新探测路由）
    mkdir -p /usr/local/sbin
    cat > /usr/local/sbin/set-initcwnd.sh <<'HELPER_EOF'
#!/bin/bash
# Auto-generated by optimize.sh — set TCP initcwnd/initrwnd=30 on default route
# 由 initcwnd.service 在 boot 时调用；运行时重新探测 DEV/GW，应对网卡名变化
set -u

# 显式 PATH（防容器/精简系统 systemd 环境 PATH 异常）
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# 强制 C locale（避免 ip 输出被本地化干扰，虽然 awk 正则不受影响，纯保险）
export LC_ALL=C

# 重试拿默认路由（boot race 时 network-online.target 早于路由刷新的极少数情况）
DEV=""; GW=""
for i in 1 2 3 4 5; do
    DEV=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    GW=$(ip route show default 2>/dev/null | awk '/^default/ {print $3; exit}')
    [[ -n "$DEV" && -n "$GW" ]] && break
    sleep 1
done

if [[ -z "$DEV" || -z "$GW" ]]; then
    echo "[set-initcwnd] no default route after 5s, skipping" >&2
    exit 0
fi

# 优先 change（保留现有 metric/proto 等属性）
if ip route change default via "$GW" dev "$DEV" initcwnd 30 initrwnd 30 2>/dev/null; then
    echo "[set-initcwnd] OK: initcwnd=30 initrwnd=30 on $DEV via $GW" >&2
    exit 0
fi

# fallback: replace（应对某些 ip 实现 change 不接受新参数的边缘情况）
if ip route replace default via "$GW" dev "$DEV" initcwnd 30 initrwnd 30 2>/dev/null; then
    echo "[set-initcwnd] OK (replace): initcwnd=30 initrwnd=30 on $DEV via $GW" >&2
    exit 0
fi

echo "[set-initcwnd] both change/replace failed on $DEV via $GW, route unchanged" >&2
# 不返回失败，避免 service 进入 failed 状态（也不会触发 systemd 警报）
exit 0
HELPER_EOF
    chmod 755 /usr/local/sbin/set-initcwnd.sh
    OUT_INFO "[信息] helper 已写入 /usr/local/sbin/set-initcwnd.sh"

    # === 写 systemd service ===（用 'EOF' 防止任何 shell 扩展）
    cat > /etc/systemd/system/initcwnd.service <<'EOF'
[Unit]
Description=Set TCP initcwnd/initrwnd to 30 on default route
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/set-initcwnd.sh

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload 2>/dev/null || true
    if systemctl enable initcwnd.service >/dev/null 2>&1; then
        OUT_SUCCESS "[成功] initcwnd.service 已启用（重启自动应用）"
    else
        OUT_ALERT "[警告] systemctl enable initcwnd.service 失败"
    fi

    # 验证当前路由
    local current
    current=$(ip route show default 2>/dev/null | grep -oE 'initcwnd [0-9]+' | head -1 | awk '{print $2}')
    if [[ "$current" == "30" ]]; then
        OUT_SUCCESS "[成功] 当前 initcwnd 已是 30"
    else
        OUT_ALERT "[警告] 当前 initcwnd=${current:-未设置}（重启后 systemd 会再尝试）"
    fi
}

# 配置 NIC 优化（offloads + ring buffer）
# - TSO/GSO: 让 NIC/内核做 TCP 分段，CPU 利用率降 20-30%
# - GRO: 接收侧软件合并小包，减少中断处理开销
# - LRO: 必须关闭（硬件合并破坏 forwarding 的 TCP 状态，代理场景禁用）
# - Ring buffer: 调到 NIC 支持的最大值（高 pps 突发场景防 NIC drop）
#
# GFW 角度：NIC 层调优在网络栈底层，对外完全不可见，0 检测风险
configure_nic_tuning() {
    OUT_INFO "[信息] 配置 NIC offloads + ring buffer..."

    # 探测主网卡
    local DEV
    DEV=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')

    if [[ -z "$DEV" ]]; then
        OUT_ALERT "[警告] 找不到默认网卡，跳过 NIC 调优"
        return 0
    fi

    # 确保 ethtool 装上
    if ! command -v ethtool >/dev/null 2>&1; then
        eval "$PM_INSTALL ethtool" >/dev/null 2>&1 \
            && OUT_INFO "[信息] ethtool 已补装"
    fi
    if ! command -v ethtool >/dev/null 2>&1; then
        OUT_ALERT "[警告] ethtool 不可用，跳过 NIC 调优"
        return 0
    fi

    OUT_INFO "[信息] 主网卡: $DEV"

    # === 立刻应用 offloads ===
    local applied_on=0
    for feat in tso gso gro; do
        if ethtool -K "$DEV" "$feat" on 2>/dev/null; then
            applied_on=$((applied_on + 1))
        fi
    done
    # LRO 必须关（代理转发会破坏 TCP 状态）
    ethtool -K "$DEV" lro off 2>/dev/null || true
    OUT_SUCCESS "[成功] NIC $DEV offloads: tso/gso/gro=on (启用 $applied_on/3), lro=off"

    # === 立刻应用 ring buffer 最大值 ===
    local rx_max tx_max
    rx_max=$(ethtool -g "$DEV" 2>/dev/null | awk '/^RX:/ {n++; if(n==1) {print $2; exit}}')
    tx_max=$(ethtool -g "$DEV" 2>/dev/null | awk '/^TX:/ {n++; if(n==1) {print $2; exit}}')

    if [[ -n "$rx_max" && "$rx_max" =~ ^[0-9]+$ && "$rx_max" -gt 0 ]]; then
        if ethtool -G "$DEV" rx "$rx_max" 2>/dev/null; then
            OUT_SUCCESS "[成功] NIC $DEV RX ring buffer = $rx_max (max)"
        else
            OUT_ALERT "[警告] NIC $DEV RX ring buffer 调整失败（虚拟网卡常见）"
        fi
    else
        OUT_INFO "[信息] NIC $DEV 不支持 RX ring buffer 配置（virtio/某些 KVM 网卡）"
    fi

    if [[ -n "$tx_max" && "$tx_max" =~ ^[0-9]+$ && "$tx_max" -gt 0 ]]; then
        if ethtool -G "$DEV" tx "$tx_max" 2>/dev/null; then
            OUT_SUCCESS "[成功] NIC $DEV TX ring buffer = $tx_max (max)"
        fi
    fi

    # === 写 helper 脚本（重启时 systemd 调用，自动重新应用）===
    mkdir -p /usr/local/sbin
    cat > /usr/local/sbin/set-nic-tuning.sh <<'HELPER_EOF'
#!/bin/bash
# Auto-generated by optimize.sh — NIC offloads + ring buffer max
# 由 nic-tuning.service 在 boot 时调用；运行时重新探测 DEV
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

# 重试拿主网卡
DEV=""
for i in 1 2 3 4 5; do
    DEV=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    [[ -n "$DEV" ]] && break
    sleep 1
done

if [[ -z "$DEV" ]]; then
    echo "[set-nic-tuning] no default NIC after 5s, skipping" >&2
    exit 0
fi

if ! command -v ethtool >/dev/null 2>&1; then
    echo "[set-nic-tuning] ethtool not found, skipping" >&2
    exit 0
fi

# Offloads（每个独立 try，部分网卡只支持一部分）
for feat in tso gso gro; do
    ethtool -K "$DEV" "$feat" on 2>/dev/null || true
done
ethtool -K "$DEV" lro off 2>/dev/null || true

# Ring buffer max
rx_max=$(ethtool -g "$DEV" 2>/dev/null | awk '/^RX:/ {n++; if(n==1) {print $2; exit}}')
tx_max=$(ethtool -g "$DEV" 2>/dev/null | awk '/^TX:/ {n++; if(n==1) {print $2; exit}}')

if [[ -n "$rx_max" && "$rx_max" =~ ^[0-9]+$ && "$rx_max" -gt 0 ]]; then
    ethtool -G "$DEV" rx "$rx_max" 2>/dev/null || true
fi
if [[ -n "$tx_max" && "$tx_max" =~ ^[0-9]+$ && "$tx_max" -gt 0 ]]; then
    ethtool -G "$DEV" tx "$tx_max" 2>/dev/null || true
fi

echo "[set-nic-tuning] applied to $DEV (rx_max=$rx_max tx_max=$tx_max)" >&2
exit 0
HELPER_EOF
    chmod 755 /usr/local/sbin/set-nic-tuning.sh
    OUT_INFO "[信息] helper 已写入 /usr/local/sbin/set-nic-tuning.sh"

    # === 写 systemd service ===
    cat > /etc/systemd/system/nic-tuning.service <<'EOF'
[Unit]
Description=NIC offloads (TSO/GSO/GRO on, LRO off) and ring buffer max
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/set-nic-tuning.sh

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload 2>/dev/null || true
    if systemctl enable nic-tuning.service >/dev/null 2>&1; then
        OUT_SUCCESS "[成功] nic-tuning.service 已启用（重启自动应用）"
    else
        OUT_ALERT "[警告] systemctl enable nic-tuning.service 失败"
    fi
}

# 配置 irqbalance（自动分散硬件中断到多 CPU）
configure_irqbalance() {
    OUT_INFO "[信息] 配置 irqbalance..."

    # 多重检测（systemctl cat 比 list-unit-files 更可靠）
    local has_irqbalance=0
    if systemctl cat irqbalance.service >/dev/null 2>&1; then
        has_irqbalance=1
    elif command -v irqbalance >/dev/null 2>&1; then
        has_irqbalance=1
    elif [[ -f /lib/systemd/system/irqbalance.service \
         || -f /etc/systemd/system/irqbalance.service \
         || -f /usr/lib/systemd/system/irqbalance.service ]]; then
        has_irqbalance=1
    fi

    # 没装就最后尝试装一次
    if [[ $has_irqbalance -eq 0 ]]; then
        OUT_ALERT "[警告] 未检测到 irqbalance，尝试现在安装..."
        eval "$PM_INSTALL irqbalance" >/dev/null 2>&1 || true
        if systemctl cat irqbalance.service >/dev/null 2>&1 \
            || command -v irqbalance >/dev/null 2>&1; then
            has_irqbalance=1
            OUT_SUCCESS "[成功] irqbalance 已补装"
        else
            OUT_ERROR "[错误] irqbalance 安装失败，跳过中断分散"
            OUT_ERROR "[排查] 手动跑 'apt-get install -y irqbalance' 看具体报错"
            return 1
        fi
    fi

    # 启动 + 持久化
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable irqbalance 2>/dev/null || true
    systemctl restart irqbalance 2>/dev/null || true

    if systemctl is-active --quiet irqbalance; then
        OUT_SUCCESS "[成功] irqbalance 运行中"
    else
        OUT_ALERT "[警告] irqbalance 启动失败，看 'journalctl -u irqbalance' 排查"
    fi
}

optimize_system() {
    OUT_INFO "[信息] 优化系统参数..."
    detect_bbr
    local ipv6=0; [[ -d /proc/sys/net/ipv6 ]] && ipv6=1

    # 备份原配置
    [[ -f /etc/sysctl.conf ]]          && cp -a /etc/sysctl.conf          "$BACKUP_DIR/sysctl.conf.bak"
    [[ -f /etc/security/limits.conf ]] && cp -a /etc/security/limits.conf "$BACKUP_DIR/limits.conf.bak"

    # --- 关键：清空 /etc/sysctl.conf，否则 `sysctl --system` 会把它作为最终文件覆盖 drop-in ---
    if [[ -f /etc/sysctl.conf ]]; then
        chattr -i /etc/sysctl.conf 2>/dev/null || true
        cat > /etc/sysctl.conf << EOF
# 已由 optimize.sh 清空 ($(date '+%F %T'))
# 所有配置移至 /etc/sysctl.d/${DROPIN}
# 原内容备份：$BACKUP_DIR/sysctl.conf.bak
EOF
        OUT_INFO "[信息] /etc/sysctl.conf 已清空（原内容已备份）"
    fi

    # --- 清掉常见的旧优化脚本残留 drop-in（可选，避免字典序靠前的文件干扰）---
    for stale in \
        /etc/sysctl.d/99-proxy.conf \
        /etc/sysctl.d/99-optimize.conf \
        /etc/sysctl.d/99-bbr.conf; do
        if [[ -f "$stale" ]]; then
            mv "$stale" "$BACKUP_DIR/$(basename "$stale").bak"
            OUT_INFO "[信息] 移除旧 drop-in: $stale"
        fi
    done

    # --- sysctl drop-in ---
    cat > "/etc/sysctl.d/${DROPIN}" << EOF
# --- memory / fs ---
vm.swappiness = 10
vm.overcommit_memory = 1
fs.file-max = 1048576
fs.nr_open = 1048576
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288

# --- socket buffer (TCP + UDP 共享) ---
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
# 单 socket 上限 64MB：覆盖 1Gbps × 500ms RTT 的 BDP（50MB），余量 28%
# 千兆 + 极端 RTT(>500ms) + 严重丢包的极少数用户略受限，对 99%+ 用户无感
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.optmem_max = 65536
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 65535
net.core.default_qdisc = ${QDISC}

# --- TCP buffer ---
# rmem/wmem 三档：MIN=4K / DEFAULT=1M / MAX=64M
# default=1M 给每个新连接立刻分配；max=64M 已覆盖跨国 BDP，避免 4GB 小机器被单连接吃爆
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.tcp_moderate_rcvbuf = 1
# tcp_mem 全局 TCP 内存池上限：1G/2G/3G（按"主资源给 TCP"思路，给 TCP 留 75% 内存）
# 注意：4GB 机器跑这个配置已是极限，建议 8GB+，否则需配合 swap 防 OOM
net.ipv4.tcp_mem = 262144 524288 786432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# --- TCP 连接管理 ---
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 1048576
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_orphan_retries = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# --- TCP 性能 ---
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 0
# 高丢包链路下，允许更多包乱序而不误判为丢包（默认 3 → 6）
net.ipv4.tcp_reordering = 6
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 1
# AccECN（精确 ECN）关闭：跨国链路多数路由器不支持 ECN 标记，AccECN 实际收益≈0
# 但其 SYN 包带 AE 比特，在中国流量中罕见，可能增加 GFW 流量识别评分
net.ipv4.tcp_ecn_option = 0
net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_congestion_control = ${CC}

# --- 路由加固 ---
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

# --- 转发 ---
net.ipv4.ip_forward = 1
EOF

    if (( ipv6 == 1 )); then
        cat >> "/etc/sysctl.d/${DROPIN}" << 'EOF'
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
EOF
    fi

    # 应用 sysctl 并捕获错误（不要吞掉 stderr，方便排查到底哪个参数失败）
    local sysctl_out
    sysctl_out=$(sysctl --system 2>&1)
    if echo "$sysctl_out" | grep -qiE 'error|invalid argument|cannot|denied|no such file'; then
        OUT_ALERT "[警告] sysctl 应用存在错误，详情如下："
        echo "$sysctl_out" | grep -iE 'error|invalid argument|cannot|denied|no such file' | tee -a "$LOG_FILE"
    fi

    # --- limits drop-in ---
    cat > "/etc/security/limits.d/${DROPIN}" << 'EOF'
*    soft nofile 1048576
*    hard nofile 1048576
*    soft nproc  65535
*    hard nproc  65535
root soft nofile 1048576
root hard nofile 1048576
EOF

    if [[ -f /etc/pam.d/common-session ]] \
       && ! grep -q 'pam_limits.so' /etc/pam.d/common-session; then
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    fi

    # --- systemd 服务/用户全局 FD 上限 ---
    mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
    cat > "/etc/systemd/system.conf.d/${DROPIN}" << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF
    cp -f "/etc/systemd/system.conf.d/${DROPIN}" "/etc/systemd/user.conf.d/${DROPIN}"

    # --- v2node service 级 drop-in：防止 service 文件硬编码 LimitNOFILE 覆盖全局设置 ---
    # 用 systemctl cat 比 list-unit-files 可靠（后者偶尔不显示新装的服务）
    if systemctl cat v2node.service >/dev/null 2>&1 \
        || command -v v2node >/dev/null 2>&1; then
        mkdir -p /etc/systemd/system/v2node.service.d
        cat > "/etc/systemd/system/v2node.service.d/${DROPIN}" << 'EOF'
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
EOF
        OUT_INFO "[信息] 已为 v2node.service 写入 FD 上限 drop-in"
    fi

    # --- 让 systemd 重新加载自身配置（DefaultLimitNOFILE 立刻生效）---
    systemctl daemon-reexec 2>/dev/null && OUT_INFO "[信息] systemd daemon-reexec 完成" || true

    # --- 如果 v2node 在跑，重启它让新的 LimitNOFILE 立刻生效 ---
    if systemctl is-active --quiet v2node 2>/dev/null; then
        OUT_INFO "[信息] 重启 v2node 应用新 FD 上限..."
        systemctl daemon-reload 2>/dev/null || true
        if systemctl restart v2node 2>/dev/null; then
            sleep 2
            if systemctl is-active --quiet v2node; then
                OUT_SUCCESS "[成功] v2node 已重启并运行"
            else
                OUT_ALERT "[警告] v2node 重启后未运行，请检查 journalctl -u v2node -n 30"
            fi
        else
            OUT_ALERT "[警告] v2node 重启失败"
        fi
    fi

    # --- journald drop-in ---
    mkdir -p /etc/systemd/journald.conf.d
    cat > "/etc/systemd/journald.conf.d/${DROPIN}" << 'EOF'
[Journal]
SystemMaxUse=384M
SystemMaxFileSize=128M
ForwardToSyslog=no
EOF
    systemctl restart systemd-journald 2>/dev/null || true

    OUT_SUCCESS "[成功] 系统参数优化完成"
}

verify_optimization() {
    OUT_INFO "[信息] 核对关键参数生效情况："
    local k v expected pass=0 fail=0
    declare -A expect=(
        [net.ipv4.tcp_congestion_control]="${CC}"
        [net.core.default_qdisc]="${QDISC}"
        [net.ipv4.tcp_max_tw_buckets]="1048576"
        [vm.swappiness]="10"
        [net.ipv4.ip_forward]="1"
        [net.core.rmem_max]="67108864"
        [net.ipv4.tcp_slow_start_after_idle]="0"
        [net.ipv4.tcp_mem]="262144 524288 786432"
    )
    for k in "${!expect[@]}"; do
        expected="${expect[$k]}"
        # 用 awk 规范化所有空白字符（tab/多空格）为单空格，避免 tcp_mem 这种用 tab 分隔的多值参数比较失败
        v=$(sysctl -n "$k" 2>/dev/null | awk '{$1=$1; print}')
        if [[ "$v" == "$expected" ]]; then
            OUT_SUCCESS "  ✓ $k = $v"
            ((pass++))
        else
            OUT_ERROR "  ✗ $k = $v (期望 $expected)"
            ((fail++))
        fi
    done
    OUT_INFO "[信息] 通过 ${pass} 项，失败 ${fail} 项"
    if (( fail > 0 )); then
        OUT_ALERT "[排查] 运行: grep -rE 'tcp_congestion_control|default_qdisc|swappiness|rmem_max|tw_buckets' /etc/sysctl.conf /etc/sysctl.d/ /usr/lib/sysctl.d/ /run/sysctl.d/ 2>/dev/null"
    fi
}

main() {
    mkdir -p "$BACKUP_DIR"
    touch "$LOG_FILE"
    OUT_INFO "====== 服务器优化开始 $(date '+%F %T') ======"
    OUT_INFO "[信息] 备份目录：$BACKUP_DIR"
    OUT_INFO "[信息] drop-in 文件名：${DROPIN}"
    if (( RELAY_MODE == 1 )); then
        OUT_INFO "[模式] 中转机（--relay）：会启用 conntrack 调优"
    else
        OUT_INFO "[模式] v2node 节点机（默认）：跳过 conntrack（如果是中转请加 --relay）"
    fi

    check_root
    check_system
    detect_pm
    check_location
    install_requirements
    install_haveged_if_needed
    configure_dns
    configure_ntp
    optimize_system
    configure_cpu_governor
    configure_irqbalance
    configure_initcwnd
    configure_nic_tuning

    # --relay 模式额外做 conntrack 调优（中转/NAT 机器专用）
    if (( RELAY_MODE == 1 )); then
        OUT_INFO "[信息] 检测到 --relay 参数，启用中转机模式"
        configure_conntrack
    fi

    verify_optimization

    OUT_SUCCESS "====== 优化完成 ======"
    OUT_INFO "[信息] DefaultLimitNOFILE 已 daemon-reexec 生效；v2node 已自动重启（如在运行）"
    OUT_INFO "[信息] 其他 systemd 服务如需新 FD 上限，请手动 systemctl restart"
    OUT_INFO "[信息] BBR 模块已加入 /etc/modules-load.d/，重启后自动加载"
    OUT_INFO "[信息] initcwnd=30 已设置（systemd: initcwnd.service，重启自动应用）"
    OUT_INFO "[信息] NIC offloads + ring buffer max 已设置（systemd: nic-tuning.service）"
    OUT_INFO "[信息] 日志：$LOG_FILE"
    OUT_INFO "[信息] 备份：$BACKUP_DIR"
}

main "$@"

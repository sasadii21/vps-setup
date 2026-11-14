#!/usr/bin/env bash
# =============================================================================
#  Node Optimizer v5 (Enterprise / High-Throughput Edition)
#  مخصوص پروکسی تلگرام، xray، sing-box، mtg، hiddify و ترافیک همزمان بالا
#
#  اجرا:                    sudo bash node-optimizer-v5.sh
#  غیرفعال کردن IPv6:       sudo DISABLE_IPV6=1 bash node-optimizer-v5.sh
#  ری‌استارت خودکار سرویس‌ها: sudo RESTART_SERVICES=1 bash node-optimizer-v5.sh
#  غیرفعال کردن ساخت Swap:  sudo AUTO_SWAP=0 bash node-optimizer-v5.sh
#  حذف کامل تغییرات:        sudo bash node-optimizer-v5.sh --uninstall
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

readonly VERSION=5
readonly BACKUP_DIR="/root/node-optimizer-backup-$(date +%Y%m%d-%H%M%S)"
readonly SYSCTL_MAIN=/etc/sysctl.d/99-xray-optimize.conf
readonly SYSCTL_IPV6=/etc/sysctl.d/98-xray-ipv6.conf
readonly NET_SCRIPT=/usr/local/sbin/xray-net-tweaks.sh
readonly NET_UNIT=/etc/systemd/system/xray-net-tweaks.service
readonly MODULES_FILE=/etc/modules-load.d/optimizer-modules.conf
readonly JOURNAL_FILE=/etc/systemd/journald.conf.d/size.conf
readonly LIMITS_FILE=/etc/security/limits.d/99-xray.conf
readonly SYSTEMD_LIMITS=/etc/systemd/system.conf.d/99-limits.conf

DISABLE_IPV6="${DISABLE_IPV6:-0}"
RESTART_SERVICES="${RESTART_SERVICES:-${RESTART_XRAY:-0}}"
AUTO_SWAP="${AUTO_SWAP:-1}"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
info(){ printf '%s➜%s %s\n' "$C" "$N" "$*"; }
ok(){   printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s⚠%s %s\n' "$Y" "$N" "$*"; }
die(){  printf '%s✖%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
trap 'warn "خطا در خط ${LINENO}: ${BASH_COMMAND}"' ERR

[ "${EUID:-$(id -u)}" -eq 0 ] || die "این اسکریپت باید با دسترسی root اجرا شود."

# سرویس‌های هدف (پروکسی + وب‌سرور + تانل)
readonly TARGET_SERVICES=(
    xray x-ui 3x-ui marzban pasarguard sing-box hiddify
    docker containerd nginx haproxy caddy
    backhaul gost mtg wg-quick@wg0
)

CHANGED=0

backup_file() {
    [ -e "$1" ] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$1" "$BACKUP_DIR/$(echo "$1" | tr '/' '_')"
}

write_file() {
    local path=$1 mode=${2:-0644} tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"; return 0
    fi
    mkdir -p "$(dirname "$path")"
    backup_file "$path"
    install -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
    CHANGED=1
}

detect_pm() {
    if   command -v apt-get >/dev/null 2>&1; then PM=apt
    elif command -v dnf     >/dev/null 2>&1; then PM=dnf
    elif command -v yum     >/dev/null 2>&1; then PM=yum
    elif command -v pacman  >/dev/null 2>&1; then PM=pacman
    else PM=none; fi
}

pm_update() {
    case "$PM" in
        apt)     apt-get update -qq >/dev/null 2>&1 ;;
        dnf|yum) "$PM" makecache -q >/dev/null 2>&1 ;;
        pacman)  pacman -Sy --noconfirm >/dev/null 2>&1 ;;
        *)       return 1 ;;
    esac
}

pm_install() {
    case "$PM" in
        apt)     apt-get install -y -qq "$@" >/dev/null 2>&1 ;;
        dnf|yum) "$PM" install -y -q "$@" >/dev/null 2>&1 ;;
        pacman)  pacman -S --noconfirm --needed "$@" >/dev/null 2>&1 ;;
        *)       return 1 ;;
    esac
}

# ---------------------------------------------------------
# حالت حذف (--uninstall)
# ---------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
    info "حذف تنظیمات Node Optimizer v${VERSION}..."
    systemctl disable --now xray-net-tweaks.service >/dev/null 2>&1 || true
    rm -f "$NET_UNIT" "$NET_SCRIPT" "$SYSCTL_MAIN" "$SYSCTL_IPV6" \
          "$MODULES_FILE" /etc/modules-load.d/bbr.conf \
          "$JOURNAL_FILE" "$LIMITS_FILE" "$SYSTEMD_LIMITS"
    for u in "${TARGET_SERVICES[@]}"; do
        rm -f "/etc/systemd/system/${u}.service.d/limits.conf"
        rmdir --ignore-fail-on-non-empty "/etc/systemd/system/${u}.service.d" 2>/dev/null || true
    done
    systemctl daemon-reload
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true
    ok "تمامی فایل‌های بهینه‌ساز حذف شدند. برای بازگشت کامل، سرور را ریبوت کنید."
    exit 0
fi

# ---------------------------------------------------------
# تشخیص سخت‌افزار
# ---------------------------------------------------------
detect_pm
VIRT=$(systemd-detect-virt 2>/dev/null || echo none)
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
CPUS=$(nproc)
KERNEL=$(uname -r)

info "شروع بهینه‌سازی نسخه ${VERSION} | مدیر بسته: ${PM} | مجازی‌سازی: ${VIRT}"
info "سخت‌افزار: ${CPUS} هسته | ${MEM_MB} مگابایت رم | کرنل: ${KERNEL}"

[ "$PM" != "none" ] && { pm_update || warn "بروزرسانی مخازن ناموفق بود؛ ادامه می‌دهیم."; }

case "$VIRT" in
    lxc|docker|podman|openvz|systemd-nspawn)
        warn "محیط کانتینری تشخیص داده شد؛ برخی تنظیمات سطح کرنل توسط هاست محدود می‌شوند." ;;
esac

info "نصب ابزارهای ضروری شبکه..."
pm_install iproute2 ethtool irqbalance conntrack iptables || true
systemctl enable --now irqbalance >/dev/null 2>&1 || true

# ---------------------------------------------------------
# ۱. همگام‌سازی زمان
# ---------------------------------------------------------
info "تنظیم همگام‌سازی زمان (Chrony)..."
if pm_install chrony; then
    systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
    systemctl enable --now chrony >/dev/null 2>&1 \
        || systemctl enable --now chronyd >/dev/null 2>&1 \
        || warn "سرویس chrony فعال نشد."
    chronyc makestep >/dev/null 2>&1 || true
    ok "زمان سرور با Chrony همگام‌سازی شد."
else
    warn "نصب chrony ممکن نشد."
fi

# ---------------------------------------------------------
# ۲. Swap هوشمند
# ---------------------------------------------------------
if [ "$AUTO_SWAP" = "1" ] && [ "$VIRT" != "openvz" ] && [ "$VIRT" != "lxc" ]; then
    SWAP_TOTAL=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
    if [ "${SWAP_TOTAL:-0}" -eq 0 ] && [ ! -f /swapfile ]; then
        FREE_DISK_MB=$(df -m / | awk 'NR==2 {print $4}')
        if [ "${FREE_DISK_MB:-0}" -gt 6144 ]; then
            info "ساخت 2GB Swap برای پایداری..."
            if fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; then
                chmod 600 /swapfile
                mkswap /swapfile >/dev/null 2>&1
                swapon /swapfile >/dev/null 2>&1 || true
                grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
                ok "Swap 2GB ساخته و فعال شد."
            fi
        fi
    else
        ok "Swap از قبل فعال است."
    fi
fi

# ---------------------------------------------------------
# ۳. محدودیت‌های File Descriptor و Process
# ---------------------------------------------------------
info "افزایش سقف File Descriptor و Process Limit..."

write_file "$LIMITS_FILE" <<'EOF'
*    soft nofile  2097152
*    hard nofile  2097152
root soft nofile  2097152
root hard nofile  2097152
*    soft nproc   131072
*    hard nproc   131072
root soft nproc   unlimited
root hard nproc   unlimited
*    soft memlock unlimited
*    hard memlock unlimited
EOF

write_file "$SYSTEMD_LIMITS" <<'EOF'
[Manager]
DefaultLimitNOFILE=2097152
DefaultLimitNPROC=131072
DefaultLimitMEMLOCK=infinity
EOF

ulimit -n 2097152 2>/dev/null || true

MODIFIED_UNITS=()
for u in "${TARGET_SERVICES[@]}"; do
    if systemctl cat "${u}.service" >/dev/null 2>&1; then
        CHANGED=0
        write_file "/etc/systemd/system/${u}.service.d/limits.conf" <<'EOF'
[Service]
LimitNOFILE=2097152
LimitNPROC=131072
LimitMEMLOCK=infinity
EOF
        if [ "$CHANGED" -eq 1 ]; then MODIFIED_UNITS+=("${u}.service"); fi
    fi
done
systemctl daemon-reload
ok "محدودیت منابع سیستم و سرویس‌ها به حداکثر ارتقا یافت."

# ---------------------------------------------------------
# ۴. ماژول‌ها و Sysctl پیشرفته (اسکیل بر اساس RAM)
# ---------------------------------------------------------
info "بارگذاری ماژول‌ها و اعمال تنظیمات Sysctl پیشرفته..."

for mod in tcp_bbr sch_fq nf_conntrack; do
    modprobe "$mod" 2>/dev/null || true
done

# انتخاب بهترین الگوریتم ازدحام
CC=cubic
if grep -qw bbr2 /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    CC=bbr2
elif grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    CC=bbr
fi

if [ "$CC" != "cubic" ]; then
    write_file "$MODULES_FILE" <<'EOF'
tcp_bbr
sch_fq
nf_conntrack
EOF
else
    warn "BBR/BBRv2 در این کرنل موجود نیست → از cubic استفاده می‌شود."
fi

# اسکیل بافرها و conntrack بر اساس مقدار رم
if   [ "$MEM_MB" -ge 16384 ]; then
    RMEM_MAX=134217728; WMEM_MAX=134217728; CT_MAX=2097152; SOMAX=65536
elif [ "$MEM_MB" -ge 8192 ]; then
    RMEM_MAX=67108864;  WMEM_MAX=67108864;  CT_MAX=1048576; SOMAX=49152
elif [ "$MEM_MB" -ge 4096 ]; then
    RMEM_MAX=33554432;  WMEM_MAX=33554432;  CT_MAX=524288;  SOMAX=32768
else
    RMEM_MAX=16777216;  WMEM_MAX=16777216;  CT_MAX=262144;  SOMAX=16384
fi

CHANGED=0
write_file "$SYSCTL_MAIN" <<EOF
# --- Congestion Control ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${CC}

# --- High-Throughput Buffers (TCP + UDP) ---
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.optmem_max = 131072
net.ipv4.tcp_rmem = 4096 262144 ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 262144 ${WMEM_MAX}
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_notsent_lowat = 16384

# --- NIC & SoftIRQ Budget ---
net.core.netdev_max_backlog = 65536
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.somaxconn = ${SOMAX}
net.core.busy_poll = 50
net.core.busy_read = 50

# --- TCP Connection Optimization ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 8
net.ipv4.tcp_max_tw_buckets = 500000
net.ipv4.tcp_max_syn_backlog = ${SOMAX}
net.ipv4.tcp_max_orphans = 131072
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_ecn = 0
net.ipv4.ip_local_port_range = 1024 65535

# --- Keepalive (سریع‌تر برای موبایل) ---
net.ipv4.tcp_keepalive_time = 180
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5

# --- Neighbor / ARP ---
net.ipv4.neigh.default.gc_thresh1 = 2048
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

# --- Memory & FS ---
fs.file-max = 4194304
fs.nr_open = 4194304
vm.swappiness = 5
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 1
vm.min_free_kbytes = 65536

# --- Security ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
kernel.panic = 10
kernel.pid_max = 4194304
EOF

sysctl -e -p "$SYSCTL_MAIN" >/dev/null 2>&1 || warn "برخی کلیدهای sysctl اعمال نشدند."

# IPv6
if [ "$DISABLE_IPV6" = "1" ]; then
    write_file "$SYSCTL_IPV6" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl -e -p "$SYSCTL_IPV6" >/dev/null 2>&1 || true
    ok "IPv6 غیرفعال شد."
elif [ -f "$SYSCTL_IPV6" ]; then
    backup_file "$SYSCTL_IPV6"
    rm -f "$SYSCTL_IPV6"
    sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 \
               net.ipv6.conf.lo.disable_ipv6=0 2>/dev/null || true
    info "IPv6 مجدداً فعال شد."
fi

ok "تنظیمات کرنل اعمال شد (Congestion: ${CC} | rmem_max: ${RMEM_MAX})"

# ---------------------------------------------------------
# ۵. سرویس ماندگار بهینه‌سازی کارت شبکه + Conntrack + RPS/XPS
# ---------------------------------------------------------
info "ساخت سرویس بهینه‌ساز سخت‌افزاری کارت شبکه..."

write_file "$NET_SCRIPT" 0755 <<'EOF_TWEAKS'
#!/usr/bin/env bash
set -u

# ۱. Mangle + DROP INVALID
if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -C INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null \
        || iptables -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
fi

if command -v ip6tables >/dev/null 2>&1 && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = "0" ]; then
    ip6tables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || ip6tables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ip6tables -C INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null \
        || ip6tables -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
fi

# ۲. Conntrack هوشمند بر اساس RAM
modprobe nf_conntrack 2>/dev/null || true
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if   [ "${MEM_MB:-0}" -ge 16384 ]; then CT_MAX=2097152
elif [ "${MEM_MB:-0}" -ge 8192 ];  then CT_MAX=1048576
elif [ "${MEM_MB:-0}" -ge 4096 ];  then CT_MAX=524288
else CT_MAX=262144; fi
CT_HASH=$(( CT_MAX / 4 ))

[ -w /sys/module/nf_conntrack/parameters/hashsize ] && \
    echo "$CT_HASH" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true

sysctl -e -qw \
    net.netfilter.nf_conntrack_max="$CT_MAX" \
    net.netfilter.nf_conntrack_tcp_timeout_established=7200 \
    net.netfilter.nf_conntrack_tcp_timeout_time_wait=20 \
    net.netfilter.nf_conntrack_tcp_timeout_fin_wait=20 \
    net.netfilter.nf_conntrack_tcp_timeout_close_wait=15 \
    net.netfilter.nf_conntrack_tcp_timeout_syn_received=20 \
    net.netfilter.nf_conntrack_udp_timeout=30 \
    net.netfilter.nf_conntrack_udp_timeout_stream=180 2>/dev/null || true

# ۳. بهینه‌سازی کارت شبکه اصلی
IFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
if [ -n "${IFACE:-}" ] && [ -d "/sys/class/net/$IFACE" ]; then
    # افزایش صف ارسال
    ip link set dev "$IFACE" txqueuelen 20000 2>/dev/null || true

    # FQ qdisc
    if command -v tc >/dev/null 2>&1; then
        tc qdisc replace dev "$IFACE" root fq 2>/dev/null || true
    fi

    # ویژگی‌های سخت‌افزاری
    if command -v ethtool >/dev/null 2>&1; then
        ethtool -K "$IFACE" gro on gso on tso on 2>/dev/null || true
        # افزایش ring buffer در صورت پشتیبانی
        ethtool -G "$IFACE" rx 4096 tx 4096 2>/dev/null || true
    fi

    # RPS / XPS
    CPUS=$(nproc)
    if [ "$CPUS" -gt 1 ] && [ -d "/sys/class/net/$IFACE/queues" ]; then
        rem=$(( CPUS % 32 )); full=$(( CPUS / 32 )); parts=()
        [ "$rem" -gt 0 ] && parts+=("$(printf '%x' $(( (1 << rem) - 1 )))")
        for ((i = 0; i < full; i++)); do parts+=(ffffffff); done
        MASK=$(IFS=,; echo "${parts[*]}")

        RXQ_COUNT=$(find "/sys/class/net/$IFACE/queues" -maxdepth 1 -name 'rx-*' 2>/dev/null | wc -l)
        if [ "$RXQ_COUNT" -gt 0 ]; then
            FLOW_CNT=$(( 65536 / RXQ_COUNT ))
            sysctl -qw net.core.rps_sock_flow_entries=65536 2>/dev/null || true
            for rx in /sys/class/net/"$IFACE"/queues/rx-*; do
                [ -e "$rx/rps_cpus" ] && echo "$MASK" > "$rx/rps_cpus" 2>/dev/null || true
                [ -e "$rx/rps_flow_cnt" ] && echo "$FLOW_CNT" > "$rx/rps_flow_cnt" 2>/dev/null || true
            done
        fi

        for tx in /sys/class/net/"$IFACE"/queues/tx-*; do
            [ -e "$tx/xps_cpus" ] && echo "$MASK" > "$tx/xps_cpus" 2>/dev/null || true
        done
    fi
fi

# ۴. CPU Governor → Performance
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "$gov" ] && echo performance > "$gov" 2>/dev/null || true
done

exit 0
EOF_TWEAKS

write_file "$NET_UNIT" <<'EOF'
[Unit]
Description=Enterprise Proxy Node Network Tweaks (MSS, Conntrack, FQ, RPS/XPS, Ethtool)
After=network-online.target ufw.service firewalld.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/xray-net-tweaks.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray-net-tweaks.service >/dev/null 2>&1 || true
systemctl restart xray-net-tweaks.service || warn "اجرای سرویس xray-net-tweaks با هشدار مواجه شد."
ok "بهینه‌سازی‌های سطح کارت شبکه، FQ، Conntrack و RPS/XPS فعال شدند."

# ---------------------------------------------------------
# ۶. محدودسازی Journald
# ---------------------------------------------------------
info "محدودسازی حجم لاگ‌های سیستم..."
CHANGED=0
write_file "$JOURNAL_FILE" <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=40M
MaxRetentionSec=5day
EOF
if [ "$CHANGED" -eq 1 ]; then
    systemctl restart systemd-journald >/dev/null 2>&1 || true
fi
ok "حجم لاگ‌های ژورنال محدود شد."

# ---------------------------------------------------------
# ۷. ری‌استارت سرویس‌ها (اختیاری)
# ---------------------------------------------------------
if [ "${#MODIFIED_UNITS[@]}" -gt 0 ]; then
    if [ "$RESTART_SERVICES" = "1" ]; then
        for u in "${MODIFIED_UNITS[@]}"; do
            systemctl try-restart "$u" 2>/dev/null && ok "سرویس $u ری‌استارت شد." || true
        done
    else
        warn "برای اعمال Limit جدید روی سرویس‌های فعال، آن‌ها را ری‌استارت کنید:"
        printf '  %s\n' "${MODIFIED_UNITS[@]}"
    fi
fi

# ---------------------------------------------------------
# گزارش نهایی
# ---------------------------------------------------------
IFACE_NOW=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
echo
ok "════════════════════════════════════════════════════════"
ok "  بهینه‌سازی نسخه ${VERSION} با موفقیت کامل شد"
ok "════════════════════════════════════════════════════════"
echo
echo "  • الگوریتم ازدحام:     $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
echo "  • صف پیش‌فرض (Qdisc):  $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
echo "  • صف فعال کارت شبکه:   $(tc qdisc show dev "${IFACE_NOW:-lo}" 2>/dev/null | head -n1 | awk '{print $2}' || echo '?')"
echo "  • TCP FastOpen:        $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo '?')"
echo "  • سقف Conntrack:       $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo '?')"
echo "  • rmem_max / wmem_max: $(sysctl -n net.core.rmem_max 2>/dev/null || echo '?')"
echo "  • somaxconn:           $(sysctl -n net.core.somaxconn 2>/dev/null || echo '?')"
echo "  • file-max:            $(sysctl -n fs.file-max 2>/dev/null || echo '?')"
[ -d "$BACKUP_DIR" ] && info "نسخه پشتیبان تنظیمات قبلی: $BACKUP_DIR"
echo
ok "سرور شما اکنون برای ترافیک همزمان بالا و پروکسی تلگرام آماده است."

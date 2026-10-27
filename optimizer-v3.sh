#!/usr/bin/env bash
# =============================================================================
#  Node Optimizer v3 - Xray / Reality / generic proxy node
#
#  اجرا:                   sudo bash node-optimizer-v3.sh
#  غیرفعال کردن IPv6:       sudo DISABLE_IPV6=1 bash node-optimizer-v3.sh
#  ری‌استارت خودکار xray:   sudo RESTART_XRAY=1 bash node-optimizer-v3.sh
#  حذف تغییرات:            sudo bash node-optimizer-v3.sh --uninstall
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

readonly VERSION=3
readonly BACKUP_DIR="/root/node-optimizer-backup-$(date +%Y%m%d-%H%M%S)"
readonly SYSCTL_MAIN=/etc/sysctl.d/99-xray-optimize.conf
readonly SYSCTL_IPV6=/etc/sysctl.d/98-xray-ipv6.conf
readonly NET_SCRIPT=/usr/local/sbin/xray-net-tweaks.sh
readonly NET_UNIT=/etc/systemd/system/xray-net-tweaks.service
readonly MODULES_FILE=/etc/modules-load.d/bbr.conf
readonly JOURNAL_FILE=/etc/systemd/journald.conf.d/size.conf

DISABLE_IPV6="${DISABLE_IPV6:-0}"
RESTART_XRAY="${RESTART_XRAY:-0}"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
info(){ printf '%s➜%s %s\n' "$C" "$N" "$*"; }
ok(){   printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s⚠%s %s\n' "$Y" "$N" "$*"; }
die(){  printf '%s✖%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
trap 'warn "خطا در خط ${LINENO}: ${BASH_COMMAND}"' ERR

[ "${EUID:-$(id -u)}" -eq 0 ] || die "این اسکریپت باید با دسترسی root اجرا شود."

# ---------------------------------------------------------
# توابع کمکی
# ---------------------------------------------------------
CHANGED=0

backup_file() {
    [ -e "$1" ] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$1" "$BACKUP_DIR/$(echo "$1" | tr '/' '_')"
}

# write_file <path> [mode] < content
# فقط در صورت تغییر محتوا بازنویسی می‌کند و CHANGED را ۱ می‌کند.
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
# حالت حذف
# ---------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
    info "حذف تنظیمات node-optimizer..."
    systemctl disable --now xray-net-tweaks.service >/dev/null 2>&1 || true
    rm -f "$NET_UNIT" "$NET_SCRIPT" "$SYSCTL_MAIN" "$SYSCTL_IPV6" "$MODULES_FILE" \
          "$JOURNAL_FILE" /etc/security/limits.d/99-xray.conf \
          /etc/systemd/system.conf.d/99-limits.conf \
          /etc/systemd/system/xray.service.d/limits.conf \
          /etc/systemd/system/x-ui.service.d/limits.conf \
          /etc/systemd/system/3x-ui.service.d/limits.conf
    systemctl daemon-reload
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true
    ok "فایل‌ها حذف شدند. مقادیر runtime تا reboot باقی می‌مانند."
    exit 0
fi

# ---------------------------------------------------------
# پیش‌نیازها
# ---------------------------------------------------------
detect_pm
VIRT=$(systemd-detect-virt 2>/dev/null || echo none)
info "شروع بهینه‌سازی نود (نسخه ${VERSION}) | مدیر بسته: ${PM} | مجازی‌سازی: ${VIRT}"
[ "$PM" != "none" ] && { pm_update || warn "بروزرسانی لیست بسته‌ها ناموفق بود؛ ادامه می‌دهیم."; }

case "$VIRT" in
    lxc|docker|podman|openvz|systemd-nspawn)
        warn "محیط کانتینری است؛ برخی sysctl ها توسط میزبان محدود می‌شوند." ;;
esac

# ---------------------------------------------------------
# ۱. همگام‌سازی زمان
# ---------------------------------------------------------
info "تنظیم همگام‌سازی زمان..."
if pm_install chrony; then
    systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
    systemctl enable --now chrony >/dev/null 2>&1 \
        || systemctl enable --now chronyd >/dev/null 2>&1 \
        || warn "سرویس chrony فعال نشد."
    chronyc makestep >/dev/null 2>&1 || true
    ok "زمان سرور با chrony همگام شد."
else
    warn "نصب chrony ممکن نشد؛ این مرحله رد شد."
fi

# ---------------------------------------------------------
# ۲. محدودیت فایل باز
# ---------------------------------------------------------
info "افزایش محدودیت File Descriptor..."
CHANGED=0
write_file /etc/security/limits.d/99-xray.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
write_file /etc/systemd/system.conf.d/99-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

XRAY_UNITS=()
for u in xray x-ui 3x-ui; do
    if systemctl cat "$u.service" >/dev/null 2>&1; then
        CHANGED=0
        write_file "/etc/systemd/system/$u.service.d/limits.conf" <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
        if [ "$CHANGED" -eq 1 ]; then XRAY_UNITS+=("$u.service"); fi
    fi
done
systemctl daemon-reload
ok "محدودیت فایل باز تنظیم شد."

# ---------------------------------------------------------
# ۳. تنظیمات کرنل
# ---------------------------------------------------------
info "اعمال تنظیمات Sysctl..."

# نسخه‌ی خیلی قدیمی (v1) برخی مقادیر ریسکی ست می‌کرد؛ به پیش‌فرض برمی‌گردانیم
if [ -f "$SYSCTL_MAIN" ] && grep -q 'tcp_adv_win_scale' "$SYSCTL_MAIN"; then
    warn "تنظیمات نسخه‌ی قدیمی پیدا شد؛ مقادیر ریسکی به پیش‌فرض برمی‌گردد."
    for kv in net.ipv4.tcp_adv_win_scale=1 net.ipv4.tcp_fastopen=1 \
              net.core.rmem_default=212992 net.core.wmem_default=212992; do
        sysctl -qw "$kv" 2>/dev/null || true
    done
fi

modprobe tcp_bbr 2>/dev/null || true
CC=cubic
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    CC=bbr
    CHANGED=0
    write_file "$MODULES_FILE" <<'EOF'
tcp_bbr
EOF
else
    warn "BBR در کرنل موجود نیست؛ cubic باقی می‌ماند."
fi

CHANGED=0
write_file "$SYSCTL_MAIN" <<EOF
# --- Congestion control & queueing ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${CC}

# --- Buffers (فقط سقف بالا می‌رود؛ مقادیر پیش‌فرض دست‌نخورده‌اند) ---
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_notsent_lowat = 16384
net.core.netdev_max_backlog = 16384

# --- Connection handling ---
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_max_syn_backlog = 16384
net.core.somaxconn = 16384
net.ipv4.ip_local_port_range = 10240 65535

# --- Keepalive ---
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# --- System ---
fs.file-max = 2097152
vm.swappiness = 10
EOF
sysctl -e -p "$SYSCTL_MAIN" >/dev/null 2>&1 || warn "برخی کلیدهای sysctl اعمال نشدند."

if [ "$DISABLE_IPV6" = "1" ]; then
    CHANGED=0
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
    info "IPv6 دوباره فعال شد."
fi
ok "تنظیمات کرنل اعمال شد (الگوریتم: ${CC})."

# ---------------------------------------------------------
# ۴. قوانین شبکه، conntrack و RPS (سرویس oneshot ماندگار)
# ---------------------------------------------------------
info "نصب سرویس تنظیمات شبکه..."
command -v iptables >/dev/null 2>&1 || pm_install iptables || warn "iptables نصب نشد."

CHANGED=0
write_file "$NET_SCRIPT" 0755 <<'EOF_TWEAKS'
#!/usr/bin/env bash
set -u

# --- iptables: MSS clamping و حذف پکت‌های INVALID ---
if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -C INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null \
        || iptables -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
fi

# --- conntrack: سقف متناسب با RAM ---
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
CT_MAX=262144
[ "${MEM_MB:-0}" -ge 2048 ] && CT_MAX=524288
sysctl -e -qw net.netfilter.nf_conntrack_max="$CT_MAX" \
              net.netfilter.nf_conntrack_tcp_timeout_established=7200 2>/dev/null || true

# --- RPS: فقط برای کارت تک‌صف روی سرورهای چندهسته‌ای ---
IFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
CPUS=$(nproc)
if [ -n "${IFACE:-}" ] && [ "$CPUS" -gt 1 ] && [ -d "/sys/class/net/$IFACE/queues" ]; then
    RXQ=$(find "/sys/class/net/$IFACE/queues" -maxdepth 1 -name 'rx-*' | wc -l)
    if [ "$RXQ" -eq 1 ]; then
        rem=$(( CPUS % 32 )); full=$(( CPUS / 32 )); parts=()
        [ "$rem" -gt 0 ] && parts+=("$(printf '%x' $(( (1 << rem) - 1 )))")
        for ((i = 0; i < full; i++)); do parts+=(ffffffff); done
        MASK=$(IFS=,; echo "${parts[*]}")
        echo "$MASK" > "/sys/class/net/$IFACE/queues/rx-0/rps_cpus" 2>/dev/null || true
        echo 4096 > "/sys/class/net/$IFACE/queues/rx-0/rps_flow_cnt" 2>/dev/null || true
        sysctl -qw net.core.rps_sock_flow_entries=32768 2>/dev/null || true
    fi
fi
exit 0
EOF_TWEAKS

CHANGED=0
write_file "$NET_UNIT" <<'EOF'
[Unit]
Description=Xray node network tweaks (iptables MSS/INVALID, conntrack, RPS)
After=network-online.target ufw.service
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
systemctl restart xray-net-tweaks.service || warn "سرویس xray-net-tweaks با خطا مواجه شد."
ok "قوانین شبکه، conntrack و RPS اعمال و ماندگار شدند."

if dpkg -s iptables-persistent >/dev/null 2>&1; then
    warn "iptables-persistent نصب است و ممکن است قوانین قدیمی را در بوت برگرداند."
fi

# ---------------------------------------------------------
# ۵. محدودسازی لاگ journald
# ---------------------------------------------------------
info "محدودسازی حجم لاگ journald..."
CHANGED=0
write_file "$JOURNAL_FILE" <<'EOF'
[Journal]
SystemMaxUse=150M
SystemMaxFileSize=30M
EOF
if [ "$CHANGED" -eq 1 ]; then
    systemctl restart systemd-journald
fi
ok "حجم لاگ‌ها محدود شد."

# ---------------------------------------------------------
# ۶. ری‌استارت سرویس‌های xray (فقط در صورت درخواست صریح)
# ---------------------------------------------------------
if [ "${#XRAY_UNITS[@]}" -gt 0 ]; then
    if [ "$RESTART_XRAY" = "1" ]; then
        for u in "${XRAY_UNITS[@]}"; do
            systemctl restart "$u" && ok "سرویس $u ری‌استارت شد."
        done
    else
        warn "برای اعمال limit جدید سرویس(های) زیر را ری‌استارت کنید: ${XRAY_UNITS[*]}"
    fi
fi

# ---------------------------------------------------------
# جمع‌بندی
# ---------------------------------------------------------
echo
ok "پایان (نسخه ${VERSION})."
echo "  congestion: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
echo "  qdisc:      $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
echo "  بررسی سرویس: systemctl status xray-net-tweaks --no-pager"
[ -d "$BACKUP_DIR" ] && info "نسخه‌های پشتیبان در: $BACKUP_DIR"
warn "برای اعمال کامل limit ها و قوانین بوت، یک بار reboot کنید (ابتدا مطمئن شوید دسترسی کنسول دارید)."

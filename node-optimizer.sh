#!/usr/bin/env bash
# =============================================================================
#  Node Optimizer v2.1 - Xray / Sing-box / Reality Edition
#  - تنظیمات کم‌ریسک و ایمن؛ حفظ رفتار ظاهری TCP (مقاوم در برابر Fingerprinting)
#  - Idempotent: قابل اجرا به دفعات بدون تداخل یا خرابی تنظیمات
#  - استفاده از ساختار Drop-in بدون دستکاری فایل‌های اصلی سیستم‌عامل
#  - پشتیبانی از بازگردانی کامل تنظیمات (--uninstall) و بررسی وضعیت (--status)
#
#  اجرای استاندارد:       sudo bash node-optimizer.sh
#  غیرفعال‌سازی IPv6:     sudo bash node-optimizer.sh --disable-ipv6
#  بررسی وضعیت سرور:      sudo bash node-optimizer.sh --status
#  حذف کامل تنظیمات:      sudo bash node-optimizer.sh --uninstall
# =============================================================================

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- رنگ‌ها و توابع خروجی ---
readonly R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' C=$'\e[36m' B=$'\e[1m' N=$'\e[0m'

info() { echo -e "${C}[➜]${N} $1"; }
ok()   { echo -e "${G}[✔]${N} $1"; }
warn() { echo -e "${Y}[⚠]${N} $1"; }
err()  { echo -e "${R}[✖]${N} $1" >&2; }

trap 'err "خطا در خط ${LINENO}: اجرای دستور \"${BASH_COMMAND}\" ناموفق بود."' ERR

# --- مسیر فایل‌های پیکربندی ---
readonly LIMITS_FILE="/etc/security/limits.d/99-xray.conf"
readonly SYSTEMD_LIMITS="/etc/systemd/system.conf.d/99-limits.conf"
readonly SYSCTL_FILE="/etc/sysctl.d/99-xray-optimize.conf"
readonly IPV6_SYSCTL_FILE="/etc/sysctl.d/98-xray-ipv6.conf"
readonly BBR_MOD_FILE="/etc/modules-load.d/bbr.conf"
readonly TWEAKS_SCRIPT="/usr/local/sbin/xray-net-tweaks.sh"
readonly TWEAKS_SERVICE="/etc/systemd/system/xray-net-tweaks.service"
readonly JOURNALD_CONF="/etc/systemd/journald.conf.d/99-size.conf"
readonly TARGET_SERVICES=(xray x-ui 3x-ui s-ui sing-box marzban marzban-node nginx haproxy caddy)

# --- متغیرهای پیش‌فرض ---
DISABLE_IPV6="${DISABLE_IPV6:-0}"
ACTION="install"
NEED_RESTART=0

# --- راهنمای اسکریپت ---
usage() {
    cat <<EOF
${B}Node Optimizer v2.1 (Xray / Reality)${N}

استفاده:
  sudo bash $(basename "$0") [OPTIONS]

گزینه‌ها:
  --disable-ipv6    غیرفعال‌سازی کامل IPv6 در سطح کرنل
  --status          نمایش وضعیت فعلی کرنل، BBR، محدودیت‌ها و قوانین شبکه
  --uninstall       حذف تمام تغییرات اسکریپت و بازگشت به حالت پیش‌فرض
  -h, --help        نمایش این راهنما

متغیر محیطی (سازگار با نسخه‌های قبلی):
  sudo DISABLE_IPV6=1 bash $(basename "$0")
EOF
    exit 0
}

# --- پردازش آرگومان‌های ورودی ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --disable-ipv6) DISABLE_IPV6=1; shift ;;
        --status)       ACTION="status"; shift ;;
        --uninstall)    ACTION="uninstall"; shift ;;
        -h|--help)      usage ;;
        *) err "آرگومان نامعتبر: $1"; usage ;;
    esac
done

# --- بررسی دسترسی Root ---
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "این اسکریپت باید با دسترسی root اجرا شود (از sudo استفاده کنید)."
    exit 1
fi

# --- تشخیص مدیر بسته و مجازی‌ساز ---
IS_CONTAINER=0
if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -c >/dev/null 2>&1; then
    IS_CONTAINER=1
fi

install_pkg() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y -qq "$@" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "$@" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "$@" >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm --needed "$@" >/dev/null 2>&1
    else
        return 1
    fi
}

# --- نمایش وضعیت فعلی (--status) ---
show_status() {
    echo -e "${B}=== وضعیت فعلی بهینه‌سازی نود ===${N}"
    echo -e "الگوریتم کنترل ازدحام : ${G}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'نامشخص')${N}"
    echo -e "صف‌بندی بسته (Qdisc)  : ${G}$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 'نامشخص')${N}"
    echo -e "سقف فایل‌های باز کرنل  : ${G}$(sysctl -n fs.file-max 2>/dev/null || echo 'نامشخص')${N}"
    echo -e "وضعیت Conntrack       : ${G}$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo '0') / $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 'نامشخص')${N}"
    echo -e "وضعیت سرویس شبکه     : $(systemctl is-active xray-net-tweaks.service 2>/dev/null || echo 'غیرفعال')"
    echo -e "وضعیت Chrony (زمان)   : $(systemctl is-active chrony 2>/dev/null || systemctl is-active chronyd 2>/dev/null || echo 'غیرفعال')"
    echo -e "\n${B}--- قوانین Mangle (TCPMSS) ---${N}"
    iptables -t mangle -S POSTROUTING 2>/dev/null | grep TCPMSS || echo "قانونی یافت نشد."
    exit 0
}

# --- حذف تنظیمات (--uninstall) ---
uninstall_tweaks() {
    info "در حال حذف تنظیمات و بازگردانی به حالت پیش‌فرض..."
    systemctl disable --now xray-net-tweaks.service >/dev/null 2>&1 || true

    if command -v iptables >/dev/null 2>&1; then
        iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        iptables -D INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        ip6tables -D INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true
    fi

    rm -f "$LIMITS_FILE" "$SYSTEMD_LIMITS" "$SYSCTL_FILE" "$IPV6_SYSCTL_FILE" \
          "$BBR_MOD_FILE" "$TWEAKS_SCRIPT" "$TWEAKS_SERVICE" "$JOURNALD_CONF" \
          /etc/systemd/journald.conf.d/size.conf

    for u in "${TARGET_SERVICES[@]}"; do
        rm -f "/etc/systemd/system/${u}.service.d/limits.conf"
        rmdir --ignore-fail-on-non-empty "/etc/systemd/system/${u}.service.d" 2>/dev/null || true
    done

    for k in all default lo; do
        sysctl -qw "net.ipv6.conf.$k.disable_ipv6=0" 2>/dev/null || true
    done

    systemctl daemon-reload
    sysctl --system >/dev/null 2>&1 || true
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    ok "تمام تغییرات با موفقیت حذف شدند. برای اعمال کامل، سرور را ریبوت کنید."
    exit 0
}

[[ "$ACTION" == "status" ]] && show_status
[[ "$ACTION" == "uninstall" ]] && uninstall_tweaks

# =============================================================================
# شروع فرآیند نصب و بهینه‌سازی
# =============================================================================
info "شروع بهینه‌سازی نود (نسخه ۲.۱)..."
if [[ "$IS_CONTAINER" -eq 1 ]]; then
    warn "محیط کانتینری (LXC/OpenVZ) شناسایی شد؛ برخی پارامترهای کرنل ممکن است توسط میزبان محدود شده باشند."
fi

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || warn "به‌روزرسانی مخازن apt ناموفق بود؛ ادامه می‌دهیم."
fi

# ---------------------------------------------------------
# ۱. همگام‌سازی زمان (حیاتی برای TLS / Reality / گواهی‌ها)
# ---------------------------------------------------------
info "تنظیم سرویس همگام‌سازی زمان (Chrony)..."
if [[ "$IS_CONTAINER" -eq 0 ]] && install_pkg chrony; then
    systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1 || true
    chronyc makestep >/dev/null 2>&1 || true
    ok "زمان سرور با موفقیت همگام‌سازی شد."
else
    warn "نصب یا اجرای Chrony امکان‌پذیر نبود (احتمالاً محدودیت کانتینر)؛ از این مرحله عبور شد."
fi

# ---------------------------------------------------------
# ۲. افزایش محدودیت File Descriptor (بدون دستکاری limits.conf)
# ---------------------------------------------------------
info "افزایش سقف فایل‌های باز (File Descriptors)..."
mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d

cat > "$LIMITS_FILE" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

cat > "$SYSTEMD_LIMITS" <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

for u in "${TARGET_SERVICES[@]}"; do
    if systemctl cat "${u}.service" >/dev/null 2>&1; then
        mkdir -p "/etc/systemd/system/${u}.service.d"
        printf '[Service]\nLimitNOFILE=1048576\n' > "/etc/systemd/system/${u}.service.d/limits.conf"
        NEED_RESTART=1
    fi
done

systemctl daemon-reload
systemctl daemon-reexec 2>/dev/null || true
ok "محدودیت فایل‌های باز روی 1,048,576 تنظیم شد."

# ---------------------------------------------------------
# ۳. تنظیمات کرنل (BBR + بافر + مدیریت پورت و کانکشن)
# ---------------------------------------------------------
info "اعمال تنظیمات شبکه و کرنل (Sysctl)..."

# بازگردانی مقادیر ریسکی نسخه‌های قدیمی به پیش‌فرض استاندارد کرنل
if [[ -f "$SYSCTL_FILE" ]] && grep -q 'tcp_adv_win_scale' "$SYSCTL_FILE"; then
    warn "تنظیمات نسخه قدیمی شناسایی شد؛ بازگردانی مقادیر حساس به پیش‌فرض کرنل..."
    for kv in net.ipv4.tcp_adv_win_scale=1 net.ipv4.tcp_fastopen=1 \
              net.core.rmem_default=212992 net.core.wmem_default=212992 \
              net.ipv4.udp_rmem_min=4096 net.ipv4.udp_wmem_min=4096; do
        sysctl -qw "$kv" 2>/dev/null || true
    done
    if [[ "$DISABLE_IPV6" != "1" ]]; then
        for k in all default lo; do sysctl -qw "net.ipv6.conf.$k.disable_ipv6=0" 2>/dev/null || true; done
    fi
fi

if [[ "$IS_CONTAINER" -eq 0 ]]; then
    modprobe tcp_bbr 2>/dev/null || true
    mkdir -p /etc/modules-load.d
    echo "tcp_bbr" > "$BBR_MOD_FILE"
fi

if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    CC="bbr"
else
    CC="cubic"
    warn "کرنل از BBR پشتیبانی نمی‌کند؛ الگوریتم ${CC} حفظ شد."
fi

# نکته امنیتی: مقادیر میانی (پیش‌فرض) در tcp_rmem و tcp_wmem دست‌نخورده باقی مانده‌اند
# تا اندازه پنجره اولیه TCP (Initial Window) کاملاً مشابه لینوکس استاندارد باشد.
cat > "$SYSCTL_FILE" <<EOF
# --- Congestion Control & Queue Discipline ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${CC}

# --- Socket & TCP Buffers (Max scaled up, Default untouched for stealth) ---
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

# --- TCP Connection Behavior ---
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# --- High-Concurrency Scaling ---
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.core.somaxconn = 16384
net.ipv4.tcp_max_tw_buckets = 262144
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
EOF

if [[ "$DISABLE_IPV6" == "1" ]]; then
    cat > "$IPV6_SYSCTL_FILE" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    ok "پروتکل IPv6 غیرفعال شد."
else
    rm -f "$IPV6_SYSCTL_FILE"
    for k in all default lo; do sysctl -qw "net.ipv6.conf.$k.disable_ipv6=0" 2>/dev/null || true; done
fi

sysctl --system >/dev/null 2>&1 || warn "برخی پارامترهای sysctl اعمال نشدند (محدودیت کرنل/کانتینر)."
ok "تنظیمات کرنل با موفقیت اعمال شد (الگوریتم فعال: ${B}${CC}${N})."

# ---------------------------------------------------------
# ۴. قوانین شبکه + Conntrack + RPS (سرویس ماندگار Systemd)
# ---------------------------------------------------------
info "پیکربندی سرویس بهینه‌ساز شبکه (iptables / Conntrack / RPS)..."
install_pkg iptables || true

# پاک‌سازی قوانین محدودکننده ICMP از نسخه‌های قدیمی اسکریپت
if command -v iptables >/dev/null 2>&1; then
    for tail in "-m limit --limit 2/s --limit-burst 5 -j ACCEPT" "-j DROP"; do
        # shellcheck disable=SC2086
        while iptables -D INPUT -p icmp --icmp-type echo-request $tail 2>/dev/null; do :; done
    done
fi

cat > "$TWEAKS_SCRIPT" <<'EOF_TWEAKS'
#!/usr/bin/env bash
set -u

# ۱. اعمال MSS Clamping و حذف پکت‌های نامعتبر (IPv4 & IPv6)
if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -C INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null \
        || iptables -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
fi

if command -v ip6tables >/dev/null 2>&1 && [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" -eq 0 ]]; then
    ip6tables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || ip6tables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ip6tables -C INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null \
        || ip6tables -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
fi

# ۲. بهینه‌سازی جدول Conntrack و Hashsize برای جلوگیری از خطای Table Full
modprobe nf_conntrack 2>/dev/null || true
if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
    echo 65536 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
fi

sysctl -e -qw \
    net.netfilter.nf_conntrack_max=262144 \
    net.netfilter.nf_conntrack_tcp_timeout_established=7200 \
    net.netfilter.nf_conntrack_tcp_timeout_time_wait=30 \
    net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30 \
    net.netfilter.nf_conntrack_tcp_timeout_close_wait=15 2>/dev/null || true

# ۳. فعال‌سازی RPS روی کارت‌های شبکه تک‌صف در سرورهای چندهسته‌ای
IFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
CPUS=$(nproc 2>/dev/null || echo 1)

if [[ -n "${IFACE:-}" ]] && [[ "$CPUS" -gt 1 ]] && [[ "$CPUS" -le 32 ]]; then
    RXQ=$(find "/sys/class/net/${IFACE}/queues" -maxdepth 1 -name 'rx-*' 2>/dev/null | wc -l)
    if [[ "$RXQ" -eq 1 ]]; then
        MASK=$(printf '%x' $(( (1 << CPUS) - 1 )))
        echo "$MASK" > "/sys/class/net/${IFACE}/queues/rx-0/rps_cpus" 2>/dev/null || true
    fi
fi

exit 0
EOF_TWEAKS
chmod 0755 "$TWEAKS_SCRIPT"

cat > "$TWEAKS_SERVICE" <<'EOF'
[Unit]
Description=Xray Node Network Tweaks (iptables, conntrack, RPS)
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
systemctl enable --now xray-net-tweaks.service >/dev/null 2>&1 || true
systemctl restart xray-net-tweaks.service
ok "قوانین شبکه، Conntrack و RPS فعال و ماندگار شدند."

if command -v dpkg >/dev/null 2>&1 && dpkg -s iptables-persistent >/dev/null 2>&1; then
    warn "بسته iptables-persistent نصب است و ممکن است قوانین قدیمی را در بوت بازگرداند."
    warn "پیشنهاد می‌شود آن را حذف کنید: sudo apt-get purge -y iptables-persistent"
fi

# ---------------------------------------------------------
# ۵. مدیریت حجم لاگ‌های سیستم (Journald)
# ---------------------------------------------------------
info "محدودسازی حجم لاگ‌های systemd-journald..."
mkdir -p /etc/systemd/journald.conf.d
rm -f /etc/systemd/journald.conf.d/size.conf

cat > "$JOURNALD_CONF" <<'EOF'
[Journal]
SystemMaxUse=150M
SystemMaxFileSize=30M
MaxRetentionSec=14day
EOF

systemctl restart systemd-journald >/dev/null 2>&1 || true
ok "حداکثر حجم لاگ‌های سیستم روی 150MB محدود شد."

# ---------------------------------------------------------
# جمع‌بندی نهایی
# ---------------------------------------------------------
echo
echo -e "${G}${B}🎉 بهینه‌سازی نود با موفقیت به پایان رسید!${N}"
echo -e "برای مشاهده وضعیت فعلی در هر زمان می‌توانید از دستور زیر استفاده کنید:"
echo -e "  ${C}sudo bash $(basename "$0") --status${N}"
echo

if [[ "$NEED_RESTART" -eq 1 ]]; then
    warn "برای اعمال سقف جدید فایل‌های باز روی سرویس‌های فعلی، آن‌ها را ری‌استارت کنید:"
    echo -e "  ${Y}sudo systemctl restart xray x-ui sing-box${N} (متناسب با سرویس نصب‌شده)"
fi
warn "پیشنهاد می‌شود برای اعمال کامل تمامی پارامترها یک بار سرور را reboot کنید."

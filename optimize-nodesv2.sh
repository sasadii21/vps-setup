#!/usr/bin/env bash
# =============================================================================
#  Node Optimizer v2 - Xray / Reality
#  - فقط تنظیمات کم‌ریسک؛ رفتار TCP ظاهری سرور (چیزی که فیلترچی می‌بیند) تقریباً دست‌نخورده می‌ماند
#  - idempotent: چندبار اجرا شود مشکلی ندارد
#  - فایل‌های سیستمی موجود را بازنویسی نمی‌کند (فقط drop-in می‌سازد)
#  - اگر نسخه‌ی قبلی اسکریپت را اجرا کرده باشید، مقادیر ریسکی آن را به پیش‌فرض برمی‌گرداند
#
#  اجرا:            sudo bash node-optimizer-v2.sh
#  غیرفعال کردن IPv6:  sudo DISABLE_IPV6=1 bash node-optimizer-v2.sh
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
info() { echo -e "${C}➜${N} $1"; }
ok()   { echo -e "${G}✔${N} $1"; }
warn() { echo -e "${Y}⚠${N} $1"; }
trap 'echo -e "${R}خطا در خط ${LINENO}${N}"' ERR

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo -e "${R}این اسکریپت باید با دسترسی root اجرا شود.${N}"; exit 1; }

DISABLE_IPV6="${DISABLE_IPV6:-0}"
HAS_APT=0; command -v apt-get >/dev/null 2>&1 && HAS_APT=1

pkg() { [ "$HAS_APT" -eq 1 ] && apt-get install -y -qq "$@" >/dev/null 2>&1; }

info "شروع بهینه‌سازی نود..."
[ "$HAS_APT" -eq 1 ] && { apt-get update -qq >/dev/null 2>&1 || warn "apt update ناموفق بود؛ ادامه می‌دهیم."; }

# ---------------------------------------------------------
# ۱. همگام‌سازی زمان
# ---------------------------------------------------------
# Reality فقط وقتی maxTimeDiff در کانفیگ تنظیم شده باشد به زمان حساس است، اما
# زمان درست برای لاگ‌ها، گواهی‌ها و عملکرد کلی سرور بهتر است.
info "تنظیم Chrony..."
if pkg chrony; then
    systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1 || true
    chronyc makestep >/dev/null 2>&1 || true
    ok "زمان سرور همگام شد."
else
    warn "نصب chrony ممکن نشد (کانتینر یا غیر-apt)؛ از این مرحله عبور شد."
fi

# ---------------------------------------------------------
# ۲. محدودیت فایل باز (بدون بازنویسی limits.conf)
# ---------------------------------------------------------
info "افزایش محدودیت File Descriptor..."
mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d
cat > /etc/security/limits.d/99-xray.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
cat > /etc/systemd/system.conf.d/99-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
# سرویس‌های رایج xray هم صریحاً limit بگیرند (سرویس‌های با LimitNOFILE خودشان نیاز دارند)
for u in xray x-ui; do
    if systemctl cat "$u.service" >/dev/null 2>&1; then
        mkdir -p "/etc/systemd/system/$u.service.d"
        printf '[Service]\nLimitNOFILE=1048576\n' > "/etc/systemd/system/$u.service.d/limits.conf"
        NEED_RESTART=1
    fi
done
systemctl daemon-reload
systemctl daemon-reexec 2>/dev/null || true
ok "محدودیت فایل باز تنظیم شد."

# ---------------------------------------------------------
# ۳. تنظیمات کرنل (BBR + بافر + مدیریت کانکشن)
# ---------------------------------------------------------
info "اعمال تنظیمات Sysctl..."
SYSCTL_FILE=/etc/sysctl.d/99-xray-optimize.conf

# اگر نسخه‌ی قبلی اجرا شده بود، مقادیر ریسکی را به پیش‌فرض کرنل برگردان
# (حذف از فایل کافی نیست؛ مقدار تا ریبوت در کرنل می‌ماند)
if [ -f "$SYSCTL_FILE" ] && grep -q 'tcp_adv_win_scale' "$SYSCTL_FILE"; then
    warn "تنظیمات نسخه‌ی قبلی پیدا شد؛ مقادیر ریسکی به پیش‌فرض برگردانده می‌شود."
    for kv in net.ipv4.tcp_adv_win_scale=1 net.ipv4.tcp_fastopen=1 \
              net.core.rmem_default=212992 net.core.wmem_default=212992 \
              net.ipv4.udp_rmem_min=4096 net.ipv4.udp_wmem_min=4096; do
        sysctl -qw "$kv" 2>/dev/null || true
    done
    if [ "$DISABLE_IPV6" != "1" ]; then
        for k in all default lo; do sysctl -qw "net.ipv6.conf.$k.disable_ipv6=0" 2>/dev/null || true; done
    fi
fi

modprobe tcp_bbr 2>/dev/null || true
echo tcp_bbr > /etc/modules-load.d/bbr.conf
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    CC=bbr
else
    CC=cubic
    warn "کرنل شما BBR ندارد؛ cubic باقی می‌ماند."
fi

# نکته: مقدار پیش‌فرض بافرها (وسط tcp_rmem/tcp_wmem و rmem_default) عمداً دست‌نخورده
# مانده تا پنجره‌ی TCP اولیه‌ی سرور مثل یک لینوکس معمولی بماند. فقط سقف بالا می‌رود.
cat > "$SYSCTL_FILE" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${CC}

net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.core.netdev_max_backlog = 16384

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1

net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_max_syn_backlog = 16384
net.core.somaxconn = 16384
net.ipv4.tcp_max_tw_buckets = 262144

fs.file-max = 2097152
EOF

if [ "$DISABLE_IPV6" = "1" ]; then
    cat > /etc/sysctl.d/98-xray-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    ok "IPv6 غیرفعال شد."
else
    rm -f /etc/sysctl.d/98-xray-ipv6.conf
fi
sysctl --system >/dev/null 2>&1 || warn "برخی کلیدهای sysctl اعمال نشد (احتمالاً کانتینر/OpenVZ)."
ok "تنظیمات کرنل اعمال شد (الگوریتم: ${CC})."

# ---------------------------------------------------------
# ۴. قوانین شبکه + conntrack + RPS (ماندگار با سرویس systemd)
# ---------------------------------------------------------
# به‌جای iptables-persistent (که تعاملی است و قوانین Docker را هم ذخیره می‌کند)
# یک سرویس oneshot کوچک می‌سازیم که فقط قوانین خودش را در هر بوت اعمال می‌کند.
info "نصب سرویس تنظیمات شبکه..."
pkg iptables || true

# پاک‌سازی قوانین ICMP نسخه‌ی قبلی (فایده‌ای نداشت و فقط عیب‌یابی را سخت می‌کرد)
if command -v iptables >/dev/null 2>&1; then
    for tail in "-m limit --limit 2/s --limit-burst 5 -j ACCEPT" "-j DROP"; do
        # shellcheck disable=SC2086
        while iptables -D INPUT -p icmp --icmp-type echo-request $tail 2>/dev/null; do :; done
    done
fi

cat > /usr/local/sbin/xray-net-tweaks.sh <<'EOF_TWEAKS'
#!/usr/bin/env bash
set -u

# --- iptables: MSS clamping + حذف پکت‌های INVALID ---
if command -v iptables >/dev/null 2>&1; then
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -C INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null \
        || iptables -I INPUT 1 -m conntrack --ctstate INVALID -j DROP
fi

# --- conntrack: جلوگیری از "table full" روی نودهای پرکاربر (بعد از لود ماژول اعمال می‌شود) ---
sysctl -e -qw net.netfilter.nf_conntrack_max=262144 \
                net.netfilter.nf_conntrack_tcp_timeout_established=7200 2>/dev/null || true

# --- RPS: فقط برای کارت شبکه‌ی تک‌صف روی سرورهای چندهسته‌ای ---
IFACE=$(ip -o -4 route show to default | awk '{print $5; exit}')
CPUS=$(nproc)
if [ -n "${IFACE:-}" ] && [ "$CPUS" -gt 1 ] && [ "$CPUS" -le 32 ]; then
    RXQ=$(find "/sys/class/net/$IFACE/queues" -maxdepth 1 -name 'rx-*' 2>/dev/null | wc -l)
    if [ "$RXQ" -eq 1 ]; then
        printf '%x' $(( (1 << CPUS) - 1 )) > "/sys/class/net/$IFACE/queues/rx-0/rps_cpus" 2>/dev/null || true
    fi
fi
exit 0
EOF_TWEAKS
chmod +x /usr/local/sbin/xray-net-tweaks.sh

cat > /etc/systemd/system/xray-net-tweaks.service <<'EOF'
[Unit]
Description=Xray node network tweaks (iptables, conntrack, RPS)
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
systemctl restart xray-net-tweaks.service
ok "قوانین شبکه فعال و ماندگار شد."

if dpkg -s iptables-persistent >/dev/null 2>&1; then
    warn "iptables-persistent (از نسخه‌ی قبلی) نصب است و قوانین قدیمی را در بوت برمی‌گرداند."
    warn "پیشنهاد: apt purge -y iptables-persistent"
fi

# ---------------------------------------------------------
# ۵. محدود کردن لاگ سیستم
# ---------------------------------------------------------
info "محدودسازی حجم لاگ journald..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size.conf <<'EOF'
[Journal]
SystemMaxUse=150M
SystemMaxFileSize=30M
EOF
systemctl restart systemd-journald
ok "لاگ‌ها محدود شدند."

# ---------------------------------------------------------
# جمع‌بندی
# ---------------------------------------------------------
echo
echo -e "${G}🎉 پایان.${N} بررسی سریع:"
echo "  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc"
echo "  systemctl status xray-net-tweaks --no-pager"
echo "  iptables -S INPUT | head; iptables -t mangle -S POSTROUTING"
[ "${NEED_RESTART:-0}" = "1" ] && warn "سرویس xray/x-ui را ری‌استارت کنید تا limit جدید اعمال شود: systemctl restart xray x-ui"
warn "برای اعمال کامل (به‌خصوص اگر نسخه‌ی قبلی را اجرا کرده بودید) یک بار reboot کنید."

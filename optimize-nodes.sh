#!/usr/bin/env bash
# =============================================================================
#  Advanced Node Optimizer - Xray / Reality Edition
#  طراحی شده برای بالاترین سرعت و مقاومت در برابر فیلترینگ
# =============================================================================
set -Eeuo pipefail

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
info() { echo -e "${C}➜${N} $1"; }
ok()   { echo -e "${G}✔${N} $1"; }
warn() { echo -e "${Y}⚠${N} $1"; }

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "${R}این اسکریپت باید با دسترسی root اجرا شود.${N}"; exit 1; }

info "شروع بهینه‌سازی پیشرفته نود..."

# ---------------------------------------------------------
# ۱. همگام‌سازی دقیق زمان (حیاتی برای Xray Reality)
# ---------------------------------------------------------
# اگر زمان سرور شما با سرور هدف Reality بیش از چند ثانیه اختلاف داشته باشد،
# هندشیک TLS با خطا مواجه شده و فیلترچی آن را مسدود می‌کند.
info "تنظیم Chrony برای همگام‌سازی زمان..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y chrony >/dev/null 2>&1
systemctl enable --now chrony >/dev/null 2>&1
chronyc makestep >/dev/null 2>&1
ok "زمان سرور کالیبره شد."

# ---------------------------------------------------------
# ۲. ارتقای محدودیت‌های سیستم (File Descriptors)
# ---------------------------------------------------------
info "افزایش محدودیت‌های System Limits..."
cat > /etc/security/limits.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
root soft nproc 1048576
root hard nproc 1048576
EOF
sed -i '/DefaultLimitNOFILE/c\DefaultLimitNOFILE=1048576' /etc/systemd/system.conf
sed -i '/DefaultLimitNOFILE/c\DefaultLimitNOFILE=1048576' /etc/systemd/user.conf
systemctl daemon-reload
ok "محدودیت‌های فایل باز برداشته شد."

# ---------------------------------------------------------
# ۳. تیونینگ فوق‌پیشرفته کرنل (TCP/UDP & BBR)
# ---------------------------------------------------------
info "اعمال تنظیمات Sysctl برای دور زدن Throttling..."
cat > /etc/sysctl.d/99-xray-optimize.conf <<EOF
# --- الگوریتم کنترل ازدحام (BBR و FQ) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- بهینه‌سازی بافرهای شبکه (جلوگیری از افت سرعت در تایم اوج مصرف) ---
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 8192 1048576 67108864
net.ipv4.tcp_wmem = 8192 1048576 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# --- ترفندهای ضد فیلترینگ و پایداری کانکشن ---
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_adv_win_scale = -2

# --- مدیریت کانکشن‌های بالا (TIME_WAIT & Keepalive) ---
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_max_syn_backlog = 32768
net.core.somaxconn = 65535
net.ipv4.tcp_max_tw_buckets = 1440000

# --- غیرفعال‌سازی IPv6 (اختیاری اما برای Reality ایران پیشنهاد می‌شود) ---
# اگر پنل/نود شما از IPv6 استفاده می‌کند این ۳ خط را پاک کنید
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl --system >/dev/null 2>&1
ok "تنظیمات شبکه و هسته لینوکس با موفقیت اعمال شد."

# ---------------------------------------------------------
# ۴. بهینه‌سازی کارت شبکه (Hardware Offloading)
# ---------------------------------------------------------
info "اعمال تنظیمات کارت شبکه (NIC Offloading)..."
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n 1)
if [ -n "$INTERFACE" ]; then
    apt-get install -y ethtool >/dev/null 2>&1
    ethtool -K "$INTERFACE" tso on gso on gro on 2>/dev/null || true
    # توزیع بار روی هسته‌های CPU (RPS)
    for rps in /sys/class/net/$INTERFACE/queues/rx-*/rps_cpus; do
        [ -f "$rps" ] && echo "ff" > "$rps" 2>/dev/null || true
    done
    ok "ترافیک کارت شبکه ($INTERFACE) روی هسته‌ها توزیع شد."
else
    warn "کارت شبکه اصلی پیدا نشد، از این مرحله عبور شد."
fi

# ---------------------------------------------------------
# ۵. فایروال ضد اکتیو-پروبینگ و MTU (Iptables)
# ---------------------------------------------------------
info "ایجاد سپرهای Iptables در برابر سیستم فیلترینگ..."
apt-get install -y iptables-persistent >/dev/null 2>&1

# 1. تنظیم اتوماتیک سایز پکت (MSS Clamping) برای جلوگیری از Fragment شدن
iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# 2. دراپ کردن پکت‌های Invalid که فیلترچی برای کشف سرور می‌فرستد
iptables -C INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || \
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

# 3. محدود کردن درخواست‌های Ping برای جلوگیری از اسکن شدن سرور (محدود به 2 پینگ در ثانیه)
iptables -C INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null || {
    iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 2/s --limit-burst 5 -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
}

netfilter-persistent save >/dev/null 2>&1
ok "قوانین ضد-تشخیص فایروال فعال شد."

# ---------------------------------------------------------
# ۶. جلوگیری از پر شدن هارد (Log Management)
# ---------------------------------------------------------
info "محدودسازی حجم لاگ‌های سیستم..."
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/size.conf <<EOF
[Journal]
SystemMaxUse=150M
SystemMaxFileSize=30M
EOF
systemctl restart systemd-journald
ok "لاگ‌های Journald محدود شدند."

echo -e "\n${G}🎉 بهینه‌سازی با موفقیت به پایان رسید. نود شما اکنون برای ترافیک سنگین Reality آماده است.${N}"

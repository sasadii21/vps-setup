#!/usr/bin/env bash
# =============================================================================
#  Tunnel Optimizer
#  بهینه‌ساز سرور تانل (Backhaul / Gost / Rathole / FRP / HAProxy / WireGuard)
#  این اسکریپت برای نود PasarGuard نیست. کانفیگ تانل، پورت و کلید را عوض نمی‌کند.
#
#  اجرا روی خود سرور تانل:
#    sudo bash tunnel-optimizer.sh
#
#  پروفایل:
#    sudo MODE=auto bash tunnel-optimizer.sh    # پیش‌فرض
#    sudo MODE=max  bash tunnel-optimizer.sh    # بافر و صف بیشتر
#    sudo MODE=safe bash tunnel-optimizer.sh    # VPS یک‌هسته‌ای
#
#  گزینه‌ها:
#    SKIP_RESTART=1          سرویس تانل و داکر را ری‌استارت نکن
#    DISABLE_IPV6=1          خاموش کردن IPv6
#    ENABLE_IPV6_FORWARD=1   فوروارد IPv6 (پیش‌فرض خاموش؛ SLAAC را به‌هم می‌زند)
#    AUTO_SWAP=0             نساختن swap
#    TUNE_DOCKER=0           دست نزدن به daemon.json
#    TUNE_NIC=0              دست نزدن به کارت شبکه
#    TUNE_NIC_CHANNELS=0     زیاد نکردن صف RSS
#    MSS_CLAMP=0             بدون کلمپ MSS (پیش‌فرض روشن است؛ MTU تانل را درست می‌کند)
#
#  وضعیت:
#    bash tunnel-optimizer.sh --status
#  حذف فقط تنظیمات همین اسکریپت:
#    sudo bash tunnel-optimizer.sh --uninstall
# =============================================================================
set -Eeuo pipefail

readonly VERSION="1.0.0"
readonly STATE_DIR=/var/lib/tunnel-optimizer
readonly BACKUP_DIR="${STATE_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
readonly SYSCTL_MAIN=/etc/sysctl.d/99-tunnel-optimize.conf
readonly SYSCTL_IPV6=/etc/sysctl.d/98-tunnel-ipv6.conf
readonly NET_SCRIPT=/usr/local/sbin/tunnel-net-tweaks.sh
readonly NET_UNIT=/etc/systemd/system/tunnel-net-tweaks.service
readonly MODULES_FILE=/etc/modules-load.d/tunnel-optimizer.conf
readonly MODPROBE_CT=/etc/modprobe.d/tunnel-conntrack.conf
readonly JOURNAL_FILE=/etc/systemd/journald.conf.d/tunnel-size.conf
readonly LIMITS_FILE=/etc/security/limits.d/99-tunnel.conf
readonly SYSTEMD_LIMITS=/etc/systemd/system.conf.d/99-tunnel-limits.conf
readonly DROPIN_NAME=99-tunnel-limits.conf
readonly DOCKER_DAEMON=/etc/docker/daemon.json
readonly CHAIN_MANGLE=TUNNEL_OPT
readonly CHAIN_INPUT=TUNNEL_OPT_IN

MODE="${MODE:-auto}"
DISABLE_IPV6="${DISABLE_IPV6:-0}"
ENABLE_IPV6_FORWARD="${ENABLE_IPV6_FORWARD:-0}"
SKIP_RESTART="${SKIP_RESTART:-0}"
AUTO_SWAP="${AUTO_SWAP:-1}"
TUNE_DOCKER="${TUNE_DOCKER:-1}"
TUNE_NIC="${TUNE_NIC:-1}"
TUNE_NIC_CHANNELS="${TUNE_NIC_CHANNELS:-1}"
MSS_CLAMP="${MSS_CLAMP:-1}"

case "$MODE" in
    auto|max|safe) ;;
    *) echo "MODE نامعتبر است. یکی از auto، max یا safe." >&2; exit 1 ;;
esac

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
info(){ printf '%s➜%s %s\n' "$C" "$N" "$*"; }
ok(){   printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s⚠%s %s\n' "$Y" "$N" "$*"; }
die(){  printf '%s✖%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
trap 'warn "خطا در خط ${LINENO}: ${BASH_COMMAND}"' ERR

backup_file() {
    local src=$1
    [ -e "$src" ] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$src" "$BACKUP_DIR/$(printf '%s' "$src" | tr '/' '_')"
}

write_file() {
    local path=$1 mode=${2:-0644} tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
    mkdir -p "$(dirname "$path")"
    backup_file "$path"
    install -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
    return 0
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
        apt)     apt-get update -qq >/dev/null 2>&1 || true ;;
        dnf|yum) "$PM" makecache -q >/dev/null 2>&1 || true ;;
        pacman)  pacman -Sy --noconfirm >/dev/null 2>&1 || true ;;
        *)       return 0 ;;
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

mem_mb() { awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo; }
cpu_count() { nproc 2>/dev/null || echo 1; }

is_tunnel_unit() {
    case "$1" in
        docker.service|containerd.service) return 0 ;;
        backhaul*.service|gost*.service|rathole*.service|frps.service|frpc.service|frp*.service) return 0 ;;
        haproxy.service|nginx.service|caddy.service) return 0 ;;
        sing-box.service|xray.service|hysteria*.service|tuic*.service) return 0 ;;
        wstunnel*.service|chisel*.service|brook*.service|realm*.service) return 0 ;;
        wg-quick@*.service|wireguard.service) return 0 ;;
        shadowsocks*.service|ss-server.service|ipt2socks*.service) return 0 ;;
        *tunnel*.service) return 0 ;;
        *) return 1 ;;
    esac
}

scale_profile() {
    local mem=$1 cpus=$2
    NOFILE=1048576
    NPROC=65535
    FILE_MAX=2097152
    case "$MODE" in
        safe)
            RMEM_MAX=4194304; WMEM_MAX=4194304; CT_MAX=65536; SOMAX=4096
            BACKLOG=8192; BUDGET=300; BUDGET_US=4000; BUSY=0
            ;;
        max)
            if   [ "$mem" -ge 8192 ]; then RMEM_MAX=33554432; WMEM_MAX=33554432; CT_MAX=1048576; SOMAX=32768
            elif [ "$mem" -ge 4096 ]; then RMEM_MAX=16777216; WMEM_MAX=16777216; CT_MAX=524288;  SOMAX=16384
            elif [ "$mem" -ge 2048 ]; then RMEM_MAX=8388608;  WMEM_MAX=8388608;  CT_MAX=262144;  SOMAX=8192
            else                           RMEM_MAX=4194304;  WMEM_MAX=4194304;  CT_MAX=131072;  SOMAX=4096
            fi
            BACKLOG=65536; BUDGET=600; BUDGET_US=8000
            if [ "$cpus" -ge 4 ]; then BUSY=50; else BUSY=0; fi
            ;;
        *)
            if   [ "$mem" -ge 8192 ]; then RMEM_MAX=16777216; WMEM_MAX=16777216; CT_MAX=524288; SOMAX=16384
            elif [ "$mem" -ge 4096 ]; then RMEM_MAX=16777216; WMEM_MAX=16777216; CT_MAX=262144; SOMAX=8192
            elif [ "$mem" -ge 2048 ]; then RMEM_MAX=8388608;  WMEM_MAX=8388608;  CT_MAX=131072; SOMAX=8192
            else                           RMEM_MAX=4194304;  WMEM_MAX=4194304;  CT_MAX=65536;  SOMAX=4096
            fi
            if [ "$cpus" -le 1 ]; then
                BACKLOG=16384; BUDGET=300; BUDGET_US=4000; BUSY=0
            elif [ "$cpus" -le 4 ]; then
                BACKLOG=32768; BUDGET=600; BUDGET_US=6000; BUSY=0
            else
                BACKLOG=65536; BUDGET=600; BUDGET_US=8000; BUSY=0
            fi
            ;;
    esac
    CT_HASH=$(( CT_MAX / 4 ))
    MIN_FREE=$(( mem * 16 ))
    TW_BUCKETS=$(( CT_MAX / 4 ))
    if [ "$CT_HASH" -lt 16384 ]; then CT_HASH=16384; fi
    if [ "$MIN_FREE" -lt 16384 ]; then MIN_FREE=16384; fi
    if [ "$MIN_FREE" -gt 262144 ]; then MIN_FREE=262144; fi
    if [ "$TW_BUCKETS" -lt 32768 ]; then TW_BUCKETS=32768; fi
    if [ "$TW_BUCKETS" -gt 500000 ]; then TW_BUCKETS=500000; fi
    return 0
}

pick_cc() {
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true
    local avail
    avail=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)
    CC=cubic
    QDISC=fq_codel
    if grep -qw bbr2 <<<"$avail"; then
        CC=bbr2; QDISC=fq
    elif grep -qw bbr <<<"$avail"; then
        CC=bbr; QDISC=fq
    fi
    return 0
}

print_status() {
    local cc qdisc fwd rp mark ct ctmax iface
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')
    fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')
    rp=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo '?')
    mark=$(sysctl -n net.ipv4.conf.all.src_valid_mark 2>/dev/null || echo '?')
    ctmax=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 'n/a')
    ct=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 'n/a')
    iface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)
    echo
    printf '%sTunnel Optimizer — وضعیت%s\n' "$B" "$N"
    echo "  congestion:        $cc"
    echo "  default qdisc:     $qdisc"
    echo "  ip_forward:        $fwd   (تانل باید 1 باشد)"
    echo "  rp_filter:         $rp    (باید 0 یا 2 باشد)"
    echo "  src_valid_mark:    $mark"
    echo "  conntrack:         ${ct} / ${ctmax}"
    echo "  ulimit -n (shell): $(ulimit -n 2>/dev/null || echo '?')  (این عدد نشست SSH است، نه خود تانل)"
    echo "  default iface:     ${iface:-?}"
    if [ -n "${iface:-}" ] && command -v tc >/dev/null 2>&1; then
        echo "  root qdisc:        $(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1{print $2}' || true)"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        echo
        echo "  سرویس‌های مرتبط:"
        local unit
        while read -r unit; do
            is_tunnel_unit "$unit" || continue
            systemctl is-active "$unit" >/dev/null 2>&1 || continue
            printf '    %-40s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
        done < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}')
    fi
    if [ -f "$SYSCTL_MAIN" ]; then
        echo
        ok "sysctl تانل نصب است: $SYSCTL_MAIN"
    else
        warn "هنوز sysctl تانل نصب نشده."
    fi
    echo
}

remove_firewall_hooks() {
    local bin
    for bin in iptables ip6tables; do
        command -v "$bin" >/dev/null 2>&1 || continue
        while "$bin" -t mangle -D POSTROUTING -j "$CHAIN_MANGLE" 2>/dev/null; do :; done
        "$bin" -t mangle -F "$CHAIN_MANGLE" 2>/dev/null || true
        "$bin" -t mangle -X "$CHAIN_MANGLE" 2>/dev/null || true
        while "$bin" -D INPUT -j "$CHAIN_INPUT" 2>/dev/null; do :; done
        "$bin" -F "$CHAIN_INPUT" 2>/dev/null || true
        "$bin" -X "$CHAIN_INPUT" 2>/dev/null || true
    done
}

discover_units() {
    FOUND_UNITS=()
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit
    while read -r unit; do
        [ -n "$unit" ] || continue
        if is_tunnel_unit "$unit"; then
            FOUND_UNITS+=("$unit")
        fi
    done < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}')
    return 0
}

apply_unit_limits() {
    MODIFIED_UNITS=()
    local unit dir
    for unit in "${FOUND_UNITS[@]+"${FOUND_UNITS[@]}"}"; do
        dir="/etc/systemd/system/${unit}.d"
        if write_file "${dir}/${DROPIN_NAME}" <<EOF
[Service]
LimitNOFILE=${NOFILE}
LimitNPROC=${NPROC}
LimitMEMLOCK=infinity
TasksMax=infinity
EOF
        then
            MODIFIED_UNITS+=("$unit")
        fi
    done
    systemctl daemon-reload || true
    return 0
}

tune_docker_daemon() {
    DOCKER_CHANGED=0
    [ "$TUNE_DOCKER" = "1" ] || return 0
    if ! command -v docker >/dev/null 2>&1 && [ ! -f /lib/systemd/system/docker.service ] && [ ! -f /usr/lib/systemd/system/docker.service ]; then
        return 0
    fi
    mkdir -p /etc/docker "$STATE_DIR"
    if ! command -v python3 >/dev/null 2>&1; then
        if [ ! -f "$DOCKER_DAEMON" ]; then
            write_file "$DOCKER_DAEMON" <<'EOF' || true
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" },
  "live-restore": true,
  "default-ulimits": { "nofile": { "Name": "nofile", "Hard": 1048576, "Soft": 1048576 } }
}
EOF
            DOCKER_CHANGED=1
            echo created > "${STATE_DIR}/docker-daemon.created"
        else
            warn "python3 نیست و daemon.json از قبل هست. برای حفظ mirror دست نخورده ماند."
        fi
        return 0
    fi
    if [ -f "$DOCKER_DAEMON" ] && [ ! -f "${STATE_DIR}/docker-daemon.json.orig" ]; then
        cp -a "$DOCKER_DAEMON" "${STATE_DIR}/docker-daemon.json.orig"
    fi
    local rc
    set +e
    python3 - "$DOCKER_DAEMON" <<'PY'
import json, os, sys
path = sys.argv[1]
created = not os.path.exists(path)
data = {}
if not created and open(path, encoding="utf-8").read().strip():
    data = json.loads(open(path, encoding="utf-8").read())
if not isinstance(data, dict):
    sys.exit(1)
ul = data.get("default-ulimits") or {}
if not isinstance(ul, dict):
    ul = {}
ul["nofile"] = {"Name": "nofile", "Hard": 1048576, "Soft": 1048576}
data["default-ulimits"] = ul
opts = data.get("log-opts") or {}
if not isinstance(opts, dict):
    opts = {}
opts.setdefault("max-size", "20m")
opts.setdefault("max-file", "3")
data["log-opts"] = opts
data.setdefault("log-driver", "json-file")
data.setdefault("live-restore", True)
text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
old = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
if old == text:
    sys.exit(10)
tmp = path + ".tunopt-tmp"
open(tmp, "w", encoding="utf-8").write(text)
os.chmod(tmp, 0o644)
os.replace(tmp, path)
sys.exit(2 if created else 0)
PY
    rc=$?
    set -e
    case "$rc" in
        0) DOCKER_CHANGED=1; ok "سقف nofile داکر ادغام شد." ;;
        2) DOCKER_CHANGED=1; echo created > "${STATE_DIR}/docker-daemon.created"; ok "daemon.json ساخته شد." ;;
        10) ok "daemon.json از قبل مناسب بود." ;;
        *) warn "daemon.json دست نخورده ماند." ;;
    esac
    return 0
}

restore_docker_daemon() {
    if [ -f "${STATE_DIR}/docker-daemon.created" ] && [ ! -f "${STATE_DIR}/docker-daemon.json.orig" ]; then
        rm -f "$DOCKER_DAEMON" "${STATE_DIR}/docker-daemon.created"
        return 0
    fi
    if [ -f "${STATE_DIR}/docker-daemon.json.orig" ]; then
        cp -a "${STATE_DIR}/docker-daemon.json.orig" "$DOCKER_DAEMON"
        rm -f "${STATE_DIR}/docker-daemon.json.orig"
    fi
    return 0
}

uninstall_all() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || die "حذف باید با root باشد."
    info "حذف تنظیمات Tunnel Optimizer..."
    systemctl disable --now tunnel-net-tweaks.service >/dev/null 2>&1 || true
    rm -f "$NET_UNIT" "$NET_SCRIPT" "$SYSCTL_MAIN" "$SYSCTL_IPV6" \
          "$MODULES_FILE" "$MODPROBE_CT" "$JOURNAL_FILE" "$LIMITS_FILE" "$SYSTEMD_LIMITS"
    rm -f /etc/systemd/system/tunnel-net-tweaks.service.d/override.conf
    rmdir --ignore-fail-on-non-empty /etc/systemd/system/tunnel-net-tweaks.service.d 2>/dev/null || true
    discover_units
    local unit
    for unit in "${FOUND_UNITS[@]+"${FOUND_UNITS[@]}"}"; do
        rm -f "/etc/systemd/system/${unit}.d/${DROPIN_NAME}"
        rmdir --ignore-fail-on-non-empty "/etc/systemd/system/${unit}.d" 2>/dev/null || true
    done
    remove_firewall_hooks
    restore_docker_daemon
    systemctl daemon-reload || true
    sysctl --system >/dev/null 2>&1 || true
    ok "فایل‌های بهینه‌ساز تانل حذف شد. خود تانل و swap دست نخورده‌اند."
    warn "یک ریبوت، تنظیم باقی‌مانده داخل حافظه را هم برمی‌دارد. ریبوت اجباری نیست."
}

if [ "${1:-}" = "--status" ]; then
    print_status
    exit 0
fi
if [ "${1:-}" = "--uninstall" ]; then
    uninstall_all
    exit 0
fi
if [ -n "${1:-}" ]; then
    die "آرگومان ناشناخته: ${1}"
fi
[ "${EUID:-$(id -u)}" -eq 0 ] || die "با root اجرا کن: sudo bash tunnel-optimizer.sh"

detect_pm
VIRT=$(systemd-detect-virt 2>/dev/null || echo none)
MEM_MB=$(mem_mb)
CPUS=$(cpu_count)
KERNEL=$(uname -r)
scale_profile "$MEM_MB" "$CPUS"
pick_cc
mkdir -p "$STATE_DIR"
printf '%s\n' "$VERSION" > "${STATE_DIR}/version"

if systemctl cat pg-node.service >/dev/null 2>&1 || systemctl cat pg-node-service.service >/dev/null 2>&1; then
    warn "روی این ماشین سرویس نود PasarGuard هم هست. این اسکریپت برای سرور تانل است."
fi

echo
printf '%sTunnel Optimizer v%s%s\n' "$B" "$VERSION" "$N"
info "پروفایل: ${MODE} | بسته: ${PM} | مجازی‌سازی: ${VIRT}"
info "سخت‌افزار: ${CPUS} هسته | ${MEM_MB}MB رم | کرنل ${KERNEL}"

case "$VIRT" in
    lxc|docker|podman|openvz|systemd-nspawn)
        warn "داخل کانتینر هستی. اسکریپت را روی خود سرور تانل اجرا کن."
        TUNE_NIC=0
        ;;
esac

if [ "$PM" != "none" ]; then
    info "نصب ابزار شبکه..."
    pm_update
    pm_install iproute2 ethtool iptables kmod ca-certificates || true
    pm_install conntrack || pm_install conntrack-tools || true
    if [ "$CPUS" -gt 1 ]; then
        pm_install irqbalance || true
        systemctl enable --now irqbalance >/dev/null 2>&1 || true
    fi
fi

info "همگام‌سازی ساعت..."
if pm_install chrony; then
    systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
    systemctl enable --now chrony >/dev/null 2>&1 \
        || systemctl enable --now chronyd >/dev/null 2>&1 \
        || warn "chrony بالا نیامد."
    chronyc makestep >/dev/null 2>&1 || true
    ok "ساعت همگام شد."
else
    warn "chrony نصب نشد."
fi

if [ "$AUTO_SWAP" = "1" ] && [ "$VIRT" != "openvz" ] && [ "$VIRT" != "lxc" ]; then
    SWAP_TOTAL=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
    if [ "${SWAP_TOTAL:-0}" -eq 0 ] && [ ! -f /swapfile ] && [ "$MEM_MB" -lt 4096 ]; then
        if [ "$MEM_MB" -lt 2048 ]; then SWAP_SIZE=1G; SWAP_MB=1024; else SWAP_SIZE=2G; SWAP_MB=2048; fi
        FREE_DISK_MB=$(df -m / | awk 'NR==2 {print $4}')
        if [ "${FREE_DISK_MB:-0}" -gt $(( SWAP_MB + 2048 )) ]; then
            info "ساخت ${SWAP_SIZE} swap..."
            if fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none; then
                chmod 600 /swapfile
                mkswap /swapfile >/dev/null
                swapon /swapfile >/dev/null 2>&1 || true
                grep -q '[[:space:]]/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
                ok "Swap ${SWAP_SIZE} فعال شد."
            fi
        fi
    else
        ok "Swap لازم نبود یا از قبل هست."
    fi
fi

info "بالا بردن سقف فایل برای سرویس تانل..."
write_file "$LIMITS_FILE" <<EOF || true
*    soft nofile ${NOFILE}
*    hard nofile ${NOFILE}
root soft nofile ${NOFILE}
root hard nofile ${NOFILE}
*    soft nproc  ${NPROC}
*    hard nproc  ${NPROC}
root soft nproc unlimited
root hard nproc unlimited
*    soft memlock unlimited
*    hard memlock unlimited
EOF
write_file "$SYSTEMD_LIMITS" <<EOF || true
[Manager]
DefaultLimitNOFILE=${NOFILE}
DefaultLimitNPROC=${NPROC}
DefaultLimitMEMLOCK=infinity
EOF
discover_units
if [ "${#FOUND_UNITS[@]}" -eq 0 ]; then
    warn "سرویس backhaul/gost/wireguard/docker پیدا نشد. حد سیستمی اعمال می‌شود."
else
    info "سرویس‌های هدف: ${FOUND_UNITS[*]}"
fi
apply_unit_limits
tune_docker_daemon
ok "سقف nofile روی ${NOFILE} تنظیم شد."

info "بارگذاری BBR، conntrack و ماژول تانل..."
for mod in tcp_bbr sch_fq nf_conntrack nf_nat wireguard tun gre ipip; do
    modprobe "$mod" 2>/dev/null || true
done
pick_cc
if [ "$CC" = "cubic" ]; then
    warn "BBR در این کرنل نیست. برای تانل بهتر است کرنل ۵.۱۵ به بالا باشد."
fi
write_file "$MODULES_FILE" <<'EOF' || true
tcp_bbr
sch_fq
nf_conntrack
wireguard
tun
EOF
write_file "$MODPROBE_CT" <<EOF || true
options nf_conntrack hashsize=${CT_HASH}
EOF

# rp_filter شل است تا برگشت ترافیک WireGuard / تانل نامتقارن دور ریخته نشود.
write_file "$SYSCTL_MAIN" <<EOF || true
# Tunnel host tuning — profile ${MODE}
# ${CPUS} cpus / ${MEM_MB} MB

net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
net.ipv4.conf.default.src_valid_mark = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 0

net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = ${CC}

net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.optmem_max = 131072
net.ipv4.tcp_rmem = 4096 131072 ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 131072 ${WMEM_MAX}
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1

net.core.netdev_max_backlog = ${BACKLOG}
net.core.netdev_budget = ${BUDGET}
net.core.netdev_budget_usecs = ${BUDGET_US}
net.core.somaxconn = ${SOMAX}
net.core.busy_poll = ${BUSY}
net.core.busy_read = ${BUSY}

net.ipv4.tcp_max_syn_backlog = ${SOMAX}
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = ${TW_BUCKETS}
net.ipv4.tcp_max_orphans = 131072
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh3 = 8192

fs.file-max = ${FILE_MAX}
fs.nr_open = ${FILE_MAX}
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 1
vm.min_free_kbytes = ${MIN_FREE}
vm.zone_reclaim_mode = 0
kernel.pid_max = 4194304
kernel.panic = 10
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF

if [ "$ENABLE_IPV6_FORWARD" = "1" ]; then
    warn "فوروارد IPv6 روشن شد. اگر آدرس v6 با SLAAC می‌گیری ممکن است مسیر پیش‌فرض بیفتد."
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
fi

sysctl -e -p "$SYSCTL_MAIN" >/dev/null 2>&1 || warn "بعضی کلیدهای sysctl روی این کرنل نیستند."
for rp in /proc/sys/net/ipv4/conf/*/rp_filter; do
    [ -w "$rp" ] && echo 2 > "$rp" 2>/dev/null || true
done
for mk in /proc/sys/net/ipv4/conf/*/src_valid_mark; do
    [ -w "$mk" ] && echo 1 > "$mk" 2>/dev/null || true
done

if [ "$DISABLE_IPV6" = "1" ]; then
    warn "IPv6 خاموش می‌شود."
    write_file "$SYSCTL_IPV6" <<'EOF' || true
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl -e -p "$SYSCTL_IPV6" >/dev/null 2>&1 || true
elif [ -f "$SYSCTL_IPV6" ]; then
    backup_file "$SYSCTL_IPV6"
    rm -f "$SYSCTL_IPV6"
    sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 \
               net.ipv6.conf.lo.disable_ipv6=0 2>/dev/null || true
fi
ok "کرنل تانل اعمال شد: ${CC} + ${QDISC} | forward=1 | conntrack=${CT_MAX}"

info "سرویس بوت کارت شبکه و MSS..."
write_file "$NET_SCRIPT" 0755 <<'EOF' || true
#!/usr/bin/env bash
set -u
SYSCTL_MAIN=/etc/sysctl.d/99-tunnel-optimize.conf
CHAIN_MANGLE=TUNNEL_OPT
MSS_CLAMP="${MSS_CLAMP:-1}"
TUNE_NIC="${TUNE_NIC:-1}"
TUNE_NIC_CHANNELS="${TUNE_NIC_CHANNELS:-1}"

[ -f "$SYSCTL_MAIN" ] && sysctl -e -p "$SYSCTL_MAIN" >/dev/null 2>&1 || true
modprobe tcp_bbr 2>/dev/null || true
modprobe sch_fq 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true
modprobe wireguard 2>/dev/null || true
modprobe tun 2>/dev/null || true

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    ip -4 route show default 2>/dev/null | grep -q . && break
    sleep 1
done

MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
CPUS=$(nproc 2>/dev/null || echo 1)
if [ -z "${CT_MAX:-}" ]; then
    if   [ "${MEM_MB:-0}" -ge 8192 ]; then CT_MAX=524288
    elif [ "${MEM_MB:-0}" -ge 4096 ]; then CT_MAX=262144
    elif [ "${MEM_MB:-0}" -ge 2048 ]; then CT_MAX=131072
    else CT_MAX=65536; fi
fi
if [ -z "${CT_HASH:-}" ]; then
    CT_HASH=$(( CT_MAX / 4 ))
    [ "$CT_HASH" -lt 16384 ] && CT_HASH=16384
fi
if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
    echo "$CT_HASH" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
fi
sysctl -e -qw \
    net.ipv4.ip_forward=1 \
    net.ipv4.conf.all.src_valid_mark=1 \
    net.ipv4.conf.all.rp_filter=2 \
    net.ipv4.conf.default.rp_filter=2 \
    net.netfilter.nf_conntrack_max="$CT_MAX" \
    net.netfilter.nf_conntrack_buckets="$CT_HASH" \
    net.netfilter.nf_conntrack_tcp_be_liberal=1 \
    net.netfilter.nf_conntrack_tcp_timeout_established=7200 \
    net.netfilter.nf_conntrack_tcp_timeout_time_wait=30 \
    net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30 \
    net.netfilter.nf_conntrack_tcp_timeout_close_wait=15 \
    net.netfilter.nf_conntrack_udp_timeout=60 \
    net.netfilter.nf_conntrack_udp_timeout_stream=300 \
    2>/dev/null || true
for rp in /proc/sys/net/ipv4/conf/*/rp_filter; do
    [ -w "$rp" ] && echo 2 > "$rp" 2>/dev/null || true
done
for mk in /proc/sys/net/ipv4/conf/*/src_valid_mark; do
    [ -w "$mk" ] && echo 1 > "$mk" 2>/dev/null || true
done

if [ "$MSS_CLAMP" = "1" ] && command -v iptables >/dev/null 2>&1; then
    while iptables -t mangle -D POSTROUTING -j "$CHAIN_MANGLE" 2>/dev/null; do :; done
    iptables -t mangle -F "$CHAIN_MANGLE" 2>/dev/null || true
    iptables -t mangle -X "$CHAIN_MANGLE" 2>/dev/null || true
    iptables -t mangle -N "$CHAIN_MANGLE" 2>/dev/null || true
    iptables -t mangle -A POSTROUTING -j "$CHAIN_MANGLE" 2>/dev/null || true
    iptables -t mangle -A "$CHAIN_MANGLE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi

cpu_mask() {
    local cpus=$1 n i base count hex groups=()
    n=$(( (cpus + 31) / 32 ))
    for ((i = 0; i < n; i++)); do
        base=$(( i * 32 ))
        count=$(( cpus - base ))
        if [ "$count" -ge 32 ]; then groups+=(ffffffff)
        else hex=$(printf '%x' $(( (1 << count) - 1 ))); groups+=("$hex"); fi
    done
    local IFS=,
    printf '%s\n' "${groups[*]}"
}

tune_iface() {
    local IFACE=$1 root handles handle rx_count mask
    [ -d "/sys/class/net/$IFACE" ] || return 0
    ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null || true
    if command -v tc >/dev/null 2>&1; then
        root=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1{print $2}')
        case "$root" in
            mq|mqprio)
                handles=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk '$2=="fq_codel" || $2=="pfifo_fast" || $2=="pfifo" {print $5}')
                for handle in $handles; do
                    [ -n "$handle" ] || continue
                    tc qdisc replace dev "$IFACE" parent "$handle" fq 2>/dev/null || true
                done
                ;;
            fq|fq_pie) ;;
            *) tc qdisc replace dev "$IFACE" root fq 2>/dev/null || true ;;
        esac
    fi
    if command -v ethtool >/dev/null 2>&1; then
        ethtool -K "$IFACE" gro on 2>/dev/null || true
        ethtool -K "$IFACE" gso on 2>/dev/null || true
        ethtool -K "$IFACE" tso on 2>/dev/null || true
        local ring
        for ring in 4096 2048 1024 512; do
            ethtool -G "$IFACE" rx "$ring" tx "$ring" 2>/dev/null && break
        done
        if [ "$TUNE_NIC_CHANNELS" = "1" ] && [ "$CPUS" -gt 1 ]; then
            local maxc curc target
            maxc=$(ethtool -l "$IFACE" 2>/dev/null | awk 'f && /Combined:/ {print $2; exit} /Pre-set maximums/ {f=1}')
            curc=$(ethtool -l "$IFACE" 2>/dev/null | awk 'f && /Combined:/ {print $2; exit} /Current hardware settings/ {f=1}')
            if [[ "${maxc:-}" =~ ^[0-9]+$ ]] && [ "$maxc" -gt 1 ]; then
                target=$CPUS
                [ "$target" -gt "$maxc" ] && target=$maxc
                if [[ "${curc:-}" =~ ^[0-9]+$ ]] && [ "$curc" -lt "$target" ]; then
                    ethtool -L "$IFACE" combined "$target" 2>/dev/null || true
                fi
            fi
        fi
    fi
    rx_count=$(find "/sys/class/net/$IFACE/queues" -maxdepth 1 -name 'rx-*' 2>/dev/null | wc -l)
    if [ "$CPUS" -gt 1 ] && [ "${rx_count:-0}" -eq 1 ]; then
        mask=$(cpu_mask "$CPUS")
        sysctl -qw net.core.rps_sock_flow_entries=32768 2>/dev/null || true
        for rx in /sys/class/net/"$IFACE"/queues/rx-*; do
            [ -e "$rx/rps_cpus" ] && echo "$mask" > "$rx/rps_cpus" 2>/dev/null || true
            [ -e "$rx/rps_flow_cnt" ] && echo 32768 > "$rx/rps_flow_cnt" 2>/dev/null || true
        done
    fi
}

if [ "$TUNE_NIC" = "1" ]; then
    for path in /sys/class/net/*; do
        iface=$(basename "$path")
        case "$iface" in
            lo|docker*|veth*|br-*|virbr*|wg*|tun*|sit*|gre*|gretap*|ipip*|dummy*|flannel*|cni*|ifb*) continue ;;
        esac
        state=$(cat "$path/operstate" 2>/dev/null || echo down)
        [ "$state" = "up" ] || [ "$state" = "unknown" ] || continue
        tune_iface "$iface"
    done
fi

if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -w "$gov" ] && echo performance > "$gov" 2>/dev/null || true
    done
fi
exit 0
EOF

write_file "$NET_UNIT" <<'EOF' || true
[Unit]
Description=Tunnel host tuning (forward, BBR, conntrack, MSS, NIC)
After=network.target systemd-modules-load.service
Before=docker.service backhaul.service gost.service wg-quick@wg0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/tunnel-net-tweaks.sh

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/tunnel-net-tweaks.service.d
write_file /etc/systemd/system/tunnel-net-tweaks.service.d/override.conf <<EOF || true
[Service]
Environment=MSS_CLAMP=${MSS_CLAMP}
Environment=TUNE_NIC=${TUNE_NIC}
Environment=TUNE_NIC_CHANNELS=${TUNE_NIC_CHANNELS}
Environment=CT_MAX=${CT_MAX}
Environment=CT_HASH=${CT_HASH}
EOF
systemctl daemon-reload
systemctl enable tunnel-net-tweaks.service >/dev/null 2>&1 || true
systemctl restart tunnel-net-tweaks.service || warn "سرویس کارت شبکه هشدار داد. journalctl -u tunnel-net-tweaks -n 40"
ok "فوروارد، MSS و صف کارت شبکه ماندگار شد."

info "سقف ژورنال..."
if write_file "$JOURNAL_FILE" <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=40M
MaxRetentionSec=5day
EOF
then
    systemctl restart systemd-journald >/dev/null 2>&1 || true
fi
ok "ژورنال محدود شد."

wait_docker() {
    local i
    for i in $(seq 1 30); do
        docker info >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

restart_tunnel_services() {
    [ "$SKIP_RESTART" = "1" ] && return 0
    local unit pid soft
    for unit in "${FOUND_UNITS[@]+"${FOUND_UNITS[@]}"}"; do
        case "$unit" in
            docker.service|containerd.service) continue ;;
        esac
        pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null || echo 0)
        soft=0
        if [ "${pid:-0}" -gt 0 ] 2>/dev/null && [ -r "/proc/$pid/limits" ]; then
            soft=$(awk '/Max open files/ {print $4}' "/proc/$pid/limits" 2>/dev/null || echo 0)
        fi
        if [ "$soft" -lt "$NOFILE" ] 2>/dev/null; then
            systemctl try-restart "$unit" >/dev/null 2>&1 && ok "ری‌استارت شد: $unit" || true
        fi
    done
    return 0
}

recreate_tunnel_containers() {
    [ "$SKIP_RESTART" = "1" ] && return 0
    [ "$TUNE_DOCKER" = "1" ] || return 0
    command -v docker >/dev/null 2>&1 || return 0
    local -A seen=()
    local id img name dir f low=0 compose_bin soft
    while read -r id img name; do
        [ -n "${id:-}" ] || continue
        case "$img$name" in
            *pasarguard/node*|*pg-node*) continue ;;
        esac
        case "$img$name" in
            *backhaul*|*gost*|*rathole*|*frp*|*frps*|*frpc*|*wstunnel*|*chisel*|*brook*|*haproxy*|*nginx*|*caddy*|*wireguard*|*sing-box*|*xray*|*hysteria*|*tunnel*|*realm*)
                ;;
            *) continue ;;
        esac
        soft=$(docker inspect "$id" --format '{{range .HostConfig.Ulimits}}{{if eq .Name "nofile"}}{{.Soft}}{{end}}{{end}}' 2>/dev/null || true)
        [ -z "$soft" ] && soft=1024
        dir=$(docker inspect "$id" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
        if [ "$soft" -lt "$NOFILE" ] 2>/dev/null; then
            low=1
            [ -n "$dir" ] && seen[$dir]=1
        fi
    done < <(docker ps -a --format '{{.ID}} {{.Image}} {{.Names}}' 2>/dev/null || true)

    if [ "$low" -eq 1 ] || [ "${DOCKER_CHANGED:-0}" = "1" ]; then
        shopt -s nullglob
        for f in /opt/*/docker-compose.yml /opt/*/docker-compose.yaml /root/*/docker-compose.yml /root/*/docker-compose.yaml; do
            grep -Eiq 'backhaul|gost|rathole|frp|wstunnel|haproxy|wireguard|sing-box|xray|hysteria|tunnel' "$f" || continue
            grep -Eiq 'pasarguard/node' "$f" && continue
            seen["$(dirname "$f")"]=1
        done
        shopt -u nullglob
    fi

    if [ "$low" -eq 0 ] && [ "${DOCKER_CHANGED:-0}" != "1" ]; then
        ok "کانتینر تانل سقف فایل جدا نمی‌خواهد، یا داکر تانل نداری."
        return 0
    fi
    if [ "${#seen[@]}" -eq 0 ] && [ "${DOCKER_CHANGED:-0}" != "1" ]; then
        return 0
    fi

    info "ری‌استارت Docker تا سقف فایل تانل اعمال شود. چند ثانیه قطع می‌شود..."
    systemctl restart containerd >/dev/null 2>&1 || true
    if ! systemctl restart docker; then
        warn "ری‌استارت docker ناموفق بود."
        return 1
    fi
    wait_docker || { warn "docker بالا نیامد."; return 1; }

    if [ "${#seen[@]}" -eq 0 ]; then
        ok "daemon داکر به‌روز شد. کانتینر تانل برای recreate پیدا نشد."
        return 0
    fi
    if docker compose version >/dev/null 2>&1; then compose_bin="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then compose_bin="docker-compose"
    else
        warn "docker compose پیدا نشد."
        return 1
    fi
    for dir in "${!seen[@]}"; do
        [ -d "$dir" ] || continue
        info "ساخت مجدد تانل در ${dir}"
        if (cd "$dir" && $compose_bin up -d --force-recreate); then
            ok "دوباره ساخته شد: ${dir}"
        else
            warn "ساخت مجدد ${dir} ناموفق بود."
        fi
    done
    while read -r id img name; do
        [ -n "${name:-}" ] || continue
        case "$img$name" in
            *backhaul*|*gost*|*rathole*|*frp*|*tunnel*|*haproxy*|*wstunnel*) ;;
            *) continue ;;
        esac
        soft=$(docker exec "$name" sh -c 'ulimit -n' 2>/dev/null || echo '?')
        if [ "$soft" = "$NOFILE" ]; then ok "nofile داخل ${name}: ${soft}"
        else warn "nofile داخل ${name}: ${soft}"; fi
    done < <(docker ps --format '{{.ID}} {{.Image}} {{.Names}}' 2>/dev/null || true)
    return 0
}

restart_tunnel_services || true
recreate_tunnel_containers || warn "بخش داکر تانل کامل نشد. اگر تانلت systemd است و بالا ری‌استارت شده، مهم نیست."

IFACE_NOW=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)
echo
ok "════════════════════════════════════════════════════════"
ok "  سرور تانل برای عبور ترافیک بالا آماده شد"
ok "════════════════════════════════════════════════════════"
echo
echo "  • پروفایل:          ${MODE}"
echo "  • ازدحام:           $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
echo "  • qdisc:            $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
echo "  • ip_forward:       $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
echo "  • rp_filter:        $(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo '?')"
echo "  • src_valid_mark:   $(sysctl -n net.ipv4.conf.all.src_valid_mark 2>/dev/null || echo '?')"
echo "  • سقف conntrack:    $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo '?')"
echo "  • UDP stream:       $(sysctl -n net.netfilter.nf_conntrack_udp_timeout_stream 2>/dev/null || echo '?')"
echo "  • rmem_max:         $(sysctl -n net.core.rmem_max 2>/dev/null || echo '?')"
echo "  • کارت:             ${IFACE_NOW:-?}"
if [ -n "${IFACE_NOW:-}" ] && command -v tc >/dev/null 2>&1; then
    echo "  • qdisc کارت:       $(tc qdisc show dev "$IFACE_NOW" 2>/dev/null | awk 'NR==1{print $2}' || true)"
fi
[ -d "$BACKUP_DIR" ] && info "نسخه قبلی فایل‌ها: $BACKUP_DIR"
echo
ok "کانفیگ خود تانل عوض نشده. ریبوت لازم نیست. وضعیت: bash tunnel-optimizer.sh --status"
echo

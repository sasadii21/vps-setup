#!/usr/bin/env bash
# =============================================================================
#  PasarGuard Node Optimizer
#  بهینه‌ساز سطح سیستم برای نود PasarGuard (نصب رسمی Docker یا systemd)
#
#  مناسب ترافیک همزمان بالا: VLESS / Reality / Trojan / Hysteria / TUIC / WireGuard
#  کانفیگ Xray، گواهی، پورت، API پنل و قوانین nft خودِ نود را تغییر نمی‌دهد.
#
#  اجرا:
#    sudo bash pg-node-optimizer.sh
#
#  پروفایل:
#    sudo MODE=auto bash pg-node-optimizer.sh     # پیش‌فرض، مقیاس با RAM و CPU
#    sudo MODE=max  bash pg-node-optimizer.sh     # سقف بالاتر بافر و RPS
#    sudo MODE=safe bash pg-node-optimizer.sh     # محافظه‌کار برای VPS یک‌هسته‌ای
#
#  گزینه‌ها (متغیر محیطی):
#    RESTART_SERVICES=1   ری‌استارت سرویس‌های پاسارگارد به‌جز داکر
#    RECREATE_NODE=0      نساز دوباره کانتینر (پیش‌فرض خودش Docker را ری‌استارت و نود را recreate می‌کند)
#    DISABLE_IPV6=1       خاموش کردن IPv6 (اگر اینباند v6 داری نزن)
#    AUTO_SWAP=0          نساختن swap
#    TUNE_DOCKER=0        دست نزدن به /etc/docker/daemon.json
#    TUNE_NIC=0           دست نزدن به ethtool / qdisc / RPS
#    TUNE_NIC_CHANNELS=0  زیاد نکردن صف RSS کارت شبکه
#    MSS_CLAMP=0          غیرفعال کردن clamp کردن MSS (پیش‌فرض روشن؛ به WireGuard کمک می‌کند)
#    FIREWALL_DROP_INVALID=1   دراپ بسته INVALID (پیش‌فرض خاموش؛ با بعضی تونل‌ها سازگار نیست)
#
#  وضعیت، بدون تغییر:
#    bash pg-node-optimizer.sh --status
#
#  حذف فقط فایل‌ها و قوانین همین اسکریپت:
#    sudo bash pg-node-optimizer.sh --uninstall
# =============================================================================
set -Eeuo pipefail

readonly VERSION="1.1.0"
readonly STATE_DIR=/var/lib/pg-node-optimizer
readonly BACKUP_DIR="${STATE_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
readonly SYSCTL_MAIN=/etc/sysctl.d/99-pasarguard-node.conf
readonly SYSCTL_IPV6=/etc/sysctl.d/98-pasarguard-ipv6.conf
readonly NET_SCRIPT=/usr/local/sbin/pg-node-net-tweaks.sh
readonly NET_UNIT=/etc/systemd/system/pg-node-net-tweaks.service
readonly MODULES_FILE=/etc/modules-load.d/pasarguard-node.conf
readonly MODPROBE_CT=/etc/modprobe.d/pasarguard-conntrack.conf
readonly JOURNAL_FILE=/etc/systemd/journald.conf.d/pasarguard-size.conf
readonly LIMITS_FILE=/etc/security/limits.d/99-pasarguard-node.conf
readonly SYSTEMD_LIMITS=/etc/systemd/system.conf.d/99-pasarguard-limits.conf
readonly DROPIN_NAME=99-pg-node-limits.conf
readonly DOCKER_DAEMON=/etc/docker/daemon.json
readonly CHAIN_MANGLE=PGNODE_OPT
readonly CHAIN_INPUT=PGNODE_OPT_IN

MODE="${MODE:-auto}"
DISABLE_IPV6="${DISABLE_IPV6:-0}"
RESTART_SERVICES="${RESTART_SERVICES:-0}"
RECREATE_NODE="${RECREATE_NODE:-1}"
AUTO_SWAP="${AUTO_SWAP:-1}"
TUNE_DOCKER="${TUNE_DOCKER:-1}"
TUNE_NIC="${TUNE_NIC:-1}"
TUNE_NIC_CHANNELS="${TUNE_NIC_CHANNELS:-1}"
MSS_CLAMP="${MSS_CLAMP:-1}"
FIREWALL_DROP_INVALID="${FIREWALL_DROP_INVALID:-0}"

case "$MODE" in
    auto|max|safe) ;;
    *) echo "MODE نامعتبر است. یکی از auto، max یا safe را بگذار." >&2; exit 1 ;;
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

# 0 = نوشته شد، 1 = بدون تغییر
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

# کم‌ارزش‌ترین گروه ۳۲بیتی اول است (CPUهای ۰ تا ۳۱).
cpu_mask() {
    local cpus=$1 n i base count hex groups=()
    [ "$cpus" -ge 1 ] || cpus=1
    n=$(( (cpus + 31) / 32 ))
    for ((i = 0; i < n; i++)); do
        base=$(( i * 32 ))
        count=$(( cpus - base ))
        if [ "$count" -ge 32 ]; then
            groups+=(ffffffff)
        else
            hex=$(printf '%x' $(( (1 << count) - 1 )))
            groups+=("$hex")
        fi
    done
    local IFS=,
    printf '%s\n' "${groups[*]}"
}

scale_profile() {
    local mem=$1 cpus=$2
    NOFILE=1048576
    NPROC=65535
    FILE_MAX=2097152
    case "$MODE" in
        safe)
            RMEM_MAX=4194304;  WMEM_MAX=4194304;  CT_MAX=65536;   SOMAX=4096
            BACKLOG=8192; BUDGET=300; BUDGET_US=4000; BUSY=0
            ;;
        max)
            if   [ "$mem" -ge 16384 ]; then RMEM_MAX=67108864; WMEM_MAX=67108864; CT_MAX=1048576; SOMAX=65535
            elif [ "$mem" -ge 8192 ];  then RMEM_MAX=33554432; WMEM_MAX=33554432; CT_MAX=524288;  SOMAX=32768
            elif [ "$mem" -ge 4096 ];  then RMEM_MAX=16777216; WMEM_MAX=16777216; CT_MAX=262144;  SOMAX=16384
            else                            RMEM_MAX=8388608;  WMEM_MAX=8388608;  CT_MAX=131072;  SOMAX=8192
            fi
            BACKLOG=65536; BUDGET=600; BUDGET_US=8000
            if [ "$cpus" -ge 4 ]; then BUSY=50; else BUSY=0; fi
            ;;
        *)
            if   [ "$mem" -ge 16384 ]; then RMEM_MAX=33554432; WMEM_MAX=33554432; CT_MAX=1048576; SOMAX=65535
            elif [ "$mem" -ge 8192 ];  then RMEM_MAX=16777216; WMEM_MAX=16777216; CT_MAX=524288;  SOMAX=32768
            elif [ "$mem" -ge 4096 ];  then RMEM_MAX=16777216; WMEM_MAX=16777216; CT_MAX=262144;  SOMAX=16384
            elif [ "$mem" -ge 2048 ];  then RMEM_MAX=8388608;  WMEM_MAX=8388608;  CT_MAX=131072;  SOMAX=8192
            else                            RMEM_MAX=4194304;  WMEM_MAX=4194304;  CT_MAX=65536;   SOMAX=4096
            fi
            if [ "$cpus" -le 1 ]; then
                BACKLOG=8192; BUDGET=300; BUDGET_US=4000; BUSY=0
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
}

print_status() {
    local cc qdisc fwd rp mark ct ctmax nofile iface
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')
    fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')
    rp=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo '?')
    mark=$(sysctl -n net.ipv4.conf.all.src_valid_mark 2>/dev/null || echo '?')
    ctmax=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 'n/a')
    ct=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 'n/a')
    nofile=$(ulimit -n 2>/dev/null || echo '?')
    iface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)
    echo
    printf '%sPasarGuard Node Optimizer — وضعیت%s\n' "$B" "$N"
    echo "  congestion:        $cc"
    echo "  default qdisc:     $qdisc"
    echo "  ip_forward:        $fwd"
    echo "  rp_filter (all):   $rp    (برای WireGuard/TUN باید 0 یا 2 باشد، نه 1)"
    echo "  src_valid_mark:    $mark  (برای fwmark اکس‌ری و تونل باید 1 باشد)"
    echo "  conntrack:         ${ct} / ${ctmax}"
    echo "  ulimit -n (shell): $nofile"
    echo "  default iface:     ${iface:-?}"
    if [ -n "${iface:-}" ] && command -v tc >/dev/null 2>&1; then
        echo "  root qdisc:        $(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1{print $2}' || true)"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        echo
        echo "  سرویس‌ها:"
        systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null \
            | awk '$1 ~ /^(docker|containerd|pg-node|pasarguard)/ {printf "    %-40s %s\n", $1, $4}' || true
    fi
    if command -v docker >/dev/null 2>&1; then
        echo
        echo "  کانتینرهای پاسارگارد:"
        docker ps --format '    {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null \
            | grep -Ei 'pg-node|pasarguard|node' || echo "    (چیزی پیدا نشد یا docker در دسترس نیست)"
    fi
    if [ -f "$SYSCTL_MAIN" ]; then
        echo
        ok "فایل sysctl این بهینه‌ساز نصب است: $SYSCTL_MAIN"
    else
        warn "هنوز sysctl پاسارگارد نصب نشده."
    fi
    echo
}

remove_firewall_hooks() {
    local bin
    for bin in iptables ip6tables; do
        command -v "$bin" >/dev/null 2>&1 || continue
        "$bin" -t mangle -D POSTROUTING -j "$CHAIN_MANGLE" 2>/dev/null || true
        "$bin" -t mangle -F "$CHAIN_MANGLE" 2>/dev/null || true
        "$bin" -t mangle -X "$CHAIN_MANGLE" 2>/dev/null || true
        "$bin" -D INPUT -j "$CHAIN_INPUT" 2>/dev/null || true
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
        case "$unit" in
            docker.service|containerd.service|xray.service|sing-box.service)
                FOUND_UNITS+=("$unit") ;;
            pg-node*.service|pasarguard*.service)
                FOUND_UNITS+=("$unit") ;;
        esac
    done < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}')
}

apply_unit_limits() {
    MODIFIED_UNITS=()
    local unit dir
    for unit in "${FOUND_UNITS[@]}"; do
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
    systemctl daemon-reload
}

tune_docker_daemon() {
    DOCKER_CHANGED=0
    [ "$TUNE_DOCKER" = "1" ] || return 0
    if ! command -v docker >/dev/null 2>&1 && [ ! -d /etc/docker ] && [ "$PM" = "none" ]; then
        return 0
    fi
    # حتی اگر باینری docker موقتا در PATH نباشد، اگر سرویس هست تنظیم کن
    if ! command -v docker >/dev/null 2>&1 && [ ! -f /lib/systemd/system/docker.service ] && [ ! -f /usr/lib/systemd/system/docker.service ]; then
        info "Docker روی این ماشین نیست؛ از daemon.json عبور می‌کنیم."
        return 0
    fi
    mkdir -p /etc/docker "$STATE_DIR"
    if ! command -v python3 >/dev/null 2>&1; then
        if [ ! -f "$DOCKER_DAEMON" ]; then
            write_file "$DOCKER_DAEMON" <<'EOF' || true
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "3"
  },
  "live-restore": true,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 1048576,
      "Soft": 1048576
    }
  }
}
EOF
            DOCKER_CHANGED=1
            echo created > "${STATE_DIR}/docker-daemon.created"
            ok "daemon.json تازه با ulimit مناسب نود ساخته شد."
        else
            warn "python3 نیست و daemon.json از قبل وجود دارد؛ برای حفظ mirror دست نخورده باقی ماند."
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
if not created:
    with open(path, "r", encoding="utf-8") as fh:
        raw = fh.read().strip()
    if raw:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            sys.stderr.write("daemon.json JSON نامعتبر است: %s\n" % exc)
            sys.exit(1)
    if not isinstance(data, dict):
        sys.stderr.write("daemon.json باید آبجکت JSON باشد.\n")
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
old = ""
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as fh:
        old = fh.read()
if old == text:
    sys.exit(10)
tmp = path + ".pgopt-tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(text)
os.chmod(tmp, 0o644)
os.replace(tmp, path)
sys.exit(2 if created else 0)
PY
    rc=$?
    set -e
    case "$rc" in
        0)  DOCKER_CHANGED=1; ok "سقف nofile داکر و چرخش لاگ، بدون پاک کردن تنظیمات قبلی، ادغام شد." ;;
        2)  DOCKER_CHANGED=1; echo created > "${STATE_DIR}/docker-daemon.created"; ok "daemon.json با ulimit نود ساخته شد." ;;
        10) ok "daemon.json از قبل مناسب نود بود." ;;
        *)  warn "daemon.json دست نخورده ماند تا تنظیم فعلی (مثلاً رجیستری میرور) خراب نشود." ;;
    esac
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
}

uninstall_all() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || die "حذف باید با root انجام شود."
    info "حذف تنظیمات PasarGuard Node Optimizer..."
    systemctl disable --now pg-node-net-tweaks.service >/dev/null 2>&1 || true
    rm -f "$NET_UNIT" "$NET_SCRIPT" "$SYSCTL_MAIN" "$SYSCTL_IPV6" \
          "$MODULES_FILE" "$MODPROBE_CT" "$JOURNAL_FILE" "$LIMITS_FILE" "$SYSTEMD_LIMITS"
    discover_units
    local unit
    for unit in "${FOUND_UNITS[@]}"; do
        rm -f "/etc/systemd/system/${unit}.d/${DROPIN_NAME}"
        rmdir --ignore-fail-on-non-empty "/etc/systemd/system/${unit}.d" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/pg-node-net-tweaks.service.d/override.conf
    rmdir --ignore-fail-on-non-empty /etc/systemd/system/pg-node-net-tweaks.service.d 2>/dev/null || true
    remove_firewall_hooks
    restore_docker_daemon
    systemctl daemon-reload || true
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true
    ok "فایل‌های این بهینه‌ساز حذف شد. swap دست نخورده است."
    warn "یک ری‌استارت سرور تنظیمات درون‌حافظه‌ای باقی‌مانده را هم پاک می‌کند."
}

# -----------------------------------------------------------------------------
# وضعیت / حذف
# -----------------------------------------------------------------------------
if [ "${1:-}" = "--status" ]; then
    print_status
    exit 0
fi

if [ "${1:-}" = "--uninstall" ]; then
    uninstall_all
    exit 0
fi

if [ -n "${1:-}" ]; then
    die "آرگومان ناشناخته: ${1}. فقط --status و --uninstall پشتیبانی می‌شود."
fi

[ "${EUID:-$(id -u)}" -eq 0 ] || die "اسکریپت باید با root اجرا شود. مثال: sudo bash pg-node-optimizer.sh"

detect_pm
VIRT=$(systemd-detect-virt 2>/dev/null || echo none)
MEM_MB=$(mem_mb)
CPUS=$(cpu_count)
KERNEL=$(uname -r)
scale_profile "$MEM_MB" "$CPUS"
pick_cc
mkdir -p "$STATE_DIR"
printf '%s\n' "$VERSION" > "${STATE_DIR}/version"

echo
printf '%sPasarGuard Node Optimizer v%s%s\n' "$B" "$VERSION" "$N"
info "پروفایل: ${MODE} | بسته: ${PM} | مجازی‌سازی: ${VIRT}"
info "سخت‌افزار: ${CPUS} هسته | ${MEM_MB}MB رم | کرنل ${KERNEL}"

case "$VIRT" in
    lxc|docker|podman|openvz|systemd-nspawn)
        warn "داخل کانتینر هستی. این اسکریپت را روی خودِ سرور نود (هاست) اجرا کن، نه داخل کانتینر pg-node."
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

# -----------------------------------------------------------------------------
# زمان — برای TLS نود و لاگ مصرف
# -----------------------------------------------------------------------------
info "همگام‌سازی ساعت با chrony..."
if pm_install chrony; then
    systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
    systemctl enable --now chrony >/dev/null 2>&1 \
        || systemctl enable --now chronyd >/dev/null 2>&1 \
        || warn "سرویس chrony بالا نیامد."
    chronyc makestep >/dev/null 2>&1 || true
    ok "ساعت سرور همگام شد."
else
    warn "chrony نصب نشد. اگر ساعت سرور عقب باشد گواهی نود و پنل به هم نمی‌خورند."
fi

# -----------------------------------------------------------------------------
# Swap فقط وقتی رم کم است. روی نود پرترافیک، swap زیاد تأخیر می‌سازد.
# -----------------------------------------------------------------------------
if [ "$AUTO_SWAP" = "1" ] && [ "$VIRT" != "openvz" ] && [ "$VIRT" != "lxc" ]; then
    SWAP_TOTAL=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
    if [ "${SWAP_TOTAL:-0}" -eq 0 ] && [ ! -f /swapfile ] && [ "$MEM_MB" -lt 8192 ]; then
        if [ "$MEM_MB" -lt 2048 ]; then SWAP_SIZE=1G; SWAP_MB=1024; else SWAP_SIZE=2G; SWAP_MB=2048; fi
        FREE_DISK_MB=$(df -m / | awk 'NR==2 {print $4}')
        if [ "${FREE_DISK_MB:-0}" -gt $(( SWAP_MB + 2048 )) ]; then
            info "رم کمتر از ۸ گیگ است و swap نداری. ساخت ${SWAP_SIZE} swap..."
            if fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none; then
                chmod 600 /swapfile
                mkswap /swapfile >/dev/null
                swapon /swapfile >/dev/null 2>&1 || true
                grep -q '[[:space:]]/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
                ok "Swap ${SWAP_SIZE} فعال شد."
            fi
        else
            warn "دیسک خالی برای swap کافی نیست."
        fi
    else
        ok "Swap لازم نبود یا از قبل وجود دارد."
    fi
fi

# -----------------------------------------------------------------------------
# سقف فایل و پروسس — گلوگاه اصلی نود وقتی کاربر زیاد می‌شود
# -----------------------------------------------------------------------------
info "بالا بردن سقف file descriptor برای docker، pg-node و xray..."
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
    warn "سرویس docker / pg-node / pasarguard پیدا نشد. limit سیستمی اعمال می‌شود؛ بعد از نصب نود اسکریپت را دوباره اجرا کن."
else
    info "سرویس‌های هدف: ${FOUND_UNITS[*]}"
fi
apply_unit_limits
tune_docker_daemon
ok "سقف nofile روی ${NOFILE} تنظیم شد."

# -----------------------------------------------------------------------------
# ماژول‌ها: BBR، fq، conntrack، و wireguard که نود رسمی برایش لازم دارد
# -----------------------------------------------------------------------------
info "بارگذاری BBR، conntrack و WireGuard..."
for mod in tcp_bbr sch_fq nf_conntrack wireguard; do
    modprobe "$mod" 2>/dev/null || true
done
pick_cc

if [ "$CC" = "cubic" ]; then
    warn "BBR در این کرنل نیست. cubic می‌ماند. برای بازدهی بهتر کرنل ۵.۱۵ به بالا نصب کن."
fi

write_file "$MODULES_FILE" <<'EOF' || true
tcp_bbr
sch_fq
nf_conntrack
wireguard
EOF

write_file "$MODPROBE_CT" <<EOF || true
options nf_conntrack hashsize=${CT_HASH}
EOF

# rp_filter=2 (loose) عمدی است.
# مقدار 1 مسیر برگشت WireGuard و TUN اکس‌ری (xray0) را بی‌صدا دور می‌ریزد.
# src_valid_mark برای fwmark سیاست مسیریابی نود لازم است.
# ip_forward برای PG_NODE_WG_HOST_ROUTING لازم است و باید قبل از بالا آمدن نود روشن باشد.
write_file "$SYSCTL_MAIN" <<EOF || true
# PasarGuard node host tuning — profile ${MODE}
# generated for ${CPUS} cpus / ${MEM_MB} MB

# --- فوروارد و تونل (WireGuard / Xray TUN) ---
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

# --- ازدحام: BBR روی fq. fq_codel را با BBR قاطی نکن ---
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = ${CC}

# --- بافر. سقف است، نه رزرو قطعی هر سوکت ---
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

# --- صف ورودی ---
net.core.netdev_max_backlog = ${BACKLOG}
net.core.netdev_budget = ${BUDGET}
net.core.netdev_budget_usecs = ${BUDGET_US}
net.core.somaxconn = ${SOMAX}
net.core.busy_poll = ${BUSY}
net.core.busy_read = ${BUSY}

# --- پذیرش اتصال زیاد، بدون گیر کردن پورت سرویس‌ها ---
net.ipv4.tcp_max_syn_backlog = ${SOMAX}
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
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

# --- keepalive متعادل برای کلاینت موبایل ---
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# --- همسایه / ARP وقتی کاربر زیاد است ---
net.ipv4.neigh.default.gc_thresh1 = 2048
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

# --- فایل و حافظه ---
fs.file-max = ${FILE_MAX}
fs.nr_open = ${FILE_MAX}
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 524288
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 1500
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 1
vm.min_free_kbytes = ${MIN_FREE}
vm.zone_reclaim_mode = 0

# --- متفرقه ---
kernel.pid_max = 4194304
kernel.panic = 10
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF

# numa_balancing روی VPS تک‌سوکت فقط jitter می‌سازد
NUMA_NODES=$(find /sys/devices/system/node -maxdepth 1 -type d -name 'node[0-9]*' 2>/dev/null | wc -l || true)
if [ "${NUMA_NODES:-0}" -le 1 ]; then
    sysctl -w kernel.numa_balancing=0 >/dev/null 2>&1 || true
fi

sysctl -e -p "$SYSCTL_MAIN" >/dev/null 2>&1 || warn "بعضی کلیدهای sysctl روی این کرنل وجود ندارند و رد شدند."

# rp_filter را روی تک‌تک اینترفیس‌ها هم شل کن؛ all به‌تنهایی wg و xray0 را پوشش نمی‌دهد
for rp in /proc/sys/net/ipv4/conf/*/rp_filter; do
    [ -w "$rp" ] && echo 2 > "$rp" 2>/dev/null || true
done
for mk in /proc/sys/net/ipv4/conf/*/src_valid_mark; do
    [ -w "$mk" ] && echo 1 > "$mk" 2>/dev/null || true
done

if [ "$DISABLE_IPV6" = "1" ]; then
    warn "IPv6 خاموش می‌شود. اینباند و مسیر IPv6 این نود از کار می‌افتد."
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
    info "فایل خاموش‌کننده IPv6 برداشته شد."
fi

ok "کرنل اعمال شد: ${CC} + ${QDISC} | conntrack سقف ${CT_MAX} | ip_forward=1 | rp_filter=2"

# -----------------------------------------------------------------------------
# سرویس بوت: conntrack، MSS، صف کارت شبکه، RPS فقط وقتی NIC تک‌صف است
# -----------------------------------------------------------------------------
info "نصب سرویس ماندگار کارت شبکه..."

write_file "$NET_SCRIPT" 0755 <<'EOF_TWEAKS' || true
#!/usr/bin/env bash
# اعمال مجدد بعد از بوت. ماژول netfilter دیر لود می‌شود و systemd-sysctl آن را از دست می‌دهد.
set -u

SYSCTL_MAIN=/etc/sysctl.d/99-pasarguard-node.conf
CHAIN_MANGLE=PGNODE_OPT
CHAIN_INPUT=PGNODE_OPT_IN
MSS_CLAMP="${MSS_CLAMP:-1}"
FIREWALL_DROP_INVALID="${FIREWALL_DROP_INVALID:-0}"
TUNE_NIC="${TUNE_NIC:-1}"
TUNE_NIC_CHANNELS="${TUNE_NIC_CHANNELS:-1}"

[ -f "$SYSCTL_MAIN" ] && sysctl -e -p "$SYSCTL_MAIN" >/dev/null 2>&1 || true

modprobe tcp_bbr 2>/dev/null || true
modprobe sch_fq 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true
modprobe wireguard 2>/dev/null || true

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    ip -4 route show default 2>/dev/null | grep -q . && break
    sleep 1
done

MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
CPUS=$(nproc 2>/dev/null || echo 1)
if [ -z "${CT_MAX:-}" ]; then
    if   [ "${MEM_MB:-0}" -ge 16384 ]; then CT_MAX=1048576
    elif [ "${MEM_MB:-0}" -ge 8192 ];  then CT_MAX=524288
    elif [ "${MEM_MB:-0}" -ge 4096 ];  then CT_MAX=262144
    elif [ "${MEM_MB:-0}" -ge 2048 ];  then CT_MAX=131072
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
    net.ipv4.conf.default.src_valid_mark=1 \
    net.ipv4.conf.all.rp_filter=2 \
    net.ipv4.conf.default.rp_filter=2 \
    net.netfilter.nf_conntrack_max="$CT_MAX" \
    net.netfilter.nf_conntrack_buckets="$CT_HASH" \
    net.netfilter.nf_conntrack_tcp_timeout_established=7200 \
    net.netfilter.nf_conntrack_tcp_timeout_time_wait=20 \
    net.netfilter.nf_conntrack_tcp_timeout_fin_wait=20 \
    net.netfilter.nf_conntrack_tcp_timeout_close_wait=15 \
    net.netfilter.nf_conntrack_tcp_timeout_syn_sent=20 \
    net.netfilter.nf_conntrack_tcp_timeout_syn_recv=20 \
    net.netfilter.nf_conntrack_udp_timeout=30 \
    net.netfilter.nf_conntrack_udp_timeout_stream=300 \
    2>/dev/null || true

for rp in /proc/sys/net/ipv4/conf/*/rp_filter; do
    [ -w "$rp" ] && echo 2 > "$rp" 2>/dev/null || true
done
for mk in /proc/sys/net/ipv4/conf/*/src_valid_mark; do
    [ -w "$mk" ] && echo 1 > "$mk" 2>/dev/null || true
done

ensure_chain() {
    local bin=$1 table=$2 chain=$3
    "$bin" -t "$table" -N "$chain" 2>/dev/null || true
}

hook_once() {
    local bin=$1 table=$2 parent=$3 chain=$4
    if [ -n "$table" ]; then
        "$bin" -t "$table" -C "$parent" -j "$chain" 2>/dev/null || "$bin" -t "$table" -A "$parent" -j "$chain"
    else
        "$bin" -C "$parent" -j "$chain" 2>/dev/null || "$bin" -I "$parent" 1 -j "$chain"
    fi
}

clear_our_firewall() {
    local bin=$1
    command -v "$bin" >/dev/null 2>&1 || return 0
    while "$bin" -t mangle -D POSTROUTING -j "$CHAIN_MANGLE" 2>/dev/null; do :; done
    "$bin" -t mangle -F "$CHAIN_MANGLE" 2>/dev/null || true
    "$bin" -t mangle -X "$CHAIN_MANGLE" 2>/dev/null || true
    while "$bin" -D INPUT -j "$CHAIN_INPUT" 2>/dev/null; do :; done
    "$bin" -F "$CHAIN_INPUT" 2>/dev/null || true
    "$bin" -X "$CHAIN_INPUT" 2>/dev/null || true
}

apply_firewall() {
    local bin=$1
    command -v "$bin" >/dev/null 2>&1 || return 0
    clear_our_firewall "$bin"
    if [ "$MSS_CLAMP" = "1" ]; then
        ensure_chain "$bin" mangle "$CHAIN_MANGLE"
        hook_once "$bin" mangle POSTROUTING "$CHAIN_MANGLE" || true
        "$bin" -t mangle -A "$CHAIN_MANGLE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || true
    fi
    if [ "$FIREWALL_DROP_INVALID" = "1" ]; then
        ensure_chain "$bin" filter "$CHAIN_INPUT"
        hook_once "$bin" "" INPUT "$CHAIN_INPUT" || true
        "$bin" -A "$CHAIN_INPUT" -m conntrack --ctstate INVALID -j DROP || true
    fi
}

apply_firewall iptables || true
if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" = "0" ]; then
    apply_firewall ip6tables || true
fi

cpu_mask() {
    local cpus=$1 n i base count hex groups=()
    n=$(( (cpus + 31) / 32 ))
    for ((i = 0; i < n; i++)); do
        base=$(( i * 32 ))
        count=$(( cpus - base ))
        if [ "$count" -ge 32 ]; then
            groups+=(ffffffff)
        else
            hex=$(printf '%x' $(( (1 << count) - 1 )))
            groups+=("$hex")
        fi
    done
    local IFS=,
    printf '%s\n' "${groups[*]}"
}

tune_iface() {
    local IFACE=$1
    [ -d "/sys/class/net/$IFACE" ] || return 0
    ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null || true

    if command -v tc >/dev/null 2>&1; then
        local root handles handle
        root=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1{print $2}')
        case "$root" in
            mq|mqprio)
                # ریشه mq را برندار. فقط بچه‌های fq_codel/pfifo را fq کن تا چندصفله بماند.
                handles=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk '$2=="fq_codel" || $2=="pfifo_fast" || $2=="pfifo" {print $5}')
                for handle in $handles; do
                    [ -n "$handle" ] || continue
                    tc qdisc replace dev "$IFACE" parent "$handle" fq 2>/dev/null || true
                done
                ;;
            fq|fq_pie) ;;
            *)
                tc qdisc replace dev "$IFACE" root fq 2>/dev/null || true
                ;;
        esac
    fi

    if command -v ethtool >/dev/null 2>&1; then
        ethtool -K "$IFACE" gro on 2>/dev/null || true
        ethtool -K "$IFACE" gso on 2>/dev/null || true
        ethtool -K "$IFACE" tso on 2>/dev/null || true
        ethtool -K "$IFACE" sg on 2>/dev/null || true
        ethtool -K "$IFACE" tx on 2>/dev/null || true
        ethtool -K "$IFACE" rx on 2>/dev/null || true
        local ring
        for ring in 4096 2048 1024 512; do
            ethtool -G "$IFACE" rx "$ring" tx "$ring" 2>/dev/null && break
        done
        if [ "$TUNE_NIC_CHANNELS" = "1" ] && [ "$CPUS" -gt 1 ]; then
            local maxc curc target
            maxc=$(ethtool -l "$IFACE" 2>/dev/null | awk 'f && /Combined:/ {print $2; exit} /^Channel parameters for/ || /Pre-set maximums/ {f=1}')
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

    # RPS فقط وقتی سخت‌افزار یک صف RX دارد. اگر RSS چند صف دارد، RPS دوباره‌کاری و کندتر است.
    local rx_count mask flow
    rx_count=$(find "/sys/class/net/$IFACE/queues" -maxdepth 1 -name 'rx-*' 2>/dev/null | wc -l)
    if [ "$CPUS" -gt 1 ] && [ "${rx_count:-0}" -eq 1 ]; then
        mask=$(cpu_mask "$CPUS")
        sysctl -qw net.core.rps_sock_flow_entries=32768 2>/dev/null || true
        flow=32768
        for rx in /sys/class/net/"$IFACE"/queues/rx-*; do
            [ -e "$rx/rps_cpus" ] && echo "$mask" > "$rx/rps_cpus" 2>/dev/null || true
            [ -e "$rx/rps_flow_cnt" ] && echo "$flow" > "$rx/rps_flow_cnt" 2>/dev/null || true
        done
        for tx in /sys/class/net/"$IFACE"/queues/tx-*; do
            [ -e "$tx/xps_cpus" ] && echo "$mask" > "$tx/xps_cpus" 2>/dev/null || true
        done
    fi
}

if [ "$TUNE_NIC" = "1" ]; then
    for path in /sys/class/net/*; do
        iface=$(basename "$path")
        case "$iface" in
            lo|docker*|veth*|br-*|virbr*|wg*|xray*|tun*|sit*|dummy*|flannel*|cni*|gre*|gretap*|erspan*|ip6tnl*|ifb*)
                continue ;;
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
    for pref in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        [ -w "$pref" ] && echo performance > "$pref" 2>/dev/null || true
    done
fi

exit 0
EOF_TWEAKS

write_file "$NET_UNIT" <<'EOF' || true
[Unit]
Description=PasarGuard node host tuning (forward, BBR, conntrack, NIC)
Documentation=https://docs.pasarguard.org/en/node/
After=network.target systemd-modules-load.service
Before=docker.service pg-node.service pg-node-service.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/pg-node-net-tweaks.sh

[Install]
WantedBy=multi-user.target
EOF

# محیط سرویس را با فلگ‌ها و سقف conntrack همین پروفایل همگام کن
mkdir -p /etc/systemd/system/pg-node-net-tweaks.service.d
write_file /etc/systemd/system/pg-node-net-tweaks.service.d/override.conf <<EOF || true
[Service]
Environment=MSS_CLAMP=${MSS_CLAMP}
Environment=FIREWALL_DROP_INVALID=${FIREWALL_DROP_INVALID}
Environment=TUNE_NIC=${TUNE_NIC}
Environment=TUNE_NIC_CHANNELS=${TUNE_NIC_CHANNELS}
Environment=CT_MAX=${CT_MAX}
Environment=CT_HASH=${CT_HASH}
EOF

systemctl daemon-reload
systemctl enable pg-node-net-tweaks.service >/dev/null 2>&1 || true
systemctl restart pg-node-net-tweaks.service || warn "سرویس کارت شبکه با هشدار تمام شد. خروجی: journalctl -u pg-node-net-tweaks -n 40"
ok "فوروارد، conntrack، MSS و صف کارت شبکه ماندگار شد."

# -----------------------------------------------------------------------------
# لاگ سیستم نود را پر نکند. لاگ خود داکر جداگانه در daemon.json چرخانده می‌شود.
# -----------------------------------------------------------------------------
info "سقف ژورنال سیستم..."
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

# -----------------------------------------------------------------------------
# سقف فایل داخل کانتینر. recreate به‌تنهایی کافی نیست؛ اول خود Docker باید
# ری‌استارت شود، وگرنه کانتینر جدید باز هم با nofile برابر 1024 ساخته می‌شود.
# -----------------------------------------------------------------------------
patch_compose_ulimit() {
    local compose=$1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$compose" "$NOFILE" <<'PY'
import os, re, shutil, sys
path, nofile = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
text = "".join(lines)
if not re.search(r"pasarguard/node|ghcr\.io/pasarguard/node", text):
    sys.exit(10)
if re.search(r"(?m)^\s*nofile\s*:", text):
    sys.exit(10)
out = []
inserted = False
image_re = re.compile(r"image:\s*.*(pasarguard/node|ghcr\.io/pasarguard/node)")
for line in lines:
    out.append(line)
    if inserted:
        continue
    if image_re.search(line):
        indent = re.match(r"^(\s*)", line).group(1)
        out.append(
            "%sulimits:\n%snofile:\n%ssoft: %s\n%shard: %s\n"
            % (indent, indent + "  ", indent + "    ", nofile, indent + "    ", nofile)
        )
        inserted = True
if not inserted:
    sys.exit(10)
bak = path + ".pgopt-bak"
if not os.path.exists(bak):
    shutil.copy2(path, bak)
tmp = path + ".pgopt-tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write("".join(out))
os.replace(tmp, path)
sys.exit(0)
PY
}

wait_docker() {
    local i
    for i in $(seq 1 30); do
        docker info >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

container_soft_nofile() {
    local id=$1 soft
    soft=$(docker inspect "$id" --format '{{range .HostConfig.Ulimits}}{{if eq .Name "nofile"}}{{.Soft}}{{end}}{{end}}' 2>/dev/null || true)
    if [ -z "${soft:-}" ]; then
        echo 1024
    else
        echo "$soft"
    fi
}

fix_pasarguard_container_nofile() {
    command -v docker >/dev/null 2>&1 || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    local -a files=()
    local -A seen=()
    local f dir id img name soft low=0 patched=0 compose_bin=""
    shopt -s nullglob
    for f in /opt/*/docker-compose.yml /opt/*/docker-compose.yaml \
             /opt/*/compose.yml /opt/*/compose.yaml \
             /opt/*/*/docker-compose.yml /opt/*/*/docker-compose.yaml; do
        files+=("$f")
    done
    shopt -u nullglob
    while read -r id img name; do
        [ -n "${id:-}" ] || continue
        case "$img" in
            *pasarguard/node*|*ghcr.io/pasarguard/node*) ;;
            *) continue ;;
        esac
        dir=$(docker inspect "$id" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)
        if [ -n "$dir" ]; then
            for f in "$dir"/docker-compose.yml "$dir"/docker-compose.yaml "$dir"/compose.yml "$dir"/compose.yaml; do
                [ -f "$f" ] && files+=("$f")
            done
        fi
        soft=$(container_soft_nofile "$id")
        if [ "$soft" -lt "$NOFILE" ] 2>/dev/null; then
            low=1
        fi
    done < <(docker ps -a --format '{{.ID}} {{.Image}} {{.Names}}' 2>/dev/null || true)

    for f in "${files[@]+"${files[@]}"}"; do
        [ -f "$f" ] || continue
        grep -Eiq 'pasarguard/node|ghcr.io/pasarguard/node' "$f" || continue
        dir=$(dirname "$f")
        [ -n "${seen[$dir]:-}" ] && continue
        seen[$dir]=1
        if patch_compose_ulimit "$f"; then
            patched=1
            ok "سقف nofile داخل compose نوشته شد: $f"
        fi
    done

    if [ "$low" -eq 0 ] && [ "$patched" -eq 0 ] && [ "${DOCKER_CHANGED:-0}" != "1" ]; then
        ok "سقف فایل کانتینر نود از قبل درست است."
        return 0
    fi

    info "ری‌استارت Docker و ساخت دوباره نود. اتصال چند ثانیه قطع می‌شود..."
    systemctl restart containerd >/dev/null 2>&1 || true
    if ! systemctl restart docker; then
        warn "ری‌استارت docker ناموفق بود. journalctl -u docker -n 30"
        return 1
    fi
    if ! wait_docker; then
        warn "docker بالا نیامد. journalctl -u docker -n 30"
        return 1
    fi

    if docker compose version >/dev/null 2>&1; then
        compose_bin="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        compose_bin="docker-compose"
    else
        warn "docker compose پیدا نشد."
        return 1
    fi

    if [ "${#seen[@]}" -eq 0 ]; then
        warn "فایل compose نود پاسارگارد پیدا نشد."
        return 1
    fi
    for dir in "${!seen[@]}"; do
        info "ساخت مجدد نود در ${dir} ..."
        if (cd "$dir" && $compose_bin up -d --force-recreate); then
            ok "نود دوباره ساخته شد: ${dir}"
        else
            warn "ساخت مجدد در ${dir} ناموفق بود."
        fi
    done

    while read -r id img name; do
        [ -n "${name:-}" ] || continue
        case "$img" in
            *pasarguard/node*|*ghcr.io/pasarguard/node*) ;;
            *) continue ;;
        esac
        soft=$(docker exec "$name" sh -c 'ulimit -n' 2>/dev/null || echo '?')
        if [ "$soft" = "$NOFILE" ]; then
            ok "nofile داخل ${name}: ${soft}"
        else
            warn "nofile داخل ${name} هنوز ${soft} است."
        fi
    done < <(docker ps --format '{{.ID}} {{.Image}} {{.Names}}' 2>/dev/null || true)
}

if [ "$RESTART_SERVICES" = "1" ]; then
    for unit in "${MODIFIED_UNITS[@]+"${MODIFIED_UNITS[@]}"}"; do
        case "$unit" in
            docker.service|containerd.service) continue ;;
        esac
        systemctl try-restart "$unit" >/dev/null 2>&1 && ok "ری‌استارت شد: $unit" || true
    done
fi

if [ "$RECREATE_NODE" = "1" ] && [ "$TUNE_DOCKER" = "1" ]; then
    fix_pasarguard_container_nofile || warn "اعمال خودکار سقف فایل کانتینر کامل نشد."
elif [ "$RECREATE_NODE" != "1" ]; then
    warn "RECREATE_NODE=0 است. سقف داخل کانتینر را خود اسکریپت عوض نمی‌کند."
fi

# -----------------------------------------------------------------------------
# گزارش
# -----------------------------------------------------------------------------
IFACE_NOW=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)
echo
ok "════════════════════════════════════════════════════════"
ok "  نود PasarGuard برای ترافیک بالا آماده شد"
ok "════════════════════════════════════════════════════════"
echo
echo "  • پروفایل:              ${MODE}"
echo "  • ازدحام:               $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
echo "  • qdisc پیش‌فرض:        $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
echo "  • ip_forward:           $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
echo "  • rp_filter:            $(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo '?')"
echo "  • src_valid_mark:       $(sysctl -n net.ipv4.conf.all.src_valid_mark 2>/dev/null || echo '?')"
echo "  • TCP Fast Open:        $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo '?')"
echo "  • سقف conntrack:        $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo '?')"
echo "  • UDP stream timeout:   $(sysctl -n net.netfilter.nf_conntrack_udp_timeout_stream 2>/dev/null || echo '?')"
echo "  • rmem_max:             $(sysctl -n net.core.rmem_max 2>/dev/null || echo '?')"
echo "  • somaxconn:            $(sysctl -n net.core.somaxconn 2>/dev/null || echo '?')"
echo "  • file-max:             $(sysctl -n fs.file-max 2>/dev/null || echo '?')"
echo "  • کارت پیش‌فرض:         ${IFACE_NOW:-?}"
if [ -n "${IFACE_NOW:-}" ] && command -v tc >/dev/null 2>&1; then
    echo "  • qdisc فعال:           $(tc qdisc show dev "$IFACE_NOW" 2>/dev/null | awk 'NR==1{print $2}' || true)"
fi
[ -d "$BACKUP_DIR" ] && info "نسخه قبلی فایل‌های عوض‌شده: $BACKUP_DIR"
echo
ok "چیزی از کانفیگ Xray و گواهی نود عوض نشده. وضعیت بعدی: bash pg-node-optimizer.sh --status"
echo

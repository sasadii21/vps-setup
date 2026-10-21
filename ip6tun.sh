#!/usr/bin/env bash
# =============================================================================
#  ip6tun - مدیریت تونل IPv6 over IPv4 (SIT) بین سرورهای لینوکس
#  Version : 1.0.0
# =============================================================================
set -uo pipefail

VERSION="1.0.0"
REPO_RAW="https://raw.githubusercontent.com/YOUR_USER/ip6tun/main/ip6tun.sh"
INSTALL_PATH="/usr/local/bin/ip6tun"
CONF_DIR="/etc/ip6tun"
CONF_FILE="${CONF_DIR}/tunnels.conf"
SERVICE_NAME="ip6tun"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
DEFAULT_MTU=1480

trap 'echo; exit 130' INT

# ─── رنگ‌ها ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'
    M=$'\e[35m'; C=$'\e[36m'; W=$'\e[97m'
    BOLD=$'\e[1m'; DIM=$'\e[2m'; NC=$'\e[0m'
else
    R=''; G=''; Y=''; B=''; M=''; C=''; W=''; BOLD=''; DIM=''; NC=''
fi

# ─── خروجی ──────────────────────────────────────────────────────────────────
ok()   { echo -e "  ${G}✔${NC} $*"; }
info() { echo -e "  ${B}ℹ${NC} $*"; }
warn() { echo -e "  ${Y}⚠${NC} $*"; }
err()  { echo -e "  ${R}✖${NC} $*" >&2; }
hr()   { echo -e "  ${DIM}$(printf '%.0s─' {1..52})${NC}"; }

banner() {
    local bar; bar=$(printf '%.0s═' {1..47})
    echo -e "${C}${BOLD}  ╔${bar}╗${NC}"
    printf "${C}${BOLD}  ║${NC}  %-45s${C}${BOLD}║${NC}\n" "IPv6 Tunnel Manager  -  v${VERSION}"
    echo -e "${C}${BOLD}  ╚${bar}╝${NC}"
}

header() {
    clear 2>/dev/null || printf '\033c'
    banner
    echo
}

pause() { read -rp "  ${DIM}برای ادامه Enter بزنید...${NC}" _; }

confirm() {
    local a
    read -rp "  ${Y}?${NC} $1 [y/N]: " a
    [[ $a =~ ^[Yy]([Ee][Ss])?$ ]]
}

need() {
    command -v "$1" &>/dev/null || { err "ابزار «$1» نصب نیست (مثلاً: apt install iproute2)"; exit 1; }
}

# ─── ورودی با اعتبارسنجی ───────────────────────────────────────────────────
ask() { # prompt [default]
    local prompt=$1 def=${2:-} ans
    if [[ -n $def ]]; then
        read -rp "  ${C}➜${NC} ${prompt} ${DIM}[${def}]${NC}: " ans
    else
        read -rp "  ${C}➜${NC} ${prompt}: " ans
    fi
    printf '%s\n' "${ans:-$def}"
}

ask_valid() { # prompt default validator [args...]
    local prompt=$1 def=$2 fn=$3 val
    shift 3
    while true; do
        val=$(ask "$prompt" "$def")
        if "$fn" "$val" "$@"; then
            printf '%s\n' "$val"
            return 0
        fi
        err "مقدار وارد شده نامعتبر است، دوباره وارد کنید."
    done
}

# ─── اعتبارسنجی ─────────────────────────────────────────────────────────────
valid_name()    { [[ $1 =~ ^[A-Za-z0-9_-]{1,15}$ ]]; }
name_exists()   { [[ -n $(get_entry "$1") ]]; }
name_ok() { # name [current_name]
    local n=$1 cur=${2:-}
    valid_name "$n" || return 1
    [[ -n $cur && $n == "$cur" ]] && return 0
    ! name_exists "$n"
}

valid_ipv4() {
    local ip=$1 o
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        (( 10#$o <= 255 )) || return 1
    done
}

valid_ipv6() {
    local a=${1%%/*}
    if command -v python3 &>/dev/null; then
        python3 -c 'import ipaddress,sys; ipaddress.IPv6Address(sys.argv[1])' "$a" 2>/dev/null
    else
        [[ $a == *:* && $a =~ ^[0-9A-Fa-f:]+$ ]]
    fi
}

valid_ipv6_opt() { [[ -z ${1:-} ]] || valid_ipv6 "$1"; }
valid_mtu()      { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 576 && 10#$1 <= 9000 )); }

# ─── ذخیره‌سازی تنظیمات ─────────────────────────────────────────────────────
# فرمت هر خط:  name|local_ipv4|remote_ipv4|ipv6|mtu|peer_ipv6
ensure_conf() {
    mkdir -p "$CONF_DIR"
    touch "$CONF_FILE"
    chmod 600 "$CONF_FILE"
}

get_entry() {
    [[ -f $CONF_FILE ]] || return 0
    awk -F'|' -v n="$1" '$1==n{print; exit}' "$CONF_FILE"
}

save_entry() { # full line
    ensure_conf
    local name=${1%%|*} tmp
    tmp=$(mktemp)
    awk -F'|' -v n="$name" '$1!=n' "$CONF_FILE" > "$tmp"
    printf '%s\n' "$1" >> "$tmp"
    mv "$tmp" "$CONF_FILE"
    chmod 600 "$CONF_FILE"
}

remove_entry() {
    ensure_conf
    local tmp; tmp=$(mktemp)
    awk -F'|' -v n="$1" '$1!=n' "$CONF_FILE" > "$tmp"
    mv "$tmp" "$CONF_FILE"
    chmod 600 "$CONF_FILE"
}

load() { # name -> T_* variables
    IFS='|' read -r T_NAME T_LOCAL T_REMOTE T_V6 T_MTU T_PEER <<< "$(get_entry "$1")"
    [[ -n ${T_NAME:-} ]]
}

# ─── عملیات کرنل ────────────────────────────────────────────────────────────
detect_ipv4() {
    ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}'
}

iface_exists() { ip link show dev "$1" &>/dev/null; }
iface_up()     { ip -o link show dev "$1" 2>/dev/null | grep -qE '[<,]UP[,>]'; }

tun_destroy() {
    iface_exists "$1" || return 0
    ip link set dev "$1" down 2>/dev/null
    ip tunnel del "$1" 2>/dev/null || ip link del dev "$1" 2>/dev/null
    return 0
}

tun_create() { # name local remote ipv6 mtu
    local n=$1 l=$2 r=$3 v=$4 m=$5
    tun_destroy "$n"
    ip tunnel add "$n" mode sit local "$l" remote "$r" ttl 255 || return 1
    ip link set dev "$n" mtu "$m" || return 1
    ip -6 addr add "${v}/64" dev "$n" 2>/dev/null
    ip link set dev "$n" up || return 1
}

# ─── نمایش دستور سرور مقابل ─────────────────────────────────────────────────
show_mirror() { # name local remote ipv6 mtu peer
    local n=$1 l=$2 r=$3 v=$4 m=$5 p=$6
    echo
    echo -e "  ${M}${BOLD}▸ دستور برای سرور مقابل (${r})${NC}"
    echo -e "  ${DIM}روی سرور مقابل یک بار این را اجرا کنید:${NC}"
    echo -e "  ${W}bash <(curl -fsSL ${REPO_RAW}) install${NC}"
    echo -e "  ${DIM}سپس:${NC}"
    echo -e "  ${W}ip6tun add ${n} ${l} ${p:-<IPv6-این-سرور-مقابل>} ${m} ${r} ${v}${NC}"
    echo
}

# ─── عملیات اصلی ────────────────────────────────────────────────────────────
do_add() { # name local remote ipv6 mtu [peer]
    local n=$1 l=$2 r=$3 v=${4%%/*} m=$5 p=${6:-}
    p=${p%%/*}
    name_ok "$n"        || { err "نام نامعتبر یا تکراری است (فقط a-z 0-9 _ - تا ۱۵ حرف)."; return 1; }
    valid_ipv4 "$l"     || { err "IPv4 محلی نامعتبر است."; return 1; }
    valid_ipv4 "$r"     || { err "IPv4 سرور مقابل نامعتبر است."; return 1; }
    valid_ipv6 "$v"     || { err "IPv6 داخل تونل نامعتبر است."; return 1; }
    valid_mtu "$m"      || { err "MTU نامعتبر است (بین 576 تا 9000)."; return 1; }
    valid_ipv6_opt "$p" || { err "IPv6 سرور مقابل نامعتبر است."; return 1; }

    save_entry "$n|$l|$r|$v|$m|$p"
    if tun_create "$n" "$l" "$r" "$v" "$m"; then
        ok "تونل ${BOLD}${n}${NC} ساخته و فعال شد."
        show_mirror "$n" "$l" "$r" "$v" "$m" "$p"
    else
        err "ساخت تونل ناموفق بود (دسترسی root و آدرس‌ها را بررسی کنید)."
        return 1
    fi
}

cmd_list() {
    if [[ ! -s $CONF_FILE ]]; then
        warn "هیچ تونلی ثبت نشده است. با «ip6tun add» یکی بسازید."
        return 0
    fi
    printf "  ${BOLD}%-14s %-16s %-16s %-24s %-6s %s${NC}\n" \
        "NAME" "REMOTE IPv4" "LOCAL IPv4" "IPv6" "MTU" "STATUS"
    hr
    local n l r v m p st
    while IFS='|' read -r n l r v m p; do
        [[ -z ${n:-} ]] && continue
        if iface_exists "$n" && iface_up "$n"; then
            st="${G}● UP${NC}"
        elif iface_exists "$n"; then
            st="${Y}◐ DOWN${NC}"
        else
            st="${R}○ OFF${NC}"
        fi
        printf "  %-14s %-16s %-16s %-24s %-6s %b\n" "$n" "$r" "$l" "$v/64" "$m" "$st"
    done < "$CONF_FILE"
    echo
}

pick_tunnel() { # title -> prints chosen name on stdout
    local title=$1 names=() n i idx
    [[ -s $CONF_FILE ]] || { err "هیچ تونلی ثبت نشده است."; return 1; }
    while IFS='|' read -r n _; do
        [[ -n ${n:-} ]] && names+=("$n")
    done < "$CONF_FILE"
    {
        echo
        info "$title"
        for i in "${!names[@]}"; do
            printf "    ${C}%2d)${NC} %s\n" $((i + 1)) "${names[i]}"
        done
        echo
    } >&2
    idx=$(ask "شماره تونل")
    if [[ $idx =~ ^[0-9]+$ ]] && (( 10#$idx >= 1 && 10#$idx <= ${#names[@]} )); then
        printf '%s\n' "${names[10#$idx - 1]}"
    else
        err "انتخاب نامعتبر است."
        return 1
    fi
}

cmd_add_interactive() {
    info "افزودن تونل جدید"; echo
    local n l r v m p
    n=$(ask_valid "نام تونل (انگلیسی، حداکثر ۱۵ حرف)" "" name_ok "")
    l=$(ask_valid "IPv4 عمومی همین سرور" "$(detect_ipv4)" valid_ipv4)
    r=$(ask_valid "IPv4 عمومی سرور مقابل" "" valid_ipv4)
    v=$(ask_valid "IPv6 همین سرور داخل تونل (مثلاً fd6d:a13a:be5c::de01/64)" "" valid_ipv6)
    p=$(ask_valid "IPv6 سرور مقابل (برای تست پینگ، Enter = خالی)" "" valid_ipv6_opt)
    m=$(ask_valid "MTU" "$DEFAULT_MTU" valid_mtu)
    do_add "$n" "$l" "$r" "$v" "$m" "$p"
}

cmd_add() { # name remote_ipv4 ipv6 [mtu] [local_ipv4|-] [peer_ipv6]
    if (( $# < 3 )); then usage; return 1; fi
    local n=$1 r=$2 v=$3 m=${4:-$DEFAULT_MTU} l=${5:--} p=${6:-}
    [[ $l == "-" ]] && l=$(detect_ipv4)
    do_add "$n" "$l" "$r" "$v" "$m" "$p"
}

cmd_edit() {
    local n=${1:-}
    [[ -n $n ]] || { n=$(pick_tunnel "کدام تونل ویرایش شود؟") || return 1; }
    load "$n" || { err "تونل «$n» پیدا نشد."; return 1; }

    local oldn=$T_NAME oldl=$T_LOCAL oldr=$T_REMOTE oldv=$T_V6 oldm=$T_MTU oldp=$T_PEER
    local nn nl nr nv nm np

    info "ویرایش ${BOLD}${oldn}${NC}  ${DIM}(Enter = همان مقدار فعلی)${NC}"; echo
    nn=$(ask_valid "نام تونل"                 "$oldn" name_ok "$oldn")
    nl=$(ask_valid "IPv4 این سرور (local)"     "$oldl" valid_ipv4)
    nr=$(ask_valid "IPv4 سرور مقابل (remote)"  "$oldr" valid_ipv4)
    nv=$(ask_valid "IPv6 این سرور داخل تونل"   "$oldv" valid_ipv6)
    nm=$(ask_valid "MTU"                      "$oldm" valid_mtu)
    np=$(ask_valid "IPv6 سرور مقابل (اختیاری)" "$oldp" valid_ipv6_opt)
    nv=${nv%%/*}; np=${np%%/*}

    remove_entry "$oldn"
    save_entry "$nn|$nl|$nr|$nv|$nm|$np"
    [[ $nn != "$oldn" ]] && tun_destroy "$oldn"

    if tun_create "$nn" "$nl" "$nr" "$nv" "$nm"; then
        ok "تونل «${nn}» به‌روزرسانی و فعال شد."
        show_mirror "$nn" "$nl" "$nr" "$nv" "$nm" "$np"
    else
        err "به‌روزرسانی ناموفق بود."
        return 1
    fi
}

cmd_del() {
    local n=${1:-}
    [[ -n $n ]] || { n=$(pick_tunnel "کدام تونل حذف شود؟") || return 1; }
    load "$n" || { err "تونل «$n» پیدا نشد."; return 1; }
    confirm "تونل «${n}» (سرور مقابل: ${T_REMOTE}) حذف شود؟" || { info "لغو شد."; return 0; }
    tun_destroy "$n"
    remove_entry "$n"
    ok "تونل «${n}» حذف شد."
}

cmd_up() {
    local n=${1:-}
    [[ -n $n ]] || { n=$(pick_tunnel "کدام تونل روشن شود؟") || return 1; }
    load "$n" || { err "تونل «$n» پیدا نشد."; return 1; }
    if tun_create "$T_NAME" "$T_LOCAL" "$T_REMOTE" "$T_V6" "$T_MTU"; then
        ok "تونل «${n}» روشن شد."
    else
        err "روشن کردن «${n}» ناموفق بود."
        return 1
    fi
}

cmd_down() {
    local n=${1:-}
    [[ -n $n ]] || { n=$(pick_tunnel "کدام تونل خاموش شود؟") || return 1; }
    tun_destroy "$n"
    ok "تونل «${n}» خاموش شد."
}

cmd_ping() {
    local n=${1:-}
    [[ -n $n ]] || { n=$(pick_tunnel "کدام تونل تست شود؟") || return 1; }
    load "$n" || { err "تونل «$n» پیدا نشد."; return 1; }
    [[ -n $T_PEER ]] || { warn "IPv6 سرور مقابل ثبت نشده است. با «ip6tun edit» اضافه کنید."; return 1; }
    info "ارسال پینگ به ${BOLD}${T_PEER}${NC} ..."
    if ping -6 -c 4 -W 2 "$T_PEER"; then
        ok "تونل «${n}» سالم است."
    else
        err "پاسخی از سرور مقابل دریافت نشد."
        return 1
    fi
}

cmd_apply() {
    if [[ ! -s $CONF_FILE ]]; then
        info "فایل تنظیمات خالی است."
        return 0
    fi
    local n l r v m p good=0 bad=0
    while IFS='|' read -r n l r v m p; do
        [[ -z ${n:-} || ${n:0:1} == "#" ]] && continue
        if tun_create "$n" "$l" "$r" "$v" "$m"; then
            ok "تونل ${n} فعال شد"
            good=$((good + 1))
        else
            err "تونل ${n} ساخته نشد"
            bad=$((bad + 1))
        fi
    done < "$CONF_FILE"
    info "فعال: ${good}  |  ناموفق: ${bad}"
    (( bad == 0 ))
}

cmd_down_all() {
    [[ -s $CONF_FILE ]] || return 0
    local n _
    while IFS='|' read -r n _; do
        [[ -n ${n:-} ]] && tun_destroy "$n"
    done < "$CONF_FILE"
    return 0
}

cmd_install() {
    local self=${BASH_SOURCE[0]:-}
    if [[ -n $self && -f $self ]]; then
        if [[ $(readlink -f "$self") != "$INSTALL_PATH" ]]; then
            install -m 755 "$self" "$INSTALL_PATH" || { err "کپی فایل ناموفق بود."; return 1; }
        fi
    else
        need curl
        local tmp; tmp=$(mktemp)
        info "دانلود نسخه جدید از گیت‌هاب..."
        if ! curl -fsSL "$REPO_RAW" -o "$tmp"; then
            rm -f "$tmp"
            err "دانلود ناموفق بود. مقدار REPO_RAW را بررسی کنید."
            return 1
        fi
        install -m 755 "$tmp" "$INSTALL_PATH"
        rm -f "$tmp"
    fi
    ok "برنامه در ${INSTALL_PATH} نصب شد."
    ensure_conf

    if [[ ! -d /run/systemd/system ]]; then
        warn "systemd فعال نیست. برای اجرا بعد از ریبوت از cron استفاده کنید:"
        echo "    @reboot ${INSTALL_PATH} apply"
        return 0
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ip6tun - IPv6 over IPv4 tunnels
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_PATH} apply
ExecStop=${INSTALL_PATH} down-all

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" &>/dev/null
    if systemctl restart "$SERVICE_NAME"; then
        ok "سرویس فعال شد؛ تونل‌ها بعد از ریبوت خودکار بالا می‌آیند."
    else
        err "سرویس اجرا نشد. با «journalctl -u ${SERVICE_NAME}» بررسی کنید."
        return 1
    fi
}

cmd_uninstall() {
    confirm "همه تونل‌ها و سرویس ip6tun حذف شوند؟" || return 1
    if [[ -f $SERVICE_FILE ]]; then
        systemctl disable --now "$SERVICE_NAME" &>/dev/null
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    fi
    cmd_down_all
    if confirm "فایل تنظیمات (${CONF_FILE}) هم حذف شود؟"; then
        rm -rf "$CONF_DIR"
    fi
    rm -f "$INSTALL_PATH"
    ok "ip6tun به‌طور کامل حذف شد."
}

# ─── منوی تعاملی ────────────────────────────────────────────────────────────
menu() {
    while true; do
        header
        echo -e "  ${BOLD}منوی اصلی${NC}"
        hr
        printf "   ${C}1${NC})  لیست تونل‌ها و وضعیت\n"
        printf "   ${C}2${NC})  افزودن تونل جدید\n"
        printf "   ${C}3${NC})  ویرایش تونل\n"
        printf "   ${C}4${NC})  حذف تونل\n"
        printf "   ${C}5${NC})  روشن کردن تونل\n"
        printf "   ${C}6${NC})  خاموش کردن تونل\n"
        printf "   ${C}7${NC})  تست پینگ IPv6 تونل\n"
        printf "   ${C}8${NC})  اعمال مجدد همه تونل‌ها\n"
        printf "   ${C}9${NC})  نصب / به‌روزرسانی سرویس\n"
        printf "   ${R}10${NC}) حذف کامل ip6tun\n"
        printf "   ${DIM}0${NC})  خروج\n"
        hr
        local c
        read -rp "  ${C}➜${NC} انتخاب شما: " c
        echo
        case $c in
            1)  cmd_list ;;
            2)  cmd_add_interactive ;;
            3)  cmd_edit ;;
            4)  cmd_del ;;
            5)  cmd_up ;;
            6)  cmd_down ;;
            7)  cmd_ping ;;
            8)  cmd_apply ;;
            9)  cmd_install ;;
            10) cmd_uninstall && exit 0 ;;
            0)  echo -e "  ${G}خدانگهدار!${NC}"; exit 0 ;;
            *)  warn "گزینه نامعتبر است."; sleep 1; continue ;;
        esac
        pause
    done
}

usage() {
cat <<EOF

  ${BOLD}ip6tun v${VERSION}${NC}  -  مدیریت تونل IPv6 over IPv4 (SIT)

  ${BOLD}دستورات:${NC}
    ip6tun                                  منوی تعاملی
    ip6tun list                             لیست تونل‌ها و وضعیت
    ip6tun add                              افزودن تونل (تعاملی)
    ip6tun add NAME REMOTE4 IPV6 [MTU] [LOCAL4|-] [PEER6]
    ip6tun edit [NAME]                      ویرایش تونل
    ip6tun del  [NAME]                      حذف تونل
    ip6tun up   [NAME]                      روشن کردن تونل
    ip6tun down [NAME]                      خاموش کردن تونل
    ip6tun ping [NAME]                      تست پینگ به سرور مقابل
    ip6tun apply                            ساخت مجدد همه تونل‌ها از فایل تنظیمات
    ip6tun install                          نصب / به‌روزرسانی و فعال‌سازی سرویس
    ip6tun uninstall                        حذف کامل

  ${BOLD}مثال:${NC}
    ip6tun add kharazmi 81.12.96.137 fd6d:a13a:be5c:1::1/64 1480 - fd6d:a13a:be5c:1::2

EOF
}

# ─── ورودی اصلی ─────────────────────────────────────────────────────────────
main() {
    local cmd=${1:-menu}
    (( $# > 0 )) && shift

    case $cmd in
        help|-h|--help)       usage; return 0 ;;
        version|-v|--version) echo "ip6tun v${VERSION}"; return 0 ;;
    esac

    [[ $EUID -eq 0 ]] || { err "این برنامه باید با root یا sudo اجرا شود."; exit 1; }
    need ip

    case $cmd in
        menu|m)                  menu ;;
        list|ls)                 cmd_list ;;
        add)                     if (( $# == 0 )); then cmd_add_interactive; else cmd_add "$@"; fi ;;
        edit|e)                  cmd_edit "$@" ;;
        del|rm|delete)           cmd_del "$@" ;;
        up)                      cmd_up "$@" ;;
        down)                    cmd_down "$@" ;;
        ping)                    cmd_ping "$@" ;;
        apply)                   cmd_apply ;;
        down-all)                cmd_down_all ;;
        install|update)          cmd_install ;;
        uninstall)               cmd_uninstall ;;
        *) err "دستور ناشناخته: ${cmd}"; usage; exit 1 ;;
    esac
}

main "$@"

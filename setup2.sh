#!/usr/bin/env bash
# =============================================================================
#  install-site.sh  |  سایت پوششی (رسانه فیلم) برای Reality
# =============================================================================
set -Eeuo pipefail

if [ -t 1 ]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'; else R=""; G=""; Y=""; C=""; N=""; fi
info() { echo "${C}➜${N} $*"; }
ok()   { echo "${G}✔${N} $*"; }
warn() { echo "${Y}⚠${N}  $*"; }
die()  { echo "${R}✘ $*${N}" >&2; exit 1; }
trap 'echo "${R}✘ خطای غیرمنتظره در خط $LINENO${N}" >&2' ERR

usage() {
cat <<'EOF'
استفاده:
  sudo bash install-site.sh [دامنه] [گزینه‌ها]

گزینه‌ها:
  -d, --domain دامنه      نام دامنه (یا به‌صورت آرگومان اول)
  -e, --email ایمیل       ایمیل برای Let's Encrypt (اختیاری)
  -l, --local پورت        nginx فقط روی 127.0.0.1:پورت گوش بدهد (وقتی Xray روی 443 است)
      --staging           گواهی آزمایشی (برای تست، بدون محدودیت نرخ)
      --force             با وجود هشدارها ادامه بده
      --overwrite-site    فایل‌های سایت را از نو بنویس
      --no-firewall       به فایروال دست نزن
      --no-dryrun         تست تمدید خودکار را انجام نده
  -h, --help              راهنما
EOF
}

DOMAIN=""; EMAIL=""; LOCAL_PORT=""
STAGING=0; FORCE=0; OVERWRITE=0; NO_FW=0; NO_DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--domain) [ $# -ge 2 ] || die "مقدار $1 وارد نشده."; DOMAIN="$2"; shift 2 ;;
    -e|--email)  [ $# -ge 2 ] || die "مقدار $1 وارد نشده."; EMAIL="$2"; shift 2 ;;
    -l|--local)  [ $# -ge 2 ] || die "مقدار $1 وارد نشده."; LOCAL_PORT="$2"; shift 2 ;;
    --staging) STAGING=1; shift ;;
    --force) FORCE=1; shift ;;
    --overwrite-site) OVERWRITE=1; shift ;;
    --no-firewall) NO_FW=1; shift ;;
    --no-dryrun) NO_DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "گزینه ناشناخته: $1 (برای راهنما: --help)" ;;
    *) DOMAIN="$1"; shift ;;
  esac
done

[ "${EUID:-$(id -u)}" -eq 0 ] || die "با دسترسی root اجرا کنید (sudo)."
command -v apt-get >/dev/null 2>&1 || die "فقط Debian/Ubuntu پشتیبانی می‌شود."

if [ -z "$DOMAIN" ]; then
  [ -t 0 ] || die "دامنه وارد نشده. مثال: bash install-site.sh example.com"
  read -r -p "نام دامنه را وارد کنید (example.com): " DOMAIN
fi
DOMAIN="${DOMAIN,,}"; DOMAIN="${DOMAIN#http*://}"; DOMAIN="${DOMAIN%%/*}"; DOMAIN="${DOMAIN%.}"
[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "دامنه نامعتبر است: $DOMAIN"
if [ -n "$EMAIL" ]; then [[ "$EMAIL" =~ ^[^@\ ]+@[^@\ ]+\.[^@\ ]+$ ]] || die "ایمیل نامعتبر است."; fi
if [ -n "$LOCAL_PORT" ]; then
  [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] && [ "$LOCAL_PORT" -ge 1024 ] && [ "$LOCAL_PORT" -le 65535 ] \
    || die "پورت --local باید بین 1024 تا 65535 باشد."
fi

SITE_ROOT="/var/www/$DOMAIN"
ACME_ROOT="/var/www/letsencrypt"
CONF="/etc/nginx/sites-available/$DOMAIN"
LIVE="/etc/letsencrypt/live/$DOMAIN"
RENEW_CONF="/etc/letsencrypt/renewal/$DOMAIN.conf"
TLS_PORT="${LOCAL_PORT:-443}"

info "شروع نصب روی دامنه: $DOMAIN"
if [ -n "$LOCAL_PORT" ]; then info "حالت لوکال: nginx روی 127.0.0.1:$LOCAL_PORT"; else info "حالت عمومی: nginx روی 80 و 443"; fi

info "نصب پیش‌نیازها"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx certbot curl dnsutils openssl ca-certificates iproute2

NGINX_VER=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
if ver_ge "$NGINX_VER" 1.25.1; then H2L=""; H2D="http2 on;"; else H2L=" http2"; H2D=""; fi

HAS_V6=0
if [ -f /proc/net/if_inet6 ] && [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" = "0" ]; then HAS_V6=1; fi

port_owner() { ss -H -ltnp "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n1; }
for p in 80 "$TLS_PORT"; do
  owner=$(port_owner "$p")
  if [ -n "$owner" ] && [ "$owner" != "nginx" ]; then
    die "پورت $p توسط «$owner» اشغال است. آن را آزاد کنید یا (برای TLS) از --local 8443 استفاده کنید."
  fi
done

if [ "$NO_FW" -eq 0 ]; then
  NEED_PORTS=(80); [ -z "$LOCAL_PORT" ] && NEED_PORTS+=(443)
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in "${NEED_PORTS[@]}"; do ufw allow "$p/tcp" >/dev/null; done
    ok "ufw: پورت‌های ${NEED_PORTS[*]} باز شد"
  elif command -v iptables >/dev/null 2>&1 && ! iptables -S INPUT 2>/dev/null | grep -q -- '-P INPUT ACCEPT'; then
    for p in "${NEED_PORTS[@]}"; do
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
    done
    ok "iptables: پورت‌های ${NEED_PORTS[*]} باز شد"
  fi
fi

proceed_or_abort() {
  warn "$1"
  [ "$FORCE" -eq 1 ] && return 0
  if [ -t 0 ]; then
    read -r -p "ادامه بدهم؟ [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "متوقف شد."
  else
    die "اجرای غیرتعاملی: مشکل را رفع کنید یا با --force ادامه دهید."
  fi
}

info "بررسی DNS"
SERVER_IP=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)
DOMAIN_IP=$(dig +short A "$DOMAIN" @1.1.1.1 | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n1 || true)
echo "   IP سرور: ${SERVER_IP:-نامشخص} | رکورد A دامنه: ${DOMAIN_IP:-ندارد}"
if [ -z "$DOMAIN_IP" ]; then
  proceed_or_abort "برای $DOMAIN رکورد A پیدا نشد."
elif [ -n "$SERVER_IP" ] && [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
  proceed_or_abort "رکورد A با IP این سرور یکی نیست. اگر از کلودفلر استفاده می‌کنید Proxy را خاموش کنید."
fi
DOMAIN_IP6=$(dig +short AAAA "$DOMAIN" @1.1.1.1 | grep -E '^[0-9a-f:]+$' | head -n1 || true)
if [ -n "$DOMAIN_IP6" ]; then
  SERVER_IP6=$(curl -6 -fsS --max-time 6 https://api6.ipify.org 2>/dev/null || true)
  if [ "${SERVER_IP6,,}" != "${DOMAIN_IP6,,}" ]; then
    proceed_or_abort "دامنه رکورد AAAA ($DOMAIN_IP6) دارد که به این سرور اشاره نمی‌کند؛ حذفش کنید."
  fi
fi

PALETTES=(
  "1a1a2e e94560 16213e 0f3460"
  "121212 e50914 222222 b3b3b3"
  "0f172a 38bdf8 1e293b 94a3b8"
  "1c1c1c ff9f00 2a2a2a f0f0f0"
)
PAL_IDX=$(( $(printf '%s' "$DOMAIN" | cksum | cut -d' ' -f1) % ${#PALETTES[@]} ))
read -r C_BRAND C_ACCENT C_BRAND_D C_ACCENT_D <<< "${PALETTES[$PAL_IDX]}"

write_site() {
  info "ساخت سایت رسانه فیلم در $SITE_ROOT"
  mkdir -p "$SITE_ROOT"/{fonts,assets,blog,.well-known}

  local font_url="https://cdn.jsdelivr.net/gh/rastikerdar/vazirmatn@v33.003/fonts/webfonts/Vazirmatn[wght].woff2"
  local font="$SITE_ROOT/fonts/vazirmatn.woff2"
  if ! curl -fsSgL --max-time 30 -o "$font" "$font_url" || [ "$(stat -c%s "$font" 2>/dev/null || echo 0)" -lt 10000 ]; then
    rm -f "$font"; warn "دانلود فونت ناموفق بود؛ از فونت سیستم استفاده می‌شود."
  fi

  cat > "$SITE_ROOT/assets/style.css" <<EOF
@font-face{font-family:"Vazirmatn";src:url(/fonts/vazirmatn.woff2) format("woff2");font-weight:100 900;font-display:swap}
:root{--bg:#111;--ink:#eee;--muted:#999;--line:#2a2a2a;--brand:#$C_BRAND;--accent:#$C_ACCENT}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:"Vazirmatn",Tahoma,sans-serif;background:var(--bg);color:var(--ink);line-height:1.8;min-height:100vh;display:flex;flex-direction:column}
a{color:inherit;text-decoration:none}a:hover{color:var(--accent)}
.wrap{max-width:960px;width:100%;margin-inline:auto;padding-inline:22px}
main{flex:1}
header{background:#000;border-bottom:1px solid var(--line)}
header .wrap{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px;padding-block:18px}
.brand{font-weight:900;font-size:1.4rem;direction:ltr;color:var(--accent);letter-spacing:1px}
nav{display:flex;gap:24px;font-size:1rem;color:#ccc}
.hero{padding-block:80px 50px;text-align:center;background:linear-gradient(to bottom, #1a1a1a, var(--bg))}
.hero h1{font-size:clamp(2rem,6vw,3.5rem);font-weight:900;line-height:1.4;margin-bottom:16px}
.hero p{color:var(--muted);font-size:1.1rem;max-width:600px;margin:0 auto}
h2{font-size:1.5rem;font-weight:800;margin-bottom:24px;padding-right:12px;border-right:4px solid var(--accent)}
.posts{padding-block:32px 64px}
.post{display:flex;flex-direction:column;gap:12px;padding:24px;border-radius:12px;background:#1a1a1a;border:1px solid var(--line);margin-bottom:20px;transition:transform 0.2s}
.post:hover{transform:translateY(-3px);border-color:var(--accent)}
.post time{color:var(--muted);font-size:.85rem}
.post h3{font-size:1.3rem;font-weight:800}
.post p{color:#bbb;font-size:.95rem}
.tag{display:inline-block;margin-top:12px;font-size:.8rem;color:#fff;background:var(--line);border-radius:4px;padding:4px 12px}
.article,.page{padding-block:48px 64px;max-width:75ch;margin:0 auto}
.article h1,.page h1{font-size:clamp(1.8rem,5vw,2.5rem);line-height:1.5;font-weight:900}
.article .meta{color:var(--muted);font-size:.95rem;margin-block:12px 32px;border-bottom:1px solid var(--line);padding-bottom:16px}
.article p,.page p{margin-bottom:20px;font-size:1.05rem}
.dl-box{background:#161616;border:1px solid var(--line);border-radius:12px;padding:28px;margin:40px 0;box-shadow:0 8px 24px rgba(0,0,0,0.5)}
.dl-box h3{margin-bottom:20px;font-size:1.25rem;color:#fff;display:flex;align-items:center;gap:8px}
.btn{display:block;background:var(--accent);color:#fff;padding:16px;border-radius:8px;text-align:center;font-weight:800;font-size:1.1rem;margin-bottom:12px;transition:opacity .2s;text-shadow:0 1px 2px rgba(0,0,0,0.3)}
.btn:hover{opacity:.85;color:#fff}
footer{background:#000;border-top:1px solid var(--line);color:var(--muted);font-size:.9rem}
footer .wrap{display:flex;justify-content:space-between;flex-wrap:wrap;gap:12px;padding-block:30px}
@media (max-width:600px){nav{gap:16px}.dl-box{padding:20px}}
EOF

  cat > "$SITE_ROOT/favicon.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" rx="22" fill="#$C_BRAND"/><path d="M35 25 L75 50 L35 75 Z" fill="#e9c46a"/></svg>
EOF

  page() {
    local rel="$1" title="$2" desc="$3" canon_tag=""
    case "$rel" in
      index.html) canon_tag="<link rel=\"canonical\" href=\"https://$DOMAIN/\">" ;;
      404.html|50x.html) canon_tag='<meta name="robots" content="noindex">' ;;
      *) canon_tag="<link rel=\"canonical\" href=\"https://$DOMAIN/${rel%.html}\">" ;;
    esac
    {
      cat <<EOF
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<meta name="description" content="$desc">
$canon_tag
<meta property="og:title" content="$title">
<meta property="og:description" content="$desc">
<meta property="og:type" content="website">
<meta property="og:locale" content="fa_IR">
<meta name="theme-color" content="#$C_BRAND">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="alternate" type="application/rss+xml" title="$DOMAIN" href="/feed.xml">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header><div class="wrap"><a class="brand" href="/">FILMBOX</a><nav aria-label="منو"><a href="/">فیلم‌ها</a><a href="/about">درباره ما</a><a href="/contact">پشتیبانی</a></nav></div></header>
<main class="wrap">
EOF
      cat
      cat <<EOF
</main>
<footer><div class="wrap"><span>© $(date +%Y) رسانه دانلود $DOMAIN</span><span><a href="/privacy">قوانین و مقررات</a> · <a href="/feed.xml">RSS</a></span></div></footer>
</body>
</html>
EOF
    } > "$SITE_ROOT/$rel"
  }

  local POSTS=(
    "interstellar|2026-10-05|۱۳ مهر ۱۴۰۵|علمی‌تخیلی|دانلود فیلم Interstellar 2014 با کیفیت 4K|نسخه کامل فیلم میان‌ستاره‌ای با حجم بالا و کیفیت فوق‌العاده بلوری به همراه زیرنویس چسبیده فارسی."
    "breaking-bad|2026-09-28|۶ مهر ۱۴۰۵|سریال|دانلود کامل سریال Breaking Bad (برکینگ بد)|تمامی فصل‌های سریال شاهکار برکینگ بد با دوبله فارسی اختصاصی و کیفیت BluRay 1080p."
    "planet-earth-2|2026-09-15|۲۴ شهریور ۱۴۰۵|مستند|دانلود مستند Planet Earth II (سیاره زمین ۲)|مستند بی‌نظیر بی‌بی‌سی با کیفیت فوق‌العاده 4K HDR و بیت‌ریت اصلی مناسب برای نمایشگرهای بزرگ."
    "dark-knight|2026-08-30|۸ شهریور ۱۴۰۵|اکشن|دانلود فیلم The Dark Knight 2008|شوالیه تاریکی؛ دانلود مستقیم نسخه ریمستر شده با بالاترین کیفیت ممکن 4K UHD."
  )

  article() {
    local p slug="$1" iso jd tag ttl dsc
    for p in "${POSTS[@]}"; do [[ "$p" == "$slug|"* ]] && break; done
    IFS='|' read -r _ iso jd tag ttl dsc <<< "$p"
    page "blog/$slug.html" "$ttl | رسانه دانلود" "$dsc" <<EOF
<article class="article"><h1>$ttl</h1><p class="meta"><time datetime="$iso">$jd</time> · ژانر: $tag</p>
<p>$dsc</p>
$(cat)
<div class="dl-box">
  <h3>🔗 باکس دانلود مستقیم (ترافیک نیم‌بها)</h3>
  <a href="#" class="btn" onclick="alert('سرورهای دانلود در حال بروزرسانی هستند. لطفاً دقایقی دیگر تلاش کنید.'); return false;">دانلود کیفیت 4K HDR (حجم: 16.5 گیگابایت)</a>
  <a href="#" class="btn" style="background:#2ecc71" onclick="alert('سرورهای دانلود در حال بروزرسانی هستند. لطفاً دقایقی دیگر تلاش کنید.'); return false;">دانلود کیفیت 1080p BluRay (حجم: 3.2 گیگابایت)</a>
  <a href="#" class="btn" style="background:#3498db; margin-bottom:0" onclick="alert('سرورهای دانلود در حال بروزرسانی هستند. لطفاً دقایقی دیگر تلاش کنید.'); return false;">دانلود کیفیت 720p x265 (حجم: 1.1 گیگابایت)</a>
</div>
<p style="margin-top:40px"><a href="/">← بازگشت به آرشیو فیلم‌ها</a></p></article>
EOF
  }

  local list="" p slug iso jd tag ttl dsc
  for p in "${POSTS[@]}"; do
    IFS='|' read -r slug iso jd tag ttl dsc <<< "$p"
    list+="<a href=\"/blog/$slug\" class=\"post\"><time datetime=\"$iso\">$jd</time><h3>$ttl</h3><p>$dsc</p><div><span class=\"tag\">$tag</span></div></a>"$'\n'
  done
  page index.html "دانلود فیلم و سریال | $DOMAIN" "مرجع دانلود فیلم و سریال با کیفیت 4K و لینک مستقیم." <<EOF
<section class="hero"><h1>رسانه بزرگ فیلم و سریال</h1>
<p>آرشیو کامل فیلم‌های 4K، سریال‌های روز دنیا و مستندهای باکیفیت با لینک مستقیم، سرورهای قدرتمند و بدون افت سرعت دانلود.</p></section>
<section class="posts"><h2>تازه‌ترین به‌روزرسانی‌ها</h2>
<div style="display:flex; flex-direction:column; gap:16px;">
$list
</div></section>
EOF

  article interstellar <<'EOF'
<p>فیلم میان‌ستاره‌ای (Interstellar) یکی از شاهکارهای کریستوفر نولان است که با کیفیت تصویر خیره‌کننده و موسیقی هانس زیمر، تجربه‌ای بی‌نظیر برای تماشا در نمایشگرهای بزرگ ارائه می‌دهد. فایل‌های قرار گرفته کاملا بدون دستکاری و با انکود اصلی هستند تا نهایت لذت بصری را تجربه کنید.</p>
EOF
  article breaking-bad <<'EOF'
<p>بدون شک یکی از بهترین سریال‌های تاریخ تلویزیون. این پکیج شامل تمامی ۶۲ قسمت با بالاترین بیت‌ریت موجود و صدای ۵.۱ کاناله است که برای آرشیو بسیار مناسب می‌باشد. زیرنویس هماهنگ به صورت Softsub درون فایل‌ها قرار گرفته است.</p>
EOF
  article planet-earth-2 <<'EOF'
<p>برای تست کیفیت تلویزیون یا مانیتور 4K خود، هیچ چیزی بهتر از این مستند طبیعت بی‌نظیر بی‌بی‌سی نیست. فایل‌های دانلودی فشرده نشده‌اند تا بالاترین جزئیات طبیعت حفظ شود.</p>
EOF
  article dark-knight <<'EOF'
<p>دومین قسمت از سه‌گانه بتمن با بازی شگفت‌انگیز هیث لجر. این نسخه، ریمستر 4K فیلم است که رنگ‌ها و کنتراست بسیار بهتری نسبت به نسخه‌های قدیمی‌تر دارد و تماشای آن به شدت توصیه می‌شود.</p>
EOF

  page about.html "درباره ما | $DOMAIN" "درباره‌ی رسانه دانلود فیلم." <<EOF
<section class="page"><h1>درباره رسانه ما</h1>
<p>ما یک پورتال خصوصی برای آرشیو و دانلود باکیفیت‌ترین فیلم‌ها و سریال‌های روز دنیا هستیم. هدف ما ارائه‌ی نسخه‌های بدون افت کیفیت و دست‌نخورده (Remux) با بالاترین سرعت دانلود است.</p>
<p>سرورهای ما روی پورت‌های 10Gbps میزبانی می‌شوند تا فایل‌های حجیم چند ده گیگابایتی در کمترین زمان ممکن قابل دریافت باشند.</p></section>
EOF
  page contact.html "پشتیبانی و تماس | $DOMAIN" "پشتیبانی خرابی لینک‌ها." <<EOF
<section class="page"><h1>پشتیبانی کاربران</h1>
<p>اگر در فرآیند دانلود با ارور قطعی سرور مواجه شدید یا فایلی پاک شده بود، لطفاً از طریق ایمیل زیر به ما اطلاع دهید تا لینک‌ها در اسرع وقت جایگزین شوند:</p>
<p>ایمیل مستقیم مدیریت: <a href="mailto:admin@$DOMAIN" style="color:var(--accent)">admin@$DOMAIN</a></p>
<p>میانگین زمان پاسخگویی: ۱۲ الی ۲۴ ساعت.</p></section>
EOF
  page privacy.html "قوانین و مقررات دانلود | $DOMAIN" "قوانین استفاده از پهنای باند." <<EOF
<section class="page"><h1>قوانین و مقررات سایت</h1>
<p>استفاده از پهنای باند این سایت تابع قوانین زیر است:</p>
<ul>
<li>تمامی لینک‌های دانلود مجهز به سیستم جلوگیری از Leech هستند و فقط برای آی‌پی شما معتبرند.</li>
<li>برای جلوگیری از افت سرعت سایر کاربران، تعداد کانکشن‌های همزمان در نرم‌افزارهای مدیریت دانلود (IDM) را روی حداکثر ۸ تنظیم کنید.</li>
<li>ترافیک مصرفی از سرورهای ما در اکثر ISP ها به صورت **تمام‌بها** محاسبه می‌شود. لطفاً هنگام دانلود فایل‌های 4K به حجم بسته اینترنتی خود دقت کنید.</li>
</ul></section>
EOF
  page 404.html "فایل پیدا نشد | $DOMAIN" "404" <<EOF
<section class="page"><h1>۴۰۴ | فایل حذف شده است</h1><p>کاربر گرامی، ممکن است لینک دانلود منقضی شده باشد یا فیلم به دلیل قوانین کپی‌رایت از سرور پاک شده باشد. <a href="/" style="color:var(--accent)">بازگشت به صفحه اصلی</a></p></section>
EOF
  page 50x.html "ترافیک بالا | $DOMAIN" "500" <<EOF
<section class="page"><h1>خطای سرور دانلود</h1><p>در حال حاضر ظرفیت سرورهای استریم و دانلود پر شده است. لطفاً چند دقیقه دیگر دوباره تلاش کنید. <a href="/" style="color:var(--accent)">بازگشت</a></p></section>
EOF

  printf 'User-agent: *\nAllow: /\nSitemap: https://%s/sitemap.xml\n' "$DOMAIN" > "$SITE_ROOT/robots.txt"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    echo "  <url><loc>https://$DOMAIN/</loc><lastmod>$(date +%F)</lastmod></url>"
    for p in about contact privacy; do echo "  <url><loc>https://$DOMAIN/$p</loc></url>"; done
    for p in "${POSTS[@]}"; do IFS='|' read -r slug iso _ <<< "$p"; echo "  <url><loc>https://$DOMAIN/blog/$slug</loc><lastmod>$iso</lastmod></url>"; done
    echo '</urlset>'
  } > "$SITE_ROOT/sitemap.xml"

  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<rss version="2.0"><channel>'
    echo "<title>$DOMAIN</title><link>https://$DOMAIN/</link><description>رسانه دانلود فیلم و سریال</description><language>fa</language>"
    echo "<lastBuildDate>$(date -R)</lastBuildDate>"
    for p in "${POSTS[@]}"; do
      IFS='|' read -r slug iso _ _ _ ttl dsc <<< "$p"
      echo "<item><title>$ttl</title><link>https://$DOMAIN/blog/$slug</link><guid>https://$DOMAIN/blog/$slug</guid><pubDate>$(date -R -d "$iso")</pubDate><description>$dsc</description></item>"
    done
    echo '</channel></rss>'
  } > "$SITE_ROOT/feed.xml"

  printf 'Contact: mailto:admin@%s\nExpires: %s\nPreferred-Languages: fa, en\nCanonical: https://%s/.well-known/security.txt\n' \
    "$DOMAIN" "$(date -u -d '+1 year' +%Y-%m-%dT%H:%M:%SZ)" "$DOMAIN" > "$SITE_ROOT/.well-known/security.txt"

  local n=0 f
  for f in index.html about.html contact.html privacy.html 404.html 50x.html robots.txt sitemap.xml feed.xml; do
    touch -c -d "$(( 2 + n * 9 )) days ago" "$SITE_ROOT/$f"; n=$((n + 1))
  done
  for f in "$SITE_ROOT"/blog/*.html; do touch -c -d "$(( 14 + n * 6 )) days ago" "$f"; n=$((n + 1)); done
  touch -c -d "$(( 90 + $(printf '%s' "$DOMAIN" | cksum | cut -d' ' -f1) % 60 )) days ago" \
    "$SITE_ROOT/assets/style.css" "$SITE_ROOT/favicon.svg" "$SITE_ROOT/fonts/vazirmatn.woff2" "$SITE_ROOT/.well-known/security.txt" 2>/dev/null || true
  ok "سایت ساخته شد"
}

mkdir -p "$ACME_ROOT"
if [ ! -f "$SITE_ROOT/index.html" ] || [ "$OVERWRITE" -eq 1 ]; then
  write_site
else
  warn "سایت از قبل وجود دارد؛ دست نخورد."
fi
chown -R www-data:www-data "$SITE_ROOT" "$ACME_ROOT"
find "$SITE_ROOT" -type d -exec chmod 755 {} + ; find "$SITE_ROOT" -type f -exec chmod 644 {} +

NEED_CERT=1; FORCE_RENEW=0
if [ -s "$LIVE/fullchain.pem" ] && openssl x509 -checkend 2592000 -noout -in "$LIVE/fullchain.pem" >/dev/null 2>&1; then
  if grep -qs '^authenticator = webroot' "$RENEW_CONF"; then
    NEED_CERT=0; ok "گواهی معتبر از قبل وجود دارد"
  else
    FORCE_RENEW=1; warn "گواهی قبلی standalone بود؛ دوباره با webroot صادر می‌شود."
  fi
fi

HTTP_ONLY_CONF() {
cat > "$CONF" <<EOF
server {
    listen 80 default_server;
    $([ "$HAS_V6" -eq 1 ] && echo "listen [::]:80 default_server;")
    server_name _;
    location ^~ /.well-known/acme-challenge/ { root $ACME_ROOT; default_type text/plain; }
    location / { return 301 https://$DOMAIN\$request_uri; }
}
EOF
}

rm -f /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh /etc/letsencrypt/renewal-hooks/post/start-nginx.sh
rm -f /etc/nginx/sites-enabled/default
printf 'server_tokens off;\n' > /etc/nginx/conf.d/00-selfsteal.conf

if [ "$NEED_CERT" -eq 1 ]; then
  info "دریافت گواهی SSL"
  HTTP_ONLY_CONF
  ln -sf "$CONF" "/etc/nginx/sites-enabled/$DOMAIN"
  nginx -t
  systemctl enable --now nginx >/dev/null 2>&1
  systemctl reload nginx

  CB=(certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --non-interactive --agree-tos --keep-until-expiring)
  if [ -n "$EMAIL" ]; then CB+=(--email "$EMAIL"); else CB+=(--register-unsafely-without-email); fi
  if [ "$STAGING" -eq 1 ]; then CB+=(--staging); warn "گواهی آزمایشی است."; fi
  if [ "$FORCE_RENEW" -eq 1 ]; then CB+=(--force-renewal); fi

  CERT_OK=0
  for i in 1 2 3; do
    if "${CB[@]}"; then CERT_OK=1; break; fi
    warn "تلاش $i ناموفق بود؛ ۸ ثانیه دیگر دوباره تلاش می‌شود..."; sleep 8
  done
  if [ "$CERT_OK" -ne 1 ] || [ ! -s "$LIVE/fullchain.pem" ]; then
    die "دریافت SSL ناموفق بود. رکورد A و باز بودن پورت ۸۰ را چک کنید."
  fi
fi

info "نوشتن کانفیگ نهایی nginx"
if [ -n "$LOCAL_PORT" ]; then
  TLS_L4="listen 127.0.0.1:$LOCAL_PORT ssl$H2L default_server;"; TLS_L6=""
else
  TLS_L4="listen 443 ssl$H2L default_server;"
  if [ "$HAS_V6" -eq 1 ]; then TLS_L6="listen [::]:443 ssl$H2L default_server;"; else TLS_L6=""; fi
fi
if [ "$HAS_V6" -eq 1 ]; then L80_V6="listen [::]:80 default_server;"; else L80_V6=""; fi

cat > "$CONF" <<EOF
server {
    listen 80 default_server;
    $L80_V6
    server_name _;
    location ^~ /.well-known/acme-challenge/ { root $ACME_ROOT; default_type text/plain; }
    location / { return 301 https://$DOMAIN\$request_uri; }
}

server {
    $TLS_L4
    $TLS_L6
    $H2D
    server_name $DOMAIN;

    ssl_certificate     $LIVE/fullchain.pem;
    ssl_certificate_key $LIVE/privkey.pem;
    ssl_protocols TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    gzip on;
    gzip_vary on;
    gzip_min_length 512;
    gzip_types text/css text/plain application/xml image/svg+xml;

    root $SITE_ROOT;
    index index.html;
    autoindex off;
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;

    location ~ /\.(?!well-known) { return 404; }
    location ~ ^/(fonts|assets)/ { expires 30d; }
    location = /favicon.ico { return 301 /favicon.svg; }
    location / { try_files \$uri \$uri.html \$uri/ =404; }
}
EOF
ln -sf "$CONF" "/etc/nginx/sites-enabled/$DOMAIN"
nginx -t || die "کانفیگ nginx خطا دارد."
systemctl enable --now nginx >/dev/null 2>&1
systemctl reload nginx
ok "nginx آماده است"

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
nginx -t >/dev/null 2>&1 && systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
systemctl enable --now certbot.timer >/dev/null 2>&1 || true

if [ "$NO_DRY" -eq 0 ] && [ "$STAGING" -eq 0 ]; then
  info "تست تمدید خودکار (dry-run)"
  certbot renew --cert-name "$DOMAIN" --dry-run >/dev/null 2>&1 || true
fi

SHORT_ID=$(openssl rand -hex 8)
cat <<EOF

${G}==============================================================${N}
 ✅ نصب تمام شد  →  https://$DOMAIN
${G}==============================================================${N}
 تنظیمات Reality:

   "realitySettings": {
     "show": false,
     "dest": "127.0.0.1:$TLS_PORT",
     "xver": 0,
     "serverNames": ["$DOMAIN"],
     "privateKey": "<کلید خصوصی>",
     "shortIds": ["$SHORT_ID"]
   }

 کلاینت: SNI = $DOMAIN | fingerprint = chrome | flow = xtls-rprx-vision
EOF

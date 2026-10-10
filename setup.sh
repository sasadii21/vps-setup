Ran 3 commands, created a file, shared files

اسکریپت کامل install-site.sh آماده‌ست و آماده‌ی گذاشتن روی گیت‌هابه. دامنه خودکار توی index.html، 404.html، robots.txt و sitemap.xml جایگذاری می‌شه، پس دیگه sed دستی لازم نیست. سینتکس و shellcheck رو تست کردم و ساخت سایت و کانفیگ nginx رو هم جدا اجرا کردم و درست بودن. خود نصب (certbot و nginx) روی سرور واقعی تست نشده، پس اول یه بار با --staging اجراش کن.

اجرا:

sudo bash install-site.sh example.com

برای تست بدون محدودیت certbot از --staging استفاده کن.

چیزای جدید:

    گواهی با webroot گرفته می‌شه، پس nginx موقع صدور و تمدید خاموش نمی‌شه.
    هوک‌های قدیمی stop-nginx / start-nginx پاک می‌شن. اگه می‌موندن، تمدید با webroot خراب می‌شد.
    اگه گواهی قبلی با روش standalone گرفته شده باشه، خودکار با webroot دوباره صادر می‌شه.
    فقط TLS 1.3 و HTTP/2 فعال می‌شه. نسخه nginx تشخیص داده می‌شه (http2 on; یا listen ... http2).
    رنگ‌بندی سایت از روی دامنه انتخاب می‌شه (۴ حالت)، تا همه‌ی نصب‌های این اسکریپت ظاهر یکسان نداشته باشن.
    rm -rf /var/www/html/* و fuser -k حذف شدن. سایت توی /var/www/دامنه ساخته می‌شه و اگه پورت ۸۰ یا ۴۴۳ دست برنامه‌ی دیگه‌ای باشه، اسکریپت متوقف می‌شه و پروسه‌ای رو نمی‌کشه.
    DNS و AAAA چک می‌شه و بدون --force مشکوک‌ها رو رد می‌کنه.
    اجرای مجدد امن شده. سایت و گواهی موجود دست نمی‌خورن، مگر با --overwrite-site.
    آخرش TLS 1.3، HTTP/2 و تاریخ انقضا چک می‌شه و بلاک realitySettings آماده با یه shortId رندوم چاپ می‌شه.

برای Reality:

    چون Xray روی پورت رندومه، حالت پیش‌فرض (nginx روی ۴۴۳) درسته و Dest می‌شه 127.0.0.1:443.
    اگه یه روز Xray رو روی ۴۴۳ بردی، با --local 8443 اجرا کن تا nginx فقط روی لوکال بشینه.

قبل از گیت‌هاب: توی کامنت بالای فایل، USER/REPO رو با آدرس خودت عوض کن. چون اسکریپت عمومی می‌شه، بهتره محتوای وبلاگ رو هم شخصی‌سازی کنی که سایت‌های ساخته‌شده با اسکریپتت شبیه هم نباشن.
Install site
SH 

IP,ORIGIN,TLS,ALPN,CURVE,CERT_LENGTH,CERT_SIGNATURE,CERT_PUBLICKEY,CERT_DOMAIN,CERT_ISSUER,GEO_CODE 172.234.99.95,172.234.99.95,TLS 1.3,h2,X25519,3404(certs count: 4),ECDSA-SHA384,ECDSA,gotaklinik.se,"Let's Encrypt",N/A 172.234.99.84,172.234.99.84,TLS 1.3,h2,X25519,3425(certs count: 4),ECDSA-SHA384,

pasted

خل خروجی اسکن
Picking the best domain from the scan results.
Picking the best domain from the scan results.

از این لیست، این سه تا بهترینن:

    yogaworld.se
    uppsaladestilleri.se
    gotaklinik.se

هر سه سایت‌های معمولی و کم‌شهرت سوئدی‌ان، روی همون رنج لینود تو هستن، گواهی Let’s Encrypt با ECDSA دارن، و TLS 1.3 و h2 پشتیبانی می‌کنن. اگه اولی تست نشد، vanerblanket.se، therover.se، earbooks.se یا gottliv.nu هم همین شرایط رو دارن.

اینا رو انتخاب نکن:

    *.cloudnet.cloud و *.cloudwaysapps.com و بقیه wildcardها
    images.apple.com، yahoo.com، github.com و *.netlify.app: خیلی معروفن و روی IP لینود بودنشون عجیبه
    marz.dt30nama.com، ircd-swed.irnetfree.xyz، se1-chat.ssswsss.com و *.wofhwifhafalffagy.com: شبیه سرور پروکسی دیگرانن و ممکنه زودتر شناسایی بشن
    CloudFlare Origin Certificate، centos7-base، teje و RunCloud Web Certificate: گواهی‌هاشون دامنه‌ی واقعی نیست

تست قبل از استفاده (روی سرورت):

openssl s_client -connect yogaworld.se:443 -tls1_3 < /dev/null | grep -E "Protocol|Verify"
curl -sI --http2 https://yogaworld.se | head -1

باید TLSv1.3 و HTTP/2 200 (یا ریدایرکت 301/302) ببینی.

تنظیمات Reality:

    Dest: yogaworld.se:443
    SNI / serverNames: yogaworld.se
    Fingerprint: chrome
    Flow: xtls-rprx-vision

یه نکته: سایت‌های کوچیک ممکنه یه روز آفلاین بشن یا گواهی‌شون عوض بشه. اگه کانکشن یهو قطع شد، اول همین تست رو دوباره بزن. روش Self-steal با دامنه‌ی خودت این وابستگی رو نداره، چون سایت دست خودته.

#!/bin/bash # ========================================================= # اسکریپت نصب سایت + SSL (نسخه پیشرفته) # استفاده: sudo bash install-site.sh example.com # ========================================================= if [ "$EUID" -ne 0 ]; then echo "لطفاً با دسترسی روت اجرا کنید (sudo)." ex

pasted

قالب و چیزی که ساختی رو بزارش توی این کد من 
تمام چیزایی که یک سایت باید داشته باشه که از حالت فیک گونه خارج بشه و برای سیستم فیلترینگ تشخیصشش سخت تر باشه
Ran 3 commands, created a file, shared files

اسکریپت خودت با قالب و امکانات جدید یکی شد و الان یک فایل کامل داری: install-site.sh. این فایل جای نسخه‌ی قبلی رو می‌گیره و دستور اجراش همونه. سینتکس و shellcheck رو تست کردم و ساخت سایت رو جدا اجرا کردم. دو باگ پیدا شد و درست شد (یه فایل خالی *.html و فایل فونت خالی). فایل‌های ساخته‌شده هم بدون خطا ساخته شدن و feed.xml و sitemap.xml XML معتبرن. خود نصب روی سرور واقعی تست نشده، پس بار اول با --staging اجراش کن.

سایت حالا واقعی‌تره:

    صفحه‌های واقعی: خانه، ۴ مقاله‌ی کامل (لینک‌هاشون کار می‌کنه)، درباره، تماس، حریم خصوصی، و صفحه‌های خطای 404 و 50x با همون قالب سایت.
    فایل‌های استاندارد وب: robots.txt، sitemap.xml، feed.xml (RSS)، favicon.svg و .well-known/security.txt.
    ساختار: استایل مشترک توی assets/style.css، آدرس‌های تمیز (/about به‌جای /about.html)، تگ‌های canonical و OpenGraph برای هر صفحه.
    جزئیات سرور: هدر Last-Modified برای هر فایل تاریخ متفاوت و گذشته داره، نه یه زمان یکسان موقع نصب. /favicon.ico هم ریدایرکت می‌شه.
    حذف شده‌ها: ساعت زنده، ping و ابزارهایی که فقط به درد صفحه‌ی «به‌زودی» می‌خوردن.

نکات:

    اگه نسخه‌ی قبلی رو قبلاً اجرا کردی، سایت قدیمی دست نمی‌خوره. برای نصب قالب جدید با --overwrite-site اجرا کن:

  sudo bash install-site.sh example.com --overwrite-site

    آدرس hello@دامنه‌ات توی صفحه‌ی تماس و security.txt هست. اگه رکورد MX نداری، ایمیل‌ها نمی‌رسن و ایرادی هم نداره، ولی اگه خواستی واقعی بشه یه ایمیل‌فوروارد روی دامنه بذار.
    محتوای مقاله‌ها عمومیه. اگه اسکریپت رو روی گیت‌هاب می‌ذاری، بهتره متن مقاله‌ها و عنوان‌ها رو خودت عوض کنی تا سایت همه‌ی نصب‌ها یکی نشه.

یه توصیه‌ی صادقانه: هیچ قالبی شناسایی رو غیرممکن نمی‌کنه. ظاهر سایت فقط وقتی کمک می‌کنه که کسی آدرس رو باز کنه یا فیلتر پروب فعال بزنه. عوامل مهم‌تر رفتار ترافیکه (حجم و الگوی مصرف یه IP)، اثر انگشت TLS کلاینت (chrome درسته) و سن دامنه. دامنه‌ی تازه‌ثبت‌شده یه کم مشکوک‌تره و بعد از چند هفته بهتر می‌شه.
Install site
SH 

ادامه بده
Claude is AI and can make mistakes. Please double-check responses.
Install site · SH
#!/usr/bin/env bash
# =============================================================================
#  install-site.sh  |  سایت پوششی (Self-steal) برای Reality  |  نسخه ۳
#
#  نصب خودکار: nginx + گواهی Let's Encrypt (بدون قطعی هنگام تمدید) + وبلاگ فارسی چندصفحه‌ای
#  دامنه به‌صورت خودکار داخل index.html و بقیه فایل‌ها جایگذاری می‌شود.
#
#  استفاده:
#    sudo bash install-site.sh example.com
#    sudo bash install-site.sh -d example.com -e me@mail.com
#    sudo bash install-site.sh example.com --local 8443    # وقتی Xray روی 443 است
#    bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install-site.sh) example.com
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
  -d, --domain دامنه     نام دامنه (یا به‌صورت آرگومان اول)
  -e, --email ایمیل      ایمیل برای Let's Encrypt (اختیاری)
  -l, --local پورت       nginx فقط روی 127.0.0.1:پورت گوش بدهد (وقتی Xray روی 443 است)
      --staging          گواهی آزمایشی (برای تست، بدون محدودیت نرخ)
      --force            با وجود هشدارها ادامه بده
      --overwrite-site   فایل‌های سایت را از نو بنویس
      --no-firewall      به فایروال دست نزن
      --no-dryrun        تست تمدید خودکار را انجام نده
  -h, --help             راهنما
EOF
}
 
# ------------------------------ آرگومان‌ها -----------------------------------
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
 
# ------------------------------ ۱. پیش‌نیازها -------------------------------
info "نصب پیش‌نیازها"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx certbot curl dnsutils openssl ca-certificates iproute2
 
NGINX_VER=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
if ver_ge "$NGINX_VER" 1.25.1; then H2L=""; H2D="http2 on;"; else H2L=" http2"; H2D=""; fi
 
HAS_V6=0
if [ -f /proc/net/if_inet6 ] && [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" = "0" ]; then HAS_V6=1; fi
 
# ------------------------------ ۲. بررسی پورت‌ها ----------------------------
port_owner() { ss -H -ltnp "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n1; }
for p in 80 "$TLS_PORT"; do
  owner=$(port_owner "$p")
  if [ -n "$owner" ] && [ "$owner" != "nginx" ]; then
    die "پورت $p توسط «$owner» اشغال است. آن را آزاد کنید یا (برای TLS) از --local 8443 استفاده کنید."
  fi
done
 
# ------------------------------ ۳. فایروال ----------------------------------
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
  warn "اگر فایروال ابری دارید (مثلاً Linode Cloud Firewall)، پورت‌های ${NEED_PORTS[*]} و پورت‌های Xray را آنجا هم باز کنید."
fi
 
# ------------------------------ ۴. بررسی DNS --------------------------------
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
  proceed_or_abort "رکورد A با IP این سرور یکی نیست. اگر از کلودفلر استفاده می‌کنید Proxy را خاموش کنید (DNS only)."
fi
DOMAIN_IP6=$(dig +short AAAA "$DOMAIN" @1.1.1.1 | grep -E '^[0-9a-f:]+$' | head -n1 || true)
if [ -n "$DOMAIN_IP6" ]; then
  SERVER_IP6=$(curl -6 -fsS --max-time 6 https://api6.ipify.org 2>/dev/null || true)
  if [ "${SERVER_IP6,,}" != "${DOMAIN_IP6,,}" ]; then
    proceed_or_abort "دامنه رکورد AAAA ($DOMAIN_IP6) دارد که به این سرور اشاره نمی‌کند؛ تأیید گواهی خراب می‌شود. حذفش کنید."
  fi
fi
 
# ------------------------------ ۵. ساخت سایت --------------------------------
PALETTES=(
  "14342f b4531f 0b1f1b e9a26b"
  "1d2b53 2f5fd0 111a38 8fb0ff"
  "3b2a4a 9a3f7a 25182f e59ac6"
  "1f3a4d 0e7c86 12242f 67d4dc"
)
# رنگ‌بندی بر اساس دامنه انتخاب می‌شود تا همه‌ی نصب‌ها ظاهر یکسان نداشته باشند
PAL_IDX=$(( $(printf '%s' "$DOMAIN" | cksum | cut -d' ' -f1) % ${#PALETTES[@]} ))
read -r C_BRAND C_ACCENT C_BRAND_D C_ACCENT_D <<< "${PALETTES[$PAL_IDX]}"
 
write_site() {
  info "ساخت سایت چندصفحه‌ای در $SITE_ROOT"
  mkdir -p "$SITE_ROOT"/{fonts,assets,blog,.well-known}
 
  local font_url="https://cdn.jsdelivr.net/gh/rastikerdar/vazirmatn@v33.003/fonts/webfonts/Vazirmatn[wght].woff2"
  local font="$SITE_ROOT/fonts/vazirmatn.woff2"
  if ! curl -fsSgL --max-time 30 -o "$font" "$font_url" || [ "$(stat -c%s "$font" 2>/dev/null || echo 0)" -lt 10000 ]; then
    rm -f "$font"; warn "دانلود فونت ناموفق بود؛ از فونت سیستم استفاده می‌شود."
  fi
 
  # ---------- استایل مشترک و آیکون ----------
  cat > "$SITE_ROOT/assets/style.css" <<EOF
@font-face{font-family:"Vazirmatn";src:url(/fonts/vazirmatn.woff2) format("woff2");font-weight:100 900;font-display:swap}
:root{--bg:#f7f6f1;--ink:#17231f;--muted:#5c6b65;--line:#dcdfd6;--brand:#$C_BRAND;--accent:#$C_ACCENT}
@media (prefers-color-scheme:dark){:root{--bg:#0f1917;--ink:#e6ece8;--muted:#98a8a1;--line:#24372f;--brand:#$C_BRAND_D;--accent:#$C_ACCENT_D}}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:"Vazirmatn",Tahoma,sans-serif;background:var(--bg);color:var(--ink);line-height:2;min-height:100vh;display:flex;flex-direction:column;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom)}
a{color:inherit;text-decoration:none}a:hover{color:var(--accent)}
:focus-visible{outline:3px solid var(--accent);outline-offset:3px}
.wrap{max-width:900px;width:100%;margin-inline:auto;padding-inline:22px}
main{flex:1}
header{border-bottom:1px solid var(--line)}
header .wrap{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px;padding-block:14px}
.brand{font-weight:800;font-size:1.15rem;direction:ltr}
nav{display:flex;gap:22px;font-size:.95rem;color:var(--muted)}
.hero{padding-block:64px 40px}
.hero h1{font-size:clamp(1.9rem,5.5vw,3.1rem);font-weight:800;line-height:1.5;max-width:20ch}
.hero p{margin-top:14px;color:var(--muted);max-width:52ch}
h2{font-size:1.25rem;font-weight:700;margin-bottom:18px}
.posts{padding-block:24px 56px}
.post{display:grid;grid-template-columns:110px 1fr;gap:20px;padding-block:22px;border-top:1px solid var(--line)}
.post time{color:var(--muted);font-size:.85rem}
.post h3{font-size:1.1rem;font-weight:700;line-height:1.8}
.post p{color:var(--muted);font-size:.95rem;margin-top:4px}
.tag{display:inline-block;margin-top:8px;font-size:.8rem;color:var(--accent);border:1px solid var(--line);border-radius:6px;padding:0 10px}
.article,.page{padding-block:48px 64px;max-width:68ch}
.article h1,.page h1{font-size:clamp(1.6rem,4.5vw,2.3rem);line-height:1.6;font-weight:800}
.article .meta{color:var(--muted);font-size:.9rem;margin-block:6px 24px}
.article p,.page p{margin-bottom:16px}
.page h1{margin-bottom:18px}
.page ul{margin:0 0 16px;padding-inline-start:22px}
.article a,.page a{color:var(--accent);text-decoration:underline}
code{direction:ltr;unicode-bidi:embed;background:var(--line);border-radius:4px;padding:0 6px;font-size:.9em}
footer{border-top:1px solid var(--line);color:var(--muted);font-size:.85rem}
footer .wrap{display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px;padding-block:20px}
@media (max-width:600px){.post{grid-template-columns:1fr;gap:2px}nav{gap:14px}}
EOF
  cat > "$SITE_ROOT/favicon.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" rx="22" fill="#$C_BRAND"/><text x="50" y="70" font-size="62" text-anchor="middle" fill="#e9c46a" font-family="Tahoma,sans-serif">ی</text></svg>
EOF
 
  # ---------- قالب مشترک صفحه: page مسیر عنوان توضیح (بدنه از stdin) ----------
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
<header><div class="wrap"><a class="brand" href="/">$DOMAIN</a><nav aria-label="منو"><a href="/">خانه</a><a href="/about">درباره</a><a href="/contact">تماس</a></nav></div></header>
<main class="wrap">
EOF
      cat
      cat <<EOF
</main>
<footer><div class="wrap"><span>© $(date +%Y) $DOMAIN</span><span><a href="/privacy">حریم خصوصی</a> · <a href="/feed.xml">RSS</a></span></div></footer>
</body>
</html>
EOF
    } > "$SITE_ROOT/$rel"
  }
 
  # شناسه|تاریخ|تاریخ شمسی|دسته|عنوان|خلاصه
  local POSTS=(
    "tls-13|2026-09-28|۶ مهر ۱۴۰۵|امنیت|چرا TLS 1.3 اتصال اول را سریع‌تر می‌کند|مرور ساده‌ی تفاوت دست‌دهی در نسخه‌های TLS و اثر آن بر زمان بارگذاری صفحه."
    "browser-cache|2026-09-14|۲۲ شهریور ۱۴۰۵|سرعت|تنظیم کش مرورگر برای فایل‌های ثابت|چند هدر ساده که حجم درخواست‌های تکراری را به‌شدت کم می‌کنند."
    "rsync-backup|2026-08-30|۸ شهریور ۱۴۰۵|سرور|پشتیبان‌گیری خودکار از سرور با rsync|یک دستور کوتاه برای نسخه‌ی پشتیبان روزانه بدون کپی دوباره‌ی همه‌چیز."
    "nginx-logs|2026-08-11|۲۰ مرداد ۱۴۰۵|ابزار|خواندن لاگ nginx بدون خسته‌شدن|الگوهای پرکاربرد برای پیدا کردن خطاها و درخواست‌های پرتکرار."
  )
 
  article() {
    local p slug="$1" iso jd tag ttl dsc
    for p in "${POSTS[@]}"; do [[ "$p" == "$slug|"* ]] && break; done
    IFS='|' read -r _ iso jd tag ttl dsc <<< "$p"
    page "blog/$slug.html" "$ttl | $DOMAIN" "$dsc" <<EOF
<article class="article"><h1>$ttl</h1><p class="meta"><time datetime="$iso">$jd</time> · $tag</p>
$(cat)
<p><a href="/">← بازگشت به نوشته‌ها</a></p></article>
EOF
  }
 
  # ---------- صفحه اصلی ----------
  local list="" p slug iso jd tag ttl dsc
  for p in "${POSTS[@]}"; do
    IFS='|' read -r slug iso jd tag ttl dsc <<< "$p"
    list+="<article class=\"post\"><time datetime=\"$iso\">$jd</time><div><h3><a href=\"/blog/$slug\">$ttl</a></h3><p>$dsc</p><span class=\"tag\">$tag</span></div></article>"$'\n'
  done
  page index.html "$DOMAIN | یادداشت‌هایی درباره وب، سرور و سرعت" "وبلاگی درباره نگهداری سرور، سرعت سایت و ابزارهای توسعه‌دهندگان." <<EOF
<section class="hero"><h1>یادداشت‌هایی درباره وب، سرور و سرعت</h1>
<p>تجربه‌های روزمره از راه‌اندازی سرور، بهینه‌سازی سایت و انتخاب ابزارهای درست. کوتاه، مشخص و قابل تکرار.</p></section>
<section class="posts"><h2>تازه‌ترین نوشته‌ها</h2>
$list</section>
EOF
 
  # ---------- نوشته‌ها ----------
  article tls-13 <<'EOF'
<p>در TLS 1.2 دست‌دهی اولیه دو رفت‌وبرگشت کامل بین کلاینت و سرور لازم داشت. در TLS 1.3 همین کار معمولاً با یک رفت‌وبرگشت انجام می‌شود، چون کلاینت از همان پیام اول کلیدهایش را می‌فرستد.</p>
<p>این تفاوت روی شبکه‌های پرتأخیر مثل اینترنت موبایل بیشتر حس می‌شود. جدا از سرعت، الگوریتم‌های قدیمی و ناامن از پروتکل حذف شده‌اند و تنظیمات ساده‌تر شده است.</p>
<p>برای فعال‌کردنش در nginx کافی است <code>ssl_protocols TLSv1.3;</code> را بنویسید و یک گواهی معتبر داشته باشید. مرورگرهای امروزی همه از آن پشتیبانی می‌کنند.</p>
EOF
  article browser-cache <<'EOF'
<p>فایل‌هایی که کم عوض می‌شوند، مثل استایل، فونت و تصویر، نباید در هر بازدید دوباره دانلود شوند. هدر <code>Cache-Control</code> به مرورگر می‌گوید چقدر می‌تواند نسخه‌ی ذخیره‌شده را نگه دارد.</p>
<p>در nginx برای مسیر فایل‌های ثابت می‌توانید <code>expires 30d;</code> بنویسید. صفحه‌های HTML را بهتر است کوتاه‌مدت یا بدون کش نگه دارید تا تغییرات زود دیده شوند.</p>
<p>اگر فایلی را عوض می‌کنید، اسمش را هم عوض کنید (مثلاً با شماره‌ی نسخه) تا کش قدیمی مزاحم نشود.</p>
EOF
  article rsync-backup <<'EOF'
<p>rsync فقط تفاوت فایل‌ها را کپی می‌کند، برای همین بار دوم و سوم خیلی سریع‌تر از بار اول است. یک نمونه‌ی ساده: <code>rsync -a --delete /var/www/ /backup/www/</code></p>
<p>با یک خط در cron می‌توانید آن را هر شب اجرا کنید: <code>0 3 * * * rsync -a --delete /var/www/ /backup/www/</code></p>
<p>پشتیبان روی همان دیسک سرور کافی نیست. حداقل یک نسخه را روی ماشین دیگر نگه دارید و هر چند وقت یک بار بازیابی‌اش را امتحان کنید.</p>
EOF
  article nginx-logs <<'EOF'
<p>لاگ‌ها به‌صورت پیش‌فرض در <code>/var/log/nginx/</code> هستند. برای دیدن خطاها به‌صورت زنده از <code>tail -f /var/log/nginx/error.log</code> استفاده کنید.</p>
<p>برای شمردن درخواست‌های ۴۰۴ می‌توانید <code>grep " 404 " access.log | wc -l</code> را بزنید، و برای پرتکرارترین آدرس‌ها از ترکیب <code>sort</code> و <code>uniq -c</code> کمک بگیرید.</p>
<p>چرخش لاگ‌ها را logrotate انجام می‌دهد؛ مهم است که حجم آن‌ها دیسک را پر نکند.</p>
EOF
 
  # ---------- صفحه‌های ثابت ----------
  page about.html "درباره | $DOMAIN" "درباره‌ی این وبلاگ و موضوع‌هایی که درباره‌شان نوشته می‌شود." <<EOF
<section class="page"><h1>درباره این وبلاگ</h1>
<p>این وبلاگ را یک مدیر سیستم برای ثبت تجربه‌های روزمره‌اش نگه می‌دارد. هدف، نوشتن یادداشت‌های کوتاه و قابل تکراری است که خودم هم بعداً سراغشان برگردم.</p>
<p>موضوع‌های اصلی:</p>
<ul><li>راه‌اندازی و نگهداری سرور لینوکس</li><li>سرعت و امنیت سایت‌ها</li><li>ابزارهای خط فرمان و خودکارسازی</li></ul>
<p>نوشته‌ها بدون تبلیغ منتشر می‌شوند و هر چند هفته یک بار به‌روز می‌شوند.</p></section>
EOF
  page contact.html "تماس | $DOMAIN" "راه ارتباط با نویسنده‌ی وبلاگ." <<EOF
<section class="page"><h1>تماس</h1>
<p>برای پیشنهاد، اصلاح یا سؤال درباره‌ی نوشته‌ها ایمیل بزنید:</p>
<p><a href="mailto:hello@$DOMAIN">hello@$DOMAIN</a></p>
<p>معمولاً ظرف چند روز پاسخ داده می‌شود.</p></section>
EOF
  page privacy.html "حریم خصوصی | $DOMAIN" "این سایت چه داده‌ای جمع می‌کند و چه داده‌ای نه." <<EOF
<section class="page"><h1>حریم خصوصی</h1>
<p>این سایت از کوکی، ابزار تحلیل یا اسکریپت شخص ثالث استفاده نمی‌کند.</p>
<ul><li>سرور مثل هر وب‌سرور دیگری لاگ دسترسی ساده (آدرس IP، زمان و آدرس صفحه) نگه می‌دارد.</li>
<li>لاگ‌ها فقط برای رفع خطا و امنیت استفاده می‌شوند و پس از مدتی حذف می‌شوند.</li>
<li>هیچ داده‌ای با دیگران به اشتراک گذاشته نمی‌شود.</li></ul>
<p>سؤالی دارید؟ از صفحه‌ی <a href="/contact">تماس</a> بپرسید.</p></section>
EOF
  page 404.html "صفحه پیدا نشد | $DOMAIN" "این صفحه وجود ندارد." <<EOF
<section class="page"><h1>۴۰۴ | صفحه پیدا نشد</h1><p>صفحه‌ای که دنبالش هستید وجود ندارد یا جابه‌جا شده است.</p><p><a href="/">بازگشت به صفحه اصلی</a></p></section>
EOF
  page 50x.html "خطای سرور | $DOMAIN" "مشکل موقتی در سرور." <<EOF
<section class="page"><h1>مشکلی پیش آمده</h1><p>سرور الان نمی‌تواند درخواست را انجام دهد. چند دقیقه‌ی دیگر دوباره تلاش کنید.</p><p><a href="/">بازگشت به صفحه اصلی</a></p></section>
EOF
 
  # ---------- فایل‌های استاندارد وب ----------
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
    echo "<title>$DOMAIN</title><link>https://$DOMAIN/</link><description>یادداشت‌هایی درباره وب، سرور و سرعت</description><language>fa</language>"
    echo "<lastBuildDate>$(date -R)</lastBuildDate>"
    for p in "${POSTS[@]}"; do
      IFS='|' read -r slug iso _ _ _ ttl dsc <<< "$p"
      echo "<item><title>$ttl</title><link>https://$DOMAIN/blog/$slug</link><guid>https://$DOMAIN/blog/$slug</guid><pubDate>$(date -R -d "$iso")</pubDate><description>$dsc</description></item>"
    done
    echo '</channel></rss>'
  } > "$SITE_ROOT/feed.xml"
  printf 'Contact: mailto:hello@%s\nExpires: %s\nPreferred-Languages: fa, en\nCanonical: https://%s/.well-known/security.txt\n' \
    "$DOMAIN" "$(date -u -d '+1 year' +%Y-%m-%dT%H:%M:%SZ)" "$DOMAIN" > "$SITE_ROOT/.well-known/security.txt"
 
  # زمان تغییر فایل‌ها را طبیعی کن (هدر Last-Modified): صفحه‌ها تازه‌تر، استایل/فونت/آیکون قدیمی‌تر
  local n=0 f
  for f in index.html about.html contact.html privacy.html 404.html 50x.html robots.txt sitemap.xml feed.xml; do
    touch -c -d "$(( 2 + n * 9 )) days ago" "$SITE_ROOT/$f"; n=$((n + 1))
  done
  for f in "$SITE_ROOT"/blog/*.html; do touch -c -d "$(( 14 + n * 6 )) days ago" "$f"; n=$((n + 1)); done
  touch -c -d "$(( 90 + $(printf '%s' "$DOMAIN" | cksum | cut -d' ' -f1) % 60 )) days ago" \
    "$SITE_ROOT/assets/style.css" "$SITE_ROOT/favicon.svg" "$SITE_ROOT/fonts/vazirmatn.woff2" "$SITE_ROOT/.well-known/security.txt" 2>/dev/null || true
  ok "سایت ساخته شد: ۴ نوشته، درباره، تماس، حریم خصوصی، 404/50x، RSS، sitemap، robots، security.txt"
}
 
mkdir -p "$ACME_ROOT"
if [ ! -f "$SITE_ROOT/index.html" ] || [ "$OVERWRITE" -eq 1 ]; then
  write_site
else
  warn "سایتی از قبل در $SITE_ROOT هست؛ دست نخورد (برای بازنویسی: --overwrite-site)"
fi
chown -R www-data:www-data "$SITE_ROOT" "$ACME_ROOT"
find "$SITE_ROOT" -type d -exec chmod 755 {} + ; find "$SITE_ROOT" -type f -exec chmod 644 {} +
 
# ------------------------------ ۶. گواهی SSL --------------------------------
NEED_CERT=1; FORCE_RENEW=0
if [ -s "$LIVE/fullchain.pem" ] && openssl x509 -checkend 2592000 -noout -in "$LIVE/fullchain.pem" >/dev/null 2>&1; then
  if grep -qs '^authenticator = webroot' "$RENEW_CONF"; then
    NEED_CERT=0; ok "گواهی معتبر از قبل وجود دارد"
  else
    FORCE_RENEW=1; warn "گواهی قبلی با روش standalone گرفته شده؛ برای تمدید بدون قطعی، با webroot دوباره صادر می‌شود."
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
 
# هوک‌های قدیمی (توقف nginx موقع تمدید) با webroot نه‌تنها لازم نیستند، تمدید را خراب هم می‌کنند
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
  if [ "$STAGING" -eq 1 ]; then CB+=(--staging); warn "گواهی آزمایشی است و مرورگرها آن را معتبر نمی‌دانند."; fi
  if [ "$FORCE_RENEW" -eq 1 ]; then CB+=(--force-renewal); fi
 
  CERT_OK=0
  for i in 1 2 3; do
    if "${CB[@]}"; then CERT_OK=1; break; fi
    warn "تلاش $i ناموفق بود؛ ۸ ثانیه دیگر دوباره تلاش می‌شود..."; sleep 8
  done
  if [ "$CERT_OK" -ne 1 ] || [ ! -s "$LIVE/fullchain.pem" ]; then
    die "دریافت SSL ناموفق بود. بررسی کنید: ۱) رکورد A به همین سرور باشد (بدون پروکسی) ۲) پورت 80 در فایروال ابری باز باشد ۳) DNS کامل پخش شده باشد."
  fi
fi
 
# ------------------------------ ۷. کانفیگ نهایی nginx -----------------------
info "نوشتن کانفیگ nginx"
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
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
    add_header Content-Security-Policy "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'" always;
 
    gzip on;
    gzip_vary on;
    gzip_min_length 512;
    gzip_types text/css text/plain application/xml image/svg+xml;
 
    client_max_body_size 1m;
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
nginx -t || die "کانفیگ nginx خطا دارد (خروجی بالا را ببینید)."
systemctl enable --now nginx >/dev/null 2>&1
systemctl reload nginx
ok "nginx آماده است"
 
# ------------------------------ ۸. تمدید خودکار -----------------------------
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
nginx -t >/dev/null 2>&1 && systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
systemctl enable --now certbot.timer >/dev/null 2>&1 || true
 
if [ "$NO_DRY" -eq 0 ] && [ "$STAGING" -eq 0 ]; then
  info "تست تمدید خودکار (dry-run)"
  if certbot renew --cert-name "$DOMAIN" --dry-run >/dev/null 2>&1; then ok "تمدید خودکار سالم است"; else warn "تست تمدید ناموفق بود؛ با «certbot renew --dry-run» بررسی کنید."; fi
fi
 
# ------------------------------ ۹. بررسی نهایی ------------------------------
info "بررسی نهایی"
TLS_OUT=$(timeout 10 openssl s_client -connect "127.0.0.1:$TLS_PORT" -servername "$DOMAIN" -alpn h2 -tls1_3 </dev/null 2>&1 || true)
if grep -q "TLSv1.3" <<< "$TLS_OUT"; then ok "TLS 1.3 فعال است"; else warn "TLS 1.3 تأیید نشد"; fi
if grep -q "ALPN protocol: h2" <<< "$TLS_OUT"; then ok "HTTP/2 فعال است"; else warn "HTTP/2 تأیید نشد"; fi
HTTP_RES=$(curl -sS -o /dev/null --http2 --connect-timeout 5 --resolve "$DOMAIN:$TLS_PORT:127.0.0.1" -w '%{http_code} (HTTP/%{http_version})' "https://$DOMAIN:$TLS_PORT/" 2>/dev/null || true)
echo "   پاسخ سایت: ${HTTP_RES:-بدون پاسخ}"
EXPIRY=$(openssl x509 -enddate -noout -in "$LIVE/fullchain.pem" 2>/dev/null | cut -d= -f2 || true)
[ -n "$EXPIRY" ] && echo "   انقضای گواهی: $EXPIRY (تمدید خودکار فعال است)"
 
SHORT_ID=$(openssl rand -hex 8)
cat <<EOF
 
${G}==============================================================${N}
 ✅ نصب تمام شد  →  https://$DOMAIN
${G}==============================================================${N}
 تنظیمات Reality (سمت سرور Xray):
 
   "realitySettings": {
     "show": false,
     "dest": "127.0.0.1:$TLS_PORT",
     "xver": 0,
     "serverNames": ["$DOMAIN"],
     "privateKey": "<خروجی: xray x25519>",
     "shortIds": ["$SHORT_ID"]
   }
 
 سمت کلاینت: SNI = $DOMAIN | fingerprint = chrome | flow = xtls-rprx-vision
 یادآوری: پورت اینباند Xray را در فایروال باز کنید.
EOF
 
Claude finished the response

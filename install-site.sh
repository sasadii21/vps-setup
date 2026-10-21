#!/usr/bin/env bash
# =============================================================================
#  install-site.sh  |  وبلاگ فنی با nginx، TLS 1.3، HTTP/2، HTTP/3 و X25519MLKEM768
#  نسخه ۵
# =============================================================================
set -Eeuo pipefail

if [ -t 1 ]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'; else R=""; G=""; Y=""; C=""; N=""; fi
info() { echo "${C}➜${N} $*"; }
ok()   { echo "${G}✔${N} $*"; }
warn() { echo "${Y}⚠${N}  $*"; }
die()  { echo "${R}✘ $*${N}" >&2; exit 1; }
trap 'echo "${R}✘ خطای غیرمنتظره در خط $LINENO: $BASH_COMMAND${N}" >&2' ERR

usage() {
cat <<'EOF'
استفاده:
  sudo bash install-site.sh [دامنه] [گزینه‌ها]

گزینه‌ها:
  -d, --domain دامنه       نام دامنه (یا به‌صورت آرگومان اول)
  -e, --email ایمیل        ایمیل برای حساب ACME (اختیاری)
  -l, --local پورت         nginx فقط روی 127.0.0.1:پورت گوش بدهد (وقتی سرویس دیگری روی 443 است)
      --ca نام             letsencrypt (پیش‌فرض) یا google (Google Trust Services)
      --eab-kid شناسه      Key ID برای EAB (فقط همراه با --ca google)
      --eab-hmac کلید      HMAC key برای EAB (فقط همراه با --ca google)
      --no-nginx-repo      nginx رسمی (nginx.org) را برای HTTP/3 نصب نکن
      --staging            گواهی آزمایشی (بدون محدودیت نرخ)
      --force              با وجود هشدارها ادامه بده
      --overwrite-site     فایل‌های سایت را از نو بنویس
      --no-firewall        به فایروال دست نزن
      --no-dryrun          تست تمدید خودکار را انجام نده
  -h, --help               راهنما
EOF
}

# ============================ محتوای سایت ====================================
# فرمت هر نوشته: slug|برچسب|عنوان|توضیح
POSTS=(
  "tls-13|امنیت|چرا TLS 1.3 را فعال کنیم؟|نگاهی کوتاه به تفاوت TLS 1.3 با نسخه‌های قدیمی و دلیل اینکه سرعت و امنیت هر دو بهتر می‌شوند."
  "post-quantum|امنیت|کلیدهای ترکیبی پساکوانتومی در TLS|X25519MLKEM768 چیست، چرا ترکیب دو الگوریتم مهم است و از چه چیزی محافظت می‌کند."
  "http3|شبکه|HTTP/3 و QUIC|چرا HTTP/3 روی UDP اجرا می‌شود و مرورگر چطور از وجود آن باخبر می‌شود."
  "nginx-logs|ابزار|خواندن لاگ nginx بدون خسته شدن|چند دستور ساده برای پیدا کردن خطاها، درخواست‌های پرتکرار و کدهای وضعیت."
)

# کارت‌های فهرست نوشته‌ها: $1 = حداکثر تعداد (۰ یعنی همه)
cards() {
  local i=0 p slug tag ttl dsc
  for p in "${POSTS[@]}"; do
    if [ "$1" -gt 0 ] && [ "$i" -ge "$1" ]; then break; fi
    IFS='|' read -r slug tag ttl dsc <<< "$p"
    printf '<a class="card" href="/blog/%s"><span class="tag">%s</span><h3>%s</h3><p>%s</p><span class="more">ادامه مطلب ←</span></a>\n' "$slug" "$tag" "$ttl" "$dsc"
    i=$((i + 1))
  done
}

# قالب مشترک صفحه‌ها
# $1 مسیر فایل  $2 عنوان  $3 توضیح  $4 مسیر canonical ("-" یعنی بدون)  $5 noindex (0/1)  بدنه از stdin
layout() {
  local rel="$1" title="$2" desc="$3" path="$4" noindex="${5:-0}" canon="" robots=""
  if [ "$path" != "-" ]; then canon="<link rel=\"canonical\" href=\"https://$DOMAIN$path\">"; fi
  if [ "$noindex" = 1 ]; then robots='<meta name="robots" content="noindex">'; fi
  mkdir -p "$(dirname "$SITE_ROOT/$rel")"
  {
    cat <<HEAD
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<meta name="description" content="$desc">
$canon
$robots
<meta property="og:title" content="$title">
<meta property="og:description" content="$desc">
<meta property="og:type" content="website">
<meta property="og:locale" content="fa_IR">
<meta name="theme-color" content="#1f4d45">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="alternate" type="application/rss+xml" title="$DOMAIN" href="/feed.xml">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<a class="skip" href="#main">رفتن به محتوا</a>
<header class="site-header"><div class="wrap bar">
  <a class="brand" href="/">$DOMAIN</a>
  <nav aria-label="منو"><a href="/blog/">نوشته‌ها</a><a href="/security">امنیت</a><a href="/about">درباره</a><a href="/contact">تماس</a></nav>
</div></header>
<main id="main" class="wrap">
HEAD
    cat
    cat <<TAIL
</main>
<footer class="site-footer"><div class="wrap foot">
  <span>© $(date +%Y) $DOMAIN</span>
  <span><a href="/privacy">حریم خصوصی</a> · <a href="/feed.xml">RSS</a> · <a href="/.well-known/security.txt">security.txt</a></span>
</div></footer>
</body>
</html>
TAIL
  } > "$SITE_ROOT/$rel"
}

# نوشتن یک نوشته: slug را می‌گیرد، بدنه را از stdin می‌خواند
article() {
  local slug="$1" line="" tag ttl dsc body p
  for p in "${POSTS[@]}"; do
    if [[ "$p" == "$slug|"* ]]; then line="$p"; fi
  done
  IFS='|' read -r _ tag ttl dsc <<< "$line"
  body=$(cat)
  layout "blog/$slug.html" "$ttl | $DOMAIN" "$dsc" "/blog/$slug" 0 <<EOF
<article class="article">
<p class="crumb"><a href="/blog/">نوشته‌ها</a> / $tag</p>
<h1>$ttl</h1>
$body
<a class="back" href="/blog/">← بازگشت به نوشته‌ها</a>
</article>
EOF
}

# یک ردیف وضعیت برای صفحه امنیت: برچسب، وضعیت(1/0)، متن وقتی فعال، متن وقتی غیرفعال
feat() {
  local cls="ok" mk="✔" text="$3"
  if [ "$2" != 1 ]; then cls="no"; mk="—"; text="${4:-}"; fi
  printf '<li class="%s"><span class="mk" aria-hidden="true">%s</span><div><strong>%s</strong><small>%s</small></div></li>\n' "$cls" "$mk" "$1" "$text"
}

write_security() {
  layout security.html "امنیت و پروتکل‌ها | $DOMAIN" "وضعیت واقعی TLS، HTTP/2، HTTP/3 و گواهی این سایت." "/security" 0 <<EOF
<section class="page">
<h1>امنیت و پروتکل‌های این سایت</h1>
<p>این فهرست هنگام نصب و بر اساس تنظیمات واقعی سرور ساخته شده است. اگر قابلیتی روی سرور فعال نباشد، همان‌جا علامت خط می‌خورد و چیزی بیشتر از واقعیت ادعا نمی‌شود.</p>
<ul class="checks">
$(feat "TLS 1.3" 1 "فقط نسخه‌ی ۱٫۳ پذیرفته می‌شود و نسخه‌های قدیمی‌تر غیرفعال‌اند." "")
$(feat "HTTP/2" 1 "چند درخواست هم‌زمان روی یک اتصال، با ALPN برابر h2." "")
$(feat "X25519MLKEM768" "$PQ_OK" "تبادل کلید ترکیبی که در برابر حمله‌های کوانتومی آینده مقاوم است." "نیازمند OpenSSL نسخه‌ی ۳٫۵ یا بالاتر روی سرور.")
$(feat "HTTP/3 (QUIC)" "$H3_OK" "پروتکل سوم HTTP روی UDP، با اعلام از طریق هدر Alt-Svc." "نیازمند nginx نسخه‌ی ۱٫۲۵ به بالا که با ماژول http_v3 ساخته شده باشد.")
$(feat "گواهی معتبر" 1 "گواهی صادرشده توسط $CA_NAME با تمدید خودکار." "")
</ul>
<p>برای جزئیات بیشتر، یادداشت <a href="/blog/post-quantum">کلیدهای ترکیبی پساکوانتومی</a> و یادداشت <a href="/blog/http3">HTTP/3 و QUIC</a> را بخوانید.</p>
</section>
EOF
}

write_site() {
  info "ساخت سایت در $SITE_ROOT"
  mkdir -p "$SITE_ROOT"/{fonts,assets,blog,.well-known}

  local font_url="https://cdn.jsdelivr.net/gh/rastikerdar/vazirmatn@v33.003/fonts/webfonts/Vazirmatn[wght].woff2"
  local font="$SITE_ROOT/fonts/vazirmatn.woff2"
  if ! curl -fsSgL --max-time 30 -o "$font" "$font_url" || [ "$(stat -c%s "$font" 2>/dev/null || echo 0)" -lt 10000 ]; then
    rm -f "$font"; warn "دانلود فونت ناموفق بود؛ از فونت سیستم استفاده می‌شود."
  fi

  cat > "$SITE_ROOT/assets/style.css" <<'CSS'
@font-face{font-family:"Vazirmatn";src:url(/fonts/vazirmatn.woff2) format("woff2");font-weight:100 900;font-display:swap}
:root{
  --bg:#faf8f3;--surface:#ffffff;--ink:#1b2622;--muted:#5d6a64;--line:#e6e2d6;
  --brand:#1f4d45;--brand-ink:#ffffff;--accent:#c8553d;--soft:#eef4f1;--ok:#1e9a58;
  --radius:16px;--shadow:0 1px 2px rgba(20,30,27,.06),0 8px 24px rgba(20,30,27,.06);
  color-scheme:light;
}
@media (prefers-color-scheme:dark){
  :root{--bg:#0e1614;--surface:#14201d;--ink:#e7eee9;--muted:#9bb0a7;--line:#23332e;--brand:#7fc7b5;--brand-ink:#0e1614;--accent:#f0866c;--soft:#172823;--ok:#4fd392;--shadow:0 1px 2px rgba(0,0,0,.4),0 8px 24px rgba(0,0,0,.35);color-scheme:dark}
}
*{box-sizing:border-box;margin:0;padding:0}
html{-webkit-text-size-adjust:100%}
body{font-family:"Vazirmatn",Tahoma,sans-serif;background:var(--bg);color:var(--ink);line-height:1.9;min-height:100vh;display:flex;flex-direction:column;-webkit-font-smoothing:antialiased}
a{color:inherit;text-decoration:none;transition:color .2s}
a:hover{color:var(--accent)}
:focus-visible{outline:2px solid var(--accent);outline-offset:3px;border-radius:4px}
.wrap{width:100%;max-width:1040px;margin-inline:auto;padding-inline:24px}
main{flex:1;padding-bottom:72px}
.skip{position:absolute;inset-inline-start:-999px;top:0}
.skip:focus{inset-inline-start:16px;top:12px;background:var(--surface);padding:8px 12px;border-radius:8px;z-index:9}
.site-header{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--bg) 85%,transparent);backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
.bar{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;padding-block:16px}
.brand{font-weight:800;font-size:1.1rem;direction:ltr;display:inline-flex;align-items:center;gap:10px}
.brand::before{content:"";width:12px;height:12px;border-radius:4px;background:var(--accent)}
nav{display:flex;gap:22px;font-size:.95rem;color:var(--muted)}
.hero{padding-block:72px 48px}
.eyebrow{display:inline-block;font-size:.85rem;color:var(--brand);background:var(--soft);border:1px solid var(--line);padding:2px 14px;border-radius:999px;margin-bottom:18px}
.hero h1{font-size:clamp(1.9rem,5vw,3.2rem);font-weight:800;line-height:1.5;max-width:20ch}
.lead{margin-top:14px;color:var(--muted);max-width:56ch;font-size:1.05rem}
.status{display:inline-flex;gap:10px;align-items:center;margin-top:24px;font-size:.9rem;color:var(--muted);direction:ltr}
.dot{width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 0 4px color-mix(in srgb,var(--ok) 22%,transparent)}
.cta{display:flex;gap:12px;flex-wrap:wrap;margin-top:28px}
.btn{display:inline-flex;align-items:center;padding:11px 22px;border-radius:999px;background:var(--brand);color:var(--brand-ink);font-weight:700;font-size:.95rem}
.btn:hover{color:var(--brand-ink);filter:brightness(1.08)}
.btn.ghost{background:transparent;color:var(--ink);border:1px solid var(--line)}
.btn.ghost:hover{color:var(--accent);border-color:var(--accent)}
.section{padding-block:40px}
.sec-head{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:20px;gap:12px}
h2{font-size:1.3rem;font-weight:800}
.sec-head a{color:var(--muted);font-size:.95rem}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:18px}
.card{display:flex;flex-direction:column;align-items:flex-start;gap:8px;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);padding:24px;box-shadow:var(--shadow);transition:transform .2s,border-color .2s}
.card:hover{transform:translateY(-3px);border-color:var(--brand);color:inherit}
.card h3{font-size:1.1rem;font-weight:700;line-height:1.7}
.card p{color:var(--muted);font-size:.95rem;flex:1}
.card .more{color:var(--brand);font-size:.9rem;font-weight:700}
.card:hover .more{color:var(--accent)}
.tag{font-size:.78rem;color:var(--accent);background:color-mix(in srgb,var(--accent) 10%,transparent);border-radius:999px;padding:0 10px;line-height:1.8}
.blog-head{padding-block:56px 8px}
.blog-head h1{font-size:clamp(1.8rem,4.5vw,2.6rem);font-weight:800}
.checks{list-style:none;display:grid;gap:12px;margin-block:24px}
.checks li{display:flex;gap:16px;align-items:flex-start;background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);padding:18px 20px}
.mk{flex:none;width:30px;height:30px;border-radius:50%;display:grid;place-items:center;font-weight:800;background:color-mix(in srgb,var(--ok) 16%,transparent);color:var(--ok)}
.checks li.no .mk{background:var(--soft);color:var(--muted)}
.checks strong{display:block;font-size:1rem}
.checks small{color:var(--muted);font-size:.9rem}
.article,.page{max-width:68ch;margin-inline:auto;padding-block:48px 24px}
.crumb{font-size:.9rem;color:var(--muted);margin-bottom:14px}
.article h1,.page h1{font-size:clamp(1.6rem,4.5vw,2.3rem);line-height:1.6;font-weight:800;margin-bottom:22px}
.article p,.page p{margin-bottom:18px;font-size:1.02rem}
.article a,.page a{color:var(--brand);text-decoration:underline;text-underline-offset:4px}
code{font-family:ui-monospace,Consolas,monospace;font-size:.88em;background:var(--soft);padding:1px 6px;border-radius:6px;direction:ltr;unicode-bidi:isolate}
.back{display:inline-block;margin-top:32px;color:var(--brand);font-weight:700}
.site-footer{border-top:1px solid var(--line);color:var(--muted);font-size:.88rem}
.foot{display:flex;justify-content:space-between;flex-wrap:wrap;gap:10px;padding-block:24px}
@media (max-width:600px){nav{gap:14px;font-size:.9rem}.hero{padding-block:48px 32px}}
@media (prefers-reduced-motion:reduce){*{transition:none!important}.card:hover{transform:none}}
CSS

  cat > "$SITE_ROOT/favicon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#1f4d45"/><path d="M32 13l17 6v13c0 10-7 17-17 21-10-4-17-11-17-21V19z" fill="none" stroke="#f0866c" stroke-width="4" stroke-linejoin="round"/><path d="M24 33l6 6 10-11" fill="none" stroke="#faf8f3" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/></svg>
SVG

  # ---- صفحه‌ها ----
  layout index.html "$DOMAIN | یادداشت‌های فنی درباره وب و سرور" "یادداشت‌های فنی درباره nginx، TLS، HTTP/3 و نگهداری سرور لینوکس." "/" 0 <<EOF
<section class="hero">
  <span class="eyebrow">یادداشت‌های فنی</span>
  <h1>سرور را درست راه بیندازید و سایت را سریع و امن نگه دارید</h1>
  <p class="lead">یادداشت‌های کوتاه و کاربردی درباره nginx، رمزنگاری TLS، پروتکل‌های جدید شبکه و ابزارهایی که هر روز با آن‌ها کار می‌کنیم.</p>
  <span class="status"><span class="dot"></span>TLS 1.3 · HTTP/2</span>
  <div class="cta"><a class="btn" href="/blog/">همه نوشته‌ها</a><a class="btn ghost" href="/security">امنیت این سایت</a></div>
</section>
<section class="section">
  <div class="sec-head"><h2>آخرین نوشته‌ها</h2><a href="/blog/">همه نوشته‌ها</a></div>
  <div class="cards">
$(cards 3)
  </div>
</section>
EOF

  layout blog/index.html "نوشته‌ها | $DOMAIN" "همه‌ی یادداشت‌های فنی درباره سرور، امنیت و شبکه." "/blog/" 0 <<EOF
<section class="blog-head"><h1>نوشته‌ها</h1><p class="lead">یادداشت‌های فنی درباره سرور، امنیت و شبکه.</p></section>
<section class="section"><div class="cards">
$(cards 0)
</div></section>
EOF

  article tls-13 <<'EOF'
<p>در TLS 1.2 برای برقراری یک اتصال امن معمولاً دو رفت‌وبرگشت کامل بین کلاینت و سرور لازم بود. در TLS 1.3 کلاینت از همان پیام اول کلیدهای خودش را می‌فرستد، پس در بیشتر موارد یک رفت‌وبرگشت کافی است. روی شبکه‌های موبایل با تأخیر بالا، این اختلاف کاملاً حس می‌شود.</p>
<p>جدا از سرعت، TLS 1.3 الگوریتم‌های رمزنگاری قدیمی و ناامن را حذف کرده و تبادل کلید به‌صورت پیش‌فرض از «محرمانگی پیشرو» (Forward Secrecy) استفاده می‌کند. یعنی حتی اگر کلید خصوصی سرور در آینده لو برود، ترافیک گذشته به‌سادگی قابل رمزگشایی نیست.</p>
<p>در nginx با دستور <code>ssl_protocols TLSv1.3;</code> فقط همین نسخه پذیرفته می‌شود. اگر کلاینت‌های قدیمی دارید، می‌توانید TLSv1.2 را هم اضافه کنید، اما برای سایت‌های جدید معمولاً لازم نیست.</p>
EOF

  article post-quantum <<'EOF'
<p>کامپیوترهای کوانتومی در آینده می‌توانند الگوریتم‌های کلید عمومی رایج، از جمله ECDH، را بشکنند. تهدید جدی‌تری هم امروز وجود دارد: کسی ترافیک رمزشده را ذخیره می‌کند و منتظر می‌ماند تا در آینده بتواند آن را رمزگشایی کند. به این روش «ذخیره کن، بعداً رمزگشایی کن» می‌گویند.</p>
<p>X25519MLKEM768 یک تبادل کلید ترکیبی است. بخشی از آن X25519 کلاسیک است و بخش دیگر ML-KEM، الگوریتمی که NIST در سال ۲۰۲۴ به‌عنوان استاندارد FIPS 203 منتشر کرد و در برابر کوانتوم مقاوم است. اگر یکی از این دو در آینده شکسته شود، دیگری همچنان از امنیت اتصال محافظت می‌کند.</p>
<p>برای فعال‌سازی به OpenSSL نسخه ۳٫۵ یا بالاتر نیاز است و در nginx با دستور <code>ssl_ecdh_curve X25519MLKEM768:X25519:prime256v1;</code> گروه‌های تبادل کلید مشخص می‌شوند. اسکریپت نصب به‌صورت خودکار بررسی می‌کند که سرور از آن پشتیبانی کند یا نه.</p>
EOF

  article http3 <<'EOF'
<p>HTTP/3 روی QUIC اجرا می‌شود و QUIC خودش روی UDP است. ادغام TLS 1.3 در QUIC باعث می‌شود اتصال و امنیت در یک مرحله انجام شوند. همچنین اگر یک بسته گم شود، فقط جریانی که به آن بسته وابسته است متوقف می‌شود و بقیه درخواست‌ها منتظر نمی‌مانند؛ این همان مشکلی است که HTTP/2 روی TCP با آن روبه‌رو بود.</p>
<p>سرور معمولاً ابتدا روی TCP و با HTTP/2 پاسخ می‌دهد و در هدر <code>Alt-Svc</code> اعلام می‌کند که HTTP/3 هم در دسترس است. مرورگر در درخواست‌های بعدی ممکن است به آن منتقل شود. برای همین باز بودن UDP پورت ۴۴۳ در فایروال، و در صورت استفاده از سرویس ابری، در گروه امنیتی آن هم لازم است.</p>
EOF

  article nginx-logs <<'EOF'
<p>لاگ پیش‌فرض nginx معمولاً در <code>/var/log/nginx/access.log</code> و خطاها در <code>/var/log/nginx/error.log</code> نوشته می‌شود. برای دیدن زنده‌ی خطاها از <code>tail -f /var/log/nginx/error.log</code> استفاده کنید.</p>
<p>برای پیدا کردن پرتکرارترین آی‌پی‌ها: <code>awk '{print $1}' access.log | sort | uniq -c | sort -rn | head</code>. برای دیدن پاسخ‌های خطای ۵۰۰ به بعد: <code>awk '$9 ~ /^5/' access.log | tail</code>. در قالب پیش‌فرض، ستون اول آی‌پی و ستون نهم کد وضعیت HTTP است.</p>
EOF

  layout about.html "درباره | $DOMAIN" "این وبلاگ چیست و چرا نوشته می‌شود." "/about" 0 <<'EOF'
<section class="page"><h1>درباره این وبلاگ</h1>
<p>این وبلاگ محل ثبت تجربه‌هایی است که از کار با سرورهای لینوکس، nginx و شبکه به دست آمده‌اند. هدف این است که یادداشت‌ها کوتاه، دقیق و قابل اجرا باشند.</p>
<p>هر نوشته تلاش می‌کند بر پایه‌ی آزمایش واقعی و منابع معتبر باشد. اگر نکته‌ای اشتباه بود یا راه بهتری می‌شناسید، از طریق صفحه‌ی تماس خوشحال می‌شوم بشنوم.</p>
</section>
EOF

  layout contact.html "تماس | $DOMAIN" "راه‌های ارتباط با نویسنده" "/contact" 0 <<EOF
<section class="page"><h1>تماس</h1>
<p>برای پیشنهاد، اصلاح یا سؤال درباره‌ی نوشته‌ها ایمیل بزنید:</p>
<p><a href="mailto:hello@$DOMAIN">hello@$DOMAIN</a></p>
<p>گزارش مشکلات امنیتی را هم به همین نشانی بفرستید. جزئیات بیشتر در <a href="/.well-known/security.txt">security.txt</a> آمده است.</p>
</section>
EOF

  layout privacy.html "حریم خصوصی | $DOMAIN" "سیاست حریم خصوصی این سایت" "/privacy" 0 <<'EOF'
<section class="page"><h1>حریم خصوصی</h1>
<p>این سایت کوکی، ابزار ردیابی یا اسکریپت شخص ثالث ندارد.</p>
<p>سرور، مانند هر وب‌سروری، نشانی آی‌پی و زمان درخواست‌ها را در فایل‌های لاگ ثبت می‌کند. این داده‌ها فقط برای امنیت و عیب‌یابی نگهداری می‌شوند و به اشخاص ثالث داده نمی‌شوند.</p>
</section>
EOF

  layout 404.html "صفحه پیدا نشد | $DOMAIN" "صفحه‌ای با این نشانی پیدا نشد." "-" 1 <<'EOF'
<section class="page"><h1>صفحه پیدا نشد</h1><p>این نشانی وجود ندارد. <a href="/">بازگشت به خانه</a></p></section>
EOF

  layout 50x.html "خطای سرور | $DOMAIN" "خطای داخلی سرور." "-" 1 <<'EOF'
<section class="page"><h1>خطای سرور</h1><p>مشکلی پیش آمده است. لطفاً کمی بعد دوباره تلاش کنید. <a href="/">بازگشت به خانه</a></p></section>
EOF

  # ---- فایل‌های استاندارد ----
  local today rfc_now slug tag ttl dsc p
  today=$(date +%F); rfc_now=$(date -R)

  printf 'User-agent: *\nAllow: /\nSitemap: https://%s/sitemap.xml\n' "$DOMAIN" > "$SITE_ROOT/robots.txt"

  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    printf '  <url><loc>https://%s/</loc><lastmod>%s</lastmod></url>\n' "$DOMAIN" "$today"
    printf '  <url><loc>https://%s/blog/</loc><lastmod>%s</lastmod></url>\n' "$DOMAIN" "$today"
    for p in security about contact privacy; do
      printf '  <url><loc>https://%s/%s</loc><lastmod>%s</lastmod></url>\n' "$DOMAIN" "$p" "$today"
    done
    for p in "${POSTS[@]}"; do
      IFS='|' read -r slug _ _ _ <<< "$p"
      printf '  <url><loc>https://%s/blog/%s</loc><lastmod>%s</lastmod></url>\n' "$DOMAIN" "$slug" "$today"
    done
    echo '</urlset>'
  } > "$SITE_ROOT/sitemap.xml"

  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<rss version="2.0"><channel>'
    printf '<title>%s</title><link>https://%s/</link><description>یادداشت‌های فنی</description><language>fa</language><lastBuildDate>%s</lastBuildDate>\n' "$DOMAIN" "$DOMAIN" "$rfc_now"
    for p in "${POSTS[@]}"; do
      IFS='|' read -r slug tag ttl dsc <<< "$p"
      printf '<item><title>%s</title><link>https://%s/blog/%s</link><guid>https://%s/blog/%s</guid><pubDate>%s</pubDate><description>%s</description></item>\n' \
        "$ttl" "$DOMAIN" "$slug" "$DOMAIN" "$slug" "$rfc_now" "$dsc"
    done
    echo '</channel></rss>'
  } > "$SITE_ROOT/feed.xml"

  printf 'Contact: mailto:hello@%s\nExpires: %s\nPreferred-Languages: fa, en\nCanonical: https://%s/.well-known/security.txt\n' \
    "$DOMAIN" "$(date -u -d '+1 year' +%Y-%m-%dT%H:%M:%SZ)" "$DOMAIN" > "$SITE_ROOT/.well-known/security.txt"

  ok "فایل‌های سایت ساخته شد"
}

# ============================ توابع nginx ====================================
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

nginx_version() {
  nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

# بدون grep -q روی خروجی بزرگ، تا SIGPIPE با pipefail مشکل نسازد
nginx_has_http3() {
  local v ver
  v=$(nginx -V 2>&1 || true)
  ver=$(nginx_version)
  [[ "$v" == *--with-http_v3_module* ]] && [ -n "$ver" ] && ver_ge "$ver" 1.25.0
}

# nginx رسمی (nginx.org) که http_v3 دارد
install_nginx_official() {
  local os_id codename
  os_id=$(. /etc/os-release && echo "${ID:-ubuntu}")
  codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")
  info "نصب nginx از مخزن رسمی nginx.org (برای HTTP/3)"
  install -d -m 755 /usr/share/keyrings
  if ! curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor --yes -o "$NGINX_KEYRING"; then
    die "دریافت کلید مخزن nginx.org ناموفق بود."
  fi
  echo "deb [signed-by=$NGINX_KEYRING] http://nginx.org/packages/$os_id $codename nginx" > "$NGINX_REPO_LIST"
  apt-get update -qq
  # --force-confnew: فایل‌های پیکربندی nginx.org جایگزین نسخه‌ی Ubuntu شوند
  apt-get install -y -qq -o Dpkg::Options::=--force-confnew nginx || die "نصب nginx از مخزن رسمی ناموفق بود."
  ok "nginx نسخه‌ی $(nginx_version) نصب شد"
}

# اطمینان از اینکه nginx.conf فایل‌های sites-enabled را می‌خواند
ensure_sites_include() {
  local line='include /etc/nginx/sites-enabled/*;'
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
  if grep -qF "$line" "$NGINX_MAIN"; then
    return 0
  fi
  cp -f "$NGINX_MAIN" "$NGINX_MAIN.bak"
  awk -v inc="    $line" '{ print } !done && /^[ \t]*http[ \t]*[{]/ { print inc; done = 1 }' "$NGINX_MAIN.bak" > "$NGINX_MAIN"
  if ! grep -qF "$line" "$NGINX_MAIN"; then
    cp -f "$NGINX_MAIN.bak" "$NGINX_MAIN"
    die "بلاک http در $NGINX_MAIN پیدا نشد. فایل بکاپ: $NGINX_MAIN.bak"
  fi
  if ! nginx -t >/tmp/nginx-check.log 2>&1; then
    cp -f "$NGINX_MAIN.bak" "$NGINX_MAIN"
    cat /tmp/nginx-check.log >&2
    die "افزودن include باعث خطای nginx شد و تغییرات برگشت داده شد."
  fi
  ok "include مربوط به sites-enabled به nginx.conf اضافه شد"
}

HTTP_ONLY_CONF() {
  local l80_v6=""
  if [ "$HAS_V6" -eq 1 ]; then l80_v6="listen [::]:80 default_server;"; fi
  cat > "$CONF" <<EOF
server {
    listen 80 default_server;
    $l80_v6
    server_name _;
    location ^~ /.well-known/acme-challenge/ { root $ACME_ROOT; default_type text/plain; }
    location / { return 301 https://$DOMAIN\$request_uri; }
}
EOF
}

# $1 = PQ (0/1)   $2 = HTTP/3 (0/1)
write_nginx_conf() {
  local pq="$1" h3="$2" tls_l4 tls_l6="" l80_v6="" h3_l4="" h3_l6="" h3_dir="" alt="" pq_line=""

  if [ -n "$LOCAL_PORT" ]; then
    tls_l4="listen 127.0.0.1:$LOCAL_PORT ssl$H2L default_server;"
  else
    tls_l4="listen 443 ssl$H2L default_server;"
    if [ "$HAS_V6" -eq 1 ]; then tls_l6="listen [::]:443 ssl$H2L default_server;"; fi
  fi
  if [ "$HAS_V6" -eq 1 ]; then l80_v6="listen [::]:80 default_server;"; fi
  if [ "$h3" -eq 1 ]; then
    h3_l4="listen 443 quic reuseport;"
    if [ "$HAS_V6" -eq 1 ]; then h3_l6="listen [::]:443 quic reuseport;"; fi
    h3_dir="http3 on;
    quic_retry on;"
    alt="add_header Alt-Svc 'h3=\":443\"; ma=86400' always;"
  fi
  if [ "$pq" -eq 1 ]; then pq_line="ssl_ecdh_curve X25519MLKEM768:X25519:prime256v1;"; fi

  cat > "$CONF" <<EOF
server {
    listen 80 default_server;
    $l80_v6
    server_name _;
    location ^~ /.well-known/acme-challenge/ { root $ACME_ROOT; default_type text/plain; }
    location / { return 301 https://$DOMAIN\$request_uri; }
}

server {
    $tls_l4
    $tls_l6
    $h3_l4
    $h3_l6
    $H2D
    $h3_dir
    server_name $DOMAIN;

    ssl_certificate     $LIVE/fullchain.pem;
    ssl_certificate_key $LIVE/privkey.pem;
    ssl_protocols TLSv1.3;
    $pq_line
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self'; img-src 'self' data:; style-src 'self'; font-src 'self'; script-src 'none'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'" always;
    $alt

    gzip on;
    gzip_vary on;
    gzip_min_length 512;
    gzip_types text/css text/plain application/xml application/rss+xml image/svg+xml;

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
}

# ============================ بررسی‌های اولیه ================================
[ "${EUID:-$(id -u)}" -eq 0 ] || die "با دسترسی root اجرا کنید (sudo)."
command -v apt-get >/dev/null 2>&1 || die "فقط Debian/Ubuntu پشتیبانی می‌شود."

DOMAIN=""; EMAIL=""; LOCAL_PORT=""; CA="letsencrypt"; EAB_KID=""; EAB_HMAC=""
STAGING=0; FORCE=0; OVERWRITE=0; NO_FW=0; NO_DRY=0; NO_NGINX_REPO=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--domain) [ $# -ge 2 ] || die "مقدار $1 وارد نشده."; DOMAIN="$2"; shift 2 ;;
    -e|--email)  [ $# -ge 2 ] || die "مقدار $1 وارد نشده."; EMAIL="$2"; shift 2 ;;
    -l|--local)  [ $# -ge 2 ] || die "مقدار $1 وارد نشده."; LOCAL_PORT="$2"; shift 2 ;;
    --ca)        [ $# -ge 2 ] || die "مقدار $1 وارد نشده."; CA="$2"; shift 2 ;;
    --eab-kid)   [ $# -ge 2 ] || die "مقدار $1 وارد نشده."; EAB_KID="$2"; shift 2 ;;
    --eab-hmac)  [ $# -ge 2 ] || die "مقدار $1 وارد نشده."; EAB_HMAC="$2"; shift 2 ;;
    --no-nginx-repo) NO_NGINX_REPO=1; shift ;;
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

case "$CA" in
  letsencrypt)
    ACME_URL=""
    CA_NAME="Let's Encrypt"; CA_MARK="letsencrypt.org" ;;
  google)
    [ -n "$EAB_KID" ] && [ -n "$EAB_HMAC" ] \
      || die "برای --ca google باید --eab-kid و --eab-hmac را بدهید (از Google Cloud Certificate Manager، بخش Public CA)."
    if [ "$STAGING" -eq 1 ]; then ACME_URL="https://dv.acme-v02.test-api.pki.goog/directory"
    else ACME_URL="https://dv.acme-v02.api.pki.goog/directory"; fi
    CA_NAME="Google Trust Services"; CA_MARK="pki.goog" ;;
  *) die "مقدار --ca باید letsencrypt یا google باشد." ;;
esac

SITE_ROOT="/var/www/$DOMAIN"
ACME_ROOT="/var/www/letsencrypt"
NGINX_MAIN="/etc/nginx/nginx.conf"
NGINX_KEYRING="/usr/share/keyrings/nginx-archive-keyring.gpg"
NGINX_REPO_LIST="/etc/apt/sources.list.d/nginx.list"
CONF="/etc/nginx/sites-available/$DOMAIN"
LIVE="/etc/letsencrypt/live/$DOMAIN"
RENEW_CONF="/etc/letsencrypt/renewal/$DOMAIN.conf"
TLS_PORT="${LOCAL_PORT:-443}"

info "شروع نصب روی دامنه: $DOMAIN"
if [ -n "$LOCAL_PORT" ]; then info "حالت لوکال: nginx روی 127.0.0.1:$LOCAL_PORT"; else info "حالت عمومی: nginx روی 80 و 443"; fi

# ============================ نصب پیش‌نیازها =================================
export DEBIAN_FRONTEND=noninteractive
info "نصب پیش‌نیازها"
apt-get update -qq
apt-get install -y -qq nginx certbot curl dnsutils openssl ca-certificates iproute2 gnupg

if [ -z "$LOCAL_PORT" ] && ! nginx_has_http3 && [ "$NO_NGINX_REPO" -eq 0 ]; then
  install_nginx_official
fi

H3_AVAIL=0
if [ -z "$LOCAL_PORT" ]; then
  if nginx_has_http3; then
    H3_AVAIL=1
  else
    warn "این nginx ماژول HTTP/3 ندارد؛ HTTP/3 غیرفعال می‌ماند."
  fi
fi

NGINX_VER=$(nginx_version)
if ver_ge "$NGINX_VER" 1.25.1; then H2L=""; H2D="http2 on;"; else H2L=" http2"; H2D=""; fi

HAS_V6=0
if [ -f /proc/net/if_inet6 ] && [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)" = "0" ]; then HAS_V6=1; fi

port_owner() { ss -H -ltnp "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n1 || true; }
for p in 80 "$TLS_PORT"; do
  owner=$(port_owner "$p")
  if [ -n "$owner" ] && [ "$owner" != "nginx" ]; then
    die "پورت $p توسط «$owner» اشغال است. آن را آزاد کنید یا (برای TLS) از --local 8443 استفاده کنید."
  fi
done

# پاکسازی: سایت پیش‌فرض و سایت پیش‌فرض nginx.org که با سایت ما تداخل می‌کنند
rm -f /etc/nginx/sites-enabled/default
if [ -f /etc/nginx/conf.d/default.conf ] && grep -q 'server_name[[:space:]]*localhost' /etc/nginx/conf.d/default.conf; then
  rm -f /etc/nginx/conf.d/default.conf
fi
ensure_sites_include
printf 'server_tokens off;\n' > /etc/nginx/conf.d/00-selfsteal.conf

# ============================ فایروال ========================================
if [ "$NO_FW" -eq 0 ]; then
  TCP_PORTS=(80)
  if [ -z "$LOCAL_PORT" ]; then TCP_PORTS+=(443); fi
  UDP_PORTS=()
  if [ "$H3_AVAIL" -eq 1 ]; then UDP_PORTS+=(443); fi

  UFW_STATUS=$(ufw status 2>/dev/null || true)
  IPT_RULES=$(iptables -S INPUT 2>/dev/null || true)

  if command -v ufw >/dev/null 2>&1 && [[ "$UFW_STATUS" == *"Status: active"* ]]; then
    for p in "${TCP_PORTS[@]}"; do ufw allow "$p/tcp" >/dev/null; done
    for p in "${UDP_PORTS[@]}"; do ufw allow "$p/udp" >/dev/null; done
    ok "ufw: پورت‌ها باز شد"
  elif command -v iptables >/dev/null 2>&1 && [[ -n "$IPT_RULES" ]] && [[ "$IPT_RULES" != *"-P INPUT ACCEPT"* ]]; then
    for p in "${TCP_PORTS[@]}"; do
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
    done
    for p in "${UDP_PORTS[@]}"; do
      iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT
    done
    ok "iptables: پورت‌ها باز شد"
  fi
fi

# ============================ DNS ============================================
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
    proceed_or_abort "دامنه رکورد AAAA ($DOMAIN_IP6) دارد که به این سرور اشاره نمی‌کند؛ حذفش کنید."
  fi
fi

# ============================ سایت ===========================================
mkdir -p "$ACME_ROOT"
if [ ! -f "$SITE_ROOT/index.html" ] || [ "$OVERWRITE" -eq 1 ]; then
  write_site
else
  warn "سایت از قبل وجود دارد؛ محتوای آن دست نخورد."
fi

# ============================ گواهی SSL ======================================
rm -f /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh /etc/letsencrypt/renewal-hooks/post/start-nginx.sh

NEED_CERT=1; FORCE_RENEW=0
if [ -s "$LIVE/fullchain.pem" ] && openssl x509 -checkend 2592000 -noout -in "$LIVE/fullchain.pem" >/dev/null 2>&1; then
  if grep -qs '^authenticator = webroot' "$RENEW_CONF" && grep -qs "$CA_MARK" "$RENEW_CONF"; then
    NEED_CERT=0; ok "گواهی معتبر از قبل وجود دارد"
  else
    FORCE_RENEW=1; warn "گواهی قبلی با تنظیمات دیگری صادر شده؛ دوباره صادر می‌شود."
  fi
fi

if [ "$NEED_CERT" -eq 1 ]; then
  info "دریافت گواهی SSL از $CA_NAME"
  HTTP_ONLY_CONF
  ln -sf "$CONF" "/etc/nginx/sites-enabled/$DOMAIN"
  nginx -t || die "کانفیگ اولیه nginx خطا دارد."
  systemctl enable --now nginx >/dev/null 2>&1
  systemctl reload nginx

  CB=(certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --non-interactive --agree-tos --keep-until-expiring)
  if [ -n "$EMAIL" ]; then CB+=(--email "$EMAIL"); else CB+=(--register-unsafely-without-email); fi
  if [ "$CA" = google ]; then
    CB+=(--server "$ACME_URL" --eab-kid "$EAB_KID" --eab-hmac-key "$EAB_HMAC")
  elif [ "$STAGING" -eq 1 ]; then
    CB+=(--staging); warn "گواهی آزمایشی است."
  fi
  if [ "$FORCE_RENEW" -eq 1 ]; then CB+=(--force-renewal); fi

  CERT_OK=0
  for i in 1 2 3; do
    if "${CB[@]}"; then CERT_OK=1; break; fi
    warn "تلاش $i ناموفق بود؛ ۸ ثانیه دیگر دوباره تلاش می‌شود..."; sleep 8
  done
  if [ "$CERT_OK" -ne 1 ] || [ ! -s "$LIVE/fullchain.pem" ]; then
    die "دریافت SSL ناموفق بود. رکورد A، باز بودن پورت ۸۰ و تنظیمات EAB (در صورت استفاده از Google) را چک کنید."
  fi
fi

# ============================ کانفیگ نهایی nginx =============================
info "نوشتن کانفیگ نهایی nginx"
PQ_ON=1; H3_ON=$H3_AVAIL
ln -sf "$CONF" "/etc/nginx/sites-enabled/$DOMAIN"
until write_nginx_conf "$PQ_ON" "$H3_ON" && nginx -t >/tmp/nginx-test.log 2>&1; do
  if [ "$PQ_ON" -eq 1 ]; then
    warn "کانفیگ با X25519MLKEM768 پذیرفته نشد (OpenSSL این سرور از آن پشتیبانی نمی‌کند)؛ بدون آن ادامه می‌دهیم."
    PQ_ON=0
  elif [ "$H3_ON" -eq 1 ]; then
    warn "کانفیگ با HTTP/3 پذیرفته نشد؛ بدون آن ادامه می‌دهیم."
    H3_ON=0
  else
    cat /tmp/nginx-test.log >&2
    die "کانفیگ nginx خطا دارد."
  fi
done
rm -f /tmp/nginx-test.log /tmp/nginx-check.log
PQ_OK=$PQ_ON; H3_OK=$H3_ON

systemctl enable --now nginx >/dev/null 2>&1
systemctl reload nginx
ok "nginx آماده است"

write_security
chown -R www-data:www-data "$SITE_ROOT" "$ACME_ROOT"
find "$SITE_ROOT" -type d -exec chmod 755 {} +
find "$SITE_ROOT" -type f -exec chmod 644 {} +

# ============================ تمدید خودکار ===================================
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
if nginx -t >/dev/null 2>&1; then systemctl reload nginx; fi
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
systemctl enable --now certbot.timer >/dev/null 2>&1 || true

if [ "$NO_DRY" -eq 0 ] && [ "$STAGING" -eq 0 ]; then
  info "تست تمدید خودکار (dry-run)"
  certbot renew --cert-name "$DOMAIN" --dry-run >/dev/null 2>&1 || warn "تست تمدید ناموفق بود؛ لاگ: /var/log/letsencrypt/letsencrypt.log"
fi

# ============================ خلاصه =========================================
SHORT_ID=$(openssl rand -hex 8)
pq_txt="✘ (OpenSSL ۳٫۵+ لازم است)"; if [ "$PQ_OK" -eq 1 ]; then pq_txt="✔"; fi
h3_txt="✘ (nginx با http_v3 لازم است)"; if [ "$H3_OK" -eq 1 ]; then h3_txt="✔"; fi

cat <<EOF

${G}==============================================================${N}
 ✅ نصب تمام شد  →  https://$DOMAIN
${G}==============================================================${N}
 nginx              : $(nginx_version)
 TLS 1.3            : ✔
 HTTP/2             : ✔
 X25519MLKEM768     : $pq_txt
 HTTP/3 (QUIC)      : $h3_txt
 گواهی              : $CA_NAME
 صفحه وضعیت         : https://$DOMAIN/security

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

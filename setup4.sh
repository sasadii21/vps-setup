#!/bin/bash
# =========================================================
# اسکریپت نصب سایت + SSL (نسخه پیشرفته)
# استفاده: sudo bash install-site.sh example.com
# =========================================================

if [ "$EUID" -ne 0 ]; then
  echo "لطفاً با دسترسی روت اجرا کنید (sudo)."
  exit 1
fi

if [ -n "$1" ]; then
  DOMAIN="$1"
else
  read -p "لطفا نام دامنه خود را وارد کنید (example.com): " DOMAIN
fi
if [ -z "$DOMAIN" ]; then
  echo "دامین وارد نشد."
  exit 1
fi

echo "--- شروع نصب سایت روی دامین: $DOMAIN ---"

# 0. فایروال
ufw allow 80/tcp  >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1
iptables -C INPUT -p tcp --dport 80  -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80  -j ACCEPT
iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j ACCEPT

# 1. پیش‌نیازها
apt update -y
apt install nginx certbot curl dnsutils psmisc -y

# 2. بررسی DNS
SERVER_IP=$(curl -s -4 https://api.ipify.org)
DOMAIN_IP=$(dig +short A "$DOMAIN" @1.1.1.1 | tail -n1)
echo "IP سرور: $SERVER_IP | IP دامنه: $DOMAIN_IP"
if [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
  echo "⚠️  رکورد A دامنه به این سرور اشاره نمی‌کند. اگر از کلودفلر استفاده می‌کنید Proxy را خاموش کنید (DNS Only)."
  echo "⚠️  پورت 80 و 443 را در فایروال ابری سرویس‌دهنده هم باز کنید."
  echo "ادامه تا ۱۰ ثانیه دیگر... (توقف: Ctrl+C)"
  sleep 10
fi
DOMAIN_IPV6=$(dig +short AAAA "$DOMAIN" @1.1.1.1 | tail -n1)
if [ -n "$DOMAIN_IPV6" ]; then
  echo "⚠️  دامنه رکورد AAAA دارد ($DOMAIN_IPV6). اگر متعلق به این سرور نیست حذفش کنید."
fi

# 3. ساخت سایت
echo "--- ساخت صفحه سایت ---"
rm -rf /var/www/html/*
mkdir -p /var/www/html/fonts

# فونت را روی خود سرور نگه می‌داریم تا به گوگل وابسته نباشد (اگر دانلود نشد، از فونت سیستم استفاده می‌شود)
curl -sfgL --max-time 30 -o /var/www/html/fonts/vazirmatn.woff2 \
  "https://cdn.jsdelivr.net/gh/rastikerdar/vazirmatn@v33.003/fonts/webfonts/Vazirmatn[wght].woff2" \
  || rm -f /var/www/html/fonts/vazirmatn.woff2

cat > /var/www/html/index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__DOMAIN__ | به‌زودی</title>
<meta name="description" content="سایت __DOMAIN__ در حال آماده‌سازی است.">
<meta name="theme-color" content="#0d2438">
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🟢</text></svg>">
<style>
@font-face{font-family:"Vazirmatn";src:url(/fonts/vazirmatn.woff2) format("woff2");font-weight:100 900;font-display:swap}
:root{
  --paper:#f2f6f5; --ink:#0d2438; --muted:#4d6577; --line:#c9d7d9;
  --panel:#ffffff; --firouzeh:#0fa89a; --lapis:#1b3a8a;
}
:root[data-theme="dark"]{
  --paper:#0a1c2b; --ink:#e8f1f2; --muted:#93aab8; --line:#21415a;
  --panel:#0f2840; --firouzeh:#33d1c0; --lapis:#7f9cf0;
}
@media (prefers-color-scheme:dark){
  :root:not([data-theme="light"]){
    --paper:#0a1c2b; --ink:#e8f1f2; --muted:#93aab8; --line:#21415a;
    --panel:#0f2840; --firouzeh:#33d1c0; --lapis:#7f9cf0;
  }
}
*{box-sizing:border-box;margin:0;padding:0}
html{height:100%}
body{
  min-height:100%;
  font-family:"Vazirmatn",Tahoma,sans-serif;
  background:var(--paper);color:var(--ink);
  display:flex;flex-direction:column;
  padding:max(20px,env(safe-area-inset-top)) 24px max(20px,env(safe-area-inset-bottom));
  background-image:
    linear-gradient(var(--line) 1px,transparent 1px),
    linear-gradient(90deg,var(--line) 1px,transparent 1px);
  background-size:56px 56px;
  background-position:center top;
}
header,main,footer{width:100%;max-width:960px;margin-inline:auto}
header{display:flex;justify-content:space-between;align-items:center;padding-block:8px}
.brand{font-weight:800;font-size:1.05rem;direction:ltr}
button.theme{
  font:inherit;font-size:.9rem;color:var(--ink);background:var(--panel);
  border:1px solid var(--line);border-radius:999px;padding:8px 16px;cursor:pointer;
}
button.theme:hover{border-color:var(--firouzeh)}
:focus-visible{outline:3px solid var(--lapis);outline-offset:3px}

main{flex:1;display:flex;flex-direction:column;justify-content:center;padding-block:48px}
h1{
  font-size:clamp(2.6rem,9vw,6.2rem);
  font-weight:900;line-height:1.15;letter-spacing:-.01em;
  max-width:14ch;
}
h1 .l1,h1 .l2{display:block;animation:rise .9s cubic-bezier(.2,.7,.2,1) both}
h1 .l2{color:var(--firouzeh);animation-delay:.18s}
@keyframes rise{from{opacity:0;transform:translateY(28px)}to{opacity:1;transform:none}}
.lead{margin-top:24px;max-width:46ch;line-height:2;color:var(--muted);font-size:1.05rem}

.status{
  margin-top:48px;background:var(--panel);border:1px solid var(--line);
  border-radius:14px;max-width:560px;
}
.status div{display:flex;justify-content:space-between;align-items:center;gap:16px;padding:16px 20px}
.status div+div{border-top:1px solid var(--line)}
.status dt{color:var(--muted);font-size:.95rem}
.status dd{font-weight:600;display:flex;align-items:center;gap:10px;font-size:.95rem}
.dot{width:10px;height:10px;border-radius:50%;background:var(--firouzeh);flex:none}
.dot.live{animation:pulse 2s ease-out infinite}
.dot.wait{background:#e0a422}
@keyframes pulse{0%{box-shadow:0 0 0 0 color-mix(in srgb,var(--firouzeh) 60%,transparent)}100%{box-shadow:0 0 0 12px transparent}}

footer{display:flex;flex-wrap:wrap;justify-content:space-between;gap:8px;color:var(--muted);font-size:.85rem;padding-top:16px;border-top:1px solid var(--line)}
@media (prefers-reduced-motion:reduce){*{animation:none!important}}
</style>
</head>
<body>
<header>
  <span class="brand">__DOMAIN__</span>
  <button class="theme" id="theme" type="button" aria-label="تغییر پوسته">پوسته تیره / روشن</button>
</header>

<main>
  <h1><span class="l1">اینجا به‌زودی</span><span class="l2">زنده می‌شود.</span></h1>
  <p class="lead">سایت <bdi dir="ltr">__DOMAIN__</bdi> در حال آماده‌سازی است. سرور و گواهی امنیتی آماده‌اند و محتوای اصلی به‌زودی جایگزین این صفحه می‌شود.</p>

  <dl class="status" aria-live="polite">
    <div><dt>اتصال امن (HTTPS)</dt><dd><span class="dot live"></span><span id="s-ssl">در حال بررسی</span></dd></div>
    <div><dt>پاسخ‌گویی سرور</dt><dd><span class="dot"></span><span id="s-ping">در حال بررسی</span></dd></div>
    <div><dt>محتوای سایت</dt><dd><span class="dot wait"></span>در حال آماده‌سازی</dd></div>
  </dl>
</main>

<footer>
  <span id="date"></span>
  <span id="clock" dir="ltr"></span>
</footer>

<script>
(function(){
  var root=document.documentElement, key="theme";
  try{var saved=localStorage.getItem(key); if(saved) root.setAttribute("data-theme",saved);}catch(e){}
  document.getElementById("theme").addEventListener("click",function(){
    var dark=root.getAttribute("data-theme")==="dark" ||
      (!root.getAttribute("data-theme") && matchMedia("(prefers-color-scheme:dark)").matches);
    var next=dark?"light":"dark";
    root.setAttribute("data-theme",next);
    try{localStorage.setItem(key,next);}catch(e){}
  });

  document.getElementById("s-ssl").textContent = location.protocol==="https:" ? "فعال و معتبر" : "غیرفعال";

  var t0=performance.now();
  fetch("/?ping="+Date.now(),{method:"HEAD",cache:"no-store"}).then(function(){
    document.getElementById("s-ping").textContent=Math.round(performance.now()-t0).toLocaleString("fa-IR")+" میلی‌ثانیه";
  }).catch(function(){document.getElementById("s-ping").textContent="نامشخص";});

  var dF=new Intl.DateTimeFormat("fa-IR-u-ca-persian",{weekday:"long",year:"numeric",month:"long",day:"numeric"});
  var tF=new Intl.DateTimeFormat("fa-IR",{hour:"2-digit",minute:"2-digit",second:"2-digit"});
  function tick(){var n=new Date();
    document.getElementById("date").textContent=dF.format(n);
    document.getElementById("clock").textContent=tF.format(n);}
  tick(); setInterval(tick,1000);
})();
</script>
</body>
</html>
HTML_EOF

sed -i "s/__DOMAIN__/$DOMAIN/g" /var/www/html/index.html

cat > /var/www/html/404.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>صفحه پیدا نشد</title>
<style>body{font-family:Tahoma,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;background:#f2f6f5;color:#0d2438;text-align:center}
a{color:#1b3a8a;font-weight:700}</style></head>
<body><div><h1>۴۰۴</h1><p>این صفحه وجود ندارد.</p><p><a href="/">بازگشت به صفحه اصلی</a></p></div></body></html>
HTML_EOF

chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

# 4. دریافت SSL
echo "--- دریافت SSL ---"
systemctl stop nginx
sleep 2
fuser -k 80/tcp >/dev/null 2>&1
sleep 2

CERTBOT_OK=0
for i in 1 2 3; do
  certbot certonly --standalone -d "$DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email \
    --preferred-challenges http
  if [ $? -eq 0 ]; then
    CERTBOT_OK=1
    break
  fi
  echo "تلاش $i ناموفق بود، تلاش مجدد در ۵ ثانیه..."
  sleep 5
done

if [ "$CERTBOT_OK" -ne 1 ]; then
  echo "❌ خطا در دریافت SSL. بررسی کنید:"
  echo "   ۱) رکورد A دقیقاً به IP این سرور باشد (بدون پروکسی کلودفلر)."
  echo "   ۲) پورت‌های 80 و 443 در فایروال ابری باز باشند."
  echo "   ۳) سرویس دیگری روی پورت 80 اجرا نباشد."
  echo "   ۴) صبر کنید DNS کامل پروپاگیت شود و دوباره اجرا کنید."
  systemctl start nginx
  exit 1
fi

# تمدید خودکار: nginx موقع تمدید (standalone) خاموش و دوباره روشن شود
mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
printf '#!/bin/sh\nsystemctl stop nginx\n'  > /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh
printf '#!/bin/sh\nsystemctl start nginx\n' > /etc/letsencrypt/renewal-hooks/post/start-nginx.sh
chmod +x /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh /etc/letsencrypt/renewal-hooks/post/start-nginx.sh

# 5. کانفیگ Nginx
echo "--- کانفیگ Nginx ---"
rm -f /etc/nginx/sites-enabled/*

cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    gzip on;
    gzip_types text/css application/javascript image/svg+xml;
    gzip_min_length 512;

    root /var/www/html;
    index index.html;
    error_page 404 /404.html;

    location /fonts/ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN

nginx -t
if [ $? -ne 0 ]; then
  echo "❌ خطا در کانفیگ nginx. خروجی nginx -t را بررسی کنید."
  exit 1
fi

systemctl enable nginx >/dev/null 2>&1
systemctl start nginx
systemctl restart nginx

sleep 1
ss -tlnp | grep -E ':80|:443'

echo "----------------------------------------------"
echo "✅ نصب با موفقیت تمام شد."
echo "🌐 سایت شما: https://$DOMAIN"
echo "----------------------------------------------"

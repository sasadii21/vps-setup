#!/bin/bash
# =========================================================
# اسکریپت نصب سایت + دریافت SSL (نسخه اصلاح‌شده)
# =========================================================

# بررسی دسترسی روت
if [ "$EUID" -ne 0 ]; then
  echo "لطفاً با دسترسی روت اجرا کنید (sudo)."
  exit 1
fi

# دریافت دامین
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

# 0. تنظیم فایروال
echo "--- در حال تنظیم فایروال ---"
ufw allow 80/tcp   >/dev/null 2>&1
ufw allow 443/tcp  >/dev/null 2>&1
iptables -I INPUT -p tcp --dport 80  -j ACCEPT
iptables -I INPUT -p tcp --dport 443 -j ACCEPT

# 1. نصب پیش‌نیازها (dnsutils برای dig و psmisc برای fuser اضافه شد)
echo "--- آپدیت و نصب پکیج‌ها ---"
apt update -y
apt install nginx certbot python3-certbot-nginx curl dnsutils psmisc -y

# 2. بررسی تطابق DNS دامنه با IP سرور (رایج‌ترین دلیل شکست SSL)
echo "--- بررسی DNS دامنه ---"
SERVER_IP=$(curl -s -4 https://api.ipify.org)
DOMAIN_IP=$(dig +short A "$DOMAIN" @1.1.1.1 | tail -n1)

echo "IP سرور شما: $SERVER_IP"
echo "IP ثبت‌شده برای دامنه: $DOMAIN_IP"

if [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
  echo "⚠️  هشدار: رکورد A دامنه به IP این سرور اشاره نمی‌کند (یا هنوز پروپاگیت نشده)."
  echo "⚠️  اگر از کلودفلر استفاده می‌کنید، ابری (Proxy) را خاموش کنید (DNS Only)."
  echo "⚠️  اگر فایروال ابری/کنسول سرویس‌دهنده (مثل Hetzner/AWS/DigitalOcean/آروان) دارید، پورت 80 و 443 را از آنجا هم باز کنید."
  echo "ادامه فرآیند تا ۱۰ ثانیه دیگر... (برای توقف Ctrl+C بزنید)"
  sleep 10
fi

# اگر دامنه رکورد AAAA (IPv6) دارد ولی متعلق به این سرور نیست،
# Let's Encrypt ممکن است تلاش کند از طریق IPv6 وریفای کند و شکست بخورد.
DOMAIN_IPV6=$(dig +short AAAA "$DOMAIN" @1.1.1.1 | tail -n1)
if [ -n "$DOMAIN_IPV6" ]; then
  echo "⚠️  توجه: دامنه دارای رکورد AAAA (IPv6) است: $DOMAIN_IPV6"
  echo "⚠️  اگر این آی‌پی متعلق به این سرور نیست، آن را از تنظیمات DNS حذف کنید."
fi

# 3. ساخت قالب فارسی سایت
echo "--- در حال ساخت قالب فارسی سایت ---"
rm -rf /var/www/html/*
mkdir -p /var/www/html
cat > /var/www/html/index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>به زودی</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Vazirmatn:wght@400;600;800&display=swap" rel="stylesheet">
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: 'Vazirmatn', Tahoma, sans-serif;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    background: linear-gradient(135deg, #1e3c72 0%, #2a5298 100%);
    color: #fff;
    text-align: center;
    padding: 20px;
  }
  .box { max-width: 560px; }
  .box h1 { font-size: 2.2rem; font-weight: 800; margin-bottom: 16px; }
  .box p {
    font-size: 1.05rem;
    line-height: 1.9;
    color: #dce6f5;
    margin-bottom: 28px;
  }
  .badge {
    display: inline-block;
    padding: 10px 26px;
    border-radius: 30px;
    background: rgba(255,255,255,0.12);
    border: 1px solid rgba(255,255,255,0.25);
    font-weight: 600;
    font-size: 0.95rem;
  }
  .footer { margin-top: 40px; font-size: 0.8rem; color: rgba(255,255,255,0.5); }
</style>
</head>
<body>
  <div class="box">
    <h1>🚀 سایت به‌زودی راه‌اندازی می‌شود</h1>
    <p>
      ما در حال آماده‌سازی این سایت هستیم. لطفاً کمی صبر کنید،
      محتوای اصلی به‌زودی جایگزین این صفحه خواهد شد.
    </p>
    <span class="badge">در حال ساخت 🛠️</span>
    <div class="footer">این صفحه به‌صورت خودکار توسط اسکریپت نصب ساخته شده است.</div>
  </div>
</body>
</html>
HTML_EOF
echo "✅ قالب فارسی ساخته شد."

# تنظیم پرمیشن‌ها
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

# 4. دریافت SSL
echo "--- دریافت SSL ---"
systemctl stop nginx
sleep 2
# اطمینان از آزاد بودن کامل پورت 80 قبل از اجرای certbot
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
  echo "❌ خطا در دریافت SSL. موارد زیر را بررسی کنید:"
  echo "   ۱) رکورد A دامنه دقیقاً به IP این سرور اشاره کند (بدون پروکسی کلودفلر)."
  echo "   ۲) در پنل سرویس‌دهنده سرور (Firewall/Security Group ابری) پورت‌های 80 و 443 باز باشند."
  echo "   ۳) هیچ سرویس دیگری (مثل Apache) روی پورت 80 در حال اجرا نباشد."
  echo "   ۴) صبر کنید تا DNS کامل پروپاگیت شود (گاهی چند ساعت طول می‌کشد) و دوباره اجرا کنید."
  systemctl start nginx
  exit 1
fi

# 5. کانفیگ Nginx
echo "--- کانفیگ Nginx ---"
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    root /var/www/html;
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

nginx -t
systemctl start nginx
systemctl restart nginx

echo "----------------------------------------------"
echo "✅ نصب با موفقیت تمام شد."
echo "🌐 سایت شما: https://$DOMAIN"
echo "----------------------------------------------"

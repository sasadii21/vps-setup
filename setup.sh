#!/bin/bash

# بررسی دسترسی روت
if [ "$EUID" -ne 0 ]; then
  echo "لطفاً با دسترسی روت اجرا کنید."
  exit
fi

# دریافت دامین
if [ -n "$1" ]; then
  DOMAIN="$1"
else
  read -p "Please enter your domain name: " DOMAIN
fi

if [ -z "$DOMAIN" ]; then
  echo "دامین وارد نشد."
  exit
fi

echo "--- شروع نصب سایت پوششی (بدون اشغال پورت 443) ---"

# 1. نصب پیش‌نیازها
apt update -y
apt install nginx certbot unzip curl -y

# 2. دریافت SSL (فقط فایل‌ها را می‌گیریم، روی Nginx سوار نمی‌کنیم)
# نکته: برای گرفتن SSL پورت 80 باید لحظه‌ای آزاد باشد.
systemctl stop nginx
ufw allow 80/tcp

echo "--- در حال دریافت SSL ---"
certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email

if [ $? -ne 0 ]; then
    echo "❌ خطا در دریافت SSL."
    echo "مطمئن شوید پروکسی کلودفلر خاموش است."
    # حتی اگر خطا داد ادامه می‌دهیم شاید فایل‌ها از قبل باشند
fi

# 3. نصب قالب سایت
echo "--- نصب قالب ---"
rm -rf /var/www/html/*
wget -O template.zip https://github.com/StartBootstrap/startbootstrap-agency/archive/gh-pages.zip

if [ -f "template.zip" ]; then
    unzip -o template.zip
    mv startbootstrap-agency-gh-pages/* /var/www/html/
    rm -rf startbootstrap-agency-gh-pages template.zip
else
    echo "<html><h1>Welcome to $DOMAIN</h1></html>" > /var/www/html/index.html
fi

# پرمیشن‌ها
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

# 4. کانفیگ Nginx روی پورت داخلی 5555
echo "--- کانفیگ Nginx روی پورت 5555 ---"
cat > /etc/nginx/sites-available/default <<EOF
server {
    # فقط روی لوکال‌هاست گوش می‌دهد تا از اینترنت مستقیم قابل دسترسی نباشد
    listen 127.0.0.1:5555;
    listen 5555; 
    server_name $DOMAIN;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

systemctl restart nginx

echo "----------------------------------------------"
echo "✅ نصب تمام شد!"
echo "⚠️  پورت 443 درگیر نشد."
echo "🔹 سایت شما الان روی پورت 5555 لوکال بالا آمده است."
echo ""
echo "📌 مسیر سرتیفیکیت‌ها برای استفاده در پنل X-UI:"
echo "Public Key: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
echo "Private Key: /etc/letsencrypt/live/$DOMAIN/privkey.pem"
echo ""
echo "⚙️  تنظیمات Fallback در پنل X-UI:"
echo "Dest: 5555"
echo "Xver: 0 (یا خاموش)"
echo "----------------------------------------------"

#!/bin/bash

# بررسی دسترسی روت
if [ "$EUID" -ne 0 ]; then
  echo "لطفاً با دسترسی روت اجرا کنید (sudo)."
  exit
fi

# دریافت دامین
if [ -n "$1" ]; then
  DOMAIN="$1"
else
  read -p "لطفا نام دامنه خود را وارد کنید (example.com): " DOMAIN
fi

if [ -z "$DOMAIN" ]; then
  echo "دامین وارد نشد."
  exit
fi

echo "--- شروع نصب سایت ترجمک روی دامین: $DOMAIN ---"

# 0. تنظیم فایروال
echo "--- در حال تنظیم فایروال ---"
ufw allow 80/tcp
ufw allow 443/tcp
iptables -I INPUT -p tcp --dport 80 -j ACCEPT
iptables -I INPUT -p tcp --dport 443 -j ACCEPT

# 1. نصب پیش‌نیازها
echo "--- آپدیت و نصب پکیج‌ها ---"
apt update -y
apt install nginx certbot python3-certbot-nginx unzip curl wget -y

# 2. نصب پروژه ترجمک (سایت فارسی)
echo "--- در حال دریافت و نصب پروژه ترجمک ---"
rm -rf /var/www/html/*

# دانلود آخرین نسخه پروژه از گیت‌هاب
wget -O tarjomak.zip https://github.com/mimalef70/tarjomak/archive/refs/heads/master.zip

if [ -f "tarjomak.zip" ]; then
    unzip -o tarjomak.zip
    # انتقال محتویات پوشه استخراج شده (tarjomak-master) به روت وب‌سایت
    mv tarjomak-master/* /var/www/html/
    rm -rf tarjomak-master tarjomak.zip
    echo "✅ سایت ترجمک با موفقیت نصب شد."
else
    echo "خطا در دانلود قالب. یک صفحه پیش‌فرض ساخته شد."
    echo "<html><body style='direction:rtl; text-align:center;'><h1>در حال بروزرسانی...</h1></body></html>" > /var/www/html/index.html
fi

# تنظیم پرمیشن‌ها
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

# 3. دریافت SSL
echo "--- دریافت SSL (ممکن است لحظاتی طول بکشد) ---"
systemctl stop nginx
sleep 2

certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email

if [ $? -ne 0 ]; then
    echo "❌ خطا در دریافت SSL."
    echo "نکته: مطمئن شوید پروکسی کلودفلر (ابر نارنجی) خاموش است."
    systemctl start nginx
    exit
fi

# 4. کانفیگ Nginx
echo "--- کانفیگ نهایی Nginx ---"
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

systemctl start nginx
systemctl restart nginx

echo "----------------------------------------------"
echo "✅ تبریک! سایت 'ترجمک' با موفقیت بالا آمد."
echo "🌐 آدرس شما: https://$DOMAIN"
echo "----------------------------------------------"

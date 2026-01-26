#!/bin/bash

# بررسی دسترسی روت
if [ "$EUID" -ne 0 ]; then
  echo "لطفاً با دسترسی روت اجرا کنید (sudo)."
  exit
fi

# دریافت دامین (یا از ورودی دستور یا پرسش از کاربر)
if [ -n "$1" ]; then
  DOMAIN="$1"
else
  read -p "Please enter your domain name: " DOMAIN
fi

if [ -z "$DOMAIN" ]; then
  echo "دامین وارد نشد."
  exit
fi

echo "--- شروع نصب برای دامین: $DOMAIN ---"

# 1. نصب پیش‌نیازها
apt update -y
apt install nginx certbot python3-certbot-nginx unzip curl -y

# 2. نصب قالب سایت (سایت پوششی)
rm -rf /var/www/html/*
wget -O template.zip https://github.com/StartBootstrap/startbootstrap-agency/archive/gh-pages.zip
if [ -f "template.zip" ]; then
    unzip template.zip
    mv startbootstrap-agency-gh-pages/* /var/www/html/
    rm -rf startbootstrap-agency-gh-pages template.zip
else
    echo "<html><h1>Welcome to $DOMAIN</h1></html>" > /var/www/html/index.html
fi

# پرمیشن‌ها
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

# 3. دریافت SSL
systemctl stop nginx
certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email

if [ $? -ne 0 ]; then
    echo "خطا در دریافت SSL. لطفا DNS را چک کنید."
    systemctl start nginx
    exit
fi

# 4. کانفیگ Nginx
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

systemctl restart nginx
echo "--- نصب تمام شد! سایت شما: https://$DOMAIN ---"

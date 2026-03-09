#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Freedom VPN Setup Script
# Sets up a multi-protocol VPN server (VMess, VLESS+Reality, Hysteria2,
# Shadowsocks) and generates a Persian guide with connection links.
#
# Usage:
#   ./freedom.sh                          # Interactive mode
#   ./freedom.sh --do-token YOUR_TOKEN    # Create a new DigitalOcean droplet
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }
ask()   { echo -en "${CYAN}[?]${NC} $1"; }

# --------------- Dependency checks ---------------

check_dependencies() {
  local missing=()
  command -v ssh      >/dev/null || missing+=(openssh)
  command -v sshpass  >/dev/null || missing+=(sshpass)
  command -v uuidgen  >/dev/null || missing+=(uuidgen)
  command -v openssl  >/dev/null || missing+=(openssl)
  command -v jq       >/dev/null || missing+=(jq)
  command -v npx      >/dev/null || missing+=(node/npm)
  command -v curl     >/dev/null || missing+=(curl)

  if [ ${#missing[@]} -gt 0 ]; then
    error "Missing dependencies: ${missing[*]}"
    echo "  Install them before running this script."
    if [[ "$OSTYPE" == "darwin"* ]]; then
      echo "  brew install ${missing[*]}"
    else
      echo "  apt-get install -y ${missing[*]}"
    fi
    exit 1
  fi
}

# --------------- DigitalOcean integration ---------------

create_droplet() {
  local token="$1"
  local name="${2:-freedom-vpn}"
  local region="${3:-fra1}"
  local size="${4:-s-1vcpu-1gb}"

  info "Creating DigitalOcean droplet: $name in $region..."

  # Generate a root password
  local root_pass
  root_pass=$(openssl rand -base64 20 | tr -d '=/+' | head -c 20)

  # Check if SSH keys exist, if so use them
  local ssh_key_ids
  ssh_key_ids=$(curl -s -X GET \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $token" \
    "https://api.digitalocean.com/v2/account/keys" | jq -r '[.ssh_keys[].id] | join(",")')

  local create_payload
  if [ -n "$ssh_key_ids" ] && [ "$ssh_key_ids" != "null" ] && [ "$ssh_key_ids" != "" ]; then
    create_payload=$(jq -n \
      --arg name "$name" \
      --arg region "$region" \
      --arg size "$size" \
      --argjson ssh_keys "[$ssh_key_ids]" \
      '{name: $name, region: $region, size: $size, image: "ubuntu-24-04-x64", ssh_keys: $ssh_keys}')
  else
    create_payload=$(jq -n \
      --arg name "$name" \
      --arg region "$region" \
      --arg size "$size" \
      '{name: $name, region: $region, size: $size, image: "ubuntu-24-04-x64"}')
  fi

  local response
  response=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $token" \
    -d "$create_payload" \
    "https://api.digitalocean.com/v2/droplets")

  local droplet_id
  droplet_id=$(echo "$response" | jq -r '.droplet.id // empty')

  if [ -z "$droplet_id" ]; then
    error "Failed to create droplet:"
    echo "$response" | jq .
    exit 1
  fi

  info "Droplet created (ID: $droplet_id). Waiting for it to become active..."

  local ip=""
  local attempts=0
  while [ -z "$ip" ] || [ "$ip" == "null" ]; do
    sleep 5
    ip=$(curl -s \
      -H "Authorization: Bearer $token" \
      "https://api.digitalocean.com/v2/droplets/$droplet_id" | \
      jq -r '.droplet.networks.v4[] | select(.type=="public") | .ip_address' | head -1)
    attempts=$((attempts + 1))
    if [ $attempts -gt 60 ]; then
      error "Timed out waiting for droplet IP."
      exit 1
    fi
  done

  info "Droplet is ready! IP: $ip"

  # If no SSH keys were used, we need to wait for the password email
  # But DO doesn't support password-based creation well anymore
  # So we'll set the password via console or expect SSH keys
  if [ -n "$ssh_key_ids" ] && [ "$ssh_key_ids" != "null" ] && [ "$ssh_key_ids" != "" ]; then
    warn "Droplet created with SSH key authentication."
    warn "You'll need to set a root password or provide SSH key access."
    ask "Enter a root password to set (or press enter to use SSH key): "
    read -r root_pass
    if [ -z "$root_pass" ]; then
      error "Password-less SSH not supported by this script yet. Please provide a password."
      echo "  You can SSH in manually and set one: ssh root@$ip"
      echo "  Then re-run this script with: ./freedom.sh"
      exit 1
    fi
  fi

  SERVER_IP="$ip"
  SERVER_PASS="$root_pass"

  # Wait for SSH to become available
  info "Waiting for SSH to become available..."
  local ssh_attempts=0
  while ! sshpass -p "$SERVER_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$SERVER_IP" 'echo ok' &>/dev/null; do
    sleep 5
    ssh_attempts=$((ssh_attempts + 1))
    if [ $ssh_attempts -gt 60 ]; then
      error "Timed out waiting for SSH."
      exit 1
    fi
  done
  info "SSH is ready."
}

create_dns_record_do() {
  local token="$1"
  local full_domain="$2"
  local ip="$3"

  # Split domain: subdomain.domain.tld
  local base_domain subdomain
  base_domain=$(echo "$full_domain" | awk -F. '{print $(NF-1)"."$NF}')
  subdomain=$(echo "$full_domain" | sed "s/\.$base_domain$//")

  info "Creating DNS A record: $subdomain -> $ip on $base_domain"

  local response
  response=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $token" \
    -d "{\"type\":\"A\",\"name\":\"$subdomain\",\"data\":\"$ip\",\"ttl\":300}" \
    "https://api.digitalocean.com/v2/domains/$base_domain/records")

  local record_id
  record_id=$(echo "$response" | jq -r '.domain_record.id // empty')

  if [ -z "$record_id" ]; then
    error "Failed to create DNS record:"
    echo "$response" | jq .
    error "Please create the A record manually: $full_domain -> $ip"
    ask "Press Enter once DNS is configured..."
    read -r
  else
    info "DNS record created (ID: $record_id). Waiting for propagation..."
    sleep 10
    # Verify DNS
    local resolved=""
    local dns_attempts=0
    while [ "$resolved" != "$ip" ]; do
      resolved=$(dig +short "$full_domain" @8.8.8.8 2>/dev/null | head -1)
      sleep 5
      dns_attempts=$((dns_attempts + 1))
      if [ $dns_attempts -gt 60 ]; then
        warn "DNS hasn't propagated yet. Continuing anyway..."
        break
      fi
    done
    info "DNS is resolving: $full_domain -> $resolved"
  fi
}

# --------------- Server setup ---------------

setup_server() {
  local ip="$1"
  local pass="$2"
  local domain="$3"
  local uuid="$4"
  local ss_pass="$5"
  local email="$6"

  local ssh_cmd="sshpass -p '$pass' ssh -o StrictHostKeyChecking=no root@$ip"

  info "Setting up server at $ip for domain $domain..."

  # Step 1: Base packages + Nginx + TLS
  info "Installing packages and obtaining TLS certificate..."
  sshpass -p "$pass" ssh -o StrictHostKeyChecking=no "root@$ip" "bash -s" << REMOTE_SCRIPT
set -e
export DEBIAN_FRONTEND=noninteractive

echo ">>> Updating system..."
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx curl unzip jq

echo ">>> Configuring Nginx..."
cat > /etc/nginx/sites-available/v2ray << EOF
server {
    listen 80;
    server_name ${domain};
    location / {
        root /var/www/html;
        index index.html;
    }
}
EOF
ln -sf /etc/nginx/sites-available/v2ray /etc/nginx/sites-enabled/v2ray
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

echo ">>> Obtaining TLS certificate..."
certbot --nginx -d ${domain} --non-interactive --agree-tos --email ${email} --redirect

echo ">>> Installing Xray..."
bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

echo ">>> Generating Reality keys..."
REALITY_OUTPUT=\$(/usr/local/bin/xray x25519 2>&1)
REALITY_PRIVATE=\$(echo "\$REALITY_OUTPUT" | head -1 | awk '{print \$NF}')
REALITY_PUBLIC=\$(echo "\$REALITY_OUTPUT" | sed -n '2p' | awk '{print \$NF}')
SHORT_ID=\$(openssl rand -hex 8)

echo "REALITY_PRIVATE=\$REALITY_PRIVATE" > /root/.vpn-keys
echo "REALITY_PUBLIC=\$REALITY_PUBLIC" >> /root/.vpn-keys
echo "SHORT_ID=\$SHORT_ID" >> /root/.vpn-keys

echo ">>> Configuring Xray..."
cat > /usr/local/etc/xray/config.json << XEOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "vmess-ws",
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [{"id": "${uuid}", "alterId": 0}]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/ws"}
      }
    },
    {
      "tag": "vless-reality",
      "port": 2083,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "www.google.com:443",
          "serverNames": ["www.google.com", "google.com"],
          "privateKey": "\$REALITY_PRIVATE",
          "shortIds": ["\$SHORT_ID"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
    },
    {
      "tag": "shadowsocks",
      "port": 8388,
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "${ss_pass}",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
XEOF

echo ">>> Updating Nginx for WebSocket proxy..."
cat > /etc/nginx/sites-available/v2ray << NEOF
server {
    listen 80;
    server_name ${domain};
    return 301 https://\\\$host\\\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location /ws {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
    }

    location / {
        root /var/www/html;
        index index.html;
    }
}
NEOF

nginx -t && systemctl restart nginx
systemctl enable xray && systemctl restart xray

echo ">>> Installing Hysteria2..."
bash <(curl -fsSL https://get.hy2.sh/)

cat > /etc/hysteria/config.yaml << HEOF
listen: :8443

tls:
  cert: /etc/letsencrypt/live/${domain}/fullchain.pem
  key: /etc/letsencrypt/live/${domain}/privkey.pem

auth:
  type: password
  password: ${uuid}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
HEOF

chmod 755 /etc/letsencrypt/live/ /etc/letsencrypt/archive/
chmod 644 /etc/letsencrypt/archive/${domain}/privkey*.pem

systemctl enable hysteria-server && systemctl restart hysteria-server

echo ">>> Downloading Android APKs..."
mkdir -p /var/www/html/apps

V2RAYNG_URL=\$(curl -s https://api.github.com/repos/2dust/v2rayNG/releases/latest | grep -oP '"browser_download_url":\s*"\K[^"]*universal[^"]*\.apk' | head -1)
[ -z "\$V2RAYNG_URL" ] && V2RAYNG_URL=\$(curl -s https://api.github.com/repos/2dust/v2rayNG/releases/latest | grep -oP '"browser_download_url":\s*"\K[^"]*\.apk' | head -1)
curl -L -o /var/www/html/apps/v2rayNG.apk "\$V2RAYNG_URL"

NEKOBOX_URL=\$(curl -s https://api.github.com/repos/MatsuriDayo/NekoBoxForAndroid/releases/latest | grep -oP '"browser_download_url":\s*"\K[^"]*arm64-v8a[^"]*\.apk' | head -1)
[ -z "\$NEKOBOX_URL" ] && NEKOBOX_URL=\$(curl -s https://api.github.com/repos/MatsuriDayo/NekoBoxForAndroid/releases/latest | grep -oP '"browser_download_url":\s*"\K[^"]*\.apk' | head -1)
curl -L -o /var/www/html/apps/NekoBox.apk "\$NEKOBOX_URL"

HIDDIFY_URL=\$(curl -s https://api.github.com/repos/hiddify/hiddify-app/releases/latest | grep -oP '"browser_download_url":\s*"\K[^"]*android-universal[^"]*\.apk' | head -1)
[ -z "\$HIDDIFY_URL" ] && HIDDIFY_URL=\$(curl -s https://api.github.com/repos/hiddify/hiddify-app/releases/latest | grep -oP '"browser_download_url":\s*"\K[^"]*android[^"]*\.apk' | head -1)
curl -L -o /var/www/html/apps/Hiddify.apk "\$HIDDIFY_URL"

echo ">>> Opening firewall ports..."
ufw allow 443/tcp  2>/dev/null || true
ufw allow 2083/tcp 2>/dev/null || true
ufw allow 8388/tcp 2>/dev/null || true
ufw allow 8388/udp 2>/dev/null || true
ufw allow 8443/tcp 2>/dev/null || true
ufw allow 8443/udp 2>/dev/null || true

echo ">>> Final status..."
echo "XRAY_STATUS=\$(systemctl is-active xray)"
echo "HYSTERIA_STATUS=\$(systemctl is-active hysteria-server)"
echo "NGINX_STATUS=\$(systemctl is-active nginx)"
cat /root/.vpn-keys
REMOTE_SCRIPT
}

# --------------- Retrieve keys from server ---------------

get_server_keys() {
  local ip="$1"
  local pass="$2"

  sshpass -p "$pass" ssh -o StrictHostKeyChecking=no "root@$ip" 'cat /root/.vpn-keys' 2>/dev/null
}

# --------------- Generate guide ---------------

generate_guide() {
  local domain="$1"
  local uuid="$2"
  local ss_pass="$3"
  local reality_public="$4"
  local short_id="$5"
  local output_dir="$6"

  local vmess_json="{\"v\":\"2\",\"ps\":\"VMess-WS-TLS\",\"add\":\"${domain}\",\"port\":\"443\",\"id\":\"${uuid}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${domain}\",\"path\":\"/ws\",\"tls\":\"tls\",\"sni\":\"${domain}\"}"
  local vmess_link="vmess://$(echo -n "$vmess_json" | base64 | tr -d '\n')"
  local vless_link="vless://${uuid}@${domain}:2083?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.google.com&fp=chrome&pbk=${reality_public}&sid=${short_id}&type=tcp#VLESS-Reality"
  local hy2_link="hysteria2://${uuid}@${domain}:8443?sni=${domain}#Hysteria2"
  local ss_encoded
  ss_encoded=$(echo -n "2022-blake3-aes-128-gcm:${ss_pass}" | base64 | tr -d '\n')
  local ss_link="ss://${ss_encoded}@${domain}:8388#Shadowsocks"

  local md_file="${output_dir}/vpn-guide-${domain}.md"
  local pdf_file="${output_dir}/vpn-guide-${domain}.pdf"

  cat > "$md_file" << 'MDHEAD'
---
pdf_options:
  format: A4
  margin: 20mm
stylesheet:
  - https://cdn.jsdelivr.net/npm/vazirmatn@33.0.3/Vazirmatn-font-face.css
body_class: rtl
css: |-
  body {
    direction: rtl;
    text-align: right;
    font-family: 'Vazirmatn', Tahoma, sans-serif;
  }
  pre, code {
    direction: ltr !important;
    text-align: left !important;
    unicode-bidi: bidi-override;
  }
  table {
    width: 100%;
    border-collapse: collapse;
    direction: rtl;
  }
  th, td {
    border: 1px solid #ccc;
    padding: 8px;
    text-align: right;
  }
  th {
    background: #f5f5f5;
  }
  h1, h2, h3 {
    direction: rtl;
    text-align: right;
  }
  blockquote {
    border-right: 4px solid #4CAF50;
    border-left: none;
    padding-right: 12px;
    padding-left: 0;
    color: #555;
  }
---

MDHEAD

  cat >> "$md_file" << MDBODY
# راهنمای اتصال به سرور VPN

## لینک‌های سریع اتصال

چهار پروتکل مختلف روی این سرور فعال است. هر کدام را در اپلیکیشن مربوطه کپی و Import کنید.

---

### 1. VMess + WebSocket + TLS (پیشنهادی برای شروع)

\`\`\`
${vmess_link}
\`\`\`

> ترافیک شما شبیه به HTTPS عادی به نظر می‌رسد. از پورت 443 استفاده می‌کند.

---

### 2. VLESS + Reality (بهترین برای دور زدن فیلترینگ پیشرفته)

\`\`\`
${vless_link}
\`\`\`

> جدیدترین و امن‌ترین پروتکل. ترافیک شما کاملاً شبیه اتصال عادی به Google به نظر می‌رسد. اگر VMess مسدود شد، این گزینه را امتحان کنید.

---

### 3. Hysteria2 (سریع‌ترین - مناسب برای ویدیو و بازی)

\`\`\`
${hy2_link}
\`\`\`

> از پروتکل UDP استفاده می‌کند و بسیار سریع است. برای تماشای ویدیو و بازی آنلاین عالی است. اگر UDP مسدود شده باشد کار نمی‌کند.

---

### 4. Shadowsocks (ساده و سبک)

\`\`\`
${ss_link}
\`\`\`

> سبک‌ترین پروتکل. مصرف باتری کمتر. مناسب برای گوشی‌های قدیمی.

---

## اپلیکیشن‌های پیشنهادی

### Android

| اپلیکیشن | پروتکل‌های پشتیبانی | لینک دانلود |
|-----------|----------------------|-------------|
| **v2rayNG** | VMess, VLESS, Shadowsocks | [دانلود مستقیم APK](https://${domain}/apps/v2rayNG.apk) / [Google Play](https://play.google.com/store/apps/details?id=com.v2ray.ang) |
| **NekoBox** | VMess, VLESS, Shadowsocks, Hysteria2 | [دانلود مستقیم APK](https://${domain}/apps/NekoBox.apk) / [GitHub](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases) |
| **Hiddify** | همه پروتکل‌ها | [دانلود مستقیم APK](https://${domain}/apps/Hiddify.apk) / [Google Play](https://play.google.com/store/apps/details?id=app.hiddify.com) |

> برای نصب APK باید در تنظیمات گوشی، گزینه "نصب از منابع ناشناس" (Install from Unknown Sources) را فعال کنید.

### iOS / iPhone / iPad

| اپلیکیشن | پروتکل‌های پشتیبانی | لینک دانلود |
|-----------|----------------------|-------------|
| **Streisand** | VMess, VLESS, Shadowsocks, Hysteria2 | [App Store](https://apps.apple.com/app/streisand/id6450534064) |
| **V2Box** | VMess, VLESS, Shadowsocks | [App Store](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) |
| **Hiddify** | همه پروتکل‌ها | [App Store](https://apps.apple.com/app/hiddify-proxy-vpn/id6596777532) |

### Windows

| اپلیکیشن | پروتکل‌های پشتیبانی | لینک دانلود |
|-----------|----------------------|-------------|
| **v2rayN** | VMess, VLESS, Shadowsocks | [GitHub](https://github.com/2dust/v2rayN/releases) |
| **Nekoray** | VMess, VLESS, Shadowsocks, Hysteria2 | [GitHub](https://github.com/MatsuriDayo/nekoray/releases) |
| **Hiddify** | همه پروتکل‌ها | [GitHub](https://github.com/hiddify/hiddify-app/releases) |

### macOS

| اپلیکیشن | پروتکل‌های پشتیبانی | لینک دانلود |
|-----------|----------------------|-------------|
| **V2rayU** | VMess, VLESS | [GitHub](https://github.com/yanue/V2rayU/releases) |
| **Nekoray** | VMess, VLESS, Shadowsocks, Hysteria2 | [GitHub](https://github.com/MatsuriDayo/nekoray/releases) |
| **Hiddify** | همه پروتکل‌ها | [GitHub](https://github.com/hiddify/hiddify-app/releases) |

### Linux

| اپلیکیشن | پروتکل‌های پشتیبانی | لینک دانلود |
|-----------|----------------------|-------------|
| **Nekoray** | VMess, VLESS, Shadowsocks, Hysteria2 | [GitHub](https://github.com/MatsuriDayo/nekoray/releases) |
| **Hiddify** | همه پروتکل‌ها | [GitHub](https://github.com/hiddify/hiddify-app/releases) |

---

## نحوه اتصال (قدم به قدم)

### روش ساده: Import با لینک

1. یکی از اپلیکیشن‌های بالا را نصب کنید (Hiddify برای همه پلتفرم‌ها پیشنهاد می‌شود)
2. یکی از لینک‌های بالا را کپی کنید
3. در اپلیکیشن روی **+** یا **Import** بزنید
4. گزینه **Import from Clipboard** را انتخاب کنید
5. روی **Connect** بزنید

### تنظیمات دستی (در صورت نیاز)

#### VMess + WebSocket + TLS

| تنظیم | مقدار |
|--------|-------|
| Protocol | VMess |
| Address | \`${domain}\` |
| Port | \`443\` |
| UUID | \`${uuid}\` |
| AlterID | \`0\` |
| Network | \`ws\` |
| WS Path | \`/ws\` |
| TLS | Enabled |
| SNI | \`${domain}\` |

#### VLESS + Reality

| تنظیم | مقدار |
|--------|-------|
| Protocol | VLESS |
| Address | \`${domain}\` |
| Port | \`2083\` |
| UUID | \`${uuid}\` |
| Flow | \`xtls-rprx-vision\` |
| Security | Reality |
| SNI | \`www.google.com\` |
| Fingerprint | \`chrome\` |
| Public Key | \`${reality_public}\` |
| Short ID | \`${short_id}\` |

#### Hysteria2

| تنظیم | مقدار |
|--------|-------|
| Protocol | Hysteria2 |
| Address | \`${domain}\` |
| Port | \`8443\` |
| Password | \`${uuid}\` |
| SNI | \`${domain}\` |

#### Shadowsocks

| تنظیم | مقدار |
|--------|-------|
| Address | \`${domain}\` |
| Port | \`8388\` |
| Method | \`2022-blake3-aes-128-gcm\` |
| Password | \`${ss_pass}\` |

---

## کدام پروتکل را استفاده کنم؟

**اینترنت عادی کار می‌کند؟**

- **بله** ← از Hysteria2 استفاده کنید (سریع‌ترین)
- **نه، فیلتر شده** ← از VMess + WS + TLS استفاده کنید
- **VMess هم مسدود شد** ← از VLESS + Reality استفاده کنید (سخت‌ترین برای شناسایی)
- **هیچکدام کار نمی‌کند** ← Shadowsocks را امتحان کنید

## نکات مهم

- **این اطلاعات را فقط با افراد مورد اعتماد به اشتراک بگذارید.** اگر تعداد زیادی کاربر از یک سرور استفاده کنند، احتمال مسدود شدن IP سرور بیشتر می‌شود.
- **اگر یک پروتکل کار نکرد، پروتکل دیگری را امتحان کنید.** هر پروتکل روش متفاوتی برای عبور از فیلترینگ دارد.
- **VLESS + Reality بهترین گزینه برای زمانی است که فیلترینگ شدید است** زیرا ترافیک شما دقیقاً شبیه اتصال عادی به Google به نظر می‌رسد.
- **Hysteria2 بهترین سرعت را دارد** اما ممکن است در زمان‌هایی که UDP مسدود شده کار نکند.
- **از Split Tunneling استفاده کنید:** در تنظیمات اپلیکیشن، سایت‌های ایرانی را از VPN خارج کنید تا هم سرعت بهتر باشد و هم مصرف ترافیک سرور کمتر شود.

---

## عیب‌یابی

| مشکل | راه حل |
|------|--------|
| اتصال برقرار نمی‌شود | پروتکل دیگری را امتحان کنید |
| سرعت کم است | Hysteria2 را امتحان کنید |
| قطع و وصل می‌شود | VLESS + Reality را امتحان کنید |
| سایت‌های ایرانی باز نمی‌شوند | Split Tunneling را فعال کنید |
| اپلیکیشن از Play Store نصب نمی‌شود | از لینک‌های "دانلود مستقیم APK" در بالا استفاده کنید |

---

*این سند به صورت خودکار تولید شده است.*
MDBODY

  info "Generating PDF..."
  npx --yes md-to-pdf "$md_file" 2>/dev/null

  info "Guide generated:"
  echo "  Markdown: $md_file"
  echo "  PDF:      $pdf_file"
}

# --------------- Main ---------------

main() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║       Freedom VPN Setup Script           ║${NC}"
  echo -e "${GREEN}║  VMess | VLESS+Reality | Hysteria2 | SS  ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
  echo ""

  check_dependencies

  local DO_TOKEN=""
  local SERVER_IP=""
  local SERVER_PASS=""
  local DOMAIN=""
  local OUTPUT_DIR="."

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      --do-token)  DO_TOKEN="$2";     shift 2 ;;
      --ip)        SERVER_IP="$2";    shift 2 ;;
      --pass)      SERVER_PASS="$2";  shift 2 ;;
      --domain)    DOMAIN="$2";       shift 2 ;;
      --output)    OUTPUT_DIR="$2";   shift 2 ;;
      -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --do-token TOKEN   DigitalOcean API token (creates a new droplet)"
        echo "  --ip IP            Server IP address"
        echo "  --pass PASSWORD    Server root password"
        echo "  --domain DOMAIN    Domain name (must have A record pointing to server)"
        echo "  --output DIR       Output directory for generated guide (default: .)"
        echo "  -h, --help         Show this help"
        echo ""
        echo "Examples:"
        echo "  $0                                    # Interactive mode"
        echo "  $0 --do-token abc123                  # Auto-create DigitalOcean droplet"
        echo "  $0 --ip 1.2.3.4 --pass x --domain d  # Use existing server"
        exit 0
        ;;
      *) error "Unknown option: $1"; exit 1 ;;
    esac
  done

  # ---- Mode selection ----

  if [ -z "$SERVER_IP" ] && [ -z "$DO_TOKEN" ]; then
    echo "How would you like to set up your server?"
    echo ""
    echo "  1) I have an existing server (IP + password)"
    echo "  2) Create a new DigitalOcean droplet"
    echo ""
    ask "Choose [1/2]: "
    read -r mode_choice

    case $mode_choice in
      2)
        ask "DigitalOcean API token: "
        read -r DO_TOKEN
        ;;
      *)
        ;;
    esac
  fi

  # ---- DigitalOcean: create droplet ----

  if [ -n "$DO_TOKEN" ]; then
    ask "Droplet name [freedom-vpn]: "
    read -r droplet_name
    droplet_name="${droplet_name:-freedom-vpn}"

    echo ""
    echo "Available regions:"
    echo "  fra1 (Frankfurt)  |  ams3 (Amsterdam)  |  lon1 (London)"
    echo "  nyc1 (New York)   |  sfo3 (San Francisco)"
    ask "Region [fra1]: "
    read -r droplet_region
    droplet_region="${droplet_region:-fra1}"

    create_droplet "$DO_TOKEN" "$droplet_name" "$droplet_region"
  fi

  # ---- Collect server details ----

  if [ -z "$SERVER_IP" ]; then
    ask "Server IP address: "
    read -r SERVER_IP
  fi

  if [ -z "$SERVER_PASS" ]; then
    ask "Root password: "
    read -rs SERVER_PASS
    echo ""
  fi

  if [ -z "$DOMAIN" ]; then
    ask "Domain name (e.g., vpn.example.com): "
    read -r DOMAIN
  fi

  # ---- DNS setup ----

  info "Checking DNS for $DOMAIN..."
  local resolved
  resolved=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | head -1)

  if [ "$resolved" != "$SERVER_IP" ]; then
    warn "DNS for $DOMAIN does not point to $SERVER_IP (currently: ${resolved:-not set})"

    if [ -n "$DO_TOKEN" ]; then
      ask "Create DNS record via DigitalOcean? [Y/n]: "
      read -r create_dns
      if [[ ! "$create_dns" =~ ^[Nn] ]]; then
        create_dns_record_do "$DO_TOKEN" "$DOMAIN" "$SERVER_IP"
      else
        warn "Please create an A record manually: $DOMAIN -> $SERVER_IP"
        ask "Press Enter once DNS is configured..."
        read -r
      fi
    else
      warn "Please create an A record: $DOMAIN -> $SERVER_IP"
      ask "Press Enter once DNS is configured..."
      read -r
    fi
  else
    info "DNS is correctly configured: $DOMAIN -> $resolved"
  fi

  # ---- Generate credentials ----

  local UUID
  UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  local SS_PASS
  SS_PASS=$(openssl rand -base64 16)
  local EMAIL="admin@$(echo "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')"

  info "Generated credentials:"
  echo "  UUID:     $UUID"
  echo "  SS Pass:  $SS_PASS"

  # ---- Run setup ----

  setup_server "$SERVER_IP" "$SERVER_PASS" "$DOMAIN" "$UUID" "$SS_PASS" "$EMAIL"

  # ---- Retrieve Reality keys ----

  info "Retrieving Reality keys from server..."
  local keys_output
  keys_output=$(get_server_keys "$SERVER_IP" "$SERVER_PASS")

  local REALITY_PUBLIC SHORT_ID
  REALITY_PUBLIC=$(echo "$keys_output" | grep REALITY_PUBLIC | cut -d= -f2)
  SHORT_ID=$(echo "$keys_output" | grep SHORT_ID | cut -d= -f2)

  if [ -z "$REALITY_PUBLIC" ]; then
    error "Could not retrieve Reality public key. VLESS+Reality may not work."
    REALITY_PUBLIC="KEY_NOT_FOUND"
    SHORT_ID="0000000000000000"
  fi

  info "Reality Public Key: $REALITY_PUBLIC"
  info "Short ID: $SHORT_ID"

  # ---- Generate guide ----

  mkdir -p "$OUTPUT_DIR"
  generate_guide "$DOMAIN" "$UUID" "$SS_PASS" "$REALITY_PUBLIC" "$SHORT_ID" "$OUTPUT_DIR"

  # ---- Done ----

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║          Setup Complete!                 ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
  echo ""
  echo "  Server:  $SERVER_IP ($DOMAIN)"
  echo "  Guide:   ${OUTPUT_DIR}/vpn-guide-${DOMAIN}.pdf"
  echo ""
  echo "  Protocols running:"
  echo "    - VMess + WS + TLS    (port 443)"
  echo "    - VLESS + Reality     (port 2083)"
  echo "    - Hysteria2           (port 8443)"
  echo "    - Shadowsocks         (port 8388)"
  echo ""
  echo "  APK downloads:"
  echo "    - https://${DOMAIN}/apps/v2rayNG.apk"
  echo "    - https://${DOMAIN}/apps/NekoBox.apk"
  echo "    - https://${DOMAIN}/apps/Hiddify.apk"
  echo ""
  warn "Share the PDF with trusted people only."
  warn "Change the server root password if you used a simple one."
  echo ""
}

main "$@"

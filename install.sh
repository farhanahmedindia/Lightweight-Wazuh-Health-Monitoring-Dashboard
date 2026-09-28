#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo ./install.sh" >&2; exit 1; }
command -v nginx >/dev/null || { echo "Install nginx and jq first." >&2; exit 1; }
command -v jq >/dev/null || { echo "Install jq first." >&2; exit 1; }

src=$(cd "$(dirname "$0")" && pwd)
install -d -m 0755 /var/www/wazuh-health /usr/local/sbin
install -m 0755 "$src/wazuh-health-collect.sh" /usr/local/sbin/wazuh-health-collect
install -m 0644 "$src/wazuh-health-collect.service" /etc/systemd/system/wazuh-health-collect.service
install -m 0644 "$src/wazuh-health-collect.timer" /etc/systemd/system/wazuh-health-collect.timer
install -m 0644 "$src/nginx-wazuh-health.conf" /etc/nginx/conf.d/wazuh-health.conf
install -m 0644 "$src/public/index.html" /var/www/wazuh-health/index.html
install -m 0644 "$src/public/style.css" /var/www/wazuh-health/style.css
install -m 0644 "$src/public/app.js" /var/www/wazuh-health/app.js

if [[ ! -e /etc/wazuh-health-dashboard.conf ]]; then
  install -m 0600 "$src/wazuh-health-dashboard.conf.example" /etc/wazuh-health-dashboard.conf
  echo "Edit /etc/wazuh-health-dashboard.conf, then run:"
  echo "  sudo systemctl restart wazuh-health-collect.service"
fi

systemctl daemon-reload
systemctl enable --now wazuh-health-collect.timer
nginx -t
systemctl reload nginx
echo "Dashboard available at http://<wazuh-server-ip>:8080 after the first successful collection."

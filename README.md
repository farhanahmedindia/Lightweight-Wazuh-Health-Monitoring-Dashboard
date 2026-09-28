# Lightweight Wazuh Health Dashboard

A lightweight on-server Wazuh health dashboard built with Bash, curl, jq, systemd, Nginx, HTML, CSS, and JavaScript.

## Architecture

- systemd timer runs the Bash collector every minute
- Bash collector checks local Wazuh service state and Linux host metrics
- OpenSearch REST API provides cluster and `wazuh-alerts-*` index statistics
- jq builds a small JSON snapshot
- Nginx serves the static dashboard on port 8080
- Browser refreshes the JSON snapshot every 60 seconds

## Metrics

- Wazuh Manager, Indexer and Dashboard service state
- OpenSearch cluster health
- Indexer node count
- Active and unassigned shards
- CPU, memory and disk usage
- Available disk space
- Latest 14 daily `wazuh-alerts-*` indices
- Documents and indexed store size per daily index

## Storage note

`store.size` is indexed disk usage. It should not be described as raw network log bytes or exact raw ingestion volume.

## Requirements

```bash
sudo apt update
sudo apt install -y nginx jq
```

## Full Setup and Run

The following steps assume the dashboard is being installed directly on the Wazuh server, typically an Ubuntu/Debian VM.

### 1. Connect to the Wazuh server

SSH into the server:

```bash
ssh <username>@<wazuh-server-ip>
```

Confirm that you are on the Wazuh server:

```bash
hostname
ip addr
```

### 2. Install Git

If Git is not already installed:

```bash
sudo apt update
sudo apt install -y git
```

Verify:

```bash
git --version
```

### 3. Clone the repository

Clone your GitHub repository:

```bash
git clone https://github.com/<your-username>/<your-repository>.git
cd <your-repository>
```

Confirm the files:

```bash
ls -la
find public -maxdepth 1 -type f -print
```

You should see:

```text
README.md
install.sh
wazuh-health-collect.sh
wazuh-health-collect.service
wazuh-health-collect.timer
nginx-wazuh-health.conf
wazuh-health-dashboard.conf.example
public/
```

### 4. Install dependencies

Install Nginx, jq, curl and the basic utilities used by the collector:

```bash
sudo apt update
sudo apt install -y nginx jq curl
```

Verify:

```bash
nginx -v
jq --version
curl --version
systemctl --version
```

### 5. Make the scripts executable

Run:

```bash
chmod +x install.sh
chmod +x wazuh-health-collect.sh
```

Verify:

```bash
ls -l install.sh wazuh-health-collect.sh
```

Both files should have execute permissions.

### 6. Create the Indexer configuration

The real credentials must stay outside the Git repository.

Run:

```bash
sudo cp wazuh-health-dashboard.conf.example /etc/wazuh-health-dashboard.conf
sudo chmod 600 /etc/wazuh-health-dashboard.conf
```

Edit the configuration:

```bash
sudo nano /etc/wazuh-health-dashboard.conf
```

Example:

```bash
WAZUH_INDEXER_URL=https://<indexer-private-ip>:9200
WAZUH_INDEXER_USER=<read-only-user>
WAZUH_INDEXER_PASSWORD=<read-only-password>
WAZUH_INDEXER_CA=/path/to/indexer-root-ca.pem
WAZUH_INDEXER_INSECURE_TLS=false
```

Use a dedicated read-only Indexer account.

Do **not** put the production password in GitHub.

### 7. Test Indexer connectivity before installing

Test that the Wazuh server can reach the Indexer:

```bash
curl -v https://<indexer-private-ip>:9200
```

If authentication is required:

```bash
curl --cacert /path/to/indexer-root-ca.pem   -u '<read-only-user>:<password>'   https://<indexer-private-ip>:9200/_cluster/health
```

A successful response should contain cluster information such as:

```json
{
  "status": "green"
}
```

If your environment uses a different trusted CA path, update the command accordingly.

### 8. Run the installer

From the cloned repository:

```bash
sudo ./install.sh
```

The installer copies the collector, systemd units, Nginx configuration and frontend into their required locations.

### 9. Check the systemd timer

Run:

```bash
sudo systemctl status wazuh-health-collect.timer --no-pager
```

You should see that the timer is enabled and active.

Also check:

```bash
sudo systemctl list-timers | grep wazuh-health
```

### 10. Run the collector manually for the first test

Do not wait for the one-minute timer.

Run:

```bash
sudo systemctl start wazuh-health-collect.service
```

Check the service:

```bash
sudo systemctl status wazuh-health-collect.service --no-pager
```

Then inspect the generated JSON:

```bash
sudo cat /var/www/wazuh-health/health.json | jq
```

You should see fields similar to:

```json
{
  "generatedAt": "...",
  "overall": "healthy",
  "services": {
    "wazuh-manager": "running",
    "wazuh-indexer": "running",
    "wazuh-dashboard": "running"
  },
  "system": {},
  "indexer": {},
  "ingestion": []
}
```

### 11. Check collector logs

If the JSON file was not created or contains unexpected data:

```bash
sudo journalctl -u wazuh-health-collect.service -n 50 --no-pager
```

For live logs:

```bash
sudo journalctl -u wazuh-health-collect.service -f
```

### 12. Test Nginx configuration

Run:

```bash
sudo nginx -t
```

Expected result:

```text
syntax is ok
test is successful
```

Then reload Nginx:

```bash
sudo systemctl reload nginx
```

Check:

```bash
sudo systemctl status nginx --no-pager
```

### 13. Test the dashboard locally

From the Wazuh server:

```bash
curl -I http://127.0.0.1:8080
```

Test the JSON endpoint:

```bash
curl http://127.0.0.1:8080/health.json
```

If both work, the dashboard is running locally.

### 14. Open port 8080 on the server firewall

If UFW is enabled:

```bash
sudo ufw status
```

Allow TCP 8080:

```bash
sudo ufw allow 8080/tcp
```

Verify:

```bash
sudo ufw status
```

**Security reminder:** do not blindly expose port 8080 to the entire internet. Prefer restricting it to your office/VPN/admin IP range when possible.

For example:

```bash
sudo ufw allow from <your-public-ip> to any port 8080 proto tcp
```

If you already added a broad rule, remove it before using the restricted rule:

```bash
sudo ufw delete allow 8080/tcp
```

### 15. Open port 8080 in the cloud firewall/security group

If the Wazuh server is running on AWS, Azure, GCP, or another cloud platform, opening UFW is **not enough**.

You also need an inbound network rule/security-group/NSG rule allowing:

```text
Protocol: TCP
Port: 8080
Source: Your trusted IP/VPN CIDR
```

For an Azure VM, for example, check the VM's **Network Security Group (NSG)** and add an inbound security rule for TCP 8080.

**Port reminder:** TCP `8080` must be allowed at every applicable network layer:

```text
Internet / VPN
      |
      v
Cloud Security Group / NSG / Firewall
      |
      v
Server UFW / iptables
      |
      v
Nginx :8080
```

Do not open `9200` publicly just to make this dashboard work. The dashboard should access the Indexer from the Wazuh server's internal network.

### 16. Open the dashboard

From your browser:

```text
http://<wazuh-server-ip>:8080
```

Example:

```text
http://10.0.1.20:8080
```

For a cloud VM, use the VM's reachable IP or DNS name:

```text
http://<public-ip>:8080
```

Prefer VPN/private access instead of exposing the dashboard publicly.

### 17. Verify automatic collection

After the first successful run, wait approximately one minute and check:

```bash
sudo systemctl status wazuh-health-collect.timer --no-pager
```

Then:

```bash
sudo stat /var/www/wazuh-health/health.json
```

The modification time should continue updating.

You can also check:

```bash
sudo journalctl -u wazuh-health-collect.service --since "5 minutes ago" --no-pager
```

### 18. Verify after reboot

The timer is configured to start automatically.

Check:

```bash
sudo systemctl is-enabled wazuh-health-collect.timer
```

Expected:

```text
enabled
```

The timer should also be active:

```bash
sudo systemctl is-active wazuh-health-collect.timer
```

Expected:

```text
active
```

## Configuration

Keep the real configuration in `/etc/wazuh-health-dashboard.conf` and never commit it.

Use a dedicated read-only Indexer user:

```bash
WAZUH_INDEXER_URL=https://<indexer-private-ip>:9200
WAZUH_INDEXER_USER=<read-only-user>
WAZUH_INDEXER_PASSWORD=<read-only-password>
WAZUH_INDEXER_CA=/path/to/indexer-root-ca.pem
WAZUH_INDEXER_INSECURE_TLS=false
```

Prefer CA-based certificate validation over disabling TLS verification.

## Troubleshooting

```bash
sudo systemctl status wazuh-health-collect.timer --no-pager
sudo systemctl status wazuh-health-collect.service --no-pager
sudo journalctl -u wazuh-health-collect.service -n 30 --no-pager
sudo cat /var/www/wazuh-health/health.json
sudo nginx -t
```

## Security

Do not publish passwords, tokens, webhook URLs, internal IP addresses, or the real `/etc/wazuh-health-dashboard.conf`.

The public dashboard should also be protected with network controls or authentication when it contains operationally sensitive information.

## License

Choose a license before publishing the repository.

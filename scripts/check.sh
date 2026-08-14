#!/usr/bin/env bash

set -Eeuo pipefail

export ANSIBLE_NOCOLOR=1

INVENTORY="${INVENTORY:-inventory/hosts.yml}"
WEB_ALIAS="${WEB_ALIAS:-web01}"
SYSLOG_ALIAS="${SYSLOG_ALIAS:-syslog01}"
PROJECT_DIR="${PROJECT_DIR:-/opt/system-admin-test}"
ADMIN_USER="admin-user"
DEPLOY_USER="deploy-user"

fail() {
  printf '\nFAIL: %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '  OK\n'
}

inventory_value() {
  local alias="$1"
  local key="$2"

  ansible-inventory \
    -i "${INVENTORY}" \
    --host "${alias}" |
    python3 -c "import json,sys; print(json.load(sys.stdin)['${key}'])"
}

remote_shell() {
  local group="$1"
  local command="$2"

  ansible "${group}" \
    -i "${INVENTORY}" \
    -b \
    -m shell \
    -a "${command}"
}

render() {
  local value="$1"
  value="${value//__PROJECT_DIR__/${PROJECT_DIR}}"
  value="${value//__WEB_HOST__/${WEB_HOST}}"
  value="${value//__SYSLOG_HOST__/${SYSLOG_HOST}}"
  printf '%s' "${value}"
}

WEB_HOST="$(inventory_value "${WEB_ALIAS}" ansible_host)"
SYSLOG_HOST="$(inventory_value "${SYSLOG_ALIAS}" ansible_host)"

printf 'Infrastructure smoke-check\n'
printf '  web-host:    %s (%s)\n' "${WEB_ALIAS}" "${WEB_HOST}"
printf '  syslog-host: %s (%s)\n\n' "${SYSLOG_ALIAS}" "${SYSLOG_HOST}"

# -----------------------------------------------------------------------------
echo "[1/9] Ansible connectivity"
# TZ: both managed hosts must be reachable from the Ansible Controller.
ansible all \
  -i "${INVENTORY}" \
  -m ping \
  >/dev/null || fail "Ansible cannot reach all managed hosts"
ok

# -----------------------------------------------------------------------------
echo "[2/9] Users, SSH hardening and Zero Trust firewall"
# TZ: admin-user/deploy-user, key-only SSH, root login disabled, default-deny firewall.
SECURITY_CMD=$(cat <<'REMOTE'
id admin-user >/dev/null &&
id deploy-user >/dev/null &&
test -s /home/admin-user/.ssh/authorized_keys &&
test -s /home/deploy-user/.ssh/authorized_keys &&
sshd -T | grep -qx 'passwordauthentication no' &&
sshd -T | grep -qx 'kbdinteractiveauthentication no' &&
sshd -T | grep -qx 'pubkeyauthentication yes' &&
sshd -T | grep -qx 'permitrootlogin no' &&
ufw status verbose | grep -Fq 'Status: active' &&
ufw status verbose | grep -Fq 'Default: deny (incoming)'
REMOTE
)
remote_shell all "${SECURITY_CMD}" >/dev/null \
  || fail "Users, SSH hardening or UFW baseline does not match the TZ"

# Successful login proves that both required users have working SSH-key access.
ansible all -i "${INVENTORY}" -u "${ADMIN_USER}" -m ping >/dev/null \
  || fail "${ADMIN_USER} cannot authenticate with an SSH key"
ansible all -i "${INVENTORY}" -u "${DEPLOY_USER}" -m ping >/dev/null \
  || fail "${DEPLOY_USER} cannot authenticate with an SSH key"

WEB_UFW_CMD=$(cat <<'REMOTE'
ufw status | python3 -c '
import sys
ports = {line.split()[0] for line in sys.stdin if "ALLOW" in line and "(v6)" not in line}
expected = {"22/tcp", "80/tcp", "443/tcp"}
assert ports == expected, (ports, expected)
'
REMOTE
)
remote_shell web "${WEB_UFW_CMD}" >/dev/null \
  || fail "web-host UFW has missing or unexpected inbound ALLOW rules"

SYSLOG_UFW_CMD=$(cat <<'REMOTE'
ufw status | python3 -c '
import sys
ports = {line.split()[0] for line in sys.stdin if "ALLOW" in line and "(v6)" not in line}
expected = {"22/tcp", "514/tcp"}
assert ports == expected, (ports, expected)
' &&
ufw status | awk '$1 == "514/tcp" && $2 ~ /^ALLOW/ && $0 !~ /\(v6\)/ {print}' | grep -Fq '__WEB_HOST__' &&
! ufw status | awk '$1 == "514/tcp" && $2 ~ /^ALLOW/ && $0 !~ /\(v6\)/ {print}' | grep -Fq 'Anywhere'
REMOTE
)
SYSLOG_UFW_CMD="$(render "${SYSLOG_UFW_CMD}")"
remote_shell syslog "${SYSLOG_UFW_CMD}" >/dev/null \
  || fail "syslog-host UFW does not restrict 514/tcp to web-host"
ok

# -----------------------------------------------------------------------------
echo "[3/9] Docker Compose topology and private networks"
# TZ: only Nginx is public; Apache and PostgreSQL are isolated in internal Docker networks.
TOPOLOGY_CMD=$(cat <<'REMOTE'
cd '__PROJECT_DIR__/deploy' &&
docker compose config >/dev/null &&
test -n "$(docker compose ps -q nginx)" &&
test -n "$(docker compose ps -q apache)" &&
test -n "$(docker compose ps -q postgres)" &&
test -n "$(docker compose ps -q rsyslog)" &&
docker inspect \
  "$(docker compose ps -q nginx)" \
  "$(docker compose ps -q apache)" \
  "$(docker compose ps -q postgres)" \
  "$(docker compose ps -q rsyslog)" |
python3 -c '
import json,sys
containers = json.load(sys.stdin)
by = {c["Config"]["Labels"]["com.docker.compose.service"]: c for c in containers}
required = {"nginx", "apache", "postgres", "rsyslog"}
assert required <= set(by), set(by)
assert all(by[s]["State"]["Running"] for s in required)
assert by["postgres"]["State"].get("Health", {}).get("Status") == "healthy"

bindings = lambda s: by[s]["HostConfig"].get("PortBindings") or {}
assert bindings("nginx").get("80/tcp")
assert bindings("nginx").get("443/tcp")
assert not bindings("apache").get("80/tcp")
assert not bindings("postgres").get("5432/tcp")
assert not bindings("rsyslog").get("1514/udp")

nets = lambda s: set(by[s]["NetworkSettings"]["Networks"])
assert len(nets("nginx")) == 2 and any(n.endswith("_app_net") for n in nets("nginx")) and any(n.endswith("_log_net") for n in nets("nginx"))
assert len(nets("apache")) == 2 and any(n.endswith("_app_net") for n in nets("apache")) and any(n.endswith("_db_net") for n in nets("apache"))
assert len(nets("postgres")) == 1 and next(iter(nets("postgres"))).endswith("_db_net")
assert len(nets("rsyslog")) == 1 and next(iter(nets("rsyslog"))).endswith("_log_net")
' &&
APP_NET="$(docker inspect "$(docker compose ps -q nginx)" | python3 -c 'import json,sys; n=json.load(sys.stdin)[0]["NetworkSettings"]["Networks"]; print(next(x for x in n if x.endswith("_app_net")))')" &&
DB_NET="$(docker inspect "$(docker compose ps -q postgres)" | python3 -c 'import json,sys; n=json.load(sys.stdin)[0]["NetworkSettings"]["Networks"]; print(next(x for x in n if x.endswith("_db_net")))')" &&
docker network inspect "$APP_NET" | python3 -c '
import json,sys
n=json.load(sys.stdin)[0]
assert n["Internal"] is True
names={v["Name"] for v in n.get("Containers",{}).values()}
assert len(names) == 2 and any("nginx" in x for x in names) and any("apache" in x for x in names), names
' &&
docker network inspect "$DB_NET" | python3 -c '
import json,sys
n=json.load(sys.stdin)[0]
assert n["Internal"] is True
names={v["Name"] for v in n.get("Containers",{}).values()}
assert len(names) == 2 and any("apache" in x for x in names) and any("postgres" in x for x in names), names
'
REMOTE
)
TOPOLOGY_CMD="$(render "${TOPOLOGY_CMD}")"
remote_shell web "${TOPOLOGY_CMD}" >/dev/null \
  || fail "Compose services, published ports or private network topology do not match the TZ/design"
ok

# -----------------------------------------------------------------------------
echo "[4/9] Nginx: 80/443, TLS, static cache and reverse proxy"
# TZ: Nginx accepts 80/443, terminates SSL, caches static files and proxies to Apache.
NGINX_CMD=$(cat <<'REMOTE'
cd '__PROJECT_DIR__/deploy' &&
docker compose exec -T nginx nginx -t >/dev/null &&
docker compose exec -T nginx nginx -T 2>/dev/null | grep -Fq 'proxy_pass http://apache:80;'
REMOTE
)
NGINX_CMD="$(render "${NGINX_CMD}")"
remote_shell web "${NGINX_CMD}" >/dev/null \
  || fail "Nginx configuration is invalid or reverse proxy to Apache is missing"

curl -fsS "http://${WEB_HOST}/" >/dev/null \
  || fail "Nginx does not serve HTTP on port 80"
curl -kfsS "https://${WEB_HOST}/" >/dev/null \
  || fail "Nginx does not terminate HTTPS on port 443"

CACHE_HEADERS="$(curl -kfsSI "https://${WEB_HOST}/static/health.css")" \
  || fail "Static resource is unavailable through Nginx"
grep -qi '^Cache-Control: public, max-age=3600' <<<"${CACHE_HEADERS}" \
  || fail "Static Cache-Control header is missing"
grep -qi '^Expires:' <<<"${CACHE_HEADERS}" \
  || fail "Static Expires header is missing"
ok

# -----------------------------------------------------------------------------
echo "[5/9] Apache and PHP 8.3+"
# TZ: Apache backend with PHP 8.3+; mod_rewrite/AllowOverride provide .htaccess support.
APACHE_CMD=$(cat <<'REMOTE'
cd '__PROJECT_DIR__/deploy' &&
docker compose exec -T apache apachectl configtest >/dev/null &&
docker compose exec -T apache apachectl -M | grep -q 'rewrite_module' &&
docker compose exec -T apache grep -Fq 'AllowOverride All' /etc/apache2/sites-enabled/000-default.conf &&
docker compose exec -T apache php -r 'exit(version_compare(PHP_VERSION, "8.3.0", ">=") ? 0 : 1);'
REMOTE
)
APACHE_CMD="$(render "${APACHE_CMD}")"
remote_shell web "${APACHE_CMD}" >/dev/null \
  || fail "Apache configuration, .htaccess support or PHP 8.3+ check failed"
ok

# -----------------------------------------------------------------------------
echo "[6/9] PostgreSQL 16+, app_db/app_user and private exposure"
# TZ: PostgreSQL 16+, app_db, password-protected app_user, private DB network only.
APP_JSON="$(curl -kfsS "https://${WEB_HOST}/")" \
  || fail "Application cannot reach PostgreSQL"
python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d.get("status") == "ok", d
assert d.get("database") == "app_db", d
assert d.get("db_health") == "postgres-ok", d
' <<<"${APP_JSON}" \
  || fail "Application did not confirm app_db access with configured PostgreSQL credentials"

POSTGRES_CMD=$(cat <<'REMOTE'
cd '__PROJECT_DIR__/deploy' &&
test "$(docker compose exec -T postgres psql -U app_user -d app_db -Atc 'SHOW server_version_num;')" -ge 160000 &&
test "$(docker compose exec -T postgres psql -U app_user -d app_db -Atc 'SELECT current_user || chr(124) || current_database();')" = 'app_user|app_db' &&
test "$(docker compose exec -T postgres psql -U app_user -d app_db -Atc 'SHOW config_file;')" = '/etc/postgresql/postgresql.conf' &&
test "$(docker compose exec -T postgres psql -U app_user -d app_db -Atc 'SHOW listen_addresses;')" = '*'
REMOTE
)
POSTGRES_CMD="$(render "${POSTGRES_CMD}")"
remote_shell web "${POSTGRES_CMD}" >/dev/null \
  || fail "PostgreSQL version, app_db/app_user or active postgresql.conf does not match the TZ/design"
# Network privacy and absence of host 5432 publication are asserted in [3/9].
ok

# -----------------------------------------------------------------------------
echo "[7/9] Nginx Syslog sender and persistent queue"
# TZ critical requirement: access_log uses Syslog facility and sender-side persistent queue.
SYSLOG_SENDER_CMD=$(cat <<'REMOTE'
cd '__PROJECT_DIR__/deploy' &&
docker compose exec -T nginx nginx -T 2>/dev/null | grep -Fq 'access_log syslog:server=rsyslog:1514' &&
docker compose exec -T nginx nginx -T 2>/dev/null | grep -Fq 'facility=local7' &&
docker compose exec -T rsyslog rsyslogd -N1 >/dev/null &&
docker inspect "$(docker compose ps -q rsyslog)" | python3 -c '
import json,sys
c=json.load(sys.stdin)[0]
assert any(m.get("Type") == "volume" and m.get("Destination") == "/var/spool/rsyslog" for m in c.get("Mounts",[])), c.get("Mounts",[])
' &&
grep -Fq 'workDirectory="/var/spool/rsyslog"' logging/rsyslog/rsyslog.conf &&
grep -Fq 'target="__SYSLOG_HOST__"' logging/rsyslog/rsyslog.conf &&
grep -Fq 'port="514"' logging/rsyslog/rsyslog.conf &&
grep -Fq 'protocol="tcp"' logging/rsyslog/rsyslog.conf &&
grep -Fq 'action.resumeRetryCount="-1"' logging/rsyslog/rsyslog.conf &&
grep -Fq 'queue.type="LinkedList"' logging/rsyslog/rsyslog.conf &&
grep -Fq 'queue.filename="remote_syslog"' logging/rsyslog/rsyslog.conf &&
grep -Fq 'queue.maxdiskspace="1g"' logging/rsyslog/rsyslog.conf &&
grep -Fq 'queue.saveonshutdown="on"' logging/rsyslog/rsyslog.conf
REMOTE
)
SYSLOG_SENDER_CMD="$(render "${SYSLOG_SENDER_CMD}")"
remote_shell web "${SYSLOG_SENDER_CMD}" >/dev/null \
  || fail "Nginx Syslog facility, remote target or persistent queue configuration is incomplete"
ok

# -----------------------------------------------------------------------------
echo "[8/9] Remote Syslog receiver"
# TZ: remote receiver accepts TCP/514 only from web-host and stores Nginx access logs.
SYSLOG_RECEIVER_CMD=$(cat <<'REMOTE'
systemctl is-active --quiet rsyslog &&
rsyslogd -N1 >/dev/null &&
ss -lnt | awk '$4 ~ /:514$/ {found=1} END {exit !found}' &&
grep -Fq 'module(load="imtcp")' /etc/rsyslog.d/10-remote-receiver.conf &&
grep -Fq 'port="514"' /etc/rsyslog.d/10-remote-receiver.conf &&
grep -Fq '$syslogfacility-text == "local7"' /etc/rsyslog.d/10-remote-receiver.conf &&
grep -Fq 'file="/var/log/remote-nginx-access.log"' /etc/rsyslog.d/10-remote-receiver.conf &&
ufw status | awk '$1 == "514/tcp" && $2 ~ /^ALLOW/ && $0 !~ /\(v6\)/ {print}' | grep -Fq '__WEB_HOST__'
REMOTE
)
SYSLOG_RECEIVER_CMD="$(render "${SYSLOG_RECEIVER_CMD}")"
remote_shell syslog "${SYSLOG_RECEIVER_CMD}" >/dev/null \
  || fail "Remote rsyslog receiver, facility, destination file or firewall source is incorrect"
ok

# -----------------------------------------------------------------------------
echo "[9/9] End-to-end Nginx access log"
# TZ: prove Nginx -> local rsyslog -> TCP/514 -> remote syslog-host.
LOG_TOKEN="smoke-$(date +%s)-$$"
curl -kfsS "https://${WEB_HOST}/?smoke=${LOG_TOKEN}" >/dev/null \
  || fail "Could not generate HTTPS request for Syslog end-to-end check"

FOUND=0
for _ in {1..10}; do
  if remote_shell syslog "grep -Fq '${LOG_TOKEN}' /var/log/remote-nginx-access.log" >/dev/null 2>&1; then
    FOUND=1
    break
  fi
  sleep 1
done

[[ "${FOUND}" -eq 1 ]] \
  || fail "Nginx access_log did not reach /var/log/remote-nginx-access.log on syslog-host"
ok

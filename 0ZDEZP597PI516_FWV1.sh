#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

echo "[netfw v1] Installing base networking, security, and runtime packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  jq \
  python3 \
  iproute2 \
  iptables \
  nftables \
  bridge-utils \
  dnsmasq \
  nginx \
  libnginx-mod-http-modsecurity \
  modsecurity-crs \
  suricata \
  ipvsadm \
  ca-certificates

mkdir -p \
  /etc/netfw \
  /usr/local/lib/netfw \
  /var/lib/netfw \
  /var/lib/netfw/web \
  /var/log/netfw

# Blank initial configuration: no preconfigured interfaces, subnets, or active features
if [[ ! -f /etc/netfw/config.json ]]; then
  cat <<'EOF' > /etc/netfw/config.json
{
  "version": "1.2.0",
  "interfaces": {
    "mgmt": [],
    "wan": "",
    "lan": [],
    "lan_ip": "",
    "lan_subnet": ""
  },
  "features": {
    "router": false,
    "switch": false,
    "ngfw": false,
    "dhcp": false,
    "dns": false,
    "l4_lb": false,
    "app_gw_afw_l7_lb": false,
    "web_ui": false
  },
  "ngfw": {
    "ssh_allow_cidrs": [],
    "suricata_enabled": false
  },
  "dhcp": {
    "range_start": "",
    "range_end": "",
    "lease_time": ""
  },
  "dns": {
    "listen_ip": "",
    "upstream_dns": []
  },
  "l4_lb": {
    "vip": "",
    "port": null,
    "protocol": "",
    "scheduler": "",
    "backends": []
  },
  "app_gw_afw_l7_lb": {
    "listen_port": null,
    "waf_enabled": false,
    "backends": []
  },
  "web_ui": {
    "bind_ip": "",
    "port": null,
    "web_dir": ""
  }
}
EOF
  chmod 0640 /etc/netfw/config.json
fi

cat <<'EOF' > /usr/local/lib/netfw/apply.py
#!/usr/bin/env python3
import json
import os
import subprocess
import sys

CFG_PATH = "/etc/netfw/config.json"
NFT_PATH = "/etc/nftables.conf"
DNSMASQ_CONF = "/etc/dnsmasq.d/netfw.conf"
NGINX_CONF = "/etc/nginx/conf.d/netfw.conf"
MODSEC_MAIN = "/etc/nginx/modsec/netfw-modsecurity.conf"


def run(cmd, check=True):
    return subprocess.run(cmd, text=True, capture_output=True, check=check)


def load_config():
    with open(CFG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def set_sysctl(key, val):
    path = "/proc/sys/" + key.replace(".", "/")
    if os.path.exists(path):
        with open(path, "w", encoding="utf-8") as f:
            f.write(str(val) + "\n")


def configure_switch_and_ip(cfg):
    iface_cfg = cfg.get("interfaces", {})
    mgmt_set = {m for m in iface_cfg.get("mgmt", []) if m}
    wan = iface_cfg.get("wan", "") or ""
    lan_ifs = [i for i in iface_cfg.get("lan", []) if i and i != wan and i not in mgmt_set]
    features = cfg.get("features", {})

    for m_if in mgmt_set:
        run(["ip", "link", "set", m_if, "nomaster"], check=False)
        run(["ip", "link", "set", m_if, "up"], check=False)

    if wan and wan not in mgmt_set:
        run(["ip", "link", "set", wan, "nomaster"], check=False)
        run(["ip", "link", "set", wan, "up"], check=False)

    br_exists = subprocess.run(["ip", "link", "show", "br0"], capture_output=True).returncode == 0
    if not features.get("switch") and br_exists:
        for nic in lan_ifs:
            run(["ip", "link", "set", nic, "nomaster"], check=False)
        run(["ip", "link", "set", "br0", "down"], check=False)
        run(["ip", "link", "del", "br0"], check=False)

    if features.get("switch") and lan_ifs:
        if not br_exists:
            run(["ip", "link", "add", "name", "br0", "type", "bridge"])
        run(["ip", "link", "set", "br0", "up"])
        for nic in lan_ifs:
            run(["ip", "link", "set", nic, "up"], check=False)
            run(["ip", "link", "set", nic, "master", "br0"], check=False)
        target_if = "br0"
    else:
        target_if = lan_ifs[0] if lan_ifs else (wan if wan and wan not in mgmt_set else "")
        for nic in lan_ifs:
            run(["ip", "link", "set", nic, "up"], check=False)

    lan_ip = iface_cfg.get("lan_ip", "") or ""
    if target_if and lan_ip and (features.get("router") or features.get("dhcp") or features.get("dns")):
        ip_only = lan_ip.split("/")[0]
        existing = run(["ip", "-4", "addr", "show", "dev", target_if], check=False).stdout
        if ip_only not in existing:
            run(["ip", "addr", "flush", "dev", target_if], check=False)
            run(["ip", "addr", "add", lan_ip, "dev", target_if], check=False)

    return target_if


def configure_nftables(cfg, lan_target_if):
    iface_cfg = cfg.get("interfaces", {})
    mgmt_ifs = [m for m in iface_cfg.get("mgmt", []) if m]
    wan = iface_cfg.get("wan", "") or ""
    subnet = iface_cfg.get("lan_subnet", "") or ""
    f = cfg.get("features", {})

    router_on = bool(f.get("router"))
    ngfw_on = bool(f.get("ngfw"))
    l4_on = bool(f.get("l4_lb"))
    web_on = bool(f.get("web_ui"))
    web_port = cfg.get("web_ui", {}).get("port")

    set_sysctl("net.ipv4.ip_forward", 1 if (router_on or l4_on) else 0)

    policy_input = "drop" if ngfw_on else "accept"
    policy_forward = "drop" if ngfw_on else "accept"

    ssh_cidrs = [c for c in cfg.get("ngfw", {}).get("ssh_allow_cidrs", []) if c]
    ssh_rules = "\n".join(
        f"    ip saddr {cidr} tcp dport 22 accept" for cidr in ssh_cidrs
    )

    lines = [
        "#!/usr/sbin/nft -f",
        "flush ruleset",
        "",
        "table inet netfw_filter {",
        "  chain input {",
        f"    type filter hook input priority filter; policy {policy_input};",
        "    iif lo accept",
        "    ct state established,related accept",
        "    ip protocol icmp accept",
        "    ipv6 nexthdr icmpv6 accept",
    ]

    for m_if in mgmt_ifs:
        lines.append(f'    iifname "{m_if}" tcp dport 22 accept')
        if web_on and web_port:
            lines.append(f'    iifname "{m_if}" tcp dport {int(web_port)} accept')

    if ngfw_on:
        if ssh_rules:
            lines.append(ssh_rules)
        if lan_target_if:
            lines.append(f'    iifname "{lan_target_if}" accept')
        lines.append("    counter drop")

    lines.extend([
        "  }",
        "",
        "  chain forward {",
        f"    type filter hook forward priority filter; policy {policy_forward};",
        "    ct state established,related accept",
    ])

    for m_if in mgmt_ifs:
        lines.append(f'    iifname "{m_if}" drop')
        lines.append(f'    oifname "{m_if}" drop')

    if router_on and lan_target_if and wan and wan not in mgmt_ifs:
        lines.append(f'    iifname "{lan_target_if}" oifname "{wan}" accept')
        if ngfw_on:
            lines.append("    counter drop")
    elif ngfw_on:
        lines.append("    counter drop")

    lines.extend([
        "  }",
        "}",
        "",
        "table ip netfw_nat {",
        "  chain prerouting {",
        "    type nat hook prerouting priority dstnat; policy accept;",
    ])

    if l4_on:
        l4 = cfg.get("l4_lb", {})
        vip = l4.get("vip") or ""
        port = l4.get("port")
        proto = l4.get("protocol") or ""
        backends = [b for b in l4.get("backends", []) if b]
        if vip and port and proto and backends:
            if len(backends) == 1:
                lines.append(
                    f"    ip daddr {vip} {proto} dport {int(port)} dnat to {backends[0]}"
                )
            else:
                count = len(backends)
                for idx, be in enumerate(backends):
                    lines.append(
                        f"    ip daddr {vip} {proto} dport {int(port)} numgen inc mod {count} == {idx} dnat to {be}"
                    )

    lines.extend([
        "  }",
        "",
        "  chain postrouting {",
        "    type nat hook postrouting priority srcnat; policy accept;",
    ])

    if router_on and subnet and wan and wan not in mgmt_ifs:
        lines.append(f'    ip saddr {subnet} oifname "{wan}" masquerade')
    if l4_on:
        lines.append("    masquerade")

    lines.extend([
        "  }",
        "}",
    ])

    with open(NFT_PATH, "w", encoding="utf-8") as f_out:
        f_out.write("\n".join(lines) + "\n")

    run(["nft", "-f", NFT_PATH])


def configure_dnsmasq(cfg, lan_target_if):
    dhcp_on = bool(cfg.get("features", {}).get("dhcp"))
    dns_on = bool(cfg.get("features", {}).get("dns"))
    lan_ip = (cfg.get("interfaces", {}).get("lan_ip") or "").split("/")[0]

    if not lan_target_if or not lan_ip or (not dhcp_on and not dns_on):
        if os.path.exists(DNSMASQ_CONF):
            os.remove(DNSMASQ_CONF)
        run(["systemctl", "stop", "dnsmasq"], check=False)
        return

    lines = [
        f"interface={lan_target_if}",
        "bind-interfaces",
    ]

    if dns_on:
        dns_cfg = cfg.get("dns", {})
        listen_ip = dns_cfg.get("listen_ip") or lan_ip
        upstreams = [ns for ns in dns_cfg.get("upstream_dns", []) if ns]
        lines.append(f"listen-address={listen_ip}")
        if upstreams:
            lines.append("no-resolv")
            for ns in upstreams:
                lines.append(f"server={ns}")
    else:
        lines.append("port=0")

    if dhcp_on:
        dhcp_cfg = cfg.get("dhcp", {})
        start = dhcp_cfg.get("range_start") or ""
        end = dhcp_cfg.get("range_end") or ""
        lease = dhcp_cfg.get("lease_time") or ""
        if start and end:
            range_line = f"dhcp-range={start},{end}" + (f",{lease}" if lease else "")
            lines.append(range_line)
            lines.append(f"dhcp-option=option:router,{lan_ip}")
            lines.append(f"dhcp-option=option:dns-server,{lan_ip}")
    else:
        lines.append("no-dhcp-interface=" + lan_target_if)

    with open(DNSMASQ_CONF, "w", encoding="utf-8") as f_out:
        f_out.write("\n".join(lines) + "\n")

    run(["systemctl", "restart", "dnsmasq"])


def configure_suricata(cfg):
    ngfw_on = bool(cfg.get("features", {}).get("ngfw"))
    suricata_on = ngfw_on and bool(cfg.get("ngfw", {}).get("suricata_enabled"))
    if suricata_on:
        run(["systemctl", "enable", "--now", "suricata"], check=False)
    else:
        run(["systemctl", "stop", "suricata"], check=False)


def configure_ipvs(cfg):
    l4_on = bool(cfg.get("features", {}).get("l4_lb"))
    run(["ipvsadm", "-C"], check=False)
    if not l4_on:
        return
    l4 = cfg.get("l4_lb", {})
    vip = l4.get("vip") or ""
    port = l4.get("port")
    sched = l4.get("scheduler") or ""
    backends = [b for b in l4.get("backends", []) if b]
    if vip and port and sched and backends:
        run(["ipvsadm", "-A", "-t", f"{vip}:{int(port)}", "-s", sched], check=False)
        for be in backends:
            run(["ipvsadm", "-a", "-t", f"{vip}:{int(port)}", "-r", be, "-m"], check=False)


def configure_app_gw_l7(cfg):
    l7_on = bool(cfg.get("features", {}).get("app_gw_afw_l7_lb"))
    l7 = cfg.get("app_gw_afw_l7_lb", {})
    port = l7.get("listen_port")
    if not l7_on or not port:
        if os.path.exists(NGINX_CONF):
            os.remove(NGINX_CONF)
        run(["systemctl", "stop", "nginx"], check=False)
        return

    waf_on = bool(l7.get("waf_enabled"))
    backends = [b for b in l7.get("backends", []) if b]

    os.makedirs("/etc/nginx/modsec", exist_ok=True)
    if waf_on and not os.path.exists(MODSEC_MAIN):
        crs_setup = "/usr/share/modsecurity-crs/crs-setup.conf.example"
        crs_rules = "/usr/share/modsecurity-crs/rules/*.conf"
        modsec_lines = [
            "SecRuleEngine On",
            "SecRequestBodyAccess On",
            "SecResponseBodyAccess Off",
            "SecAuditEngine RelevantOnly",
            "SecAuditLog /var/log/netfw/modsec_audit.log",
        ]
        if os.path.exists(crs_setup):
            modsec_lines.append(f"Include {crs_setup}")
        modsec_lines.append(f"Include {crs_rules}")
        with open(MODSEC_MAIN, "w", encoding="utf-8") as mf:
            mf.write("\n".join(modsec_lines) + "\n")

    upstream_servers = "\n".join(f"    server {b};" for b in backends) if backends else "    server 127.0.0.1:8081 down;"
    waf_block = "    modsecurity on;\n    modsecurity_rules_file /etc/nginx/modsec/netfw-modsecurity.conf;" if waf_on else ""

    nginx_lines = [
        "upstream netfw_l7_pool {",
        upstream_servers,
        "}",
        "",
        "server {",
        f"    listen {int(port)};",
        waf_block,
        "    location / {",
        "        proxy_pass http://netfw_l7_pool;",
        "        proxy_set_header Host $host;",
        "        proxy_set_header X-Real-IP $remote_addr;",
        "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
        "    }",
        "}",
    ]

    with open(NGINX_CONF, "w", encoding="utf-8") as nf:
        nf.write("\n".join(nginx_lines) + "\n")

    run(["nginx", "-t"])
    run(["systemctl", "restart", "nginx"])


def configure_web_ui(cfg):
    web_on = bool(cfg.get("features", {}).get("web_ui"))
    web_cfg = cfg.get("web_ui", {})
    if web_on and web_cfg.get("bind_ip") and web_cfg.get("port"):
        run(["systemctl", "restart", "netfw-web.service"], check=False)
    else:
        run(["systemctl", "stop", "netfw-web.service"], check=False)


def main():
    if not os.path.exists(CFG_PATH):
        print(f"Missing config at {CFG_PATH}", file=sys.stderr)
        sys.exit(1)
    cfg = load_config()
    lan_target_if = configure_switch_and_ip(cfg)
    configure_nftables(cfg, lan_target_if)
    configure_dnsmasq(cfg, lan_target_if)
    configure_suricata(cfg)
    configure_ipvs(cfg)
    configure_app_gw_l7(cfg)
    configure_web_ui(cfg)
    print(f"[netfw] Applied v{cfg.get('version', '1.2.0')} (LAN target: {lan_target_if or 'none'})")


if __name__ == "__main__":
    main()
EOF
chmod 0755 /usr/local/lib/netfw/apply.py

cat <<'EOF' > /usr/local/lib/netfw/web_server.py
#!/usr/bin/env python3
import http.server
import json
import mimetypes
import os
import subprocess
import sys
import threading
from urllib.parse import urlparse

CFG_PATH = "/etc/netfw/config.json"
LOCK = threading.Lock()


def read_cfg():
    with open(CFG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def write_cfg(data):
    tmp = CFG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o640)
    os.replace(tmp, CFG_PATH)


def set_by_path(obj, dot_path, val):
    parts = [p for p in dot_path.lstrip(".").split(".") if p]
    if not parts:
        raise ValueError("Empty path")
    cur = obj
    for key in parts[:-1]:
        if not isinstance(cur, dict) or key not in cur:
            raise KeyError(f"Unknown key: {key}")
        cur = cur[key]
    last = parts[-1]
    if not isinstance(cur, dict) or last not in cur:
        raise KeyError(f"Unknown key: {last}")
    cur[last] = val


class Handler(http.server.BaseHTTPRequestHandler):
    def _send_json(self, code, payload):
        raw = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _read_body_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        return json.loads(raw.decode("utf-8"))

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        with LOCK:
            cfg = read_cfg()

        if path == "/api/status":
            self._send_json(200, {
                "version": cfg.get("version"),
                "interfaces": cfg.get("interfaces"),
                "features": cfg.get("features"),
            })
            return

        if path == "/api/config":
            self._send_json(200, cfg)
            return

        web_dir = cfg.get("web_ui", {}).get("web_dir") or ""
        if not web_dir:
            self._send_json(404, {"error": "web_ui.web_dir is not configured"})
            return

        rel = "index.html" if path == "/" else path.lstrip("/")
        base_abs = os.path.realpath(web_dir)
        target_abs = os.path.realpath(os.path.join(base_abs, rel))

        if not target_abs.startswith(base_abs + os.sep) and target_abs != base_abs:
            self._send_json(403, {"error": "Forbidden path"})
            return

        if os.path.isdir(target_abs):
            target_abs = os.path.join(target_abs, "index.html")

        if not os.path.isfile(target_abs):
            self._send_json(404, {"error": "File not found in web_dir"})
            return

        ctype, _ = mimetypes.guess_type(target_abs)
        if not ctype:
            ctype = "application/octet-stream"

        with open(target_abs, "rb") as f:
            content = f.read()

        self.send_response(200)
        self.send_header("Content-Type", f"{ctype}; charset=utf-8" if ctype.startswith("text/") or ctype == "application/javascript" else ctype)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            body = self._read_body_json()
        except Exception as exc:
            self._send_json(400, {"error": f"Invalid JSON: {exc}"})
            return

        with LOCK:
            cfg = read_cfg()
            features = cfg.get("features", {})

            if path == "/api/enable":
                feat = body.get("feature")
                if feat == "all":
                    for k in features:
                        features[k] = True
                elif feat in features:
                    features[feat] = True
                else:
                    self._send_json(400, {"error": f"Unknown feature: {feat}"})
                    return
                write_cfg(cfg)
                self._send_json(200, {"features": features})
                return

            if path == "/api/disable":
                feat = body.get("feature")
                if feat == "all":
                    for k in features:
                        features[k] = False
                elif feat in features:
                    features[feat] = False
                else:
                    self._send_json(400, {"error": f"Unknown feature: {feat}"})
                    return
                write_cfg(cfg)
                self._send_json(200, {"features": features})
                return

            if path == "/api/set":
                dot_path = body.get("path", "")
                value = body.get("value")
                try:
                    set_by_path(cfg, dot_path, value)
                except Exception as exc:
                    self._send_json(400, {"error": str(exc)})
                    return
                write_cfg(cfg)
                self._send_json(200, {"updated": dot_path, "value": value})
                return

            if path == "/api/apply":
                res = subprocess.run(["/usr/local/bin/netfw", "apply"], text=True, capture_output=True)
                self._send_json(
                    200 if res.returncode == 0 else 500,
                    {"returncode": res.returncode, "stdout": res.stdout, "stderr": res.stderr},
                )
                return

        self._send_json(404, {"error": "Unknown endpoint"})

    def log_message(self, fmt, *args):
        return


def main():
    cfg = read_cfg()
    web_cfg = cfg.get("web_ui", {})
    bind_ip = web_cfg.get("bind_ip") or ""
    port = web_cfg.get("port")
    if not bind_ip or not port:
        print("web_ui.bind_ip and web_ui.port must be configured before starting web server", file=sys.stderr)
        sys.exit(1)
    web_dir = web_cfg.get("web_dir") or ""
    if web_dir:
        os.makedirs(web_dir, exist_ok=True)
    server = http.server.ThreadingHTTPServer((bind_ip, int(port)), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
EOF
chmod 0755 /usr/local/lib/netfw/web_server.py

cat <<'EOF' > /usr/local/bin/netfw
#!/usr/bin/env bash
set -euo pipefail

CFG="/etc/netfw/config.json"
APPLY="/usr/local/lib/netfw/apply.py"

VALID_FEATURES=(
  "router"
  "switch"
  "ngfw"
  "dhcp"
  "dns"
  "l4_lb"
  "app_gw_afw_l7_lb"
  "web_ui"
)

usage() {
  cat <<'USAGE'
Usage:
  netfw status                         Show configured interfaces and features
  netfw enable <feature|all>           Enable a feature (or 'all') in config.json
  netfw disable <feature|all>          Disable a feature (or 'all') in config.json
  netfw set <jq_path> <json_or_val>    Set a config field (e.g., netfw set .interfaces.wan eth1)
  netfw show                           Print full /etc/netfw/config.json
  netfw apply                          Apply config.json to kernel, firewall, DNS/DHCP, L4/L7, Web API

Features:
  router            IPv4 routing + NAT masquerade
  switch            Layer 2 bridge (br0) across LAN ports
  ngfw              Stateful nftables drop-by-default firewall + Suricata IDS/IPS
  dhcp              DHCP server (dnsmasq)
  dns               DNS forwarder/resolver (dnsmasq)
  l4_lb             Layer 4 load balancer / DNAT + IPVS
  app_gw_afw_l7_lb  L7 reverse proxy + Application Gateway + ModSecurity WAF
  web_ui            JSON API + external web_dir file server
USAGE
}

is_valid_feature() {
  local target="$1"
  for f in "${VALID_FEATURES[@]}"; do
    [[ "$f" == "$target" ]] && return 0
  done
  return 1
}

update_feature() {
  local state="$1"
  local feat="$2"
  local tmp
  tmp="$(mktemp)"

  if [[ "$feat" == "all" ]]; then
    jq --argjson val "$state" '.features |= with_entries(.value = $val)' "$CFG" > "$tmp"
  else
    if ! is_valid_feature "$feat"; then
      rm -f "$tmp"
      echo "Unknown feature: $feat" >&2
      exit 1
    fi
    jq --arg k "$feat" --argjson val "$state" '.features[$k] = $val' "$CFG" > "$tmp"
  fi
  mv "$tmp" "$CFG"
  chmod 0640 "$CFG"
  echo "Set feature '$feat' -> $state"
}

cmd="${1:-status}"
case "$cmd" in
  status)
    echo "=== Interfaces ==="
    jq -r '.interfaces | "Mgmt: \(.mgmt | join(", ")) | WAN: \(.wan) | LAN: \(.lan | join(", ")) | LAN IP: \(.lan_ip) | Subnet: \(.lan_subnet)"' "$CFG"
    echo "=== Features ==="
    jq -r '.features | to_entries[] | "  \(.key): \(.value)"' "$CFG"
    ;;
  enable)
    [[ $# -lt 2 ]] && { usage; exit 1; }
    update_feature true "$2"
    ;;
  disable)
    [[ $# -lt 2 ]] && { usage; exit 1; }
    update_feature false "$2"
    ;;
  set)
    [[ $# -lt 3 ]] && { usage; exit 1; }
    path="$2"
    raw_val="$3"
    tmp="$(mktemp)"
    if jq -e . >/dev/null 2>&1 <<<"$raw_val"; then
      jq --argjson v "$raw_val" "$path = \$v" "$CFG" > "$tmp"
    else
      jq --arg v "$raw_val" "$path = \$v" "$CFG" > "$tmp"
    fi
    mv "$tmp" "$CFG"
    chmod 0640 "$CFG"
    echo "Updated $path"
    ;;
  show)
    jq . "$CFG"
    ;;
  apply)
    python3 "$APPLY"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
EOF
chmod 0755 /usr/local/bin/netfw

cat <<'EOF' > /etc/systemd/system/netfw-web.service
[Unit]
Description=Pi 5 Modular Network Firmware Web API & File Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/lib/netfw/web_server.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' > /etc/systemd/system/netfw.service
[Unit]
Description=Pi 5 Modular Network Firmware v1
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/netfw apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable netfw.service
echo "[netfw v1.2] Installation complete with blank initial config. Configure via 'netfw' CLI or web API."

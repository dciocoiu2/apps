$dirs = @("core", "dataplane", "mgmt")
foreach ($d in $dirs) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }

Set-Content core/types.py @'
from ipaddress import IPv4Address, IPv4Network
from dataclasses import dataclass, field
from typing import Optional, Dict, List

@dataclass
class Interface:
    name: str
    ip: IPv4Address
    network: IPv4Network
    mac: Optional[str] = None
    mtu: int = 1500
    up: bool = True
    driver: str = "emu"
    device: Optional[str] = None

@dataclass
class Route:
    prefix: IPv4Network
    next_hop: Optional[IPv4Address]
    out_iface: str
    metric: int = 10

@dataclass
class NATRule:
    src_net: Optional[IPv4Network] = None
    dst_net: Optional[IPv4Network] = None
    out_iface: Optional[str] = None
    static_map: Optional[Dict[str, str]] = None

@dataclass
class ACLRule:
    action: str
    src: IPv4Network
    dst: IPv4Network
    proto: Optional[str] = None
    sport: Optional[int] = None
    dport: Optional[int] = None

@dataclass
class Config:
    hostname: str = "pyrouter"
    interfaces: Dict[str, Interface] = field(default_factory=dict)
    routes: List[Route] = field(default_factory=list)
    nat: List[NATRule] = field(default_factory=list)
    acl_in: Dict[str, List[ACLRule]] = field(default_factory=dict)
    acl_out: Dict[str, List[ACLRule]] = field(default_factory=dict)
    log_path: str = "audit.jsonl"
'@

Set-Content core/fib.py @'
from ipaddress import IPv4Address
from typing import Optional, List
from core.types import Route

class FIB:
    def __init__(self, routes: List[Route]):
        self.routes = routes

    def lookup(self, dst: IPv4Address) -> Optional[Route]:
        c = [r for r in self.routes if dst in r.prefix]
        return sorted(c, key=lambda r: r.prefix.prefixlen, reverse=True)[0] if c else None
'@

Set-Content core/neighbor.py @'
import time
from typing import Dict, Optional

class ARPCache:
    def __init__(self, ttl=300):
        self.ttl = ttl
        self.cache: Dict[str, tuple[str, float]] = {}

    def get(self, ip: str) -> Optional[str]:
        v = self.cache.get(ip)
        if not v: return None
        mac, exp = v
        if exp < time.time():
            self.cache.pop(ip, None)
            return None
        return mac

    def put(self, ip: str, mac: str):
        self.cache[ip] = (mac, time.time() + self.ttl)
'@

Set-Content core/icmp.py @'
from scapy.all import IP, ICMP, send

def send_ttl_exceeded(src_ip: str, dst_ip: str, original_ip_pkt: bytes):
    pkt = IP(src=dst_ip, dst=src_ip)/ICMP(type=11, code=0)/original_ip_pkt[:28]
    send(pkt, verbose=False)

def send_dest_unreach(src_ip: str, dst_ip: str, original_ip_pkt: bytes):
    pkt = IP(src=dst_ip, dst=src_ip)/ICMP(type=3, code=0)/original_ip_pkt[:28]
    send(pkt, verbose=False)
'@

Set-Content core/policy.py @'
from scapy.layers.inet import IP, TCP, UDP, ICMP
from core.types import ACLRule, NATRule, Interface
from typing import List

def acl_permit(pkt, rules: List[ACLRule]) -> bool:
    ip = pkt.getlayer(IP)
    for r in rules:
        if ip.src in r.src and ip.dst in r.dst:
            if r.proto:
                if r.proto == "icmp" and ip.getlayer(ICMP) is None: continue
                if r.proto == "tcp" and ip.getlayer(TCP) is None: continue
                if r.proto == "udp" and ip.getlayer(UDP) is None: continue
            return r.action == "permit"
    return True

def apply_snat(pkt, rule: NATRule, out_if: Interface):
    ip = pkt.getlayer(IP)
    if rule.out_iface and rule.out_iface != out_if.name: return pkt
    if rule.src_net and (ip.src not in rule.src_net): return pkt
    ip.src = str(out_if.ip)
    return pkt
'@

Set-Content dataplane/emu.py @'
import asyncio
from scapy.all import IP, Ether
from core.fib import FIB
from core.types import Config
from core.policy import acl_permit, apply_snat
from core.neighbor import ARPCache
from core.icmp import send_ttl_exceeded, send_dest_unreach

class EmuPort:
    def __init__(self, name: str):
        self.name = name
        self.rx = asyncio.Queue()
        self.tx_peers: list[EmuPort] = []

    def connect(self, peer: "EmuPort"):
        self.tx_peers.append(peer)

    async def send(self, pkt):
        for p in self.tx_peers:
            await p.rx.put(pkt)

async def run_emulator(cfg: Config, ports: dict[str, EmuPort]):
    fib = FIB(cfg.routes)
    arp = ARPCache()
    while True:
        tasks = [asyncio.create_task(ports[i.name].rx.get()) for i in cfg.interfaces.values() if i.up]
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for p in pending: p.cancel()
        for d in done:
            raw = d.result()
            ip = raw.getlayer(IP)
            route = fib.lookup(ip.dst)
            if not route:
                send_dest_unreach(ip.src, ip.dst, bytes(raw))
                continue
            out_if = cfg.interfaces[route.out_iface]
            if not acl_permit(ip, []): continue
            for n in cfg.nat: ip = apply_snat(ip, n, out_if)
            if ip.ttl <= 1:
                send_ttl_exceeded(ip.src, ip.dst, bytes(raw))
                continue
            ip.ttl -= 1
            eth = Ether(dst="00:00:00:00:00:01")/ip
            await ports[out_if.name].send(eth)
'@

Set-Content dataplane/pcap.py @'
import asyncio
from scapy.all import sniff, sendp, Ether, IP, get_working_ifaces
from core.fib import FIB
from core.types import Config, Interface
from core.policy import acl_permit, apply_snat
from core.neighbor import ARPCache
from core.icmp import send_ttl_exceeded, send_dest_unreach
import threading

def start_sniffer(iface: Interface, q: asyncio.Queue, loop):
    def handler(pkt):
        if pkt.haslayer(IP):
            asyncio.run_coroutine_threadsafe(q.put(pkt), loop)
    sniff(store=False, prn=handler, iface=iface.device or iface.name)

async def run_pcap(cfg: Config):
    fib = FIB(cfg.routes)
    arp = ARPCache()
    queues: dict[str, asyncio.Queue] = {i.name: asyncio.Queue() for i in cfg.interfaces.values() if i.up}
    loop = asyncio.get_event_loop()
    threads = []
    for i in cfg.interfaces.values():
        t = threading.Thread(target=start_sniffer, args=(i, queues[i.name], loop), daemon=True)
        t.start()
        threads.append(t)
    while True:
        tasks = [asyncio.create_task(queues[i.name].get()) for i in cfg.interfaces.values() if i.up]
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for p in pending: p.cancel()
        for d in done:
            pkt = d.result()
            ip = pkt.getlayer(IP)
            route = fib.lookup(ip.dst)
            if not route:
                send_dest_unreach(ip.src, ip.dst, bytes(pkt))
                continue
            out_if = cfg.interfaces[route.out_iface]
            in_acl = cfg.acl_in.get(route.out_iface, [])
            out_acl = cfg.acl_out.get(route.out_iface, [])
            if not acl_permit(ip, in_acl): continue
            for n in cfg.nat: ip = apply_snat(ip, n, out_if)
            if not acl_permit(ip, out_acl): continue
            if ip.ttl <= 1:
                send_ttl_exceeded(ip.src, ip.dst, bytes(pkt))
                continue
            ip.ttl -= 1
            eth = Ether(dst="ff:ff:ff:ff:ff:ff")/ip
            sendp(eth, iface=out_if.device or out_if.name, verbose=False)
'@

Set-Content mgmt/cli.py @'
import cmd
from ipaddress import IPv4Network, IPv4Address
from core.types import Config, Interface, Route, ACLRule, NATRule
import json, time

class IOSCli(cmd.Cmd):
    intro = "Welcome to pyrouter. Type ? or help."
    prompt = "pyrouter# "

    def __init__(self, cfg: Config):
        super().__init__()
        self.cfg = cfg
        self.config_mode = False

    def audit(self, action: str, detail: dict):
        with open(self.cfg.log_path, "a") as f:
            f.write(json.dumps({"ts": time.time(), "action": action, "detail": detail})+"\n")

    def do_enable(self, arg):
        self.prompt = "pyrouter(config)# "
        self.config_mode = True

    def do_exit(self, arg): return True

    def do_show(self, arg):
        if arg == "ip route":
            for r in self.cfg.routes:
                print(f"{r.prefix} via {r.next_hop or 'connected'} dev {r.out_iface} metric {r.metric}")
        elif arg == "interfaces":
            for i in self.cfg.interfaces.values():
                print(f"{i.name} {i.ip}/{i.network.prefixlen} driver={i.driver} dev={i.device or i.name} up={i.up}")

    def do_interface(self, arg):
        if not self.config_mode: print("Enter config mode (enable)"); return
        parts = arg.split()
        if len(parts) < 2: print("usage: interface <name> <cidr> [driver=pcap|emu] [device=DEV]"); return
        name, cidr = parts[0], parts[1]
        kv = dict(p.split("=",1) for p in parts[2:] if "=" in p)
        drv = kv.get("driver","emu")
        dev = kv.get("device")
        net = IPv4Network(cidr, strict=False)
        ip = list(net.hosts())[0]
        self.cfg.interfaces[name] = Interface(name=name, ip=ip, network=net, driver=drv, device=dev)
        self.audit("interface", {"name": name, "cidr": cidr, "driver": drv, "device": dev})
        print(f"Configured {name} {ip}/{net.prefixlen} driver={drv} dev={dev or name}")

    def do_ip(self, arg):
        if not self.config_mode: print("Enter config mode"); return
        parts = arg.split()
        if parts[:2] == ["route", "add"]:
            prefix = IPv4Network(parts[2])
            nh = None if parts[3] == "connected" else IPv4Address(parts[3])
            iface = parts[4]
            self.cfg.routes.append(Route(prefix=prefix, next_hop=nh, out_iface=iface))
            self.audit("route_add", {"prefix": str(prefix), "next_hop": str(nh) if nh else None, "out_iface": iface})
            print(f"Added route {prefix} via {nh or 'connected'} dev {iface}")

    def do_acl(self, arg):
        if not self.config_mode: print("Enter config mode"); return
        p = arg.split()
        if len(p) < 6: print("usage: acl in|out <iface> permit|deny <src> <dst> [proto]"); return
        direction, iface, action, src, dst = p[:5]
        proto = p[5] if len(p) > 5 else None
        rule = ACLRule(action=action, src=IPv4Network(src), dst=IPv4Network(dst), proto=proto)
        if direction == "in": self.cfg.acl_in.setdefault(iface, []).append(rule)
        else: self.cfg.acl_out.setdefault(iface, []).append(rule)
        self.audit("acl", {"dir": direction, "iface": iface, "action": action, "src": src, "dst": dst, "proto": proto})
        print(f"ACL {direction} {iface} {action} {src} {dst} {proto or ''}")

    def do_nat(self, arg):
        if not self.config_mode: print("Enter config mode"); return
        p = arg.split()
        if p[:1] == ["snat"]:
            out_if, src = p[1], p[2]
            self.cfg.nat.append(NATRule(src_net=IPv4Network(src), out_iface=out_if))
            self.audit("nat_snat", {"out_iface": out_if, "src": src})
            print(f"SNAT {src} out {out_if}")
'@

Set-Content mgmt/api.py @'
from fastapi import FastAPI, Depends, HTTPException
from fastapi.security import HTTPBearer
from pydantic import BaseModel
import jwt, time
from core.types import Config, Route
from ipaddress import IPv4Network, IPv4Address

SECRET = "change-me"
roles = {"viewer": ["GET"], "operator": ["GET","POST"], "admin": ["GET","POST","DELETE"]}

class TokenData(BaseModel):
    sub: str
    role: str
    exp: int

def make_token(user: str, role: str, ttl=3600):
    return jwt.encode({"sub": user, "role": role, "exp": int(time.time())+ttl}, SECRET, algorithm="HS256")

app = FastAPI()
security = HTTPBearer()
CFG: Config = None

def auth(role_req: str):
    def _inner(credentials=Depends(security)):
        try:
            data = jwt.decode(credentials.credentials, SECRET, algorithms=["HS256"])
        except Exception:
            raise HTTPException(status_code=401, detail="invalid token")
        if role_req not in roles.get(data["role"], []):
            raise HTTPException(status_code=403, detail="insufficient role")
        return data
    return _inner

class RouteIn(BaseModel):
    prefix: str
    next_hop: str | None
    out_iface: str

@app.get("/routes")
def get_routes(user=Depends(auth("GET"))):
    return [{"prefix": str(r.prefix), "next_hop": str(r.next_hop) if r.next_hop else None, "out_iface": r.out_iface} for r in CFG.routes]

@app.post("/routes")
def add_route(item: RouteIn, user=Depends(auth("POST"))):
    CFG.routes.append(Route(prefix=IPv4Network(item.prefix), next_hop=IPv4Address(item.next_hop) if item.next_hop else None, out_iface=item.out_iface))
    return {"status": "ok"}

@app.delete("/routes")
def clear_routes(user=Depends(auth("DELETE"))):
    CFG.routes.clear()
    return {"status": "ok"}
'@

Set-Content main.py @'
import asyncio, threading
from core.types import Config
from mgmt.cli import IOSCli
from mgmt.api import app, make_token, CFG as API_CFG
from dataplane.emu import EmuPort, run_emulator
from dataplane.pcap import run_pcap
import uvicorn, sys

def start_api(cfg: Config):
    API_CFG = cfg
    uvicorn.run(app, host="127.0.0.1", port=8080)

async def start_dp(cfg: Config, mode: str):
    if mode == "emu":
        ports = {name: EmuPort(name) for name in cfg.interfaces.keys()}
        for p in ports.values():
            for q in ports.values():
                if p is not q: p.connect(q)
        await run_emulator(cfg, ports)
    elif mode == "pcap":
        await run_pcap(cfg)
    else:
        raise RuntimeError("unknown mode")

if __name__ == "__main__":
    cfg = Config()
    print("Admin token:", make_token("admin", "admin", ttl=86400))
    t_api = threading.Thread(target=start_api, args=(cfg,), daemon=True)
    t_api.start()
    IOSCli(cfg).cmdloop()
    mode = "emu" if all(i.driver == "emu" for i in cfg.interfaces.values()) else "pcap"
    try:
        asyncio.run(start_dp(cfg, mode))
    except KeyboardInterrupt:
        sys.exit(0)
'@

Set-Content README.txt @'
Prerequisites
Install Python 3.10+ and these packages:
pip install scapy fastapi uvicorn pyjwt

Run
python main.py

CLI quickstart
enable
interface r0 10.0.0.0/24 driver=emu
interface r1 10.0.1.0/24 driver=emu
ip route add 10.0.1.0/24 connected r1
ip route add 10.0.0.0/24 connected r0
acl out r0 permit 0.0.0.0/0 0.0.0.0/0
nat snat r0 10.0.0.0/24

Test with Scapy in another Python shell:
from scapy.all import Ether, IP, sendp
pkt = Ether()/IP(src="10.0.0.2", dst="10.0.1.2")/b"hello"
sendp(pkt)

API
Use printed admin token for FastAPI bearer auth at http://127.0.0.1:8080/routes
'@

Write-Host "done"
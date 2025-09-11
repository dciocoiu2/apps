# bootstrap-netlab.ps1 (Part 1/3)
# Fully self-contained localhost-only networking lab (L2–L7).
# Generates all source files, headers, scenarios, and a build harness.
# Requires a tiny prebuilt C compiler binary placed in netlab/bin.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-File {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Content
  )
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $Content | Out-File -FilePath $Path -Encoding UTF8 -Force
}

# Create root directories
$root = "netlab"
$dirs = @(
  "$root/bin",
  "$root/include",
  "$root/src",
  "$root/scenarios",
  "$root/out"
)
foreach ($d in $dirs) {
  if (-not (Test-Path $d)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
  }
}

# README.md
New-File "$root/README.md" @'
# netlab (localhost-only)

A single-folder networking lab that emulates L2–L7 devices (switch, router, firewall, WAF, L4/L7 load balancers) and hosts entirely in user space. No real sockets; packets move through an in-memory event-driven graph.

Build requires a tiny, prebuilt C compiler binary placed locally in `bin/` with one of these names:
- tcc-win-x64.exe
- tcc-linux-x86_64
- tcc-linux-arm64
- tcc-macos-x86_64
- tcc-macos-arm64

Build:
- Windows: `.\build.ps1`
- macOS/Linux (PowerShell 7): `pwsh ./build.ps1`

Run:
- Windows: `.\out\netlab.exe scenarios\simple_l2.toml 1000`
- macOS/Linux: `./out/netlab scenarios/simple_l2.toml 1000`
'@

# build.ps1
New-File "$root/build.ps1" @'
param(
  [string]$OutputName = "netlab"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Determine script directory
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $root

function Find-Compiler {
  if ($IsWindows) {
    $candidates = @("bin\tcc-win-x64.exe")
  } else {
    $arch = uname -m
    if ($arch -eq "x86_64") {
      $candidates = @("bin/tcc-linux-x86_64","bin/tcc-macos-x86_64")
    } elseif ($arch -in @("aarch64","arm64")) {
      $candidates = @("bin/tcc-linux-arm64","bin/tcc-macos-arm64")
    } else {
      $candidates = @(
        "bin/tcc-linux-x86_64","bin/tcc-linux-arm64",
        "bin/tcc-macos-x86_64","bin/tcc-macos-arm64"
      )
    }
  }
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  return $null
}

$cc = Find-Compiler
if (-not $cc) {
  Write-Host "No bundled compiler found in bin/. Expected one of:" -ForegroundColor Yellow
  if ($IsWindows) {
    Write-Host "  bin\tcc-win-x64.exe"
  } else {
    Write-Host "  bin/tcc-linux-x86_64, bin/tcc-linux-arm64, bin/tcc-macos-x86_64, bin/tcc-macos-arm64"
  }
  Write-Host "Place a matching tiny compiler binary into bin/ and re-run." -ForegroundColor Yellow
  exit 1
}

if ($IsWindows) { $out = "out\$OutputName.exe" }
else             { $out = "out/$OutputName"    }

$srcs = Get-ChildItem -Path "src" -Filter "*.c" | ForEach-Object { $_.FullName }
$incs = "-Iinclude"

Write-Host "Building with $cc ..." -ForegroundColor Cyan
$cmd = @($cc, $incs) + $srcs + @("-o", $out)
& $cmd
if ($LASTEXITCODE -ne 0) {
  Write-Error "Build failed with exit code $LASTEXITCODE"
  exit $LASTEXITCODE
}
Write-Host "Built: $out" -ForegroundColor Green
Pop-Location
'@

# include/netlab.h
New-File "$root/include/netlab.h" @'
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
  #define PATH_SEP "\\"
#else
  #define PATH_SEP "/"
#endif

#define NL_MAX_PORTS    16
#define NL_MAX_RULES    128
#define NL_MAX_BACKENDS 32
#define NL_MAX_NAME     64
#define NL_DROP          0
#define NL_FWD           1

static inline void nl_die(const char *msg) {
  fprintf(stderr, "fatal: %s\n", msg);
  exit(1);
}
'@

# include/packet.h
New-File "$root/include/packet.h" @'
#pragma once
#include "netlab.h"

typedef enum { ETH_IPV4=0x0800, ETH_ARP=0x0806 } nl_ethertype_t;
typedef enum { L4_NONE=0, L4_UDP=17, L4_TCP=6, L4_ICMP=1 } nl_l4_t;

typedef struct {
  uint8_t dst[6], src[6];
  uint16_t ethertype;
} nl_eth_t;

typedef struct {
  uint8_t src[4], dst[4];
  uint8_t ttl, proto;
} nl_ipv4_t;

typedef struct {
  uint16_t src, dst;
} nl_l4_hdr_t;

typedef struct {
  uint8_t type, code;
  uint16_t id, seq;
} nl_icmp_t;

typedef struct {
  char text[2048];
} nl_http_t;

typedef struct nl_pkt {
  nl_eth_t   eth;
  nl_ipv4_t  ip;
  nl_l4_hdr_t l4;
  nl_icmp_t  icmp;
  nl_http_t  http;
  size_t     payload_len;
  uint8_t    payload[2048];
  int        ingress_port;
  char       trace[256];
} nl_pkt_t;

static inline void nl_mac_copy(uint8_t *d, const uint8_t *s) {
  for (int i = 0; i < 6; i++) d[i] = s[i];
}

static inline int nl_mac_eq(const uint8_t *a, const uint8_t *b) {
  for (int i = 0; i < 6; i++) if (a[i] != b[i]) return 0;
  return 1;
}

static inline int nl_ip_eq(const uint8_t *a, const uint8_t *b) {
  for (int i = 0; i < 4; i++) if (a[i] != b[i]) return 0;
  return 1;
}
'@

# include/engine.h
New-File "$root/include/engine.h" @'
#pragma once
#include "packet.h"

typedef struct nl_node nl_node_t;
typedef struct nl_link nl_link_t;

typedef struct {
  char      name[NL_MAX_NAME];
  nl_node_t *a, *b;
  int       port_a, port_b;
  double    latency_ms, jitter_ms, loss, bandwidth_mbps;
} nl_link_cfg_t;

typedef struct {
  nl_node_t *nodes[256];
  int        node_count;
  nl_link_t *links[512];
  int        link_count;
  uint64_t   now_ms;
} nl_world_t;

typedef struct {
  char     name[NL_MAX_NAME];
  int      id;
  int      port_count;
  nl_link_t *ports[NL_MAX_PORTS];
  void     (*on_rx)(nl_world_t*, nl_node_t*, int, nl_pkt_t*);
  void     (*on_tick)(nl_world_t*, nl_node_t*);
  void     (*destroy)(nl_node_t*);
  void     *state;
} nl_node_t;

struct nl_link {
  char      name[NL_MAX_NAME];
  nl_node_t *peer[2];
  int       port_idx[2];
  double    latency_ms, jitter_ms, loss, bw_mbps;
};

void nl_world_init(nl_world_t *w);
nl_node_t* nl_node_create(nl_world_t *w, const char *type, const char *name, const char *args);
void nl_link_connect(nl_world_t *w, const nl_link_cfg_t *cfg);
void nl_inject(nl_world_t *w, nl_node_t *n, int port, nl_pkt_t *p);
void nl_run(nl_world_t *w, uint64_t duration_ms);
'@

# include/nodes.h
New-File "$root/include/nodes.h" @'
#pragma once
#include "engine.h"

// Switch
typedef struct { uint8_t mac[6]; int port; uint64_t last_ms; } nl_fdb_entry_t;
typedef struct { nl_fdb_entry_t fdb[128]; int fdbn; } nl_switch_t;

// Router
typedef struct { uint8_t ip[4], mask[4], gw[4]; int out_port; uint8_t mac[6]; } nl_route_t;
typedef struct { nl_route_t rt[64]; int rtn; } nl_router_t;

// Firewall
typedef struct { char action[8]; char expr[128]; } nl_fw_rule_t;
typedef struct { nl_fw_rule_t rules[NL_MAX_RULES]; int rn; } nl_firewall_t;

// WAF
typedef struct { char deny_pattern[64]; } nl_waf_rule_t;
typedef struct { nl_waf_rule_t rules[NL_MAX_RULES]; int rn; } nl_waf_t;

// Load balancer
typedef struct {
  uint8_t   vip[4];
  uint16_t  vport;
  int       l7, rr_idx;
  int       backends_n;
  uint8_t   b_ip[NL_MAX_BACKENDS][4];
  uint16_t  b_port[NL_MAX_BACKENDS];
} nl_lb_t;

// Host
typedef struct {
  char     role[16];
  uint8_t  ip[4];
  uint8_t  mac[6];
  uint16_t tcp_listen;
  int      http;
  char     http_body[256];
} nl_host_t;

// Sending helper
void nl_send(struct nl_world *w, nl_node_t *from, int out_port, nl_pkt_t *p);
'@
# bootstrap-netlab.ps1 (Part 2/3)

# src/engine.c
New-File "$root/src/engine.c" @'
#include "engine.h"
#include <time.h>
#include <stdlib.h>
#include <string.h>

typedef struct ev {
  uint64_t   at_ms;
  nl_node_t *dst;
  int        port;
  nl_pkt_t   pkt;
} ev_t;

static ev_t evq[8192];
static int evn;

static void ev_push(uint64_t at, nl_node_t *dst, int port, nl_pkt_t *pkt){
  if (evn >= (int)(sizeof evq/sizeof evq[0])) nl_die("event queue overflow");
  evq[evn].at_ms = at;
  evq[evn].dst   = dst;
  evq[evn].port  = port;
  evq[evn].pkt   = *pkt;
  evn++;
}

static int ev_pop_min(int *idx){
  if (evn == 0) return 0;
  int m = 0;
  for (int i = 1; i < evn; i++) {
    if (evq[i].at_ms < evq[m].at_ms) m = i;
  }
  *idx = m;
  return 1;
}

void nl_world_init(nl_world_t *w){
  memset(w, 0, sizeof *w);
  evn = 0;
}

void nl_inject(nl_world_t *w, nl_node_t *n, int port, nl_pkt_t *p){
  ev_push(w->now_ms, n, port, p);
}

static void deliver(nl_world_t *w, nl_node_t *dst, int port, nl_pkt_t *pkt){
  if (dst && dst->on_rx) dst->on_rx(w, dst, port, pkt);
}

typedef struct nl_link nl_link_t;
static int side_of(nl_link_t *l, nl_node_t *n){
  if (l->peer[0] == n) return 0;
  if (l->peer[1] == n) return 1;
  return -1;
}

static void link_send(nl_world_t *w, nl_link_t *l, nl_node_t *src, nl_pkt_t *p){
  int s = side_of(l, src), d = (s == 0 ? 1 : 0);
  if (s < 0) return;
  double r = (double)rand() / RAND_MAX;
  if (r < l->loss) return;
  double lat = l->latency_ms + ((double)rand()/RAND_MAX - 0.5) * 2.0 * l->jitter_ms;
  if (lat < 0) lat = 0;
  uint64_t at = w->now_ms + (uint64_t)(lat + 0.5);
  ev_push(at, l->peer[d], l->port_idx[d], p);
}

void nl_link_connect(nl_world_t *w, const nl_link_cfg_t *cfg){
  nl_link_t *l = calloc(1, sizeof *l);
  strncpy(l->name, cfg->name, sizeof l->name - 1);
  l->peer[0]        = cfg->a;
  l->port_idx[0]    = cfg->port_a;
  l->peer[1]        = cfg->b;
  l->port_idx[1]    = cfg->port_b;
  l->latency_ms     = cfg->latency_ms;
  l->jitter_ms      = cfg->jitter_ms;
  l->loss           = cfg->loss;
  l->bw_mbps        = cfg->bandwidth_mbps;
  w->links[w->link_count++] = l;
  cfg->a->ports[cfg->port_a] = l;
  cfg->b->ports[cfg->port_b] = l;
}

void nl_send(nl_world_t *w, nl_node_t *from, int out_port, nl_pkt_t *p){
  nl_link_t *l = from->ports[out_port];
  if (!l) return;
  link_send(w, l, from, p);
}

void nl_tick_all(nl_world_t *w){
  for (int i = 0; i < w->node_count; i++) {
    if (w->nodes[i]->on_tick) w->nodes[i]->on_tick(w, w->nodes[i]);
  }
}

void nl_run(nl_world_t *w, uint64_t duration_ms){
  uint64_t end = w->now_ms + duration_ms;
  while (w->now_ms <= end) {
    int idx;
    while (ev_pop_min(&idx)) {
      if (evq[idx].at_ms > w->now_ms) break;
      ev_t e = evq[idx];
      evq[idx] = evq[--evn];
      deliver(w, e.dst, e.port, &e.pkt);
    }
    nl_tick_all(w);
    w->now_ms += 1;
  }
}

// forward declarations for node factories
extern nl_node_t* nl_switch_create(const char*, const char*);
extern nl_node_t* nl_router_create(const char*, const char*);
extern nl_node_t* nl_firewall_create(const char*, const char*);
extern nl_node_t* nl_waf_create(const char*, const char*);
extern nl_node_t* nl_lb_create(const char*, const char*);
extern nl_node_t* nl_host_create(const char*, const char*);

nl_node_t* nl_node_create(nl_world_t *w, const char *type, const char *name, const char *args){
  nl_node_t *n = NULL;
  if      (!strcmp(type,"switch"))   n = nl_switch_create(name,args);
  else if (!strcmp(type,"router"))   n = nl_router_create(name,args);
  else if (!strcmp(type,"firewall")) n = nl_firewall_create(name,args);
  else if (!strcmp(type,"waf"))      n = nl_waf_create(name,args);
  else if (!strcmp(type,"lb"))       n = nl_lb_create(name,args);
  else if (!strcmp(type,"host"))     n = nl_host_create(name,args);
  else nl_die("unknown node type");

  n->id = w->node_count;
  w->nodes[w->node_count++] = n;
  return n;
}
'@

# src/packet.c
New-File "$root/src/packet.c" @'
#include "packet.h"

void nl_pkt_make_arp(nl_pkt_t *p){
  memset(p,0,sizeof *p);
  p->eth.ethertype = ETH_ARP;
}

void nl_pkt_make_ip(nl_pkt_t *p, const uint8_t src[4], const uint8_t dst[4], nl_l4_t proto){
  memset(p,0,sizeof *p);
  p->eth.ethertype = ETH_IPV4;
  memcpy(p->ip.src, src, 4);
  memcpy(p->ip.dst, dst, 4);
  p->ip.ttl   = 64;
  p->ip.proto = (uint8_t)proto;
}
'@

# src/nodes_switch.c
New-File "$root/src/nodes_switch.c" @'
#include "nodes.h"

static void fdb_learn(nl_switch_t *s, const uint8_t mac[6], int port, uint64_t now){
  for (int i = 0; i < s->fdbn; i++) {
    if (nl_mac_eq(s->fdb[i].mac, mac)) {
      s->fdb[i].port = port;
      s->fdb[i].last_ms = now;
      return;
    }
  }
  if (s->fdbn < 128) {
    nl_fdb_entry_t *e = &s->fdb[s->fdbn++];
    nl_mac_copy(e->mac, mac);
    e->port    = port;
    e->last_ms = now;
  }
}

static int fdb_lookup(nl_switch_t *s, const uint8_t mac[6]){
  for (int i = 0; i < s->fdbn; i++) {
    if (nl_mac_eq(s->fdb[i].mac, mac)) {
      return s->fdb[i].port;
    }
  }
  return -1;
}

static void sw_on_rx(nl_world_t *w, nl_node_t *n, int in_port, nl_pkt_t *p){
  nl_switch_t *s = (nl_switch_t*)n->state;
  fdb_learn(s, p->eth.src, in_port, w->now_ms);
  int out = fdb_lookup(s, p->eth.dst);
  if (out >= 0 && out != in_port) {
    nl_send(w,n,out,p);
    return;
  }
  // Flood
  for (int i = 0; i < n->port_count; i++) {
    if (i != in_port && n->ports[i]) {
      nl_send(w,n,i,p);
    }
  }
}

static void sw_destroy(nl_node_t *n){
  free(n->state);
  free(n);
}

nl_node_t* nl_switch_create(const char *name, const char *args){
  (void)args;
  nl_node_t *n = calloc(1,sizeof *n);
  strncpy(n->name, name, NL_MAX_NAME-1);
  n->port_count = NL_MAX_PORTS;
  n->on_rx      = sw_on_rx;
  n->destroy    = sw_destroy;
  n->state      = calloc(1,sizeof(nl_switch_t));
  return n;
}
'@

# src/nodes_router.c
New-File "$root/src/nodes_router.c" @'
#include "nodes.h"

static int ip_match(const uint8_t ip[4], const uint8_t net[4], const uint8_t mask[4]){
  for (int i = 0; i < 4; i++) {
    if ((ip[i] & mask[i]) != (net[i] & mask[i])) return 0;
  }
  return 1;
}

static nl_route_t* route_lookup(nl_router_t *r, const uint8_t dst[4]){
  nl_route_t *best = NULL;
  int best_len = -1;
  for (int i = 0; i < r->rtn; i++){
    int prefix = 0;
    for (int b = 0; b < 4; b++){
      for (int k = 7; k >= 0; k--){
        if (r->rt[i].mask[b] & (1<<k)) prefix++;
      }
    }
    if (ip_match(dst, r->rt[i].ip, r->rt[i].mask)){
      if (prefix > best_len){
        best     = &r->rt[i];
        best_len = prefix;
      }
    }
  }
  return best;
}

static void r_on_rx(nl_world_t *w, nl_node_t *n, int in_port, nl_pkt_t *p){
  (void)in_port;
  if (p->eth.ethertype != ETH_IPV4) return;
  if (p->ip.ttl == 0) return;
  nl_router_t *r = (nl_router_t*)n->state;
  nl_route_t *rt = route_lookup(r, p->ip.dst);
  if (!rt) return;
  p->ip.ttl--;
  nl_mac_copy(p->eth.src, rt->mac);
  nl_send(w, n, rt->out_port, p);
}

static void r_destroy(nl_node_t *n){
  free(n->state);
  free(n);
}

static int parse_ip(const char *s, uint8_t out[4]){
  unsigned a,b,c,d;
  if (sscanf(s, "%u.%u.%u.%u",&a,&b,&c,&d) != 4) return 0;
  out[0]=a; out[1]=b; out[2]=c; out[3]=d;
  return 1;
}

static void parse_cidr(const char *cidr, uint8_t ip[4], uint8_t mask[4]){
  char buf[64]; strncpy(buf,cidr,sizeof buf -1);
  char *slash = strchr(buf,'/');
  int  p = 0;
  if (slash){
    *slash = 0;
    p = atoi(slash+1);
  }
  parse_ip(buf, ip);
  memset(mask,0,4);
  for (int i = 0; i < p; i++){
    mask[i/8] |= (uint8_t)(0x80 >> (i%8));
  }
}

nl_node_t* nl_router_create(const char *name, const char *args){
  nl_node_t *n = calloc(1,sizeof *n);
  strncpy(n->name, name, NL_MAX_NAME-1);
  n->port_count = NL_MAX_PORTS;
  n->on_rx      = r_on_rx;
  n->destroy    = r_destroy;
  nl_router_t *r = calloc(1,sizeof *r);

  // args = "route=10.0.1.0/24,port=1,mac=02:00:...;route=..."
  const char *p = args;
  while (p && *p){
    char  rid[64]={0}, macs[32]={0};
    int   port=0;
    if (sscanf(p,"route=%63[^,],port=%d,mac=%31[^;];", rid,&port,macs) == 3){
      uint8_t ip[4], mask[4], mac[6];
      parse_cidr(rid, ip, mask);
      unsigned m[6];
      if (sscanf(macs,"%x:%x:%x:%x:%x:%x",&m[0],&m[1],&m[2],&m[3],&m[4],&m[5]) == 6){
        for (int i = 0; i < 6; i++) mac[i] = (uint8_t)m[i];
      } else {
        memset(mac,0,6);
      }
      nl_route_t *e = &r->rt[r->rtn++];
      memcpy(e->ip,   ip,   4);
      memcpy(e->mask, mask, 4);
      e->out_port = port;
      nl_mac_copy(e->mac, mac);
    }
    p = strchr(p,';');
    if (p) p++;
  }

  n->state = r;
  return n;
}
'@

# src/nodes_firewall.c
New-File "$root/src/nodes_firewall.c" @'
#include "nodes.h"

static int match_expr(const nl_pkt_t *p, const char *expr){
  if (!strncmp(expr,"ip.src=",7)){
    unsigned a,b,c,d;
    if (sscanf(expr+7,"%u.%u.%u.%u",&a,&b,&c,&d)!=4) return 0;
    uint8_t ip[4]={a,b,c,d};
    return nl_ip_eq(p->ip.src, ip);
  } else if (!strncmp(expr,"ip.dst=",7)){
    unsigned a,b,c,d;
    if (sscanf(expr+7,"%u.%u.%u.%u",&a,&b,&c,&d)!=4) return 0;
    uint8_t ip[4]={a,b,c,d};
    return nl_ip_eq(p->ip.dst, ip);
  } else if (!strncmp(expr,"l4=",3)){
    const char *v = expr+3;
    if (!strcmp(v,"tcp"))  return p->ip.proto==L4_TCP;
    if (!strcmp(v,"udp"))  return p->ip.proto==L4_UDP;
    if (!strcmp(v,"icmp")) return p->ip.proto==L4_ICMP;
  } else if (!strncmp(expr,"tcp.dst=",8)){
    return p->ip.proto==L4_TCP && p->l4.dst==atoi(expr+8);
  } else if (!strncmp(expr,"udp.dst=",8)){
    return p->ip.proto==L4_UDP && p->l4.dst==atoi(expr+8);
  }
  return 0;
}

static int firewall_decide(nl_firewall_t *fw, const nl_pkt_t *p){
  for (int i = 0; i < fw->rn; i++){
    if (match_expr(p, fw->rules[i].expr)){
      return fw->rules[i].action[0]=='a' ? NL_FWD : NL_DROP;
    }
  }
  return NL_FWD;  // default allow
}

static void fw_on_rx(nl_world_t *w, nl_node_t *n, int in_port, nl_pkt_t *p){
  nl_firewall_t *fw = (nl_firewall_t*)n->state;
  if (firewall_decide(fw,p) == NL_DROP) return;
  for (int i = 0; i < n->port_count; i++){
    if (i != in_port && n->ports[i]){
      nl_send(w,n,i,p);
    }
  }
}

static void fw_destroy(nl_node_t *n){
  free(n->state);
  free(n);
}

nl_node_t* nl_firewall_create(const char *name, const char *args){
  nl_node_t *n = calloc(1,sizeof *n);
  strncpy(n->name, name, NL_MAX_NAME-1);
  n->port_count = 2;
  n->on_rx      = fw_on_rx;
  n->destroy    = fw_destroy;

  nl_firewall_t *fw = calloc(1,sizeof *fw);
  const char *p = args;
  while (p && *p){
    char act[8]={0}, expr[128]={0};
    if (sscanf(p,"rule=%7s %127[^;];", act, expr) == 2){
      nl_fw_rule_t *r = &fw->rules[fw->rn++];
      strncpy(r->action, act, sizeof r->action-1);
      strncpy(r->expr,   expr, sizeof r->expr-1);
    }
    p = strchr(p,';');
    if (p) p++;
  }

  n->state = fw;
  return n;
}
'@

# src/nodes_waf.c
New-File "$root/src/nodes_waf.c" @'
#include "nodes.h"
#include <string.h>
#include <stdio.h>

static int waf_block(nl_waf_t *waf, const nl_pkt_t *p){
  if (p->ip.proto != L4_TCP) return 0;
  if (p->payload_len==0 && p->http.text[0]==0) return 0;
  for (int i = 0; i < waf->rn; i++){
    if (strstr(p->http.text, waf->rules[i].deny_pattern)) return 1;
  }
  return 0;
}

static void waf_on_rx(nl_world_t *w, nl_node_t *n, int in_port, nl_pkt_t *p){
  nl_waf_t *waf = (nl_waf_t*)n->state;
  if (waf_block(waf,p)) {
    // dropped
    return;
  }
  for (int i = 0; i < n->port_count; i++) {
    if (i != in_port && n->ports[i]) {
      nl_send(w,n,i,p);
    }
  }
}

static void waf_destroy(nl_node_t *n){
  free(n->state);
  free(n);
}

nl_node_t* nl_waf_create(const char *name, const char *args){
  nl_node_t *n = calloc(1,sizeof *n);
  strncpy(n->name, name, NL_MAX_NAME-1);
  n->port_count = 2;
  n->on_rx      = waf_on_rx;
  n->destroy    = waf_destroy;

  nl_waf_t *w = calloc(1,sizeof *w);
  const char *p = args;
  while (p && *p){
    char pat[64] = {0};
    if (sscanf(p,"deny=%63[^;];", pat) == 1){
      nl_waf_rule_t *r = &w->rules[w->rn++];
      strncpy(r->deny_pattern, pat, sizeof r->deny_pattern - 1);
    }
    p = strchr(p,';');
    if (p) p++;
  }

  n->state = w;
  return n;
}
'@
# bootstrap-netlab.ps1 (Part 3/3)

# src/nodes_lb.c
New-File "$root/src/nodes_lb.c" @'
#include "nodes.h"
#include <string.h>
#include <stdio.h>

static int ip_parse(const char *s, uint8_t out[4]){
  unsigned a,b,c,d;
  if (sscanf(s,"%u.%u.%u.%u",&a,&b,&c,&d)!=4) return 0;
  out[0]=a; out[1]=b; out[2]=c; out[3]=d; return 1;
}

static void lb_on_rx(nl_world_t *w, nl_node_t *n, int in_port, nl_pkt_t *p){
  (void)in_port;
  nl_lb_t *lb = (nl_lb_t*)n->state;
  if (p->eth.ethertype != ETH_IPV4) return;
  if (!nl_ip_eq(p->ip.dst, lb->vip) || (p->l4.dst != lb->vport)) return;

  int idx = lb->backends_n ? (lb->rr_idx++ % lb->backends_n) : 0;

  if (lb->l7 && p->http.text[0]) {
    if (strstr(p->http.text, "Host: api.")) idx = 0;
    else if (strstr(p->http.text, "Host: www.")) idx = (lb->backends_n>1 ? 1 : 0);
  }

  memcpy(p->ip.dst, lb->b_ip[idx], 4);
  p->l4.dst = lb->b_port[idx];

  for (int i = 0; i < n->port_count; i++) {
    if (i != in_port && n->ports[i]) nl_send(w,n,i,p);
  }
}

static void lb_destroy(nl_node_t *n){
  free(n->state);
  free(n);
}

nl_node_t* nl_lb_create(const char *name, const char *args){
  nl_node_t *n = calloc(1,sizeof *n);
  strncpy(n->name,name,NL_MAX_NAME-1);
  n->port_count = 2;
  n->on_rx = lb_on_rx;
  n->destroy = lb_destroy;

  nl_lb_t *lb = calloc(1,sizeof *lb);
  char vip[32]={0}, backs[256]={0};
  int vport=80, l7=0;
  if (sscanf(args,"vip=%31[^,],vport=%d,l7=%d,backends=%255[^\n]", vip, &vport, &l7, backs) >= 3){
    ip_parse(vip, lb->vip);
    lb->vport = (uint16_t)vport;
    lb->l7 = l7;
    const char *p = backs;
    while (p && *p){
      unsigned a,b,c,d,port;
      if (sscanf(p,"%u.%u.%u.%u:%u",&a,&b,&c,&d,&port) == 5){
        uint8_t ip[4]={a,b,c,d};
        memcpy(lb->b_ip[lb->backends_n], ip, 4);
        lb->b_port[lb->backends_n] = (uint16_t)port;
        lb->backends_n++;
      }
      const char *comma = strchr(p, ',');
      if (!comma) break;
      p = comma + 1;
    }
  }

  n->state = lb;
  return n;
}
'@

# src/nodes_host.c
New-File "$root/src/nodes_host.c" @'
#include "nodes.h"
#include <stdio.h>
#include <string.h>

static int parse_ip(const char *s, uint8_t out[4]){
  unsigned a,b,c,d; if(sscanf(s,"%u.%u.%u.%u",&a,&b,&c,&d)!=4) return 0;
  out[0]=a; out[1]=b; out[2]=c; out[3]=d; return 1;
}

void nl_pkt_make_ip(nl_pkt_t *p, const uint8_t src[4], const uint8_t dst[4], nl_l4_t proto);

static void send_icmp_echo(nl_world_t *w, nl_node_t *n, int out_port, const uint8_t dst[4], uint16_t id, uint16_t seq){
  nl_pkt_t p; nl_pkt_make_ip(&p, ((nl_host_t*)n->state)->ip, dst, L4_ICMP);
  p.icmp.type=8; p.icmp.code=0; p.icmp.id=id; p.icmp.seq=seq;
  nl_send(w,n,out_port,&p);
}

static void send_http_get(nl_world_t *w, nl_node_t *n, int out_port, const uint8_t dst[4], uint16_t port, const char *host, const char *path){
  nl_pkt_t p; nl_pkt_make_ip(&p, ((nl_host_t*)n->state)->ip, dst, L4_TCP);
  p.l4.src=50000; p.l4.dst=port;
  snprintf(p.http.text, sizeof p.http.text, "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: netlab\r\n\r\n", path, host?host:"localhost");
  nl_send(w,n,out_port,&p);
}

static void host_on_rx(nl_world_t *w, nl_node_t *n, int in_port, nl_pkt_t *p){
  (void)in_port;
  nl_host_t *h = (nl_host_t*)n->state;
  if (!nl_ip_eq(p->ip.dst, h->ip)) return;

  if (p->ip.proto == L4_ICMP && p->icmp.type == 8) {
    nl_pkt_t r = *p; memcpy(r.ip.dst, p->ip.src,4); memcpy(r.ip.src, h->ip,4); r.icmp.type=0;
    nl_send(w,n,0,&r);
  } else if (p->ip.proto == L4_TCP && h->http && p->l4.dst == h->tcp_listen && p->http.text[0]) {
    nl_pkt_t r; nl_pkt_make_ip(&r, h->ip, p->ip.src, L4_TCP);
    r.l4.src=h->tcp_listen; r.l4.dst=p->l4.src;
    snprintf(r.http.text, sizeof r.http.text,
             "HTTP/1.1 200 OK\r\nContent-Length:%zu\r\nConnection: close\r\nContent-Type:text/plain\r\n\r\n%s",
             strlen(h->http_body), h->http_body);
    nl_send(w,n,0,&r);
  } else if (p->ip.proto == L4_TCP && p->http.text[0]) {
    printf("[%s] HTTP response: %.64s\n", n->name, p->http.text);
  } else if (p->ip.proto == L4_ICMP && p->icmp.type == 0) {
    printf("[%s] ping reply from %u.%u.%u.%u seq=%u\n", n->name,
      p->ip.src[0],p->ip.src[1],p->ip.src[2],p->ip.src[3], p->icmp.seq);
  }
}

static void host_on_tick(nl_world_t *w, nl_node_t *n){
  nl_host_t *h = (nl_host_t*)n->state;
  if (!strcmp(h->role,"client")) {
    if (w->now_ms==100) { uint8_t d[4]={10,0,0,100}; send_icmp_echo(w,n,0,d,1,1); }
    if (w->now_ms==300) { uint8_t d[4]={10,0,0,100}; send_http_get(w,n,0,d,80,"www.local","/"); }
  }
  (void)h;
}

static void host_destroy(nl_node_t *n){ free(n->state); free(n); }

nl_node_t* nl_host_create(const char *name, const char *args){
  nl_node_t *n=(nl_node_t*)calloc(1,sizeof *n);
  strncpy(n->name,name,NL_MAX_NAME-1);
  n->port_count=1; n->on_rx=host_on_rx; n->on_tick=host_on_tick; n->destroy=host_destroy;
  nl_host_t *h=(nl_host_t*)calloc(1,sizeof *h);
  char ip[32]={0}, role[16]="server"; int http=0, port=80; char body[256]="hello from host";
  sscanf(args,"role=%15[^,],ip=%31[^,],http=%d,port=%d,body=%255[^\n]", role, ip, &http, &port, body);
  strncpy(h->role, role, sizeof h->role -1); parse_ip(ip,h->ip);
  h->http=http; h->tcp_listen=(uint16_t)port; strncpy(h->http_body, body, sizeof h->http_body -1);
  h->mac[0]=2; h->mac[1]=0; h->mac[2]=0; h->mac[3]=0; h->mac[4]=0; h->mac[5]=(uint8_t)(n->name[0]);
  n->state=h; return n;
}
'@

# src/topo.c
New-File "$root/src/topo.c" @'
#include "engine.h"
#include <stdio.h>
#include <string.h>

static nl_node_t* find(nl_world_t *w, const char *name){
  for(int i=0;i<w->node_count;i++) if(!strcmp(w->nodes[i]->name,name)) return w->nodes[i];
  return NULL;
}

static void trim(char *s){
  size_t n=strlen(s);
  while(n && (s[n-1]=='\n'||s[n-1]=='\r'||s[n-1]==' '||s[n-1]=='\t')) s[--n]=0;
}

void nl_load_scenario(nl_world_t *w, const char *path){
  FILE *f = fopen(path,"rb"); if(!f) nl_die("cannot open scenario");
  char line[1024]; int section=0;
  while(fgets(line,sizeof line,f)){
    trim(line); if(line[0]=='#'||line[0]==0) continue;
    if(!strcmp(line,"[nodes]")){ section=1; continue; }
    if(!strcmp(line,"[links]")){ section=2; continue; }
    if(section==1){
      // name = type(args)
      char name[64]={0}, type[64]={0}, args[512]={0};
      if(sscanf(line,"%63[^=]=%63[^ (](%511[^)])", name, type, args)>=2){
        nl_node_create(w, type, name, args);
      }
    } else if(section==2){
      // A.p <-> B.q
      char a[64]={0}, b[64]={0}; int pa=0,pb=0;
      if(sscanf(line,"%63[^.].%d <-> %63[^.].%d", a,&pa,b,&pb)==4){
        nl_node_t *na=find(w,a), *nb=find(w,b); if(!na||!nb) nl_die("unknown node in link");
        nl_link_cfg_t lc = {0};
        strncpy(lc.name, "link", sizeof lc.name -1);
        lc.a=na; lc.b=nb; lc.port_a=pa; lc.port_b=pb;
        lc.latency_ms=1; lc.jitter_ms=0; lc.loss=0; lc.bandwidth_mbps=1000;
        nl_link_connect(w,&lc);
      }
    }
  }
  fclose(f);
}
'@

# src/main.c
New-File "$root/src/main.c" @'
#include "engine.h"
#include <stdio.h>
#include <stdlib.h>

void nl_load_scenario(nl_world_t *w, const char *path);

int main(int argc, char **argv){
  if(argc < 2){
    fprintf(stderr, "usage: %s scenarios/simple_l2.toml [duration_ms]\n", argv[0]);
    return 2;
  }
  nl_world_t w; nl_world_init(&w);
  nl_load_scenario(&w, argv[1]);
  uint64_t dur = (argc>=3)? (uint64_t)atoll(argv[2]) : 1000;
  nl_run(&w, dur);
  for(int i=0;i<w.node_count;i++) if(w.nodes[i]->destroy) w.nodes[i]->destroy(w.nodes[i]);
  return 0;
}
'@

# Scenarios
New-File "$root/scenarios/simple_l2.toml" @'
[nodes]
sw1 = switch()
fw1 = firewall(rule=deny tcp.dst=23;rule=allow l4=tcp;)
waf1 = waf(deny=<script;deny=UNION SELECT)
lb1 = lb(vip=10.0.0.100,vport=80,l7=1,backends=10.0.0.11:80,10.0.0.12:80)
h1 = host(role=client,ip=10.0.0.1,http=0,port=0,body=unused)
h2 = host(role=server,ip=10.0.0.11,http=1,port=80,body=hello from h2)
h3 = host(role=server,ip=10.0.0.12,http=1,port=80,body=hello from h3)

[links]
h1.0 <-> sw1.0
sw1.1 <-> fw1.0
fw1.1 <-> waf1.0
waf1.1 <-> lb1.0
lb1.1 <-> sw1.2
sw1.3 <-> h2.0
sw1.4 <-> h3.0
'@

New-File "$root/scenarios/l3_routing.toml" @'
[nodes]
swA = switch()
swB = switch()
r1 = router(route=10.0.1.0/24,port=0,mac=02:00:00:00:01:01;route=10.0.2.0/24,port=1,mac=02:00:00:00:01:02;)
hA = host(role=client,ip=10.0.1.10,http=0,port=0,body=unused)
hB = host(role=server,ip=10.0.2.20,http=1,port=80,body=routed hello)

[links]
hA.0 <-> swA.0
swA.1 <-> r1.0
r1.1 <-> swB.0
swB.1 <-> hB.0
'@

New-File "$root/scenarios/waf_lb.toml" @'
[nodes]
waf1 = waf(deny=<script)
lb1 = lb(vip=10.0.0.100,vport=80,l7=1,backends=10.0.0.11:80,10.0.0.12:80)
hC = host(role=client,ip=10.0.0.2,http=0,port=0,body=unused)
hS1 = host(role=server,ip=10.0.0.11,http=1,port=80,body=S1)
hS2 = host(role=server,ip=10.0.0.12,http=1,port=80,body=S2)

[links]
hC.0 <-> waf1.0
waf1.1 <-> lb1.0
lb1.1 <-> hS1.0
lb1.1 <-> hS2.0
'@

Write-Host "`nDone. Created ./netlab with sources, scenarios, and build harness." -ForegroundColor Green
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1) Place a tiny prebuilt compiler into netlab/bin (e.g., tcc-win-x64.exe on Windows)."
Write-Host "  2) Build: .\netlab\build.ps1"
Write-Host "  3) Run:   .\netlab\out\netlab.exe scenarios\simple_l2.toml 1000" -ForegroundColor Cyan

#!/usr/bin/env python3
#NOTE: plugins are separate
import http.server,socketserver,json,sys,os,io,base64,hashlib,random,time,math,csv,urllib.request,urllib.parse,threading,argparse,traceback
STATE={"cfg":{"seed":123456789,"initial_cash":100000000.0,"risk":{"max_position":10000000.0,"max_notional":100000000000.0,"max_drawdown":0.25,"daily_loss_limit":5000000.0,"per_trade_loss_limit":1000000.0},"execution":{"fee_bps":0.2,"slip_bps":0.8,"twap":{"enabled":False,"slices":10,"duration_ms":900000},"vwap":{"enabled":False,"window":50},"pov":{"enabled":False,"participation":0.1}},"strategy":{"type":"rule_chain","params":{"fast":20,"slow":100,"rsiw":14},"rules":[{"if":"sma(close,fast)>sma(close,slow) and rsi(close,rsiw)<70","do":"BUY","qty":1000},{"if":"sma(close,fast)<sma(close,slow) or rsi(close,rsiw)>80","do":"SELL_ALL"}]},"rbac":{"roles":{"admin":{"caps":["config.write","run.execute","module.load","data.ingest","stream.manage","export.files"]},"ops":{"caps":["run.execute","data.ingest","stream.manage","export.files"]},"viewer":{"caps":["export.files"]}}},"profile":"paper"},"data":[],"audit":[],"trace":[],"running":False,"outdir":"out","modules":{"data":{},"strategy":{},"exec":{}},"commits":[],"streams":{},"daily":{"start_ts":0,"start_equity":0.0,"loss":0.0}}
def now_ms():return int(time.time()*1000)
def hcfg(c):return hashlib.sha256(json.dumps(c,sort_keys=True,separators=(",",":")).encode("utf-8")).hexdigest()
def write_text(p,t):os.makedirs(os.path.dirname(p),exist_ok=True);open(p,"w",encoding="utf-8").write(t)
def write_lines(p,ls):os.makedirs(os.path.dirname(p),exist_ok=True);open(p,"w",encoding="utf-8").write("\n".join(ls))
def load_json(p):return json.load(open(p,"r",encoding="utf-8"))
def parse_ts(ts):
    try:return int(ts)
    except:
        from time import strptime,mktime
        for f in("%Y-%m-%d %H:%M:%S","%Y-%m-%d","%Y/%m/%d %H:%M:%S","%Y/%m/%d"):
            try:return int(mktime(strptime(ts,f)))
            except:pass
        return 0
def load_bars_csv_text(t):
    rd=csv.DictReader(io.StringIO(t))
    b=[]
    ap=b.append
    for r in rd:
        ap({"ts":parse_ts(r.get("timestamp",r.get("ts",""))),"open":float(r["open"]),"high":float(r["high"]),"low":float(r["low"]),"close":float(r["close"]),"volume":float(r.get("volume",0.0))})
    b.sort(key=lambda x:x["ts"]);return b
def sma(s,w):
    n=len(s)
    if n<w or w<=0:return None
    su=0.0
    for i in range(n-w,n):su+=s[i]
    return su/float(w)
def ema(s,w):
    n=len(s)
    if n<w or w<=0:return None
    k=2.0/(w+1.0)
    e=s[n-w]
    for i in range(n-w+1,n):e=s[i]*k+e*(1.0-k)
    return e
def rsi(c,w):
    n=len(c)
    if n<w+1 or w<=0:return None
    g=0.0;l=0.0
    for i in range(n-w,n-1):
        d=c[i+1]-c[i]
        if d>0:g+=d
        else:l+=-d
    if l==0.0:return 100.0
    rs=g/l
    return 100.0-(100.0/(1.0+rs))
def eval_expr(e,env):
    def pf(tok):
        n,rest=tok.split("(",1);args=rest[:-1];parts=[p.strip() for p in args.split(",")];return n.strip(),parts
    def val(x):
        if x in env:return env[x]
        try:return float(x)
        except:
            if "(" in x and x.endswith(")"):
                n,parts=pf(x)
                if n=="sma":
                    sn=parts[0];w=int(env.get(parts[1],parts[1]));return sma(env[sn],w)
                if n=="ema":
                    sn=parts[0];w=int(env.get(parts[1],parts[1]));return ema(env[sn],w)
                if n=="rsi":
                    sn=parts[0];w=int(env.get(parts[1],parts[1]));return rsi(env[sn],w)
            return None
    t=e.replace(">="," ≥ ").replace("<="," ≤ ").replace("=="," ≡ ").replace(">"," > ").replace("<"," < ").replace("and"," and ").replace("or"," or ").split()
    r=[];i=0
    while i<len(t):
        tt=t[i]
        if tt=="and" or tt=="or":
            r.append(tt);i+=1;continue
        l=tt;o=t[i+1];ri=t[i+2];lv=val(l);rv=val(ri)
        if lv is None or rv is None:c=False
        else:
            if o==" > " or o==">":c=lv>rv
            elif o==" < " or o=="<":c=lv<rv
            elif o=="≥":c=lv>=rv
            elif o=="≤":c=lv<=rv
            elif o=="≡":c=(lv==rv)
            else:c=False
        r.append(c);i+=3
    if not r:return False
    a=r[0] if isinstance(r[0],bool) else False;j=1
    while j<len(r):
        op=r[j];v=r[j+1]
        if op=="and":a=a and v
        elif op=="or":a=a or v
        j+=2
    return a
def apply_dsl(dsl,env):
    if dsl.get("type")!="rule_chain":return None
    p=dsl.get("params",{})
    for k,v in p.items():env[k]=v
    for r in dsl.get("rules",[]):
        c=r.get("if","")
        if c=="" or eval_expr(c,env):
            a=r.get("do","").upper()
            if a=="BUY":q=float(r.get("qty",0));return {"action":"BUY","qty":q}
            if a=="SELL":q=float(r.get("qty",0));return {"action":"SELL","qty":q}
            if a=="SELL_ALL":return {"action":"SELL_ALL"}
            if a=="HOLD":return {"action":"HOLD"}
            return None
    return None
def exec_price_fee(side,qty,price,fee_bps,slip_bps):
    adj=price*(slip_bps/10000.0)
    ep=price+(adj if side=="BUY" else -adj)
    fee=ep*qty*(fee_bps/10000.0)
    return ep,fee
def allowed(role,cap):
    return cap in STATE["cfg"].get("rbac",{}).get("roles",{}).get(role,{}).get("caps",[])
def commit_config(actor,role,new_cfg):
    if not allowed(role,"config.write"):
        return False,"rbac_denied"
    old=STATE["cfg"]
    snap=json.dumps(old,sort_keys=True,separators=(",",":"))
    try:
        STATE["cfg"]=new_cfg
        cid=hcfg(new_cfg)
        STATE["commits"].append({"ts":now_ms(),"actor":actor,"role":role,"cid":cid})
        STATE["audit"].append(json.dumps({"ts":now_ms(),"event":"config_commit","actor":actor,"role":role,"cid":cid},separators=(",",":")))
        return True,cid
    except Exception as e:
        STATE["cfg"]=json.loads(snap)
        STATE["audit"].append(json.dumps({"ts":now_ms(),"event":"config_rollback","error":str(e)},separators=(",",":")))
        return False,"rollback"
def risk_check_pre(env,cfg,side,qty,price):
    mp=float(cfg.get("risk",{}).get("max_position",1e18))
    mn=float(cfg.get("risk",{}).get("max_notional",1e18))
    psl=float(cfg.get("risk",{}).get("per_trade_loss_limit",1e18))
    np=env["position"]+(qty if side=="BUY" else -qty)
    if abs(np)>mp:return False,"position_limit"
    if qty*price>mn:return False,"notional_limit"
    if psl<1e17:
        estp,fee=exec_price_fee(side,qty,price,cfg["execution"]["fee_bps"],cfg["execution"]["slip_bps"])
        estloss=fee
        if estloss>psl:return False,"per_trade_loss_limit"
    return True,""
def risk_check_post(env,cfg):
    md=float(cfg.get("risk",{}).get("max_drawdown",1.0))
    pk=env["equity_peak"];eq=env["equity"]
    if eq>pk:env["equity_peak"]=eq
    dd=(pk-eq)/pk if pk>0 else 0.0
    if dd>md:return False,"drawdown_breach"
    return True,""
def daily_roll(env,cfg,ts):
    day=int(ts//86400)
    if STATE["daily"]["start_ts"]==0 or int(STATE["daily"]["start_ts"]//86400)!=day:
        STATE["daily"]["start_ts"]=ts
        STATE["daily"]["start_equity"]=env["equity"]
        STATE["daily"]["loss"]=0.0
def daily_limit_breach(env,cfg):
    lim=float(cfg.get("risk",{}).get("daily_loss_limit",1e18))
    if lim>=1e17:return False
    cur=STATE["daily"]["start_equity"];loss=max(0.0,cur-env["equity"])
    STATE["daily"]["loss"]=loss
    return loss>lim
def sharpe_from_trace(lines):
    eq=[];ap=eq.append
    for ln in lines:
        o=json.loads(ln);ap(o["equity"])
    if len(eq)<3:return None
    re=[];apr=re.append
    for i in range(1,len(eq)):
        if eq[i-1]>0:apr((eq[i]-eq[i-1])/eq[i-1])
    if not re:return None
    avg=sum(re)/float(len(re))
    var=sum((x-avg)*(x-avg) for x in re)/float(len(re))/1.0
    sd=math.sqrt(var) if var>0 else 0.0
    if sd==0.0:return None
    return (avg/sd)*math.sqrt(252.0)
def twap_slices(qty,slices):
    if slices<=0:return []
    q=qty/float(slices)
    return [q for _ in range(slices)]
def vwap_price(window,series):
    n=len(series)
    if n==0:return None
    w=min(window,n)
    s=0.0;v=0.0
    for i in range(n-w,n):
        p=series[i];vol=1.0
        s+=p*vol;v+=vol
    return s/v if v>0 else series[-1]
def pov_qty(target_pov,bar_vol):
    if bar_vol<=0:return 0.0
    return target_pov*bar_vol
def exec_algo(cfg,env,side,qty,ref_price,ts):
    ex=cfg.get("execution",{})
    fee_bps=float(ex.get("fee_bps",0.2))
    slip_bps=float(ex.get("slip_bps",0.8))
    if ex.get("twap",{}).get("enabled",False):
        slices=int(ex["twap"].get("slices",10))
        duration_ms=int(ex["twap"].get("duration_ms",600000))
        if slices<1:slices=1
        interval=duration_ms//slices if duration_ms>0 else 1
        filled_qty=0.0
        for i in range(slices):
            q=min(qty-filled_qty,twap_slices(qty,slices)[i])
            if q<=0:break
            ep,fee=exec_price_fee(side,q,ref_price,fee_bps,slip_bps)
            filled_qty+=_apply_fill(env,side,q,ep,fee,ts+i*interval)
        return filled_qty
    if ex.get("vwap",{}).get("enabled",False):
        vwp=vwap_price(int(ex["vwap"].get("window",50)),env["close_series"])
        base=ref_price if vwp is None else vwp
        ep,fee=exec_price_fee(side,qty,base,fee_bps,slip_bps)
        return _apply_fill(env,side,qty,ep,fee,ts)
    if ex.get("pov",{}).get("enabled",False):
        part=float(ex["pov"].get("participation",0.1))
        bar_vol=max(1.0,env.get("bar_volume",1.0))
        q=min(qty,pov_qty(part,bar_vol))
        ep,fee=exec_price_fee(side,q,ref_price,fee_bps,slip_bps)
        return _apply_fill(env,side,q,ep,fee,ts)
    ep,fee=exec_price_fee(side,qty,ref_price,fee_bps,slip_bps)
    return _apply_fill(env,side,qty,ep,fee,ts)
def _apply_fill(env,side,qty,price,fee,ts):
    if side=="BUY":
        cost=price*qty+fee
        if env["cash"]>=cost:
            env["cash"]-=cost;env["position"]+=qty
            STATE["audit"].append(json.dumps({"ts":ts,"event":"fill","side":"BUY","qty":qty,"price":price,"fee":fee},separators=(",",":")))
            return qty
        else:
            STATE["audit"].append(json.dumps({"ts":ts,"event":"reject","reason":"insufficient_cash"},separators=(",",":")))
            return 0.0
    else:
        qty=min(qty,env["position"])
        proceeds=price*qty-fee
        env["cash"]+=proceeds;env["position"]-=qty
        STATE["audit"].append(json.dumps({"ts":ts,"event":"fill","side":"SELL","qty":qty,"price":price,"fee":fee},separators=(",",":")))
        return qty
def backtest(cfg,data,outdir):
    os.makedirs(outdir,exist_ok=True)
    STATE["audit"].clear();STATE["trace"].clear()
    ch=hcfg(cfg);STATE["audit"].append(json.dumps({"ts":now_ms(),"event":"config_snapshot","hash":ch,"cfg":cfg},separators=(",",":")))
    env={"ts":0,"close_series":[],"position":0.0,"cash":float(cfg.get("initial_cash",100000000.0)),"equity":float(cfg.get("initial_cash",100000000.0)),"equity_peak":float(cfg.get("initial_cash",100000000.0)),"fills":[],"bar_volume":0.0}
    dsl=cfg.get("strategy",STATE["cfg"]["strategy"])
    fee=float(cfg.get("execution",{}).get("fee_bps",0.2));slip=float(cfg.get("execution",{}).get("slip_bps",0.8))
    STATE["daily"]["start_ts"]=0;STATE["daily"]["start_equity"]=env["equity"];STATE["daily"]["loss"]=0.0
    la=len(data)
    for idx in range(la):
        b=data[idx]
        env["ts"]=b["ts"];env["bar_volume"]=b.get("volume",0.0)
        env["close_series"].append(b["close"])
        denv={"close":env["close_series"],"fast":None,"slow":None,"position":env["position"]}
        act=apply_dsl(dsl,denv)
        daily_roll(env,cfg,b["ts"])
        if act:
            if act["action"]=="BUY":
                q=float(act.get("qty",0))
                ok,rr=risk_check_pre(env,cfg,"BUY",q,b["close"])
                if ok and q>0:
                    filled=exec_algo(cfg,env,"BUY",q,b["close"],b["ts"])
                    if filled<=0.0:STATE["audit"].append(json.dumps({"ts":b["ts"],"event":"reject","reason":"no_fill"},separators=(",",":")))
                else:
                    STATE["audit"].append(json.dumps({"ts":b["ts"],"event":"reject","reason":rr},separators=(",",":")))
            elif act["action"]=="SELL":
                q=float(act.get("qty",0))
                ok,rr=risk_check_pre(env,cfg,"SELL",q,b["close"])
                if ok and q>0:
                    filled=exec_algo(cfg,env,"SELL",q,b["close"],b["ts"])
                    if filled<=0.0:STATE["audit"].append(json.dumps({"ts":b["ts"],"event":"reject","reason":"no_fill"},separators=(",",":")))
                else:
                    STATE["audit"].append(json.dumps({"ts":b["ts"],"event":"reject","reason":rr},separators=(",",":")))
            elif act["action"]=="SELL_ALL":
                q=env["position"]
                if q>0.0:
                    ok,rr=risk_check_pre(env,cfg,"SELL",q,b["close"])
                    if ok:
                        exec_algo(cfg,env,"SELL",q,b["close"],b["ts"])
                    else:
                        STATE["audit"].append(json.dumps({"ts":b["ts"],"event":"reject","reason":rr},separators=(",",":")))
        env["equity"]=env["cash"]+env["position"]*b["close"]
        if daily_limit_breach(env,cfg):
            STATE["audit"].append(json.dumps({"ts":b["ts"],"event":"circuit_breaker","reason":"daily_loss_limit"},separators=(",",":")))
            break
        ok,rr=risk_check_post(env,cfg)
        STATE["trace"].append(json.dumps({"ts":b["ts"],"close":b["close"],"position":env["position"],"cash":env["cash"],"equity":env["equity"]},separators=(",",":")))
        if not ok:
            STATE["audit"].append(json.dumps({"ts":b["ts"],"event":"circuit_breaker","reason":rr},separators=(",",":")))
            break
    pnl=env["equity"]-float(cfg.get("initial_cash",100000000.0))
    ret=(pnl/float(cfg.get("initial_cash",100000000.0))) if cfg.get("initial_cash",100000000.0)>0 else 0.0
    sh=sharpe_from_trace(STATE["trace"])
    summ={"initial_cash":float(cfg.get("initial_cash",100000000.0)),"final_equity":env["equity"],"pnl":pnl,"return":ret,"fills":len([x for x in STATE["audit"] if '"event":"fill"' in x]),"sharpe":sh,"config_hash":ch,"bars":len(STATE["trace"])}
    write_lines(os.path.join(outdir,"audit.jsonl"),STATE["audit"]);write_lines(os.path.join(outdir,"trace.jsonl"),STATE["trace"]);write_text(os.path.join(outdir,"summary.json"),json.dumps(summ,indent=2))
    return summ
def register_module(actor,role,kind,name,b64json):
    if not allowed(role,"module.load"):
        return False,"rbac_denied"
    try:
        raw=base64.b64decode(b64json).decode("utf-8","ignore")
        obj=json.loads(raw)
        STATE["modules"][kind][name]=obj
        STATE["audit"].append(json.dumps({"ts":now_ms(),"event":"module_load","kind":kind,"name":name},separators=(",",":")))
        return True,"ok"
    except Exception as e:
        STATE["audit"].append(json.dumps({"ts":now_ms(),"event":"module_load_error","kind":kind,"name":name,"error":str(e)},separators=(",",":")))
        return False,"error"
def run_data_module(name,params):
    m=STATE["modules"]["data"].get(name)
    if not m:return []
    t=m.get("type")
    if t=="embedded_csv":
        return load_bars_csv_text(m.get("csv",""))
    if t=="http_text":
        u=params.get("url",m.get("url",""))
        try:
            with urllib.request.urlopen(u,timeout=10) as r:text=r.read().decode("utf-8","ignore")
        except Exception:return []
        if m.get("format")=="csv":return load_bars_csv_text(text)
        return []
    if t=="json_schema":
        arr=m.get("data",[]);b=[]
        ap=b.append
        for o in arr:ap({"ts":parse_ts(o["ts"]),"open":float(o["open"]),"high":float(o["high"]),"low":float(o["low"]),"close":float(o["close"]),"volume":float(o.get("volume",0.0))})
        b.sort(key=lambda x:x["ts"]);return b
    return []
def run_strategy_module(name):
    m=STATE["modules"]["strategy"].get(name)
    if not m:return STATE["cfg"]["strategy"]
    return m
def run_exec_module(name,cfg):
    m=STATE["modules"]["exec"].get(name)
    if not m:return cfg.get("execution",STATE["cfg"]["execution"])
    ex=cfg.get("execution",{})
    for k,v in m.items():
        ex[k]=v
    return ex
def start_stream(name,url,interval_ms):
    if name in STATE["streams"]:return
    def loop():
        while STATE["streams"].get(name,{}).get("running",False):
            try:
                with urllib.request.urlopen(url,timeout=10) as r:t=r.read().decode("utf-8","ignore")
                bars=load_bars_csv_text(t)
                STATE["data"]=bars
                STATE["audit"].append(json.dumps({"ts":now_ms(),"event":"stream_tick","name":name,"rows":len(bars)},separators=(",",":")))
            except Exception as e:
                STATE["audit"].append(json.dumps({"ts":now_ms(),"event":"stream_error","name":name,"error":str(e)},separators=(",",":")))
            time.sleep(max(0.01,interval_ms/1000.0))
    STATE["streams"][name]={"running":True,"url":url,"interval_ms":interval_ms}
    threading.Thread(target=loop,daemon=True).start()
def stop_stream(name):
    if name in STATE["streams"]:STATE["streams"][name]["running"]=False
HTML=b"""<!DOCTYPE html><html><head><meta charset=utf-8><title>Institutional FinTech OS</title><meta name=viewport content="width=device-width,initial-scale=1"><style>
body{font-family:system-ui,Arial;margin:0;background:#0c0f13;color:#e6e6e6}
header{background:#12161c;padding:12px 16px;display:flex;justify-content:space-between;align-items:center}
h1{font-size:18px;margin:0}
main{padding:16px;display:grid;grid-template-columns:1fr 1fr;gap:16px}
section{background:#12161c;padding:12px;border-radius:8px}
label{display:block;margin:6px 0 2px}
input,textarea,select,button{width:100%;padding:8px;border-radius:6px;border:1px solid #2a2f3a;background:#0c0f13;color:#e6e6e6}
button{cursor:pointer}
pre{background:#0c0f13;padding:8px;border-radius:6px;overflow:auto;max-height:380px}
table{width:100%;border-collapse:collapse}
td,th{border-bottom:1px solid #2a2f3a;padding:6px;text-align:left}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:8px}
</style></head><body>
<header><h1>Institutional FinTech OS(single-file)</h1><div class=grid2><select id=role><option>admin</option><option>ops</option><option>viewer</option></select><button onclick="run()">Run Backtest</button></div></header>
<main>
<section><h2>Configuration</h2><div id=cfg></div><div class=grid2><button onclick="saveCfg()">Save</button><button onclick="resetCfg()">Reset</button></div></section>
<section><h2>Data</h2><label>Upload CSV</label><input type=file id=up accept=.csv onchange="upload()"><label>Fetch URL</label><input id=url placeholder='https://example.com/data.csv'><button onclick="fetchUrl()">Fetch</button><label>Run Data Module(name)</label><input id=modn placeholder='module_name'><label>Module Params(JSON)</label><textarea id=modp rows=4>{"url":""}</textarea><button onclick="runModule()">Load Module Data</button><label>Stream name</label><input id=sname><label>Stream URL</label><input id=surl><label>Interval(ms)</label><input id=sint type=number value=5000><div class=grid2><button onclick="startStream()">Start Stream</button><button onclick="stopStream()">Stop Stream</button></div><h3>Preview</h3><pre id=datap></pre></section>
<section><h2>Strategy DSL</h2><textarea id=dsl rows=16></textarea><div class=grid2><label>Apply Strategy Module(name)</label><input id=strmod></div></section>
<section><h2>Execution</h2><div class=grid2><label>Fee(bps)</label><input id=fee type=number step=0.01><label>Slippage(bps)</label><input id=slip type=number step=0.01></div><div class=grid2><label>TWAP enabled</label><select id=twap_en><option>false</option><option>true</option></select><label>TWAP slices</label><input id=twap_s type=number value=10></div><div class=grid2><label>TWAP duration(ms)</label><input id=twap_d type=number value=900000><label>VWAP enabled</label><select id=vwap_en><option>false</option><option>true</option></select></div><div class=grid2><label>VWAP window</label><input id=vwap_w type=number value=50><label>POV enabled</label><select id=pov_en><option>false</option><option>true</option></select></div><div class=grid2><label>POV participation(0-1)</label><input id=pov_p type=number step=0.01 value=0.1></div></section>
<section><h2>Risk</h2><div class=grid2><label>Initial Cash</label><input id=cash type=number><label>Max Position</label><input id=mp type=number></div><div class=grid2><label>Max Notional</label><input id=mn type=number><label>Max Drawdown(0-1)</label><input id=md type=number step=0.01></div><div class=grid2><label>Daily Loss Limit</label><input id=dll type=number><label>Per-trade Loss Limit</label><input id=ptl type=number></div><label>Seed</label><input id=seed type=number></section>
<section><h2>RBAC & Modules</h2><label>Module kind</label><select id=mk><option>data</option><option>strategy</option><option>exec</option></select><label>Module name</label><input id=mnm><label>Payload(base64 JSON)</label><textarea id=mb64 rows=8></textarea><button onclick="loadModule()">Register Module</button><h3>Registered Modules</h3><pre id=mods></pre><div class=grid2><button onclick="exportAudit()">Export Audit</button><button onclick="exportTrace()">Export Trace</button></div></section>
<section><h2>Results</h2><pre id=out></pre><h3>Audit</h3><pre id=audit></pre><h3>Trace</h3><pre id=trace></pre></section>
</main>
<script>
async function load(){let r=await fetch('/state');let s=await r.json();document.getElementById('dsl').value=JSON.stringify(s.cfg.strategy,null,2);document.getElementById('cash').value=s.cfg.initial_cash;document.getElementById('mp').value=s.cfg.risk.max_position;document.getElementById('mn').value=s.cfg.risk.max_notional;document.getElementById('md').value=s.cfg.risk.max_drawdown;document.getElementById('dll').value=s.cfg.risk.daily_loss_limit;document.getElementById('ptl').value=s.cfg.risk.per_trade_loss_limit;document.getElementById('fee').value=s.cfg.execution.fee_bps;document.getElementById('slip').value=s.cfg.execution.slip_bps;document.getElementById('twap_en').value=s.cfg.execution.twap.enabled?'true':'false';document.getElementById('twap_s').value=s.cfg.execution.twap.slices;document.getElementById('twap_d').value=s.cfg.execution.twap.duration_ms;document.getElementById('vwap_en').value=s.cfg.execution.vwap.enabled?'true':'false';document.getElementById('vwap_w').value=s.cfg.execution.vwap.window;document.getElementById('pov_en').value=s.cfg.execution.pov.enabled?'true':'false';document.getElementById('pov_p').value=s.cfg.execution.pov.participation;document.getElementById('seed').value=s.cfg.seed;document.getElementById('cfg').innerHTML='<pre>'+JSON.stringify(s.cfg,null,2)+'</pre>';document.getElementById('mods').textContent=JSON.stringify(s.modules,null,2);preview(s.data)}
function preview(d){let p=document.getElementById('datap');p.textContent=''+d.length+' rows\\n'+d.slice(0,10).map(x=>JSON.stringify(x)).join('\\n')}
async function saveCfg(){let s=JSON.parse(document.getElementById('dsl').value);let cur=JSON.parse(document.getElementById('cfg').textContent);let ex={"fee_bps":parseFloat(document.getElementById('fee').value),"slip_bps":parseFloat(document.getElementById('slip').value),"twap":{"enabled":document.getElementById('twap_en').value==='true',"slices":parseInt(document.getElementById('twap_s').value),"duration_ms":parseInt(document.getElementById('twap_d').value)},"vwap":{"enabled":document.getElementById('vwap_en').value==='true',"window":parseInt(document.getElementById('vwap_w').value)},"pov":{"enabled":document.getElementById('pov_en').value==='true',"participation":parseFloat(document.getElementById('pov_p').value)}};let b={"initial_cash":parseFloat(document.getElementById('cash').value),"risk":{"max_position":parseFloat(document.getElementById('mp').value),"max_notional":parseFloat(document.getElementById('mn').value),"max_drawdown":parseFloat(document.getElementById('md').value),"daily_loss_limit":parseFloat(document.getElementById('dll').value),"per_trade_loss_limit":parseFloat(document.getElementById('ptl').value)},"execution":ex,"seed":parseInt(document.getElementById('seed').value),"strategy":s,"rbac":cur.rbac,"profile":cur.profile};let role=document.getElementById('role').value;let r=await fetch('/config?role='+role,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)});await r.json();load()}
async function resetCfg(){await fetch('/reset',{method:'POST'});load()}
async function upload(){let f=document.getElementById('up').files[0];let t=await f.text();await fetch('/data',{method:'POST',headers:{'Content-Type':'text/csv'},body:t});load()}
async function fetchUrl(){let u=document.getElementById('url').value;let r=await fetch('/fetch?url='+encodeURIComponent(u));let t=await r.text();await fetch('/data',{method:'POST',headers:{'Content-Type':'text/csv'},body:t});load()}
async function loadModule(){let kind=document.getElementById('mk').value;let name=document.getElementById('mnm').value;let b64=document.getElementById('mb64').value;let role=document.getElementById('role').value;let r=await fetch('/module?kind='+kind+'&name='+encodeURIComponent(name)+'&role='+role,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({b64:b64})});await r.json();load()}
async function runModule(){let n=document.getElementById('modn').value;let p=document.getElementById('modp').value;let r=await fetch('/run_module?name='+encodeURIComponent(n),{method:'POST',headers:{'Content-Type':'application/json'},body:p});let t=await r.json();await fetch('/data',{method:'POST',headers:{'Content-Type':'text/csv'},body:t.csv});load()}
async function startStream(){let n=document.getElementById('sname').value;let u=document.getElementById('surl').value;let ms=parseInt(document.getElementById('sint').value||5000);await fetch('/stream_start?name='+encodeURIComponent(n)+'&url='+encodeURIComponent(u)+'&ms='+ms,{method:'POST'});load()}
async function stopStream(){let n=document.getElementById('sname').value;await fetch('/stream_stop?name='+encodeURIComponent(n),{method:'POST'});load()}
async function applyStrategyModule(){let n=document.getElementById('strmod').value;if(!n){return}let r=await fetch('/strategy_apply?name='+encodeURIComponent(n),{method:'POST'});await r.text();load()}
async function exportAudit(){let r=await fetch('/export_audit',{method:'POST'});let t=await r.text();alert(t)}
async function exportTrace(){let r=await fetch('/export_trace',{method:'POST'});let t=await r.text();alert(t)}
async function run(){document.getElementById('out').textContent='running...';let role=document.getElementById('role').value;let r=await fetch('/run?role='+role,{method:'POST'});let s=await r.json();document.getElementById('out').textContent=JSON.stringify(s,null,2);let a=await (await fetch('/audit')).text();document.getElementById('audit').textContent=a;let tr=await (await fetch('/trace')).text();document.getElementById('trace').textContent=tr}
load()
</script></body></html>"""
class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path=="/":
            self.send_response(200);self.send_header("Content-Type","text/html");self.end_headers();self.wfile.write(HTML)
        elif self.path=="/state":
            self.send_response(200);self.send_header("Content-Type","application/json");self.end_headers();self.wfile.write(json.dumps({"cfg":STATE["cfg"],"data":STATE["data"],"modules":STATE["modules"]},separators=(",",":")).encode())
        elif self.path.startswith("/fetch"):
            q=urllib.parse.urlparse(self.path).query;u=urllib.parse.parse_qs(q).get("url",[""])[0]
            try:
                with urllib.request.urlopen(u,timeout=10) as r:t=r.read().decode("utf-8","ignore")
            except Exception:t=""
            self.send_response(200);self.send_header("Content-Type","text/plain");self.end_headers();self.wfile.write(t.encode("utf-8"))
        elif self.path=="/audit":
            self.send_response(200);self.send_header("Content-Type","text/plain");self.end_headers();self.wfile.write(("\n".join(STATE["audit"])).encode("utf-8"))
        elif self.path=="/trace":
            self.send_response(200);self.send_header("Content-Type","text/plain");self.end_headers();self.wfile.write(("\n".join(STATE["trace"])).encode("utf-8"))
        else:
            super().do_GET()
    def do_POST(self):
        l=int(self.headers.get("Content-Length","0"));b=self.rfile.read(l)
        if self.path.startswith("/config"):
            role=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("role",["viewer"])[0]
            try:new=json.loads(b.decode("utf-8"));ok,cid=commit_config("web",role,new)
            except Exception:ok,cid=False,"bad_json"
            self.send_response(200);self.send_header("Content-Type","application/json");self.end_headers();self.wfile.write(json.dumps({"ok":ok,"commit":cid},separators=(",",":")).encode("utf-8"))
        elif self.path=="/data":
            t=b.decode("utf-8","ignore");STATE["data"]=load_bars_csv_text(t);self.send_response(200);self.end_headers()
        elif self.path.startswith("/module"):
            q=urllib.parse.urlparse(self.path).query;p=urllib.parse.parse_qs(q);kind=p.get("kind",["data"])[0];name=p.get("name",[""])[0];role=p.get("role",["viewer"])[0]
            try:payload=json.loads(b.decode("utf-8"));ok,msg=register_module("web",role,kind,name,payload.get("b64",""))
            except Exception:ok,msg=False,"bad_json"
            self.send_response(200);self.send_header("Content-Type","application/json");self.end_headers();self.wfile.write(json.dumps({"ok":ok,"msg":msg},separators=(",",":")).encode("utf-8"))
        elif self.path.startswith("/run_module"):
            n=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("name",[""])[0]
            try:params=json.loads(b.decode("utf-8"))
            except Exception:params={}
            bars=run_data_module(n,params)
            csvbuf="timestamp,open,high,low,close,volume\n"+"\n".join([",".join([str(x["ts"]),str(x["open"]),str(x["high"]),str(x["low"]),str(x["close"]),str(x["volume"])]) for x in bars])
            self.send_response(200);self.send_header("Content-Type","application/json");self.end_headers();self.wfile.write(json.dumps({"csv":csvbuf},separators=(",",":")).encode("utf-8"))
        elif self.path.startswith("/stream_start"):
            p=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query);name=p.get("name",[""])[0];url=p.get("url",[""])[0];ms=int(p.get("ms",[5000])[0])
            if not allowed("ops","stream.manage") and not allowed("admin","stream.manage"):self.send_response(403);self.end_headers();return
            start_stream(name,url,ms);self.send_response(200);self.end_headers()
        elif self.path.startswith("/stream_stop"):
            name=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("name",[""])[0];stop_stream(name);self.send_response(200);self.end_headers()
        elif self.path.startswith("/strategy_apply"):
            name=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("name",[""])[0]
            st=run_strategy_module(name);STATE["cfg"]["strategy"]=st;self.send_response(200);self.end_headers()
        elif self.path.startswith("/run"):
            role=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("role",["viewer"])[0]
            if not allowed(role,"run.execute"):self.send_response(403);self.end_headers();return
            if not STATE["data"]:self.send_response(400);self.end_headers();return
            try:STATE["cfg"]["execution"]=run_exec_module("default_exec",STATE["cfg"])
            except Exception:pass
            STATE["running"]=True
            try:summ=backtest(STATE["cfg"],STATE["data"],STATE["outdir"])
            except Exception as e:
                STATE["audit"].append(json.dumps({"ts":now_ms(),"event":"run_error","error":str(e),"trace":traceback.format_exc()},separators=(",",":")));summ={"error":"run_error"}
            STATE["running"]=False
            self.send_response(200);self.send_header("Content-Type","application/json");self.end_headers();self.wfile.write(json.dumps(summ,separators=(",",":")).encode("utf-8"))
        elif self.path=="/reset":
            STATE["cfg"]={"seed":123456789,"initial_cash":100000000.0,"risk":{"max_position":10000000.0,"max_notional":100000000000.0,"max_drawdown":0.25,"daily_loss_limit":5000000.0,"per_trade_loss_limit":1000000.0},"execution":{"fee_bps":0.2,"slip_bps":0.8,"twap":{"enabled":False,"slices":10,"duration_ms":900000},"vwap":{"enabled":False,"window":50},"pov":{"enabled":False,"participation":0.1}},"strategy":{"type":"rule_chain","params":{"fast":20,"slow":100,"rsiw":14},"rules":[{"if":"sma(close,fast)>sma(close,slow) and rsi(close,rsiw)<70","do":"BUY","qty":1000},{"if":"sma(close,fast)<sma(close,slow) or rsi(close,rsiw)>80","do":"SELL_ALL"}]},"rbac":{"roles":{"admin":{"caps":["config.write","run.execute","module.load","data.ingest","stream.manage","export.files"]},"ops":{"caps":["run.execute","data.ingest","stream.manage","export.files"]},"viewer":{"caps":["export.files"]}}},"profile":"paper"};self.send_response(200);self.end_headers()
        elif self.path=="/export_audit":
            if not (allowed("admin","export.files") or allowed("ops","export.files") or allowed("viewer","export.files")):self.send_response(403);self.end_headers();return
            write_lines(os.path.join(STATE["outdir"],"audit.jsonl"),STATE["audit"]);self.send_response(200);self.end_headers();self.wfile.write(b"exported audit.jsonl")
        elif self.path=="/export_trace":
            if not (allowed("admin","export.files") or allowed("ops","export.files") or allowed("viewer","export.files")):self.send_response(403);self.end_headers();return
            write_lines(os.path.join(STATE["outdir"],"trace.jsonl"),STATE["trace"]);self.send_response(200);self.end_headers();self.wfile.write(b"exported trace.jsonl")
        else:
            self.send_response(404);self.end_headers()
def serve(host,port):
    with socketserver.TCPServer((host,port),Handler) as httpd:httpd.serve_forever()
def main():
    p=argparse.ArgumentParser();p.add_argument("--host",default="0.0.0.0");p.add_argument("--port",type=int,default=8080);p.add_argument("--out",default="out");p.add_argument("--data");p.add_argument("--config");a=p.parse_args();STATE["outdir"]=a.out
    if a.config:
        try:STATE["cfg"]=load_json(a.config)
        except Exception:pass
    if a.data:
        try:STATE["data"]=load_bars_csv_text(open(a.data,"r",encoding="utf-8").read())
        except Exception:pass
    t=threading.Thread(target=serve,args=(a.host,a.port),daemon=True);t.start();print("http://%s:%d"%(a.host,a.port))
    try:
        while True:time.sleep(1)
    except KeyboardInterrupt:sys.exit(0)
if __name__=="__main__":main()
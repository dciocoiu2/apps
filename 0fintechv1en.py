#!/usr/bin/env python
import http.server,socketserver,json,sys,os,io,base64,hashlib,random,time,math,csv,urllib.request,urllib.parse,threading,argparse,traceback

STATE={"cfg":{"seed":123456789,"initial_cash":100000000.0,"risk":{"max_position":10000000.0,"max_notional":100000000000.0,"max_drawdown":0.25,"daily_loss_limit":5000000.0,"per_trade_loss_limit":1000000.0},"execution":{"fee_bps":0.2,"slip_bps":0.8,"twap":{"enabled":False,"slices":10,"duration_ms":900000},"vwap":{"enabled":False,"window":50},"pov":{"enabled":False,"participation":0.1}},"strategy":{"type":"rule_chain","params":{"fast":20,"slow":100,"rsiw":14},"rules":[{"if":"sma(close,fast)>sma(close,slow) and rsi(close,rsiw)<70","do":"BUY","qty":1000},{"if":"sma(close,fast)<sma(close,slow) or rsi(close,rsiw)>80","do":"SELL_ALL"}]},"rbac":{"roles":{"admin":{"caps":["config.write","run.execute","module.load","data.ingest","stream.manage","import.plugin","export.files"]},"ops":{"caps":["run.execute","data.ingest","stream.manage","import.plugin","export.files"]},"viewer":{"caps":["export.files"]}}},"profile":"paper"},"data":[],"audit":[],"trace":[],"running":False,"outdir":"out","modules":{"data":{},"strategy":{},"exec":{},"risk":{}},"commits":[],"streams":{},"daily":{"start_ts":0,"start_equity":0.0,"loss":0.0}}

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
    b=[];ap=b.append
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
    g=0.0; l=0.0
    for i in range(n-w,n-1):
        d=c[i+1]-c[i]
        if d>0:g+=d
        else:l+=-d
    if l==0.0:return 100.0
    rs=g/l
    return 100.0-(100.0/(1.0+rs))

def eval_expr(e,env):
    def pf(tok):
        n,rest=tok.split("(",1)
        args=rest[:-1]
        parts=[p.strip() for p in args.split(",")]
        return n.strip(),parts
    def val(x):
        if x in env:return env[x]
        try:return float(x)
        except:
            if "(" in x and x.endswith(")"):
                n,parts=pf(x)
                if n=="sma":sn=parts[0];w=int(env.get(parts[1],parts[1]));return sma(env[sn],w)
                if n=="ema":sn=parts[0];w=int(env.get(parts[1],parts[1]));return ema(env[sn],w)
                if n=="rsi":sn=parts[0];w=int(env.get(parts[1],parts[1]));return rsi(env[sn],w)
            return None
    t=e.replace(">="," ≥ ").replace("<="," ≤ ").replace("=="," ≡ ").replace(">"," > ").replace("<"," < ").replace("and"," and ").replace("or"," or ").split()
    r=[];i=0
    while i<len(t):
        tt=t[i]
        if tt in("and","or"):
            r.append(tt);i+=1;continue
        l=tt;op=t[i+1];ri=t[i+2]
        lv=val(l);rv=val(ri)
        if lv is None or rv is None:c=False
        else:
            if op in (">"," > "):c=lv>rv
            elif op in ("<"," < "):c=lv<rv
            elif op=="≥":c=lv>=rv
            elif op=="≤":c=lv<=rv
            elif op=="≡":c=(lv==rv)
            else:c=False
        r.append(c);i+=3
    if not r:return False
    a=r[0];j=1
    while j<len(r):
        op=r[j];v=r[j+1]
        if op=="and":a=a and v
        elif op=="or":a=a or v
        j+=2
    return a

def apply_dsl(dsl,env):
    if dsl.get("type")!="rule_chain":return None
    for k,v in dsl.get("params",{}).items():env[k]=v
    for r in dsl.get("rules",[]):
        cond=r.get("if","")
        if cond=="" or eval_expr(cond,env):
            a=r.get("do","").upper()
            if a=="BUY":return {"action":"BUY","qty":float(r.get("qty",0))}
            if a=="SELL":return {"action":"SELL","qty":float(r.get("qty",0))}
            if a=="SELL_ALL":return {"action":"SELL_ALL"}
            if a=="HOLD":return {"action":"HOLD"}
    return None

def exec_price_fee(side,qty,price,fee_bps,slip_bps):
    adj=price*(slip_bps/10000.0)
    ep=price+(adj if side=="BUY" else -adj)
    fee=ep*qty*(fee_bps/10000.0)
    return ep,fee

def allowed(role,cap):
    return cap in STATE["cfg"].get("rbac",{}).get("roles",{}).get(role,{}).get("caps",[])

def commit_config(actor,role,new_cfg):
    if not allowed(role,"config.write"):return False,"rbac_denied"
    old=STATE["cfg"];snap=json.dumps(old,sort_keys=True,separators=(",",":"))
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
    ptl=float(cfg.get("risk",{}).get("per_trade_loss_limit",1e18))
    np=env["position"]+(qty if side=="BUY" else -qty)
    if abs(np)>mp:return False,"position_limit"
    if qty*price>mn:return False,"notional_limit"
    if ptl<1e17:
        ep,fee=exec_price_fee(side,qty,price,cfg["execution"].get("fee_bps",0.2),cfg["execution"].get("slip_bps",0.8))
        estloss=fee
        if estloss>ptl:return False,"per_trade_loss_limit"
    return True,""

def risk_check_post(env,cfg):
    md=float(cfg.get("risk",{}).get("max_drawdown",1.0))
    pk=env["equity_peak"];eq=env["equity"]
    if eq>pk:env["equity_peak"]=eq;return True,""
    dd=(pk-eq)/pk if pk>0 else 0.0
    if dd>md:return False,"drawdown_breach"
    return True,""

def daily_roll(env,cfg,ts):
    day=int(ts//86400000)
    if STATE["daily"]["start_ts"]==0 or int(STATE["daily"]["start_ts"]//86400000)!=day:
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
    eq=[]
    for ln in lines:
        o=json.loads(ln);eq.append(o["equity"])
    if len(eq)<3:return None
    re=[]
    for i in range(1,len(eq)):
        if eq[i-1]>0:re.append((eq[i]-eq[i-1])/eq[i-1])
    if not re:return None
    avg=sum(re)/float(len(re));var=sum((x-avg)*(x-avg) for x in re)/float(len(re))
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

def _apply_fill(env,side,qty,price,fee,ts):
    if qty<=0:return 0.0
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

def exec_algo(cfg,env,side,qty,ref_price,ts):
    ex=cfg.get("execution",{})
    fee_bps=float(ex.get("fee_bps",0.2));slip_bps=float(ex.get("slip_bps",0.8))
    if ex.get("twap",{}).get("enabled",False):
        slices=int(ex["twap"].get("slices",10));duration_ms=int(ex["twap"].get("duration_ms",600000))
        if slices<1:slices=1
        per=qty/float(slices)
        filled=0.0
        for i in range(slices):
            q=min(qty-filled,per)
            if q<=0:break
            ep,fee=exec_price_fee(side,q,ref_price,fee_bps,slip_bps)
            filled+=_apply_fill(env,side,q,ep,fee,ts+i*(duration_ms//max(1,slices)))
        return filled
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
    if ex.get("iceberg",{}).get("enabled",False):
        child=int(ex["iceberg"].get("child_size",1000))
        if child<1:child=1
        remain=qty;filled=0.0
        while remain>0:
            q=min(child,remain)
            ep,fee=exec_price_fee(side,q,ref_price,fee_bps,slip_bps)
            f=_apply_fill(env,side,q,ep,fee,ts)
            if f<=0:break
            filled+=f;remain-=f
        return filled
    ep,fee=exec_price_fee(side,qty,ref_price,fee_bps,slip_bps)
    return _apply_fill(env,side,qty,ep,fee,ts)

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
                q=float(act.get("qty",0));ok,rr=risk_check_pre(env,cfg,"SELL",q,b["close"])
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
    write_lines(os.path.join(STATE["outdir"],"audit.jsonl"),STATE["audit"]);write_lines(os.path.join(STATE["outdir"],"trace.jsonl"),STATE["trace"]);write_text(os.path.join(STATE["outdir"],"summary.json"),json.dumps(summ,indent=2))
    return summ

# Plugin registry and autodetect
def register_module(actor,role,kind,name,obj):
    if not allowed(role,"module.load") and not allowed(role,"import.plugin"):return False,"rbac_denied"
    STATE["modules"].setdefault(kind,{})[name]=obj
    STATE["audit"].append(json.dumps({"ts":now_ms(),"event":"module_register","kind":kind,"name":name,"actor":actor,"role":role},separators=(",",":")))
    return True,"ok"

def autodetect_plugin(obj):
    if not isinstance(obj,dict):return None
    if "csv" in obj or obj.get("type") in ("embedded_csv","http_text","json_schema"):return "data"
    if "rules" in obj and obj.get("type")=="rule_chain":return "strategy"
    if any(k in obj for k in ("twap","vwap","pov","iceberg")):return "exec"
    if "limits" in obj or "kill_switch" in obj:return "risk"
    if "type" in obj:
        t=obj.get("type")
        if t in ("embedded_csv","http_text","json_schema"):return "data"
        if t=="rule_chain":return "strategy"
    return None

def run_data_module(name,params):
    m=STATE["modules"]["data"].get(name)
    if not m:return []
    t=m.get("type")
    if t=="embedded_csv":return load_bars_csv_text(m.get("csv",""))
    if t=="http_text":
        u=params.get("url",m.get("url",""))
        try:
            with urllib.request.urlopen(u,timeout=10) as r:text=r.read().decode("utf-8","ignore")
        except Exception:return []
        if m.get("format")=="csv":return load_bars_csv_text(text)
        return []
    if t=="json_schema":
        arr=m.get("data",[]);b=[];ap=b.append
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
    ex=cfg.get("execution",{}).copy()
    for k,v in m.items():ex[k]=v
    return ex

def start_stream(name,url,interval_ms):
    if name in STATE["streams"] and STATE["streams"][name].get("running",False):return
    def loop():
        while STATE["streams"].get(name,{}).get("running",False):
            try:
                with urllib.request.urlopen(url,timeout=10) as r:t=r.read().decode("utf-8","ignore")
                bars=load_bars_csv_text(t);STATE["data"]=bars
                STATE["audit"].append(json.dumps({"ts":now_ms(),"event":"stream_tick","name":name,"rows":len(bars)},separators=(",",":")))
            except Exception as e:
                STATE["audit"].append(json.dumps({"ts":now_ms(),"event":"stream_error","name":name,"error":str(e)},separators=(",",":")))
            time.sleep(max(0.01,interval_ms/1000.0))
    STATE["streams"][name]={"running":True,"url":url,"interval_ms":interval_ms}
    threading.Thread(target=loop,daemon=True).start()

def stop_stream(name):
    if name in STATE["streams"]:STATE["streams"][name]["running"]=False

# HTTP server and endpoints
HTML=b"""<!DOCTYPE html><html><head><meta charset=utf-8><title>FinTech OS</title><meta name=viewport content="width=device-width,initial-scale=1"><style>
body{font-family:system-ui,Arial;margin:0;background:#0b0d10;color:#e6e6e6}
header{background:#12161c;padding:12px 16px;display:flex;justify-content:space-between;align-items:center}
h1{font-size:18px;margin:0}
main{padding:16px;display:grid;grid-template-columns:1fr 1fr;gap:16px}
section{background:#12161c;padding:12px;border-radius:8px}
label{display:block;margin:6px 0 2px}
input,textarea,select,button{width:100%;padding:8px;border-radius:6px;border:1px solid #2a2f3a;background:#0b0d10;color:#e6e6e6}
button{cursor:pointer}
pre{background:#0b0d10;padding:8px;border-radius:6px;overflow:auto;max-height:320px}
</style></head><body><header><h1>FinTech OS(single-file)</h1><div><select id=role><option>admin</option><option>ops</option><option>viewer</option></select><button onclick="run()">Run</button></div></header><main>
<section><h2>Config</h2><div id=cfg></div><button onclick="saveCfg()">Save</button><button onclick="resetCfg()">Reset</button></section>
<section><h2>Data</h2><label>Upload CSV</label><input type=file id=up accept=.csv onchange="upload()"><label>Fetch URL</label><input id=url placeholder='https://example.com/data.csv'><button onclick="fetchUrl()">Fetch</button><label>Run Module(name)</label><input id=modn placeholder='module_name'><label>Module Params(JSON)</label><textarea id=modp rows=3>{"url":""}</textarea><button onclick="runModule()">Run Module</button><h3>Preview</h3><pre id=datap></pre></section>
<section><h2>Strategy</h2><textarea id=dsl rows=12></textarea><label>Apply Strategy Module</label><input id=strmod><button onclick="applyStrategyModule()">Apply</button></section>
<section><h2>Execution & Risk</h2><label>Execution Module</label><input id=execmod placeholder='exec_module_name'><label>Risk Module</label><input id=riskmod placeholder='risk_module_name'></section>
<section><h2>Import Plugin (JSON)</h2><label>Plugin name (optional)</label><input id=impname placeholder='optional_name'><label>Paste JSON</label><textarea id=imp rows=12></textarea><button onclick="importPlugin()">Import</button><h3>Registered Modules</h3><pre id=mods></pre></section>
<section><h2>Results</h2><pre id=out></pre><h3>Audit</h3><pre id=audit></pre><h3>Trace</h3><pre id=trace></pre></section>
</main><script>
async function load(){let r=await fetch('/state');let s=await r.json();document.getElementById('dsl').value=JSON.stringify(s.cfg.strategy,null,2);document.getElementById('cfg').innerHTML='<pre>'+JSON.stringify(s.cfg,null,2)+'</pre>';document.getElementById('mods').textContent=JSON.stringify(s.modules,null,2);preview(s.data)}
function preview(d){let p=document.getElementById('datap');p.textContent=''+d.length+' rows\\n'+d.slice(0,5).map(x=>JSON.stringify(x)).join('\\n')}
async function saveCfg(){let s=JSON.parse(document.getElementById('dsl').value);let cur=JSON.parse(document.getElementById('cfg').textContent);let b=cur; b.strategy=s; let role=document.getElementById('role').value;await fetch('/config?role='+role,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)});load()}
async function resetCfg(){await fetch('/reset',{method:'POST'});load()}
async function upload(){let f=document.getElementById('up').files[0];let t=await f.text();await fetch('/data',{method:'POST',headers:{'Content-Type':'text/csv'},body:t});load()}
async function fetchUrl(){let u=document.getElementById('url').value;let r=await fetch('/fetch?url='+encodeURIComponent(u));let t=await r.text();await fetch('/data',{method:'POST',headers:{'Content-Type':'text/csv'},body:t});load()}
async function runModule(){let n=document.getElementById('modn').value;let p=document.getElementById('modp').value;let r=await fetch('/run_module?name='+encodeURIComponent(n),{method:'POST',headers:{'Content-Type':'application/json'},body:p});let t=await r.json();await fetch('/data',{method:'POST',headers:{'Content-Type':'text/csv'},body:t.csv});load()}
async function applyStrategyModule(){let n=document.getElementById('strmod').value;if(!n){return}let r=await fetch('/strategy_apply?name='+encodeURIComponent(n),{method:'POST'});await r.text();load()}
async function importPlugin(){let name=document.getElementById('impname').value;let txt=document.getElementById('imp').value;let role=document.getElementById('role').value;await fetch('/import_plugin?role='+role+'&name='+encodeURIComponent(name),{method:'POST',headers:{'Content-Type':'application/json'},body:txt});load()}
async function run(){document.getElementById('out').textContent='running...';let role=document.getElementById('role').value;let execm=document.getElementById('execmod').value;let riskm=document.getElementById('riskmod').value;let r=await fetch('/run?role='+role+'&exec='+encodeURIComponent(execm)+'&risk='+encodeURIComponent(riskm),{method:'POST'});let s=await r.json();document.getElementById('out').textContent=JSON.stringify(s,null,2);document.getElementById('audit').textContent=await (await fetch('/audit')).text();document.getElementById('trace').textContent=await (await fetch('/trace')).text()}
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
            except Exception as e:t=""
            self.send_response(200);self.send_header("Content-Type","text/plain");self.end_headers();self.wfile.write(t.encode("utf-8"))
        elif self.path=="/audit":
            self.send_response(200);self.send_header("Content-Type","text/plain");self.end_headers();self.wfile.write(("\n".join(STATE["audit"])).encode("utf-8"))
        elif self.path=="/trace":
            self.send_response(200);self.send_header("Content-Type","text/plain");self.end_headers();self.wfile.write(("\n".join(STATE["trace"])).encode("utf-8"))
        else:
            super().do_GET()

    def do_POST(self):
        l=int(self.headers.get("Content-Length","0"));b=self.rfile.read(l)
        path=self.path.split("?",1)[0]
        if self.path.startswith("/config"):
            role=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("role",["viewer"])[0]
            try:new=json.loads(b.decode("utf-8"));ok,cid=commit_config("web",role,new)
            except Exception:ok,cid=False,"bad_json"
            self.send_response(200);self.send_header("Content-Type","application/json");self.end_headers();self.wfile.write(json.dumps({"ok":ok,"commit":cid},separators=(",",":")).encode())
            return
        if path=="/data":
            t=b.decode("utf-8","ignore");STATE["data"]=load_bars_csv_text(t);self.send_response(200);self.end_headers();return
        if path=="/run_module":
            n=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("name",[""])[0]
            try:params=json.loads(b.decode("utf-8"))
            except:params={}
            bars=run_data_module(n,params)
            csvbuf="timestamp,open,high,low,close,volume\n"+"\n".join([",".join([str(x["ts"]),str(x["open"]),str(x["high"]),str(x["low"]),str(x["close"]),str(x["volume"])]) for x in bars])
            self.send_response(200);self.send_header("Content-Type","application/json");self.end_headers();self.wfile.write(json.dumps({"csv":csvbuf},separators=(",",":")).encode());return
        if path=="/strategy_apply":
            name=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("name",[""])[0]
            st=run_strategy_module(name);STATE["cfg"]["strategy"]=st;self.send_response(200);self.end_headers();return
        if path=="/import_plugin":
            role=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("role",["viewer"])[0]
            provided_name=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("name",[""])[0]
            try:
                obj=json.loads(b.decode("utf-8"))
            except Exception:
                self.send_response(400);self.end_headers();self.wfile.write(b"bad_json");return
            kind=autodetect_plugin(obj)
            if kind is None:
                self.send_response(400);self.end_headers();self.wfile.write(b"unknown_plugin_type");return
            name=provided_name if provided_name else obj.get("name",None)
            if not name:
                name=kind+"_"+hashlib.sha256(json.dumps(obj,separators=(",",":")).encode()).hexdigest()[:8]
            ok,msg=register_module("web",role,kind,name,obj)
            if not ok:
                self.send_response(403);self.end_headers();self.wfile.write(msg.encode());return
            self.send_response(200);self.end_headers();self.wfile.write(b"imported");return
        if path.startswith("/stream_start"):
            p=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query);name=p.get("name",[""])[0];url=p.get("url",[""])[0];ms=int(p.get("ms",[5000])[0])
            if not (allowed("ops","stream.manage") or allowed("admin","stream.manage")):self.send_response(403);self.end_headers();return
            start_stream(name,url,ms);self.send_response(200);self.end_headers();return
        if path.startswith("/stream_stop"):
            name=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("name",[""])[0];stop_stream(name);self.send_response(200);self.end_headers();return
        if path.startswith("/module"):
            q=urllib.parse.urlparse(self.path).query;p=urllib.parse.parse_qs(q);kind=p.get("kind",["data"])[0];name=p.get("name",[""])[0];role=p.get("role",["viewer"])[0]
            try:payload=json.loads(b.decode("utf-8"));ok,msg=register_module("web",role,kind,name,payload)
            except Exception:ok,msg=False,"bad_json"
            self.send_response(200);self.send_header("Content-Type","application/json");self.end_headers();self.wfile.write(json.dumps({"ok":ok,"msg":msg},separators=(",",":")).encode());return
        if path.startswith("/run"):
            q=urllib.parse.urlparse(self.path).query;params=urllib.parse.parse_qs(q);role=params.get("role",["viewer"])[0];execm=params.get("exec",[""])[0];riskm=params.get("risk",[""])[0]
            if not allowed(role,"run.execute"):self.send_response(403);self.end_headers();return
            if not STATE["data"]:self.send_response(400);self.end_headers();return
            try:
                if execm:STATE["cfg"]["execution"]=run_exec_module(execm,STATE["cfg"])
                if riskm and riskm in STATE["modules"].get("risk",{}):
                    rpl=STATE["modules"]["risk"][riskm]
                    for k,v in rpl.get("limits",{}).items():STATE["cfg"]["risk"][k]=v
            except Exception:pass
            STATE["running"]=True
            try:summ=backtest(STATE["cfg"],STATE["data"],STATE["outdir"])
            except Exception as e:
                STATE["audit"].append(json.dumps({"ts":now_ms(),"event":"run_error","error":str(e),"trace":traceback.format_exc()},separators=(",",":")));summ={"error":"run_error"}
            STATE["running"]=False
            self.send_response(200);self.send_header("Content-Type","application/json");self.end_headers();self.wfile.write(json.dumps(summ,separators=(",",":")).encode());return
        if path=="/reset":
            STATE["cfg"]={"seed":123456789,"initial_cash":100000000.0,"risk":{"max_position":10000000.0,"max_notional":100000000000.0,"max_drawdown":0.25,"daily_loss_limit":5000000.0,"per_trade_loss_limit":1000000.0},"execution":{"fee_bps":0.2,"slip_bps":0.8,"twap":{"enabled":False,"slices":10,"duration_ms":900000},"vwap":{"enabled":False,"window":50},"pov":{"enabled":False,"participation":0.1}},"strategy":{"type":"rule_chain","params":{"fast":20,"slow":100,"rsiw":14},"rules":[{"if":"sma(close,fast)>sma(close,slow) and rsi(close,rsiw)<70","do":"BUY","qty":1000},{"if":"sma(close,fast)<sma(close,slow) or rsi(close,rsiw)>80","do":"SELL_ALL"}]},"rbac":{"roles":{"admin":{"caps":["config.write","run.execute","module.load","data.ingest","stream.manage","import.plugin","export.files"]},"ops":{"caps":["run.execute","data.ingest","stream.manage","import.plugin","export.files"]},"viewer":{"caps":["export.files"]}}},"profile":"paper"}
            self.send_response(200);self.end_headers();return
        if path=="/export_audit":
            if not (allowed("admin","export.files") or allowed("ops","export.files")):self.send_response(403);self.end_headers();return
            write_lines(os.path.join(STATE["outdir"],"audit.jsonl"),STATE["audit"]);self.send_response(200);self.end_headers();self.wfile.write(b"exported");return
        if path=="/export_trace":
            if not (allowed("admin","export.files") or allowed("ops","export.files")):self.send_response(403);self.end_headers();return
            write_lines(os.path.join(STATE["outdir"],"trace.jsonl"),STATE["trace"]);self.send_response(200);self.end_headers();self.wfile.write(b"exported");return
        self.send_response(404);self.end_headers();return

def serve(host,port):
    with socketserver.TCPServer((host,port),Handler) as httpd:
        httpd.serve_forever()

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
$root="pyloadlab";New-Item -ItemType Directory -Force $root|Out-Null;New-Item -ItemType Directory -Force "$root\core"|Out-Null;New-Item -ItemType Directory -Force "$root\protocols"|Out-Null;New-Item -ItemType Directory -Force "$root\reporting\templates"|Out-Null;New-Item -ItemType Directory -Force "$root\dashboard"|Out-Null;New-Item -ItemType Directory -Force "$root\dist"|Out-Null;New-Item -ItemType Directory -Force "$root\gui"|Out-Null;New-Item -ItemType Directory -Force "$root\examples"|Out-Null
Set-Content "$root\requirements.txt" -Encoding UTF8 -Value @'
httpx
websocket-client
grpcio
sqlalchemy
confluent-kafka
pika
paho-mqtt
paramiko
psutil
jinja2
streamlit
pandas
plotly
pyzmq
PySide6
tenacity
jsonschema
tqdm
'@
Set-Content "$root\core\models.py" -Encoding UTF8 -Value @'
from dataclasses import dataclass,field
from typing import Any,Dict,List,Optional
@dataclass
class Extractor:
    kind:str
    expr:str
    var:str
@dataclass
class Assertion:
    kind:str
    expr:Optional[str]=None
    expected:Optional[Any]=None
    threshold_ms:Optional[int]=None
@dataclass
class Step:
    type:str
    name:str
    config:Dict[str,Any]=field(default_factory=dict)
    headers:Dict[str,str]=field(default_factory=dict)
    params:Dict[str,Any]=field(default_factory=dict)
    body:Optional[str]=None
    timeout_s:float=30.0
    retries:int=0
    think_min_ms:int=0
    think_max_ms:int=0
    data_source_key:Optional[str]=None
    extractors:List[Extractor]=field(default_factory=list)
    assertions:List[Assertion]=field(default_factory=list)
    condition:Optional[str]=None
    loop:int=1
@dataclass
class ThreadGroup:
    name:str
    users:int
    ramp_up_s:float
    loop_count:int
@dataclass
class TestPlan:
    name:str
    description:str
    steps:List[Step]
    thread_groups:List[ThreadGroup]
    variables:Dict[str,Any]=field(default_factory=dict)
    data_sources:Dict[str,Dict[str,Any]]=field(default_factory=dict)
    report_path:str="report.html"
    db_path:str="runs.db"
'@
Set-Content "$root\core\context.py" -Encoding UTF8 -Value @'
import re,json
class Context:
    def __init__(self,vars):
        self.vars=dict(vars or {})
        self.cookies={}
    def render(self,s):
        if s is None:return None
        return s.format(**self.vars)
    def apply_extractors(self,text,extractors):
        for ex in extractors:
            if ex.kind=="regex":
                m=re.search(ex.expr,text or "")
                if m:self.vars[ex.var]=m.group(1) if m.groups() else m.group(0)
            elif ex.kind=="json":
                try:
                    obj=json.loads(text or "")
                    cur=obj
                    for p in ex.expr.split("."):
                        cur=cur[int(p)] if isinstance(cur,list) else cur.get(p)
                    self.vars[ex.var]=cur
                except:pass
'@
Set-Content "$root\core\data_feeds.py" -Encoding UTF8 -Value @'
import csv,json
from pathlib import Path
class DataFeeds:
    def __init__(self,cfgs):
        self.cfgs=cfgs or {}
        self.state={k:{"i":0,"rows":None} for k in self.cfgs}
    def next(self,key):
        if not key or key not in self.cfgs:return {}
        c=self.cfgs[key];t=c.get("type")
        if t=="csv":
            p=Path(c["path"])
            if self.state[key]["rows"] is None:
                self.state[key]["rows"]=list(csv.DictReader(p.open("r",newline="",encoding="utf-8")))
            rows=self.state[key]["rows"];i=self.state[key]["i"];self.state[key]["i"]=i+1;return rows[i%len(rows)]
        if t=="json":
            p=Path(c["path"]);data=json.loads(p.read_text(encoding="utf-8"));i=self.state[key]["i"];self.state[key]["i"]=i+1;return data[i%len(data)] if isinstance(data,list) else data
        return {}
'@
Set-Content "$root\core\assertions.py" -Encoding UTF8 -Value @'
import re,json,jsonschema
def status_code(resp,expected):return (resp.status_code==expected,f"{resp.status_code}!={expected}")
def resp_time(ms,thr):return (ms<=thr,f"{ms}>{thr}")
def contains(text,sub):return (sub in text,f"missing:{sub}")
def regex(text,pat):return (re.search(pat,text or "") is not None,f"no:{pat}")
def json_path(text,path,expected):
    try:
        obj=json.loads(text or "")
        cur=obj
        for p in path.split("."):
            cur=cur[int(p)] if isinstance(cur,list) else cur.get(p)
        return (cur==expected,f"{cur}!={expected}")
    except:return (False,"badjson")
def json_schema(text,schema):
    try:
        obj=json.loads(text or "")
        jsonschema.validate(obj,schema);return (True,"")
    except Exception as e:return (False,str(e))
'@
Set-Content "$root\protocols\http_client.py" -Encoding UTF8 -Value @'
import httpx
class HttpClient:
    def __init__(self,timeout_s=30.0):
        self.client=httpx.Client(timeout=timeout_s,follow_redirects=True)
    def request(self,method,url,headers=None,params=None,body=None,cookies=None):
        r=self.client.request(method,url,headers=headers,params=params,data=body,cookies=cookies)
        return r
    def close(self):self.client.close()
'@
Set-Content "$root\protocols\ws_client.py" -Encoding UTF8 -Value @'
import websocket
class WSClient:
    def connect(self,url,headers=None):self.ws=websocket.create_connection(url,header=[f"{k}: {v}" for k,v in (headers or {}).items()]);return True
    def send(self,msg):self.ws.send(msg);return self.ws.recv()
    def close(self):self.ws.close()
'@
Set-Content "$root\protocols\grpc_client.py" -Encoding UTF8 -Value @'
import grpc,importlib
class GRPCClient:
    def call(self,target,module,stub_class,method_name,request_kwargs):
        ch=grpc.insecure_channel(target)
        m=importlib.import_module(module)
        stub=getattr(m,stub_class)(ch)
        req_name=request_kwargs.pop("_request_class",None)
        Req=getattr(m,req_name) if req_name else None
        if Req is None:raise RuntimeError("request_class")
        meth=getattr(stub,method_name)
        resp=meth(Req(**request_kwargs));return resp
'@
Set-Content "$root\protocols\db_client.py" -Encoding UTF8 -Value @'
from sqlalchemy import create_engine,text
class DBClient:
    def __init__(self,url):self.eng=create_engine(url,future=True)
    def exec(self,sql,params=None):
        with self.eng.connect() as c:
            r=c.execute(text(sql),params or {})
            try:return [dict(x._mapping) for x in r]
            except:return []
'@
Set-Content "$root\protocols\kafka_client.py" -Encoding UTF8 -Value @'
from confluent_kafka import Producer,Consumer
class KafkaClient:
    def __init__(self,conf):self.p=Producer(conf);self.c=Consumer({**conf,"group.id":conf.get("group.id","pyloadlab"),"auto.offset.reset":"earliest"})
    def produce(self,topic,msg):self.p.produce(topic,msg);self.p.flush()
    def consume(self,topic,timeout_s=5):self.c.subscribe([topic]);m=self.c.poll(timeout_s);return m.value().decode() if m and not m.error() else ""
'@
Set-Content "$root\protocols\rabbitmq_client.py" -Encoding UTF8 -Value @'
import pika
class RabbitClient:
    def __init__(self,url):self.params=pika.URLParameters(url);self.conn=pika.BlockingConnection(self.params);self.ch=self.conn.channel()
    def publish(self,exchange,routing_key,msg):self.ch.basic_publish(exchange=exchange,routing_key=routing_key,body=msg)
    def get(self,queue):m=self.ch.basic_get(queue,auto_ack=True);return (m[2].decode() if m and m[2] else "")
'@
Set-Content "$root\protocols\mqtt_client.py" -Encoding UTF8 -Value @'
import paho.mqtt.client as mqtt,time
class MQTTClient:
    def __init__(self,host,port=1883):self.msg="";self.c=mqtt.Client();self.c.on_message=lambda c,u,m:setattr(self,"msg",m.payload.decode());self.c.connect(host,port);self.c.loop_start()
    def pub(self,topic,msg):self.c.publish(topic,msg)
    def sub(self,topic,wait_s=3):self.c.subscribe(topic);time.sleep(wait_s);return self.msg
'@
Set-Content "$root\protocols\ftp_client.py" -Encoding UTF8 -Value @'
from ftplib import FTP
import paramiko,io
class FTPClient:
    def put(self,host,user,pwd,path,content):
        f=FTP(host);f.login(user,pwd);f.storbinary("STOR "+path,io.BytesIO(content.encode()));f.quit();return True
class SFTPClient:
    def put(self,host,port,user,pwd,path,content):
        t=paramiko.Transport((host,port));t.connect(username=user,password=pwd);s=paramiko.SFTPClient.from_transport(t);fp=s.file(path,"w");fp.write(content);fp.close();s.close();t.close();return True
'@
Set-Content "$root\core\metrics.py" -Encoding UTF8 -Value @'
import psutil,time
class Metrics:
    def __init__(self,interval_s=1.0):self.interval_s=interval_s;self.samples=[]
    def start(self,duration_s):
        end=time.time()+duration_s
        while time.time()<end:
            cpu=psutil.cpu_percent(interval=None);mem=psutil.virtual_memory().percent;net=psutil.net_io_counters();disk=psutil.disk_io_counters()
            self.samples.append({"t":time.time(),"cpu":cpu,"mem":mem,"net_sent":net.bytes_sent,"net_recv":net.bytes_recv,"disk_r":disk.read_bytes,"disk_w":disk.write_bytes})
            time.sleep(self.interval_s)
'@
Set-Content "$root\core\runner.py" -Encoding UTF8 -Value @'
import time,random,threading,sqlite3,json
from tenacity import retry,stop_after_attempt,wait_exponential
from core.models import TestPlan,Step,ThreadGroup
from core.context import Context
from core.data_feeds import DataFeeds
from core.assertions import status_code,resp_time,contains,regex,json_path,json_schema
from core.metrics import Metrics
from protocols.http_client import HttpClient
from protocols.ws_client import WSClient
from protocols.grpc_client import GRPCClient
from protocols.db_client import DBClient
from protocols.kafka_client import KafkaClient
from protocols.rabbitmq_client import RabbitClient
from protocols.mqtt_client import MQTTClient
from protocols.ftp_client import FTPClient,SFTPClient
class Result:
    def __init__(self,step,ok,ms,code,msg,asserts):self.ts=time.time();self.step=step;self.ok=ok;self.ms=ms;self.code=code;self.msg=msg;self.asserts=asserts
class Engine:
    def __init__(self,plan:TestPlan):
        self.plan=plan
        self.results=[]
        self.feeds=DataFeeds(plan.data_sources)
        self.ctx=Context(plan.variables)
        self.http=HttpClient()
    def check(self,resp,ms,assertions,text):
        out=[];ok=True
        for a in assertions:
            if a.kind=="status_code":r=status_code(resp,int(a.expected));out.append(("status_code",r[0],r[1]));ok=ok and r[0]
            elif a.kind=="response_time_ms":r=resp_time(ms,int(a.threshold_ms or a.expected));out.append(("response_time_ms",r[0],r[1]));ok=ok and r[0]
            elif a.kind=="contains":r=contains(text,str(a.expected));out.append(("contains",r[0],r[1]));ok=ok and r[0]
            elif a.kind=="regex":r=regex(text,str(a.expr or a.expected));out.append(("regex",r[0],r[1]));ok=ok and r[0]
            elif a.kind=="json_path":r=json_path(text,str(a.expr),a.expected);out.append(("json_path",r[0],r[1]));ok=ok and r[0]
            elif a.kind=="json_schema":r=json_schema(text,json.loads(a.expr));out.append(("json_schema",r[0],r[1]));ok=ok and r[0]
        return ok,out
    @retry(stop=stop_after_attempt(3),wait=wait_exponential(multiplier=0.2))
    def do_http(self,s,cookies):
        u=self.ctx.render(s.config.get("url"));h={k:self.ctx.render(v) for k,v in s.headers.items()};p={k:self.ctx.render(str(v)) for k,v in s.params.items()};b=self.ctx.render(s.body)
        t0=time.time();r=self.http.request(s.config.get("method","GET"),u,h,p,b,cookies);ms=(time.time()-t0)*1000;txt=r.text;self.ctx.apply_extractors(txt,s.extractors);ok,asserts=self.check(r,ms,s.assertions,txt);return Result(s,ok,ms,r.status_code,txt,asserts),r.cookies
    def do_ws(self,s):
        c=WSClient();u=self.ctx.render(s.config.get("url"));c.connect(u,s.headers);msg=self.ctx.render(s.body or "ping");t0=time.time();resp=c.send(msg);ms=(time.time()-t0)*1000;self.ctx.apply_extractors(resp,s.extractors);ok,asserts=self.check(type("R",(object,),{"status_code":101}),ms,s.assertions,resp);c.close();return Result(s,ok,ms,101,resp,asserts)
    def do_grpc(self,s):
        g=GRPCClient();resp=g.call(s.config["target"],s.config["module"],s.config["stub"],s.config["method"],s.config.get("request",{}));txt=str(resp);self.ctx.apply_extractors(txt,s.extractors);return Result(s,True,0.0,0,txt,[])
    def do_db(self,s):
        d=DBClient(s.config["url"]);t0=time.time();rows=d.exec(s.config["sql"],s.config.get("params"));ms=(time.time()-t0)*1000;txt=json.dumps(rows) if rows else "";self.ctx.apply_extractors(txt,s.extractors);ok,asserts=self.check(type("R",(object,),{"status_code":200}),ms,s.assertions,txt);return Result(s,ok,ms,200,txt,asserts)
    def do_kafka(self,s):
        k=KafkaClient(s.config["conf"]);if s.config.get("mode")=="produce":k.produce(s.config["topic"],self.ctx.render(s.body or ""));return Result(s,True,0,0,"",[])
        m=k.consume(s.config["topic"]);self.ctx.apply_extractors(m,s.extractors);return Result(s,True,0,0,m,[])
    def do_rabbit(self,s):
        r=RabbitClient(s.config["url"]);if s.config.get("mode")=="publish":r.publish(s.config.get("exchange",""),s.config["routing_key"],self.ctx.render(s.body or ""));return Result(s,True,0,0,"",[])
        m=r.get(s.config["queue"]);self.ctx.apply_extractors(m,s.extractors);return Result(s,True,0,0,m,[])
    def do_mqtt(self,s):
        m=MQTTClient(s.config["host"],int(s.config.get("port",1883)));if s.config.get("mode")=="pub":m.pub(s.config["topic"],self.ctx.render(s.body or ""));return Result(s,True,0,0,"",[])
        msg=m.sub(s.config["topic"]);self.ctx.apply_extractors(msg,s.extractors);return Result(s,True,0,0,msg,[])
    def do_ftp(self,s):
        if s.config.get("type")=="sftp":x=SFTPClient();ok=x.put(s.config["host"],int(s.config.get("port",22)),s.config["user"],s.config["pwd"],s.config["path"],self.ctx.render(s.body or ""));return Result(s,ok,0,0,"",[])
        x=FTPClient();ok=x.put(s.config["host"],s.config["user"],s.config["pwd"],s.config["path"],self.ctx.render(s.body or ""));return Result(s,ok,0,0,"",[])
    def exec_step(self,s,cookies):
        if s.condition and not eval(s.condition,{},self.ctx.vars):return Result(s,True,0,0,"",[])
        res=None;ck=cookies
        for _ in range(max(1,s.loop)):
            if s.type=="http":res,ck=self.do_http(s,ck)
            elif s.type=="ws":res=self.do_ws(s)
            elif s.type=="grpc":res=self.do_grpc(s)
            elif s.type=="db":res=self.do_db(s)
            elif s.type=="kafka":res=self.do_kafka(s)
            elif s.type=="rabbitmq":res=self.do_rabbit(s)
            elif s.type=="mqtt":res=self.do_mqtt(s)
            elif s.type=="ftp":res=self.do_ftp(s)
            self.results.append(res)
            if s.think_max_ms or s.think_min_ms:time.sleep(random.uniform(s.think_min_ms/1000.0,s.think_max_ms/1000.0))
        return ck
    def run_tg(self,tg:ThreadGroup):
        def worker():
            cookies=None
            for _ in range(tg.loop_count):
                for s in self.plan.steps:
                    feed=self.feeds.next(s.data_source_key);self.ctx.vars.update(feed)
                    cookies=self.exec_step(s,cookies)
        delay=max(0.0,tg.ramp_up_s/max(tg.users,1));threads=[]
        for i in range(tg.users):
            t=threading.Thread(target=worker,daemon=True);threads.append(t);t.start();time.sleep(delay)
        for t in threads:t.join()
    def run(self):
        est=0.0
        for tg in self.plan.thread_groups:est+=tg.ramp_up_s+tg.loop_count*len(self.plan.steps)
        m=Metrics();mt=threading.Thread(target=m.start,args=(max(1.0,est),),daemon=True);mt.start()
        for tg in self.plan.thread_groups:self.run_tg(tg)
        mt.join()
        self.metrics=m.samples
        return self.results
class Logger:
    def __init__(self,path):self.db=path;self.conn=sqlite3.connect(self.db);self.conn.execute("create table if not exists runs(id integer primary key,plan text,ts real)");self.conn.execute("create table if not exists results(run_id int,ts real,step text,ok int,ms real,code int,msg text)");self.conn.execute("create table if not exists metrics(run_id int,ts real,cpu real,mem real,net_sent int,net_recv int,disk_r int,disk_w int)")
    def save(self,plan,results,metrics):
        cur=self.conn.cursor();cur.execute("insert into runs(plan,ts) values(?,?)",(plan.name,time.time()));rid=cur.lastrowid
        for r in results:cur.execute("insert into results(run_id,ts,step,ok,ms,code,msg) values(?,?,?,?,?,?,?)",(rid,r.ts,r.step.name,1 if r.ok else 0,r.ms,int(r.code or 0),r.msg))
        for s in metrics:cur.execute("insert into metrics(run_id,ts,cpu,mem,net_sent,net_recv,disk_r,disk_w) values(?,?,?,?,?,?,?,?)",(rid,s["t"],s["cpu"],s["mem"],s["net_sent"],s["net_recv"],s["disk_r"],s["disk_w"]))
        self.conn.commit();return rid
'@
Set-Content "$root\reporting\templates\report.html.j2" -Encoding UTF8 -Value @'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>{{ plan.name }} Report</title><style>body{font-family:Arial;margin:20px}table{width:100%;border-collapse:collapse}th,td{border:1px solid #eee;padding:6px;font-size:12px}th{background:#f9f9f9}.ok{color:#0a0}.fail{color:#a00}</style></head><body>
<h1>{{ plan.name }}</h1><p>{{ plan.description }}</p>
<div><b>Total:</b> {{ total }} <b>Success:</b> {{ success_rate }}% <b>Avg ms:</b> {{ avg_ms }} <b>P95 ms:</b> {{ p95_ms }}</div>
<h2>Results</h2><table><thead><tr><th>Time</th><th>Step</th><th>OK</th><th>ms</th><th>code</th><th>msg</th></tr></thead><tbody>
{% for r in results %}<tr><td>{{ r.ts }}</td><td>{{ r.step.name }}</td><td class="{{ 'ok' if r.ok else 'fail' }}">{{ 'OK' if r.ok else 'FAIL' }}</td><td>{{ "%.2f"|format(r.ms) }}</td><td>{{ r.code }}</td><td>{{ r.msg[:200] }}</td></tr>{% endfor %}
</tbody></table>
<h2>Metrics</h2><table><thead><tr><th>t</th><th>cpu</th><th>mem</th><th>net_s</th><th>net_r</th><th>disk_r</th><th>disk_w</th></tr></thead><tbody>
{% for s in metrics %}<tr><td>{{ s.t }}</td><td>{{ s.cpu }}</td><td>{{ s.mem }}</td><td>{{ s.net_sent }}</td><td>{{ s.net_recv }}</td><td>{{ s.disk_r }}</td><td>{{ s.disk_w }}</td></tr>{% endfor %}
</tbody></table>
</body></html>
'@
Set-Content "$root\reporting\report.py" -Encoding UTF8 -Value @'
import statistics
from pathlib import Path
from jinja2 import Environment,FileSystemLoader
def gen(plan,results,metrics,out):
    env=Environment(loader=FileSystemLoader(str(Path(__file__).parent/"templates")))
    t=env.get_template("report.html.j2")
    ms=[r.ms for r in results];avg=round(statistics.mean(ms),2) if ms else 0.0
    p95=round(statistics.quantiles(ms,n=20)[18],2) if len(ms)>=20 else (ms[int(0.95*len(ms))] if ms else 0.0)
    ok=sum(1 for r in results if r.ok);total=len(results);rate=round(ok/total*100.0,2) if total else 0.0
    html=t.render(plan=plan,results=results,metrics=metrics,total=total,success_rate=rate,avg_ms=avg,p95_ms=p95)
    Path(out).write_text(html,encoding="utf-8");return out
def export_json(path,results):
    import json;json.dump([{"ts":r.ts,"step":r.step.name,"ok":r.ok,"ms":r.ms,"code":r.code,"msg":r.msg} for r in results],open(path,"w",encoding="utf-8"))
def export_csv(path,results):
    import csv;f=open(path,"w",newline="",encoding="utf-8");w=csv.writer(f);w.writerow(["ts","step","ok","ms","code","msg"]);[w.writerow([r.ts,r.step.name,int(r.ok),r.ms,r.code,r.msg]) for r in results];f.close()
'@
Set-Content "$root\dashboard\app.py" -Encoding UTF8 -Value @'
import streamlit as st,sqlite3,pandas as pd,plotly.express as px
st.set_page_config(layout="wide")
db=st.text_input("db","runs.db")
if db:
    conn=sqlite3.connect(db)
    runs=pd.read_sql_query("select * from runs",conn)
    st.write(runs)
    rid=st.selectbox("run",runs["id"]) if not runs.empty else None
    if rid:
        res=pd.read_sql_query(f"select * from results where run_id={rid}",conn)
        met=pd.read_sql_query(f"select * from metrics where run_id={rid}",conn)
        st.plotly_chart(px.histogram(res,x="ms"),use_container_width=True)
        st.plotly_chart(px.line(met,x="ts",y=["cpu","mem"]),use_container_width=True)
        st.plotly_chart(px.line(met,x="ts",y=["net_sent","net_recv","disk_r","disk_w"]),use_container_width=True)
        errs=res[res["ok"]==0];st.write(errs.groupby(["code"]).size())
'@
Set-Content "$root\dist\controller.py" -Encoding UTF8 -Value @'
import zmq,json,sys
def main():
    ctx=zmq.Context();sock=ctx.socket(zmq.ROUTER);sock.bind("tcp://*:5555")
    plan=json.loads(open(sys.argv[1],"r",encoding="utf-8").read())
    workers=int(sys.argv[2]) if len(sys.argv)>2 else 1
    ready=set();assigned=set()
    while True:
        id,empty,msg=sock.recv_multipart()
        if msg==b"ready":
            ready.add(id)
            if len(assigned)<workers and id in ready:
                sock.send_multipart([id,b"",json.dumps(plan).encode()])
                assigned.add(id)
        elif msg==b"done":
            if id in assigned:assigned.remove(id)
            if not assigned:break
    sock.close()
if __name__=="__main__":main()
'@
Set-Content "$root\dist\worker.py" -Encoding UTF8 -Value @'
import zmq,json
from core.models import TestPlan,Step,ThreadGroup
from core.runner import Engine,Logger
def main():
    ctx=zmq.Context();sock=ctx.socket(zmq.DEALER);sock.connect("tcp://localhost:5555");sock.send(b"ready")
    id,empty,plan_bytes=sock.recv_multipart()
    raw=json.loads(plan_bytes.decode())
    plan=TestPlan(name=raw["name"],description=raw.get("description",""),steps=[Step(**x) for x in raw["steps"]],thread_groups=[ThreadGroup(**x) for x in raw["thread_groups"]],variables=raw.get("variables",{}),data_sources=raw.get("data_sources",{}),report_path=raw.get("report_path","report.html"),db_path=raw.get("db_path","runs.db"))
    e=Engine(plan);res=e.run();log=Logger(plan.db_path);rid=log.save(plan,res,e.metrics);sock.send(b"done");sock.close()
if __name__=="__main__":main()
'@
Set-Content "$root\gui\app.py" -Encoding UTF8 -Value @'
from PySide6.QtWidgets import QApplication,QMainWindow,QWidget,QVBoxLayout,QHBoxLayout,QLineEdit,QComboBox,QPushButton,QTableWidget,QTableWidgetItem,QFileDialog,QSpinBox
import sys,json
from core.models import TestPlan,Step,ThreadGroup
from core.runner import Engine,Logger
from reporting.report import gen
class GUI(QMainWindow):
    def __init__(self):
        super().__init__();self.setWindowTitle("PyLoadLab");self.plan=TestPlan(name="Plan",description="",steps=[],thread_groups=[ThreadGroup(name="TG",users=1,ramp_up_s=0,loop_count=1)],variables={},data_sources={},report_path="report.html",db_path="runs.db")
        w=QWidget();l=QVBoxLayout(w);self.name=QLineEdit("Plan");self.desc=QLineEdit("");self.report=QLineEdit("report.html");self.db=QLineEdit("runs.db");l.addWidget(self.name);l.addWidget(self.desc);l.addWidget(self.report);l.addWidget(self.db)
        tg=QHBoxLayout();self.users=QSpinBox();self.users.setValue(1);self.ramp=QSpinBox();self.ramp.setValue(0);self.loops=QSpinBox();self.loops.setValue(1);tg.addWidget(self.users);tg.addWidget(self.ramp);tg.addWidget(self.loops);l.addLayout(tg)
        h=QHBoxLayout();self.type=QComboBox();self.type.addItems(["http","ws","grpc","db","kafka","rabbitmq","mqtt","ftp"]);self.url=QLineEdit("");self.method=QLineEdit("GET");self.body=QLineEdit("");h.addWidget(self.type);h.addWidget(self.url);h.addWidget(self.method);h.addWidget(self.body);l.addLayout(h)
        self.tbl=QTableWidget(0,4);self.tbl.setHorizontalHeaderLabels(["type","url","method","body"]);l.addWidget(self.tbl)
        b=QHBoxLayout();add=QPushButton("Add");run=QPushButton("Run");save=QPushButton("Save");load=QPushButton("Load");b.addWidget(add);b.addWidget(run);b.addWidget(save);b.addWidget(load);l.addLayout(b)
        add.clicked.connect(self.add_step);run.clicked.connect(self.run);save.clicked.connect(self.save);load.clicked.connect(self.load)
        self.setCentralWidget(w)
    def add_step(self):
        s=Step(type=self.type.currentText(),name=self.type.currentText(),config={"url":self.url.text(),"method":self.method.text() if self.type.currentText()=="http" else self.method.text()},body=self.body.text())
        self.plan.steps.append(s);r=self.tbl.rowCount();self.tbl.insertRow(r);self.tbl.setItem(r,0,QTableWidgetItem(s.type));self.tbl.setItem(r,1,QTableWidgetItem(s.config.get("url","")));self.tbl.setItem(r,2,QTableWidgetItem(s.config.get("method","")));self.tbl.setItem(r,3,QTableWidgetItem(s.body or ""))
    def run(self):
        self.plan.name=self.name.text();self.plan.description=self.desc.text();self.plan.report_path=self.report.text();self.plan.db_path=self.db.text();self.plan.thread_groups=[ThreadGroup(name="TG",users=int(self.users.value()),ramp_up_s=float(self.ramp.value()),loop_count=int(self.loops.value()))]
        e=Engine(self.plan);res=e.run();Logger(self.plan.db_path).save(self.plan,res,e.metrics);gen(self.plan,res,e.metrics,self.plan.report_path)
    def save(self):
        p=QFileDialog.getSaveFileName(self,"Save",".","JSON (*.json)")[0]
        if p:
            raw={"name":self.plan.name,"description":self.plan.description,"steps":[s.__dict__ for s in self.plan.steps],"thread_groups":[tg.__dict__ for tg in self.plan.thread_groups],"variables":self.plan.variables,"data_sources":self.plan.data_sources,"report_path":self.plan.report_path,"db_path":self.plan.db_path}
            open(p,"w",encoding="utf-8").write(json.dumps(raw))
    def load(self):
        p=QFileDialog.getOpenFileName(self,"Load",".","JSON (*.json)")[0]
        if p:
            raw=json.loads(open(p,"r",encoding="utf-8").read())
            self.plan=TestPlan(name=raw["name"],description=raw.get("description",""),steps=[Step(**x) for x in raw["steps"]],thread_groups=[ThreadGroup(**x) for x in raw["thread_groups"]],variables=raw.get("variables",{}),data_sources=raw.get("data_sources",{}),report_path=raw.get("report_path","report.html"),db_path=raw.get("db_path","runs.db"))
            self.tbl.setRowCount(0)
            for s in self.plan.steps:
                r=self.tbl.rowCount();self.tbl.insertRow(r);self.tbl.setItem(r,0,QTableWidgetItem(s.type));self.tbl.setItem(r,1,QTableWidgetItem(s.config.get("url","")));self.tbl.setItem(r,2,QTableWidgetItem(s.config.get("method","")));self.tbl.setItem(r,3,QTableWidgetItem(s.body or ""))
def main():
    app=QApplication(sys.argv);g=GUI();g.show();sys.exit(app.exec())
if __name__=="__main__":main()
'@
Set-Content "$root\cli.py" -Encoding UTF8 -Value @'
import argparse,json
from core.models import TestPlan,Step,ThreadGroup
from core.runner import Engine,Logger
from reporting.report import gen,export_json,export_csv
def main():
    p=argparse.ArgumentParser();p.add_argument("--plan",required=True);p.add_argument("--json");p.add_argument("--csv");args=p.parse_args()
    raw=json.loads(open(args.plan,"r",encoding="utf-8").read())
    plan=TestPlan(name=raw["name"],description=raw.get("description",""),steps=[Step(**x) for x in raw["steps"]],thread_groups=[ThreadGroup(**x) for x in raw["thread_groups"]],variables=raw.get("variables",{}),data_sources=raw.get("data_sources",{}),report_path=raw.get("report_path","report.html"),db_path=raw.get("db_path","runs.db"))
    e=Engine(plan);res=e.run();Logger(plan.db_path).save(plan,res,e.metrics);gen(plan,res,e.metrics,plan.report_path)
    if args.json:export_json(args.json,res)
    if args.csv:export_csv(args.csv,res)
if __name__=="__main__":main()
'@
Set-Content "$root\examples\plan.json" -Encoding UTF8 -Value @'
{
"name":"Example",
"description":"Demo",
"steps":[
{"type":"http","name":"get","config":{"url":"https://jsonplaceholder.typicode.com/posts/{id}","method":"GET"},"headers":{"Accept":"application/json"},"params":{},"body":null,"timeout_s":30,"retries":1,"think_min_ms":10,"think_max_ms":50,"data_source_key":"ids","extractors":[{"kind":"json","expr":"userId","var":"userId"}],"assertions":[{"kind":"status_code","expected":200},{"kind":"response_time_ms","expected":1500}]},
{"type":"http","name":"get_user","config":{"url":"https://jsonplaceholder.typicode.com/users/{userId}","method":"GET"},"headers":{"Accept":"application/json"},"params":{},"body":null,"timeout_s":30,"retries":1,"think_min_ms":10,"think_max_ms":50,"data_source_key":null,"extractors":[],"assertions":[{"kind":"status_code","expected":200}]}
],
"thread_groups":[{"name":"TG","users":2,"ramp_up_s":1,"loop_count":2}],
"variables":{},
"data_sources":{"ids":{"type":"json","path":"examples/ids.json"}},
"report_path":"report.html",
"db_path":"runs.db"
}
'@
Set-Content "$root\examples\ids.json" -Encoding UTF8 -Value @'
[{"id":1},{"id":2},{"id":3}]
'@
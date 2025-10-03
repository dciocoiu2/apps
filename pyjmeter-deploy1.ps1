$root="pyjmeter"
New-Item -ItemType Directory -Force $root|Out-Null
New-Item -ItemType Directory -Force "$root\protocols"|Out-Null
New-Item -ItemType Directory -Force "$root\reporting\templates"|Out-Null
New-Item -ItemType Directory -Force "$root\examples"|Out-Null
Set-Content "$root\requirements.txt" -Encoding UTF8 -Value @'
httpx
psutil
jinja2
faker
pandas
matplotlib
ttkbootstrap
'@
Set-Content "$root\models.py" -Encoding UTF8 -Value @'
from dataclasses import dataclass,field
from typing import Dict,List,Optional,Any
import json
@dataclass
class AssertionConfig:
    type:str
    expected:Any
    path:Optional[str]=None
    regex_flags:Optional[int]=None
    threshold_ms:Optional[int]=None
@dataclass
class RequestStep:
    name:str
    method:str
    url:str
    headers:Dict[str,str]=field(default_factory=dict)
    params:Dict[str,Any]=field(default_factory=dict)
    body:Optional[str]=None
    timeout_s:float=30.0
    retries:int=0
    think_time_ms:int=0
    assertions:List[AssertionConfig]=field(default_factory=list)
    data_source_key:Optional[str]=None
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
    thread_groups:List[ThreadGroup]
    steps:List[RequestStep]
    variables:Dict[str,Any]=field(default_factory=dict)
    data_sources:Dict[str,Dict[str,Any]]=field(default_factory=dict)
    report_path:str="report.html"
    def to_json(self)->str:
        return json.dumps(self,default=lambda o:o.__dict__,indent=2)
    @staticmethod
    def from_json(json_str:str)->"TestPlan":
        raw=json.loads(json_str)
        steps=[RequestStep(**s) for s in raw["steps"]]
        tgs=[ThreadGroup(**tg) for tg in raw["thread_groups"]]
        for s in steps:
            s.assertions=[AssertionConfig(**a) for a in s.assertions] if s.assertions else []
        return TestPlan(name=raw["name"],description=raw.get("description",""),thread_groups=tgs,steps=steps,variables=raw.get("variables",{}),data_sources=raw.get("data_sources",{}),report_path=raw.get("report_path","report.html"))
'@
Set-Content "$root\assertions.py" -Encoding UTF8 -Value @'
import re
import json
def assert_status_code(resp,expected:int):
    return resp.status_code==expected,f"Expected {expected}, got {resp.status_code}"
def assert_response_time_ms(elapsed_ms:float,threshold_ms:int):
    return elapsed_ms<=threshold_ms,f"Response time {elapsed_ms:.2f}ms exceeded {threshold_ms}ms"
def assert_contains(text:str,expected:str):
    ok=expected in text
    return ok,f"Text does not contain '{expected}'"
def assert_regex(text:str,pattern:str,flags:int=0):
    ok=re.search(pattern,text,flags) is not None
    return ok,f"Regex '{pattern}' not found"
def assert_json_path(text:str,path:str,expected):
    try:
        obj=json.loads(text)
    except Exception:
        return False,"Response is not valid JSON"
    parts=path.split(".")
    cur=obj
    for p in parts:
        if isinstance(cur,list):
            try:
                cur=cur[int(p)]
            except Exception:
                return False,f"JSON path list index '{p}' invalid"
        else:
            if p not in cur:
                return False,f"JSON path '{p}' not found"
            cur=cur[p]
    ok=cur==expected
    return ok,f"JSON path {path} expected {expected}, got {cur}"
ASSERTION_HANDLERS={
    "status_code":lambda resp,cfg,ctx:assert_status_code(resp,int(cfg.expected)),
    "response_time_ms":lambda resp,cfg,ctx:assert_response_time_ms(ctx["elapsed_ms"],int(cfg.threshold_ms or cfg.expected)),
    "contains":lambda resp,cfg,ctx:assert_contains(resp.text,str(cfg.expected)),
    "regex":lambda resp,cfg,ctx:assert_regex(resp.text,str(cfg.expected),int(cfg.regex_flags or 0)),
    "json_path":lambda resp,cfg,ctx:assert_json_path(resp.text,str(cfg.path),cfg.expected),
}
'@
Set-Content "$root\protocols\http_client.py" -Encoding UTF8 -Value @'
import httpx
from typing import Dict,Any,Optional
class HttpClient:
    def __init__(self,timeout_s:float=30.0):
        self.timeout_s=timeout_s
        self._client=httpx.Client(timeout=timeout_s,follow_redirects=True)
    def request(self,method:str,url:str,headers:Dict[str,str],params:Dict[str,Any],body:Optional[str]):
        data_to_send=body
        resp=self._client.request(method.upper(),url,headers=headers,params=params,content=data_to_send)
        return resp
    def close(self):
        self._client.close()
'@
Set-Content "$root\data_feeds.py" -Encoding UTF8 -Value @'
import csv
import json
from pathlib import Path
from typing import Dict,Any,Optional
from faker import Faker
class DataFeedManager:
    def __init__(self,configs:Dict[str,Dict[str,Any]]):
        self.configs=configs
        self.faker=Faker()
        self.state={k:{"index":0,"rows":None} for k in configs}
    def get_next(self,key:Optional[str])->Dict[str,Any]:
        if not key or key not in self.configs:
            return {}
        cfg=self.configs[key]
        kind=cfg.get("type")
        if kind=="csv":
            path=Path(cfg["path"])
            if self.state[key]["rows"] is None:
                with path.open("r",newline="",encoding="utf-8") as f:
                    reader=csv.DictReader(f)
                    self.state[key]["rows"]=list(reader)
            rows=self.state[key]["rows"]
            i=self.state[key]["index"]
            row=rows[i%len(rows)]
            self.state[key]["index"]=i+1
            return row
        elif kind=="json":
            path=Path(cfg["path"])
            data=json.loads(path.read_text(encoding="utf-8"))
            i=self.state[key]["index"]
            self.state[key]["index"]=i+1
            if isinstance(data,list):
                return data[i%len(data)]
            return data
        elif kind=="faker":
            profile=self.faker.profile()
            return {**profile}
        else:
            return {}
'@
Set-Content "$root\metrics.py" -Encoding UTF8 -Value @'
import time
import psutil
from dataclasses import dataclass,field
from typing import List
@dataclass
class Sample:
    timestamp:float
    cpu_percent:float
    mem_percent:float
@dataclass
class SystemMetrics:
    samples:List[Sample]=field(default_factory=list)
    interval_s:float=1.0
    _running:bool=False
    def start(self):
        self._running=True
        psutil.cpu_percent(interval=None)
        self.samples.clear()
    def sample_once(self):
        ts=time.time()
        cpu=psutil.cpu_percent(interval=None)
        mem=psutil.virtual_memory().percent
        self.samples.append(Sample(ts,cpu,mem))
    def stop(self):
        self._running=False
    def collect_blocking(self,duration_s:float):
        self.start()
        end=time.time()+duration_s
        while time.time()<end:
            self.sample_once()
            time.sleep(self.interval_s)
        self.stop()
'@
Set-Content "$root\runner.py" -Encoding UTF8 -Value @'
import time
import threading
from typing import Dict,Any,List
from models import TestPlan,RequestStep,ThreadGroup
from protocols.http_client import HttpClient
from assertions import ASSERTION_HANDLERS
from data_feeds import DataFeedManager
from metrics import SystemMetrics
class Result:
    def __init__(self,step_name,method,url,status_code,elapsed_ms,success,assertion_results,error=None):
        self.step_name=step_name
        self.method=method
        self.url=url
        self.status_code=status_code
        self.elapsed_ms=elapsed_ms
        self.success=success
        self.assertion_results=assertion_results
        self.error=error
        self.timestamp=time.time()
class Runner:
    def __init__(self,plan:TestPlan):
        self.plan=plan
        self.results:List[Result]=[]
        self.metrics=SystemMetrics()
        self.data_feeds=DataFeedManager(plan.data_sources)
    def _execute_step(self,client:HttpClient,step:RequestStep)->Result:
        retries=step.retries
        last_error=None
        start=time.time()
        status_code=None
        resp=None
        try:
            data_ctx=self.data_feeds.get_next(step.data_source_key)
            url=step.url.format(**data_ctx,**self.plan.variables)
            headers={k:v.format(**data_ctx,**self.plan.variables) for k,v in step.headers.items()}
            params={k:str(v).format(**data_ctx,**self.plan.variables) for k,v in step.params.items()}
            body=step.body
            for attempt in range(retries+1):
                try:
                    req_start=time.time()
                    resp=client.request(step.method,url,headers,params,body)
                    elapsed_ms=(time.time()-req_start)*1000.0
                    status_code=resp.status_code
                    if step.think_time_ms>0:
                        time.sleep(step.think_time_ms/1000.0)
                    break
                except Exception as e:
                    last_error=e
                    if attempt<retries:
                        time.sleep(0.1)
            elapsed_ms_total=(time.time()-start)*1000.0
            assertion_results=[]
            success=True
            if resp is not None:
                for cfg in step.assertions:
                    handler=ASSERTION_HANDLERS.get(cfg.type)
                    if handler:
                        ok,msg=handler(resp,cfg,{"elapsed_ms":elapsed_ms_total})
                        assertion_results.append((cfg.type,ok,msg))
                        success=success and ok
            else:
                success=False
                assertion_results.append(("transport",False,f"Request failed: {last_error}"))
            return Result(step.name,step.method,step.url,status_code,elapsed_ms_total,success,assertion_results,error=last_error)
        except Exception as e:
            return Result(step.name,step.method,step.url,status_code,0.0,False,[("exception",False,str(e))],error=e)
    def _run_thread_group(self,tg:ThreadGroup,steps:List[RequestStep]):
        client=HttpClient()
        try:
            def worker(user_id:int):
                for _ in range(tg.loop_count):
                    for step in steps:
                        res=self._execute_step(client,step)
                        self.results.append(res)
            threads=[]
            delay=tg.ramp_up_s/max(tg.users,1)
            for i in range(tg.users):
                t=threading.Thread(target=worker,args=(i,),daemon=True)
                threads.append(t)
                t.start()
                time.sleep(delay if delay>0 else 0)
            for t in threads:
                t.join()
        finally:
            client.close()
    def run(self)->List[Result]:
        total_duration_estimate=0.0
        for tg in self.plan.thread_groups:
            total_duration_estimate+=max(1.0,tg.ramp_up_s+tg.loop_count*len(self.plan.steps))
        metrics_thread=threading.Thread(target=self.metrics.collect_blocking,args=(total_duration_estimate,),daemon=True)
        metrics_thread.start()
        for tg in self.plan.thread_groups:
            self._run_thread_group(tg,self.plan.steps)
        metrics_thread.join()
        return self.results
'@
Set-Content "$root\reporting\templates\report.html.j2" -Encoding UTF8 -Value @'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>{{ plan.name }} — Performance Report</title>
<style>
body{font-family:Arial,sans-serif;margin:20px}
.summary{display:flex;gap:20px;margin-bottom:20px}
.card{border:1px solid #ddd;padding:10px;border-radius:6px}
table{width:100%;border-collapse:collapse;margin-top:10px}
th,td{border:1px solid #eee;padding:6px;text-align:left;font-size:12px}
th{background:#f9f9f9}
.ok{color:#0a0}
.fail{color:#a00}
.chart{margin:20px 0}
.monospace{font-family:monospace}
</style>
</head>
<body>
<h1>{{ plan.name }}</h1>
<p>{{ plan.description }}</p>
<div class="summary">
<div class="card"><b>Total requests:</b> {{ total_requests }}<br/><b>Success rate:</b> {{ success_rate }}%</div>
<div class="card"><b>Avg response time:</b> {{ avg_rt_ms }} ms<br/><b>P95 response time:</b> {{ p95_rt_ms }} ms</div>
<div class="card"><b>Error count:</b> {{ error_count }}<br/><b>Unique status codes:</b> {{ status_codes | join(', ') }}</div>
</div>
<h2>Results</h2>
<table>
<thead><tr><th>Time</th><th>Step</th><th>Method</th><th>URL</th><th>Status</th><th>Resp Time (ms)</th><th>Success</th><th>Assertions</th><th>Error</th></tr></thead>
<tbody>
{% for r in results %}
<tr>
<td>{{ r.timestamp }}</td>
<td>{{ r.step_name }}</td>
<td>{{ r.method }}</td>
<td class="monospace">{{ r.url }}</td>
<td>{{ r.status_code }}</td>
<td>{{ "%.2f"|format(r.elapsed_ms) }}</td>
<td class="{{ 'ok' if r.success else 'fail' }}">{{ 'OK' if r.success else 'FAIL' }}</td>
<td>{% for a in r.assertion_results %}<div class="{{ 'ok' if a[1] else 'fail' }}">{{ a[0] }}: {{ a[2] }}</div>{% endfor %}</td>
<td>{{ r.error }}</td>
</tr>
{% endfor %}
</tbody>
</table>
<h2>System metrics</h2>
<table>
<thead><tr><th>Time</th><th>CPU %</th><th>Memory %</th></tr></thead>
<tbody>
{% for s in sys_metrics %}
<tr><td>{{ s.timestamp }}</td><td>{{ s.cpu_percent }}</td><td>{{ s.mem_percent }}</td></tr>
{% endfor %}
</tbody>
</table>
</body>
</html>
'@
Set-Content "$root\reporting\report.py" -Encoding UTF8 -Value @'
from typing import List,Dict,Any
from jinja2 import Environment,FileSystemLoader
import statistics
from pathlib import Path
def generate_html(plan,results,sys_metrics,output_path:str):
    env=Environment(loader=FileSystemLoader(str(Path(__file__).parent/"templates")))
    tmpl=env.get_template("report.html.j2")
    total_requests=len(results)
    success_count=sum(1 for r in results if r.success)
    success_rate=round((success_count/total_requests*100.0),2) if total_requests else 0.0
    rt_list=[r.elapsed_ms for r in results]
    avg_rt_ms=round(statistics.mean(rt_list),2) if rt_list else 0.0
    p95_rt_ms=round(statistics.quantiles(rt_list,n=20)[18],2) if len(rt_list)>=20 else (rt_list[int(0.95*len(rt_list))] if rt_list else 0.0)
    error_count=total_requests-success_count
    status_codes=sorted(set(str(r.status_code) for r in results if r.status_code is not None))
    html=tmpl.render(plan=plan,results=results,sys_metrics=sys_metrics,total_requests=total_requests,success_rate=success_rate,avg_rt_ms=avg_rt_ms,p95_rt_ms=p95_rt_ms,error_count=error_count,status_codes=status_codes)
    Path(output_path).write_text(html,encoding="utf-8")
    return output_path
'@
Set-Content "$root\app.py" -Encoding UTF8 -Value @'
import tkinter as tk
from tkinter import ttk,filedialog,messagebox
import json
from pathlib import Path
from models import TestPlan,RequestStep,ThreadGroup,AssertionConfig
from runner import Runner
from reporting.report import generate_html
import ttkbootstrap as tb
class App:
    def __init__(self,root):
        self.root=root
        self.root.title("PyJMeter — Python Performance Suite")
        self.plan=TestPlan(name="Untitled Plan",description="",thread_groups=[ThreadGroup(name="TG1",users=1,ramp_up_s=0.0,loop_count=1)],steps=[],variables={},data_sources={})
        self._build_ui()
    def _build_ui(self):
        nb=tb.Notebook(self.root)
        nb.pack(fill="both",expand=True)
        self.frame_plan=ttk.Frame(nb)
        self.frame_steps=ttk.Frame(nb)
        self.frame_datasources=ttk.Frame(nb)
        nb.add(self.frame_plan,text="Plan")
        nb.add(self.frame_steps,text="Steps")
        nb.add(self.frame_datasources,text="Data Sources")
        ttk.Label(self.frame_plan,text="Name").grid(row=0,column=0,sticky="w")
        self.entry_name=ttk.Entry(self.frame_plan,width=40)
        self.entry_name.insert(0,self.plan.name)
        self.entry_name.grid(row=0,column=1,sticky="we")
        ttk.Label(self.frame_plan,text="Description").grid(row=1,column=0,sticky="w")
        self.entry_desc=ttk.Entry(self.frame_plan,width=60)
        self.entry_desc.grid(row=1,column=1,sticky="we")
        ttk.Label(self.frame_plan,text="Report path").grid(row=2,column=0,sticky="w")
        self.entry_report=ttk.Entry(self.frame_plan,width=60)
        self.entry_report.insert(0,self.plan.report_path)
        self.entry_report.grid(row=2,column=1,sticky="we")
        ttk.Label(self.frame_plan,text="Thread group users").grid(row=3,column=0,sticky="w")
        self.entry_users=ttk.Entry(self.frame_plan,width=10)
        self.entry_users.insert(0,"1")
        self.entry_users.grid(row=3,column=1,sticky="w")
        ttk.Label(self.frame_plan,text="Ramp-up (s)").grid(row=4,column=0,sticky="w")
        self.entry_ramp=ttk.Entry(self.frame_plan,width=10)
        self.entry_ramp.insert(0,"0")
        self.entry_ramp.grid(row=4,column=1,sticky="w")
        ttk.Label(self.frame_plan,text="Loop count").grid(row=5,column=0,sticky="w")
        self.entry_loops=ttk.Entry(self.frame_plan,width=10)
        self.entry_loops.insert(0,"1")
        self.entry_loops.grid(row=5,column=1,sticky="w")
        btn_frame=ttk.Frame(self.frame_plan)
        btn_frame.grid(row=6,column=0,columnspan=2,pady=10)
        ttk.Button(btn_frame,text="New step",command=self.add_step_dialog).pack(side="left",padx=5)
        ttk.Button(btn_frame,text="Load plan",command=self.load_plan).pack(side="left",padx=5)
        ttk.Button(btn_frame,text="Save plan",command=self.save_plan).pack(side="left",padx=5)
        ttk.Button(btn_frame,text="Run",command=self.run_plan).pack(side="left",padx=5)
        self.steps_tree=ttk.Treeview(self.frame_steps,columns=("method","url"),show="headings",height=10)
        self.steps_tree.heading("method",text="Method")
        self.steps_tree.heading("url",text="URL")
        self.steps_tree.pack(fill="both",expand=True)
        ttk.Button(self.frame_steps,text="Edit selected",command=self.edit_selected_step).pack(pady=6)
        ttk.Button(self.frame_steps,text="Delete selected",command=self.delete_selected_step).pack(pady=6)
        self.ds_tree=ttk.Treeview(self.frame_datasources,columns=("type","path"),show="headings",height=6)
        self.ds_tree.heading("type",text="Type")
        self.ds_tree.heading("path",text="Path")
        self.ds_tree.pack(fill="both",expand=True)
        ttk.Button(self.frame_datasources,text="Add CSV",command=lambda:self.add_ds("csv")).pack(pady=6)
        ttk.Button(self.frame_datasources,text="Add JSON",command=lambda:self.add_ds("json")).pack(pady=6)
        ttk.Button(self.frame_datasources,text="Add Faker",command=lambda:self.add_ds("faker")).pack(pady=6)
        self.refresh_steps()
        self.refresh_ds()
    def add_ds(self,kind):
        if kind in("csv","json"):
            path=filedialog.askopenfilename(title=f"Select {kind.upper()} file")
            if not path:return
            key=f"{kind}_{len(self.plan.data_sources)+1}"
            self.plan.data_sources[key]={"type":kind,"path":path}
        else:
            key=f"faker_{len(self.plan.data_sources)+1}"
            self.plan.data_sources[key]={"type":"faker"}
        self.refresh_ds()
    def refresh_ds(self):
        for i in self.ds_tree.get_children():
            self.ds_tree.delete(i)
        for k,cfg in self.plan.data_sources.items():
            self.ds_tree.insert("","end",iid=k,values=(cfg["type"],cfg.get("path","")))
    def add_step_dialog(self):
        d=tk.Toplevel(self.root)
        d.title("Add Step")
        ttk.Label(d,text="Name").grid(row=0,column=0,sticky="w")
        e_name=ttk.Entry(d,width=40);e_name.grid(row=0,column=1)
        ttk.Label(d,text="Method").grid(row=1,column=0,sticky="w")
        cb_method=ttk.Combobox(d,values=["GET","POST","PUT","DELETE"]);cb_method.set("GET");cb_method.grid(row=1,column=1)
        ttk.Label(d,text="URL").grid(row=2,column=0,sticky="w")
        e_url=ttk.Entry(d,width=60);e_url.grid(row=2,column=1)
        ttk.Label(d,text="Headers (JSON)").grid(row=3,column=0,sticky="w")
        e_headers=ttk.Entry(d,width=60);e_headers.insert(0,'{"Content-Type":"application/json"}');e_headers.grid(row=3,column=1)
        ttk.Label(d,text="Params (JSON)").grid(row=4,column=0,sticky="w")
        e_params=ttk.Entry(d,width=60);e_params.insert(0,"{}");e_params.grid(row=4,column=1)
        ttk.Label(d,text="Body").grid(row=5,column=0,sticky="w")
        e_body=ttk.Entry(d,width=60);e_body.grid(row=5,column=1)
        ttk.Label(d,text="Timeout (s)").grid(row=6,column=0,sticky="w")
        e_timeout=ttk.Entry(d,width=10);e_timeout.insert(0,"30");e_timeout.grid(row=6,column=1,sticky="w")
        ttk.Label(d,text="Retries").grid(row=7,column=0,sticky="w")
        e_retries=ttk.Entry(d,width=10);e_retries.insert(0,"0");e_retries.grid(row=7,column=1,sticky="w")
        ttk.Label(d,text="Think time (ms)").grid(row=8,column=0,sticky="w")
        e_think=ttk.Entry(d,width=10);e_think.insert(0,"0");e_think.grid(row=8,column=1,sticky="w")
        ttk.Label(d,text="Data source key").grid(row=9,column=0,sticky="w")
        e_ds=ttk.Entry(d,width=20);e_ds.grid(row=9,column=1,sticky="w")
        ttk.Label(d,text="Assertions (JSON list)").grid(row=10,column=0,sticky="w")
        e_assert=ttk.Entry(d,width=60)
        e_assert.insert(0,'[{"type":"status_code","expected":200}]')
        e_assert.grid(row=10,column=1)
        def save():
            try:
                headers=json.loads(e_headers.get())
                params=json.loads(e_params.get())
                assertions=[AssertionConfig(**a) for a in json.loads(e_assert.get())]
                step=RequestStep(name=e_name.get(),method=cb_method.get(),url=e_url.get(),headers=headers,params=params,body=e_body.get() or None,timeout_s=float(e_timeout.get()),retries=int(e_retries.get()),think_time_ms=int(e_think.get()),assertions=assertions,data_source_key=e_ds.get() or None)
                self.plan.steps.append(step)
                self.refresh_steps()
                d.destroy()
            except Exception as ex:
                messagebox.showerror("Error",f"Invalid input: {ex}")
        ttk.Button(d,text="Add",command=save).grid(row=11,column=0,pady=8)
        ttk.Button(d,text="Cancel",command=d.destroy).grid(row=11,column=1,pady=8)
    def refresh_steps(self):
        for i in self.steps_tree.get_children():
            self.steps_tree.delete(i)
        for idx,s in enumerate(self.plan.steps):
            self.steps_tree.insert("","end",iid=str(idx),values=(s.method,s.url))
    def edit_selected_step(self):
        sel=self.steps_tree.selection()
        if not sel:return
        messagebox.showinfo("Info","Editing UI abbreviated for demo. Delete and re-add the step.")
    def delete_selected_step(self):
        sel=self.steps_tree.selection()
        if not sel:return
        idx=int(sel[0])
        del self.plan.steps[idx]
        self.refresh_steps()
    def load_plan(self):
        path=filedialog.askopenfilename(title="Load plan",filetypes=[("JSON","*.json")])
        if not path:return
        try:
            jp=Path(path).read_text(encoding="utf-8")
            self.plan=TestPlan.from_json(jp)
            self.entry_name.delete(0,tk.END);self.entry_name.insert(0,self.plan.name)
            self.entry_desc.delete(0,tk.END);self.entry_desc.insert(0,self.plan.description)
            self.entry_report.delete(0,tk.END);self.entry_report.insert(0,self.plan.report_path)
            tg=self.plan.thread_groups[0]
            self.entry_users.delete(0,tk.END);self.entry_users.insert(0,str(tg.users))
            self.entry_ramp.delete(0,tk.END);self.entry_ramp.insert(0,str(tg.ramp_up_s))
            self.entry_loops.delete(0,tk.END);self.entry_loops.insert(0,str(tg.loop_count))
            self.refresh_steps()
            self.refresh_ds()
        except Exception as ex:
            messagebox.showerror("Error",f"Failed to load: {ex}")
    def save_plan(self):
        self.plan.name=self.entry_name.get()
        self.plan.description=self.entry_desc.get()
        self.plan.report_path=self.entry_report.get()
        self.plan.thread_groups=[ThreadGroup(name="TG1",users=int(self.entry_users.get()),ramp_up_s=float(self.entry_ramp.get()),loop_count=int(self.entry_loops.get()))]
        path=filedialog.asksaveasfilename(title="Save plan",defaultextension=".json",filetypes=[("JSON","*.json")])
        if not path:return
        Path(path).write_text(self.plan.to_json(),encoding="utf-8")
        messagebox.showinfo("Saved",f"Plan saved to {path}")
    def run_plan(self):
        if not self.plan.steps:
            messagebox.showerror("Error","Add at least one step.")
            return
        self.save_plan_fields()
        runner=Runner(self.plan)
        results=runner.run()
        out=generate_html(self.plan,results,runner.metrics.samples,self.plan.report_path)
        messagebox.showinfo("Done",f"Report generated at {out}")
    def save_plan_fields(self):
        self.plan.name=self.entry_name.get()
        self.plan.description=self.entry_desc.get()
        self.plan.report_path=self.entry_report.get()
        self.plan.thread_groups=[ThreadGroup(name="TG1",users=int(self.entry_users.get()),ramp_up_s=float(self.entry_ramp.get()),loop_count=int(self.entry_loops.get()))]
def main():
    root=tb.Window(themename="flatly")
    App(root)
    root.mainloop()
if __name__=="__main__":
    main()
'@
Set-Content "$root\examples\sample_plan.json" -Encoding UTF8 -Value @'
{
  "name":"Sample Plan",
  "description":"Basic GET test",
  "thread_groups":[{"name":"TG1","users":5,"ramp_up_s":2,"loop_count":3}],
  "steps":[
    {
      "name":"Get Post",
      "method":"GET",
      "url":"https://jsonplaceholder.typicode.com/posts/{id}",
      "headers":{"Accept":"application/json"},
      "params":{},
      "body":null,
      "timeout_s":30,
      "retries":1,
      "think_time_ms":50,
      "assertions":[
        {"type":"status_code","expected":200},
        {"type":"response_time_ms","expected":1500},
        {"type":"json_path","path":"userId","expected":1}
      ],
      "data_source_key":"csv_1"
    }
  ],
  "variables":{},
  "data_sources":{"csv_1":{"type":"csv","path":"examples/ids.csv"}},
  "report_path":"report.html"
}
'@
Set-Content "$root\examples\ids.csv" -Encoding UTF8 -Value @'
id
1
2
3
4
5
'@
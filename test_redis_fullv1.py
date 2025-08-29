import tkinter as tk
from tkinter import filedialog, messagebox, scrolledtext, ttk
import redis
import socket
import ssl
import traceback
import logging
import os
import json
import threading
import time
import queue
import pprint

SETTINGS_FILE = "redis_test_full_settings.json"
PRESETS_FILE = "redis_presets.json"
class RedisTesterApp:
    def __init__(self, root):
        self.root = root
        self.root.title("Redis Connection Tester (with ACL & SSL certs)")
        self.log_file_path = tk.StringVar(value="redis_test_full.log")
        self.connection_name_var = tk.StringVar()
        self.host_var = tk.StringVar()
        self.port_var = tk.StringVar(value="6379")
        self.username_var = tk.StringVar()
        self.password_var = tk.StringVar()
        self.db_var = tk.StringVar(value="0")
        self.tls_mode_var = tk.StringVar(value="Require TLS") 
        self.verify_cert_var = tk.BooleanVar(value=False)
        self.ca_cert_path = tk.StringVar()
        self.client_cert_path = tk.StringVar()
        self.client_key_path = tk.StringVar()
        self.presets = {}
        self.redis_client = None
        self.monitor_thread = None
        self.monitor_running = False
        self.monitor_queue = queue.Queue()
        self.build_ui()
        self.load_settings()
        self.load_presets()
        self.setup_logging()
        self.root.protocol("WM_DELETE_WINDOW", self.on_closing)
    def build_ui(self):
        conn_frame = tk.Frame(self.root)
        conn_frame.pack(side=tk.TOP, fill=tk.X, padx=5, pady=5)
        tk.Label(conn_frame, text="Connection Name:").grid(row=0, column=0, sticky='e')
        self.connection_name_entry = tk.Entry(conn_frame, textvariable=self.connection_name_var, width=40)
        self.connection_name_entry.grid(row=0, column=1, sticky='w')
        tk.Button(conn_frame, text="Save Preset", command=self.save_preset).grid(row=0, column=2, sticky='w')
        tk.Label(conn_frame, text="Host:").grid(row=1, column=0, sticky='e')
        self.host_entry = tk.Entry(conn_frame, textvariable=self.host_var, width=40)
        self.host_entry.grid(row=1, column=1, sticky='w')
        tk.Label(conn_frame, text="Port:").grid(row=2, column=0, sticky='e')
        self.port_entry = tk.Entry(conn_frame, textvariable=self.port_var, width=10)
        self.port_entry.grid(row=2, column=1, sticky='w')
        tk.Label(conn_frame, text="Username (ACL):").grid(row=3, column=0, sticky='e')
        self.username_entry = tk.Entry(conn_frame, textvariable=self.username_var, width=40)
        self.username_entry.grid(row=3, column=1, sticky='w')
        tk.Label(conn_frame, text="Password:").grid(row=4, column=0, sticky='e')
        self.password_entry = tk.Entry(conn_frame, textvariable=self.password_var, show='*', width=40)
        self.password_entry.grid(row=4, column=1, sticky='w')
        tk.Label(conn_frame, text="Database (0-15):").grid(row=5, column=0, sticky='e')
        self.db_entry = tk.Entry(conn_frame, textvariable=self.db_var, width=5)
        self.db_entry.grid(row=5, column=1, sticky='w')
        tk.Label(conn_frame, text="TLS Mode:").grid(row=6, column=0, sticky='e')
        tls_options = ["None", "Allow TLS", "Require TLS"]
        self.tls_mode_menu = tk.OptionMenu(conn_frame, self.tls_mode_var, *tls_options)
        self.tls_mode_menu.grid(row=6, column=1, sticky='w')
        self.verify_cert_check = tk.Checkbutton(conn_frame, text="Verify SSL Certificate", variable=self.verify_cert_var)
        self.verify_cert_check.grid(row=7, column=1, sticky='w')
        tk.Label(conn_frame, text="CA Cert File:").grid(row=8, column=0, sticky='e')
        ca_frame = tk.Frame(conn_frame)
        ca_frame.grid(row=8, column=1, sticky='w')
        self.ca_cert_entry = tk.Entry(ca_frame, textvariable=self.ca_cert_path, width=35)
        self.ca_cert_entry.pack(side=tk.LEFT)
        tk.Button(ca_frame, text="Browse", command=self.browse_ca_cert).pack(side=tk.LEFT, padx=5)
        tk.Label(conn_frame, text="Client Cert File:").grid(row=9, column=0, sticky='e')
        client_cert_frame = tk.Frame(conn_frame)
        client_cert_frame.grid(row=9, column=1, sticky='w')
        self.client_cert_entry = tk.Entry(client_cert_frame, textvariable=self.client_cert_path, width=35)
        self.client_cert_entry.pack(side=tk.LEFT)
        tk.Button(client_cert_frame, text="Browse", command=self.browse_client_cert).pack(side=tk.LEFT, padx=5)
        tk.Label(conn_frame, text="Client Key File:").grid(row=10, column=0, sticky='e')
        client_key_frame = tk.Frame(conn_frame)
        client_key_frame.grid(row=10, column=1, sticky='w')
        self.client_key_entry = tk.Entry(client_key_frame, textvariable=self.client_key_path, width=35)
        self.client_key_entry.pack(side=tk.LEFT)
        tk.Button(client_key_frame, text="Browse", command=self.browse_client_key).pack(side=tk.LEFT, padx=5)
        tk.Label(conn_frame, text="Log File:").grid(row=11, column=0, sticky='e')
        self.log_path_entry = tk.Entry(conn_frame, textvariable=self.log_file_path, width=40)
        self.log_path_entry.grid(row=11, column=1, sticky='w')
        tk.Button(conn_frame, text="Browse", command=self.browse_log_file).grid(row=11, column=2, sticky='w')
        tk.Label(conn_frame, text="Load Preset:").grid(row=12, column=0, sticky='e')
        self.preset_listbox = tk.Listbox(conn_frame, height=5, width=40)
        self.preset_listbox.grid(row=12, column=1, sticky='w')
        self.preset_listbox.bind('<<ListboxSelect>>', self.on_preset_select)
        tk.Button(conn_frame, text="Delete Preset", command=self.delete_preset).grid(row=12, column=2, sticky='w')
        button_frame = tk.Frame(conn_frame)
        button_frame.grid(row=13, column=0, columnspan=3, pady=5)
        tk.Button(button_frame, text="Test Connection", command=self.run_test).grid(row=0, column=0, padx=5)
        tk.Button(button_frame, text="Check SSL Info", command=self.check_ssl_cert).grid(row=0, column=1, padx=5)
        tk.Button(button_frame, text="Save Settings", command=self.save_settings).grid(row=0, column=2, padx=5)
        ttk.Separator(self.root, orient=tk.HORIZONTAL).pack(fill=tk.X, pady=5)
        self.notebook = ttk.Notebook(self.root)
        self.notebook.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)
        self.output_tab = tk.Frame(self.notebook)
        self.notebook.add(self.output_tab, text="Output")
        self.output = scrolledtext.ScrolledText(self.output_tab, height=20, width=80)
        self.output.pack(fill=tk.BOTH, expand=True)
        self.cli_tab = tk.Frame(self.notebook)
        self.notebook.add(self.cli_tab, text="Redis CLI")
        self.cli_output = scrolledtext.ScrolledText(self.cli_tab, height=15, width=80)
        self.cli_output.pack(fill=tk.BOTH, expand=True)
        cli_entry_frame = tk.Frame(self.cli_tab)
        cli_entry_frame.pack(fill=tk.X)
        self.cli_input = tk.Entry(cli_entry_frame, width=70)
        self.cli_input.pack(side=tk.LEFT, padx=5, pady=5, fill=tk.X, expand=True)
        self.cli_input.bind("<Return>", self.execute_redis_command)
        tk.Button(cli_entry_frame, text="Run Command", command=self.execute_redis_command).pack(side=tk.RIGHT, padx=5)
        self.monitor_tab = tk.Frame(self.notebook)
        self.notebook.add(self.monitor_tab, text="Monitor")
        self.monitor_output = scrolledtext.ScrolledText(self.monitor_tab, height=20, width=80)
        self.monitor_output.pack(fill=tk.BOTH, expand=True)
        monitor_btn_frame = tk.Frame(self.monitor_tab)
        monitor_btn_frame.pack(fill=tk.X)
        self.monitor_start_btn = tk.Button(monitor_btn_frame, text="Start Monitor", command=self.start_monitor)
        self.monitor_start_btn.pack(side=tk.LEFT, padx=5, pady=5)
        self.monitor_stop_btn = tk.Button(monitor_btn_frame, text="Stop Monitor", command=self.stop_monitor, state=tk.DISABLED)
        self.monitor_stop_btn.pack(side=tk.LEFT, padx=5, pady=5)

    def browse_ca_cert(self):
        path = filedialog.askopenfilename(title="Select CA Certificate File", filetypes=[("PEM files", "*.pem"), ("All files", "*.*")])
        if path:
            self.ca_cert_path.set(path)
    def browse_client_cert(self):
        path = filedialog.askopenfilename(title="Select Client Certificate File", filetypes=[("PEM files", "*.pem"), ("All files", "*.*")])
        if path:
            self.client_cert_path.set(path)
    def browse_client_key(self):
        path = filedialog.askopenfilename(title="Select Client Key File", filetypes=[("PEM files", "*.pem"), ("All files", "*.*")])
        if path:
            self.client_key_path.set(path)
    def browse_log_file(self):
        path = filedialog.asksaveasfilename(title="Select Log File", defaultextension=".log",
                                            filetypes=[("Log files", "*.log"), ("All files", "*.*")])
        if path:
            self.log_file_path.set(path)
    def save_preset(self):
        name = self.connection_name_var.get().strip()
        if not name:
            messagebox.showerror("Error", "Connection Name is required to save preset.")
            return
        preset = {
            "host": self.host_var.get().strip(),
            "port": self.port_var.get().strip(),
            "username": self.username_var.get().strip(),
            "password": self.password_var.get(),
            "db": self.db_var.get(),
            "tls_mode": self.tls_mode_var.get(),
            "verify_cert": self.verify_cert_var.get(),
            "ca_cert_path": self.ca_cert_path.get(),
            "client_cert_path": self.client_cert_path.get(),
            "client_key_path": self.client_key_path.get(),
            "log_file_path": self.log_file_path.get(),
        }
        self.presets[name] = preset
        self.save_presets()
        self.refresh_preset_list()
        messagebox.showinfo("Saved", f"Preset '{name}' saved.")
    def delete_preset(self):
        selected = self.preset_listbox.curselection()
        if not selected:
            return
        name = self.preset_listbox.get(selected[0])
        if name in self.presets:
            del self.presets[name]
            self.save_presets()
            self.refresh_preset_list()
    def on_preset_select(self, event=None):
        selected = self.preset_listbox.curselection()
        if not selected:
            return
        name = self.preset_listbox.get(selected[0])
        preset = self.presets.get(name)
        if not preset:
            return
        self.connection_name_var.set(name)
        self.host_var.set(preset.get("host", ""))
        self.port_var.set(preset.get("port", "6379"))
        self.username_var.set(preset.get("username", ""))
        self.password_var.set(preset.get("password", ""))
        self.db_var.set(preset.get("db", "0"))
        self.tls_mode_var.set(preset.get("tls_mode", "Require TLS"))
        self.verify_cert_var.set(preset.get("verify_cert", False))
        self.ca_cert_path.set(preset.get("ca_cert_path", ""))
        self.client_cert_path.set(preset.get("client_cert_path", ""))
        self.client_key_path.set(preset.get("client_key_path", ""))
        self.log_file_path.set(preset.get("log_file_path", "redis_error.log"))
    def save_presets(self):
        try:
            with open(PRESETS_FILE, "w") as f:
                json.dump(self.presets, f, indent=2)
        except Exception as e:
            messagebox.showerror("Error", f"Failed to save presets: {e}")
    def load_presets(self):
        if os.path.exists(PRESETS_FILE):
            try:
                with open(PRESETS_FILE, "r") as f:
                    self.presets = json.load(f)
            except Exception:
                self.presets = {}
        self.refresh_preset_list()
    def refresh_preset_list(self):
        self.preset_listbox.delete(0, tk.END)
        for name in sorted(self.presets.keys()):
            self.preset_listbox.insert(tk.END, name)
    def save_settings(self):
        settings = {
            "host": self.host_var.get(),
            "port": self.port_var.get(),
            "username": self.username_var.get(),
            "password": self.password_var.get(),
            "db": self.db_var.get(),
            "tls_mode": self.tls_mode_var.get(),
            "verify_cert": self.verify_cert_var.get(),
            "ca_cert_path": self.ca_cert_path.get(),
            "client_cert_path": self.client_cert_path.get(),
            "client_key_path": self.client_key_path.get(),
            "log_file_path": self.log_file_path.get(),
            "connection_name": self.connection_name_var.get(),
        }
        try:
            with open(SETTINGS_FILE, "w") as f:
                json.dump(settings, f, indent=2)
            self.log("[SAVE] Settings saved.")
        except Exception as e:
            self.log(f"[FAIL] Failed to save settings: {e}")
    def load_settings(self):
        if os.path.exists(SETTINGS_FILE):
            try:
                with open(SETTINGS_FILE, "r") as f:
                    settings = json.load(f)
                self.host_var.set(settings.get("host", ""))
                self.port_var.set(settings.get("port", "6379"))
                self.username_var.set(settings.get("username", ""))
                self.password_var.set(settings.get("password", ""))
                self.db_var.set(settings.get("db", "0"))
                self.tls_mode_var.set(settings.get("tls_mode", "Require TLS"))
                self.verify_cert_var.set(settings.get("verify_cert", False))
                self.ca_cert_path.set(settings.get("ca_cert_path", ""))
                self.client_cert_path.set(settings.get("client_cert_path", ""))
                self.client_key_path.set(settings.get("client_key_path", ""))
                self.log_file_path.set(settings.get("log_file_path", "redis_error.log"))
                self.connection_name_var.set(settings.get("connection_name", ""))
            except Exception:
                pass
    def setup_logging(self):
        log_file = self.log_file_path.get()
        logging.basicConfig(filename=log_file, level=logging.DEBUG,
                            format='%(asctime)s %(levelname)s:%(message)s')
    def log(self, message):
        self.output.insert(tk.END, message + "\n")
        self.output.see(tk.END)
        logging.info(message)
    def try_redis_connection(self, host, port, username, password, db, tls_mode, verify_cert, ca_cert=None, client_cert=None, client_key=None):
        try:
            ssl_cert_reqs = ssl.CERT_NONE
            if tls_mode in ("Allow TLS", "Require TLS"):
                ssl_cert_reqs = ssl.CERT_REQUIRED if verify_cert else ssl.CERT_NONE
            self.log(f"[🔌] Connecting to Redis {host}:{port} with TLS mode '{tls_mode}' ...")
            redis_params = {"host": host,"port": port,"db": int(db),"decode_responses": True,"socket_connect_timeout": 5,"socket_timeout": 5,}
            if username:
                redis_params["username"] = username
            if password:
                redis_params["password"] = password
            if tls_mode == "Require TLS":
                redis_params["ssl"] = True
                redis_params["ssl_cert_reqs"] = ssl_cert_reqs
            elif tls_mode == "Allow TLS":
                redis_params["ssl"] = False
            else:
                redis_params["ssl"] = False
            self.redis_client = redis.Redis(**redis_params)
            pong = self.redis_client.ping()
            if pong:
                self.log("[SUCCESS] Connection established successfully.")
                self.detailed_diagnostics()
            else:
                self.log("[FAIL_PING] Ping failed - no response.")
        except redis.AuthenticationError:
            self.log("[FAIL] Authentication failed: Invalid username or password.")
        except redis.ConnectionError as ce:
            self.log(f"[ERROR] Connection error: {ce}")
        except Exception as e:
            self.log(f"[ERROR] Unexpected error: {e}")
            logging.error(traceback.format_exc())
    def detailed_diagnostics(self):
        self.log("[DIAG] Running detailed diagnostics...")
        try:
            info = self.redis_client.info()
            info_str = pprint.pformat(info, indent=2)
            self.log(f"******************Redis INFO*******************\n{info_str}")
        except Exception as e:
            self.log(f"[FAIL] Failed to get INFO: {e}")
        try:
            role = self.redis_client.role()
            role_str = pprint.pformat(role)
            self.log(f"******************Redis ROLE******************\n{role_str}")
        except Exception as e:
            self.log(f"[FAIL] Failed to get ROLE: {e}")
        try:
            config = self.redis_client.config_get()
            config_str = pprint.pformat(config)
            self.log(f"*******************Redis CONFIG GET******************\n{config_str}")
        except Exception as e:
            self.log(f"[FAIL] Failed to get CONFIG: {e}")
    def run_test(self):
        host = self.host_var.get().strip()
        try:
            port = int(self.port_var.get().strip())
        except ValueError:
            messagebox.showerror("Invalid Port", "Port must be a valid integer.")
            return
        username = self.username_var.get().strip()
        password = self.password_var.get()
        db = self.db_var.get()
        tls_mode = self.tls_mode_var.get()
        verify_cert = self.verify_cert_var.get()
        ca_cert = self.ca_cert_path.get() if self.ca_cert_path.get() else None
        client_cert = self.client_cert_path.get() if self.client_cert_path.get() else None
        client_key = self.client_key_path.get() if self.client_key_path.get() else None
        self.output.delete('1.0', tk.END)
        self.log(f"[TEST_START] Starting test for {host}:{port} ...")
        t = threading.Thread(target=self.try_redis_connection,args=(host, port, username, password, db, tls_mode, verify_cert,ca_cert, client_cert, client_key))
        t.daemon = True
        t.start()
    def check_missing_ciphers(self):
        try:
            available_ciphers = ssl.OPENSSL_VERSION.split()[-1]
            ctx = ssl.create_default_context()
            supported_ciphers = ctx.get_ciphers()     
            if not supported_ciphers:
                self.log("[WARN] No ciphers found in the SSL context.")
                return
            self.log("[CHCK] Checking for missing ciphers...")
            missing_ciphers = []
            for cipher in supported_ciphers:
                try:
                    redis_params = {"host": self.host_var.get().strip(),"port": int(self.port_var.get()),"ssl": True,"ssl_cert_reqs": ssl.CERT_REQUIRED,"ssl_ciphers": cipher["name"],}
                    test_client = redis.Redis(**redis_params)
                    test_client.ping()
                except redis.ConnectionError:
                    missing_ciphers.append(cipher["name"])
                if missing_ciphers:
                    self.log(f"[ERR] Missing ciphers preventing connection: {', '.join(missing_ciphers)}")
                else:
                    self.log("[SUCCESS] No missing ciphers detected.")                   
        except Exception as e:
            self.log(f"[ERROR] Unexpected error during cipher check: {e}")
            logging.error(traceback.format_exc())
    def execute_redis_command(self, event=None):
        if not self.redis_client:
            self.cli_output.insert(tk.END, "No Redis connection. Please test and connect first.\n")
            self.cli_output.see(tk.END)
            return
        cmd_line = self.cli_input.get().strip()
        if not cmd_line:
            return
        self.cli_input.delete(0, tk.END)
        try:
            parts = cmd_line.split()
            cmd = parts[0].upper()
            args = parts[1:]
            self.cli_output.insert(tk.END, f"> {cmd_line}\n")
            res = self.redis_client.execute_command(cmd, *args)
            if isinstance(res, (list, tuple)):
                res_str = "\n".join([str(r) for r in res])
            else:
                res_str = str(res)
            self.cli_output.insert(tk.END, f"{res_str}\n")
        except Exception as e:
            self.cli_output.insert(tk.END, f"Error: {e}\n")
        self.cli_output.see(tk.END)
    def start_monitor(self):
        if not self.redis_client:
            self.monitor_output.insert(tk.END, "No Redis connection. Please test and connect first.\n")
            self.monitor_output.see(tk.END)
            return
        if self.monitor_running:
            return
        self.monitor_running = True
        self.monitor_start_btn.config(state=tk.DISABLED)
        self.monitor_stop_btn.config(state=tk.NORMAL)
        self.monitor_output.insert(tk.END, "[MON_START] Starting MONITOR mode...\n")
        self.monitor_output.see(tk.END)
        def monitor_loop():
            try:
                monitor = self.redis_client.monitor()
                for cmd in monitor.listen():
                    if not self.monitor_running:
                        break
                    self.monitor_queue.put(cmd)
            except Exception as e:
                self.monitor_queue.put(f"[ERR] Monitor error: {e}")
        self.monitor_thread = threading.Thread(target=monitor_loop, daemon=True)
        self.monitor_thread.start()
        self.root.after(100, self.update_monitor_output)
    def update_monitor_output(self):
        while not self.monitor_queue.empty():
            msg = self.monitor_queue.get()
            self.monitor_output.insert(tk.END, f"{msg}\n")
            self.monitor_output.see(tk.END)
        if self.monitor_running:
            self.root.after(100, self.update_monitor_output)
    def stop_monitor(self):
        if not self.monitor_running:
            return
        self.monitor_running = False
        self.monitor_start_btn.config(state=tk.NORMAL)
        self.monitor_stop_btn.config(state=tk.DISABLED)
        self.monitor_output.insert(tk.END, "[MON_STOP] MONITOR stopped.\n")
        self.monitor_output.see(tk.END)
    def check_ssl_cert(self):
        ca_cert = self.ca_cert_path.get()
        client_cert = self.client_cert_path.get()
        client_key = self.client_key_path.get()
        if not ca_cert and not client_cert and not client_key:
            messagebox.showinfo("SSL Certificate Info", "No SSL certificates selected.")
            return
        try:
            context = ssl.create_default_context(purpose=ssl.Purpose.SERVER_AUTH)
            if ca_cert:
                context.load_verify_locations(cafile=ca_cert)
            if client_cert and client_key:
                context.load_cert_chain(certfile=client_cert, keyfile=client_key)
            messagebox.showinfo("SSL Certificate Info", "SSL context loaded successfully.\n" +
                                f"CA Cert: {ca_cert}\nClient Cert: {client_cert}\nClient Key: {client_key}")
        except Exception as e:
            messagebox.showerror("SSL Certificate Info", f"Failed to load SSL certs: {e}")
    def on_closing(self):
        if self.monitor_running:
            self.monitor_running = False
            time.sleep(0.5)
        self.save_settings()
        self.root.destroy()
if __name__ == "__main__":
    root = tk.Tk()
    app = RedisTesterApp(root)
    root.mainloop()
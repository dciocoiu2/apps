<#
.SYNOPSIS
    OmniFlow v2 - Portable API Client & Proxy
.DESCRIPTION
    Single-file .NET application. 
    Modes:
    1. Client: Compose and send REST requests.
    2. Proxy: Intercept local network traffic (HTTP Capture + HTTPS Tunneling).
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

$csharpSource = @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace OmniFlow
{
    // --- MAIN FORM ---
    public class MainForm : Form
    {
        // UI State
        private bool isProxyMode = false;
        private ProxyServer proxyServer;

        // Controls
        private Button modeSwitchBtn;
        private Panel clientPanel;
        private Panel proxyPanel;
        
        // Client Controls
        private ComboBox methodBox;
        private TextBox urlBox;
        private Button sendButton;
        
        // Proxy Controls
        private Button startProxyBtn;
        private Label proxyStatusLabel;

        // Shared Controls
        private ListBox historyList;
        private TabControl requestTabs;
        private TabControl responseTabs;
        private TextBox reqBodyBox;
        private TextBox reqHeadersBox;
        private TextBox resBodyBox;
        private TextBox resHeadersBox;
        private Label statusLabel;
        
        // Data
        private HttpClient client;
        private List<RequestLog> logs;

        public MainForm()
        {
            this.Text = "OmniFlow | Client & Proxy";
            this.Size = new Size(1100, 750);
            this.StartPosition = FormStartPosition.CenterScreen;
            this.Font = new Font("Segoe UI", 9F, FontStyle.Regular);
            
            client = new HttpClient();
            logs = new List<RequestLog>();
            proxyServer = new ProxyServer();
            proxyServer.OnRequestCaptured += (log) => this.Invoke((Action)(() => AddLog(log)));

            InitializeUI();
        }

        private void InitializeUI()
        {
            // Root Layout
            var topBar = new Panel { Dock = DockStyle.Top, Height = 45, Padding = new Padding(5), BackColor = Color.FromArgb(230,230,230) };
            var mainSplit = new SplitContainer { Dock = DockStyle.Fill, SplitterDistance = 280 };
            var rightSplit = new SplitContainer { Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, SplitterDistance = 350 };
            
            this.Controls.Add(mainSplit);
            this.Controls.Add(topBar);

            // --- Top Bar (Mode Switcher) ---
            modeSwitchBtn = new Button { 
                Parent = topBar, Text = "Switch to PROXY", 
                Left = 5, Top = 8, Width = 120, Height = 28,
                BackColor = Color.FromArgb(60, 60, 60), ForeColor = Color.White
            };
            modeSwitchBtn.Click += ToggleMode;

            // Client Controls Panel
            clientPanel = new Panel { Parent = topBar, Left = 130, Top = 0, Width = 900, Height = 45, Anchor = AnchorStyles.Left | AnchorStyles.Right };
            methodBox = new ComboBox { Parent = clientPanel, Left = 5, Top = 10, Width = 80, DropDownStyle = ComboBoxStyle.DropDownList };
            methodBox.Items.AddRange(new object[] { "GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS" });
            methodBox.SelectedIndex = 0;
            
            urlBox = new TextBox { Parent = clientPanel, Left = 90, Top = 10, Width = 650, Height = 25, Text = "https://httpbin.org/get", Anchor = AnchorStyles.Left | AnchorStyles.Right };
            
            sendButton = new Button { 
                Parent = clientPanel, Text = "SEND", 
                Left = 750, Top = 9, Width = 80, Height = 28, 
                BackColor = Color.FromArgb(0, 122, 204), ForeColor = Color.White, Anchor = AnchorStyles.Right 
            };
            sendButton.Click += async (s, e) => await SendClientRequest();

            // Proxy Controls Panel (Hidden by default)
            proxyPanel = new Panel { Parent = topBar, Left = 130, Top = 0, Width = 900, Height = 45, Visible = false };
            startProxyBtn = new Button { 
                Parent = proxyPanel, Text = "Start Proxy (Port 8888)", 
                Left = 5, Top = 9, Width = 160, Height = 28, 
                BackColor = Color.SeaGreen, ForeColor = Color.White 
            };
            startProxyBtn.Click += ToggleProxyServer;

            proxyStatusLabel = new Label { Parent = proxyPanel, Left = 180, Top = 14, Width = 500, Text = "Status: Stopped. Configure system proxy to 127.0.0.1:8888" };

            // --- Sidebar (History) ---
            historyList = new ListBox { Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, Font = new Font("Consolas", 9F) };
            historyList.SelectedIndexChanged += LoadHistoryItem;
            mainSplit.Panel1.Controls.Add(historyList);

            // --- Editors ---
            requestTabs = new TabControl { Dock = DockStyle.Fill };
            reqBodyBox = CreateEditor(); reqHeadersBox = CreateEditor();
            AddTab(requestTabs, "Headers", reqHeadersBox);
            AddTab(requestTabs, "Body", reqBodyBox);

            responseTabs = new TabControl { Dock = DockStyle.Fill };
            resBodyBox = CreateEditor(true); resHeadersBox = CreateEditor(true);
            AddTab(responseTabs, "Response Body", resBodyBox);
            AddTab(responseTabs, "Response Headers", resHeadersBox);

            statusLabel = new Label { Dock = DockStyle.Bottom, Height = 25, Text = "Ready", BackColor = Color.WhiteSmoke, TextAlign = ContentAlignment.MiddleLeft };

            rightSplit.Panel1.Controls.Add(requestTabs);
            rightSplit.Panel2.Controls.Add(responseTabs);
            rightSplit.Panel2.Controls.Add(statusLabel);
            mainSplit.Panel2.Controls.Add(rightSplit);
        }

        private void ToggleMode(object sender, EventArgs e)
        {
            isProxyMode = !isProxyMode;
            modeSwitchBtn.Text = isProxyMode ? "Switch to CLIENT" : "Switch to PROXY";
            clientPanel.Visible = !isProxyMode;
            proxyPanel.Visible = isProxyMode;
            this.Text = isProxyMode ? "OmniFlow | Proxy Mode" : "OmniFlow | Client Mode";
        }

        private void ToggleProxyServer(object sender, EventArgs e)
        {
            if (!proxyServer.IsRunning) {
                try {
                    proxyServer.Start();
                    startProxyBtn.Text = "Stop Proxy";
                    startProxyBtn.BackColor = Color.IndianRed;
                    proxyStatusLabel.Text = "Listening on 127.0.0.1:8888...";
                } catch (Exception ex) { MessageBox.Show("Error starting proxy: " + ex.Message); }
            } else {
                proxyServer.Stop();
                startProxyBtn.Text = "Start Proxy (Port 8888)";
                startProxyBtn.BackColor = Color.SeaGreen;
                proxyStatusLabel.Text = "Status: Stopped";
            }
        }

        private void AddLog(RequestLog log)
        {
            logs.Add(log);
            historyList.Items.Add(log.ToString());
            // Auto-scroll if at bottom could go here
        }

        private void AddTab(TabControl ctrl, string title, Control content) {
            var page = new TabPage(title);
            page.Controls.Add(content);
            ctrl.TabPages.Add(page);
        }

        private TextBox CreateEditor(bool ro = false) {
            return new TextBox { Multiline = true, Dock = DockStyle.Fill, ScrollBars = ScrollBars.Vertical, Font = new Font("Consolas", 9F), ReadOnly = ro, BackColor = ro ? Color.White : SystemColors.Window };
        }

        // --- CLIENT LOGIC ---
        private async Task SendClientRequest()
        {
            sendButton.Enabled = false; 
            statusLabel.Text = "Sending...";
            
            var method = new HttpMethod(methodBox.SelectedItem.ToString());
            var req = new HttpRequestMessage(method, urlBox.Text);
            
            // Headers
            if(!string.IsNullOrWhiteSpace(reqHeadersBox.Text)) {
                foreach(var line in reqHeadersBox.Lines) {
                    var p = line.Split(new[]{':'}, 2);
                    if(p.Length==2) req.Headers.TryAddWithoutValidation(p[0].Trim(), p[1].Trim());
                }
            }
            
            // Body
            if (method != HttpMethod.Get && !string.IsNullOrEmpty(reqBodyBox.Text))
                req.Content = new StringContent(reqBodyBox.Text, Encoding.UTF8, "application/json");

            var watch = System.Diagnostics.Stopwatch.StartNew();
            int code = 0; string body="", heads="";

            try {
                var res = await client.SendAsync(req);
                watch.Stop();
                code = (int)res.StatusCode;
                body = await res.Content.ReadAsStringAsync();
                heads = res.Headers.ToString() + res.Content.Headers.ToString();
                statusLabel.Text = $"{code} {res.ReasonPhrase} | {watch.ElapsedMilliseconds}ms";
            } catch (Exception ex) {
                statusLabel.Text = "Error: " + ex.Message;
                body = ex.ToString();
            } finally { sendButton.Enabled = true; }

            var log = new RequestLog { Method = method.Method, Url = urlBox.Text, Status = code, TimeMs = watch.ElapsedMilliseconds, ReqBody = reqBodyBox.Text, ReqHeaders = reqHeadersBox.Text, ResBody = body, ResHeaders = heads };
            AddLog(log);
            LoadLogToUI(log);
        }

        private void LoadHistoryItem(object sender, EventArgs e) {
            if (historyList.SelectedIndex == -1) return;
            LoadLogToUI(logs[historyList.SelectedIndex]);
        }

        private void LoadLogToUI(RequestLog log) {
            methodBox.SelectedItem = methodBox.Items.Contains(log.Method) ? log.Method : "GET";
            urlBox.Text = log.Url;
            reqBodyBox.Text = log.ReqBody;
            reqHeadersBox.Text = log.ReqHeaders;
            resBodyBox.Text = log.ResBody;
            resHeadersBox.Text = log.ResHeaders;
            statusLabel.Text = $"Status: {log.Status} | Time: {log.TimeMs}ms";
        }

        protected override void OnFormClosing(FormClosingEventArgs e) {
            proxyServer.Stop();
            base.OnFormClosing(e);
        }
    }

    // --- DATA MODEL ---
    public class RequestLog {
        public string Method { get; set; }
        public string Url { get; set; }
        public int Status { get; set; }
        public long TimeMs { get; set; }
        public string ReqBody { get; set; }
        public string ReqHeaders { get; set; }
        public string ResBody { get; set; }
        public string ResHeaders { get; set; }
        public override string ToString() => $"[{Method}] {Url} ({Status})";
    }

    // --- PROXY SERVER LOGIC ---
    public class ProxyServer {
        private TcpListener listener;
        public bool IsRunning { get; private set; }
        public event Action<RequestLog> OnRequestCaptured;

        public void Start() {
            listener = new TcpListener(IPAddress.Any, 8888);
            listener.Start();
            IsRunning = true;
            Task.Run(() => ListenLoop());
        }

        public void Stop() {
            IsRunning = false;
            listener?.Stop();
        }

        private async Task ListenLoop() {
            while (IsRunning) {
                try {
                    var client = await listener.AcceptTcpClientAsync();
                    _ = HandleClient(client);
                } catch { if(IsRunning) Thread.Sleep(100); }
            }
        }

        private async Task HandleClient(TcpClient client) {
            using (client)
            using (var stream = client.GetStream()) {
                // Read Request Line
                var buffer = new byte[8192];
                var read = await stream.ReadAsync(buffer, 0, buffer.Length);
                if (read == 0) return;
                
                var rawReq = Encoding.ASCII.GetString(buffer, 0, read);
                var lines = rawReq.Split(new[] { "\r\n" }, StringSplitOptions.None);
                var requestLine = lines[0].Split(' ');
                
                if (requestLine.Length < 2) return;
                var method = requestLine[0];
                var url = requestLine[1];

                // HANDLE HTTPS TUNNEL (CONNECT)
                if (method == "CONNECT") {
                    var log = new RequestLog { Method = "TUNNEL", Url = url, Status = 200, ReqHeaders = rawReq, ResBody = "[Encrypted Tunnel Established]" };
                    OnRequestCaptured?.Invoke(log);

                    var remoteParts = url.Split(':');
                    var host = remoteParts[0];
                    var port = remoteParts.Length > 1 ? int.Parse(remoteParts[1]) : 443;

                    try {
                        using (var remote = new TcpClient(host, port))
                        using (var remoteStream = remote.GetStream()) {
                            // Send 200 OK to Client to confirm tunnel
                            var confirm = Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection Established\r\n\r\n");
                            await stream.WriteAsync(confirm, 0, confirm.Length);

                            // Relay Blindly
                            var t1 = stream.CopyToAsync(remoteStream);
                            var t2 = remoteStream.CopyToAsync(stream);
                            await Task.WhenAny(t1, t2);
                        }
                    } catch {}
                    return;
                }

                // HANDLE HTTP PROXY
                // Note: This is a basic HTTP implementation.
                var logHttp = new RequestLog { Method = method, Url = url, ReqHeaders = rawReq };
                
                try {
                    // Create Request to Real Server
                    var reqMessage = new HttpRequestMessage(new HttpMethod(method), url);
                    
                    // Simple Header Forwarding (Strip Proxy headers)
                    foreach(var l in lines) {
                        if(l.Contains(":")) {
                            var p = l.Split(new[]{':'}, 2);
                            if(!p[0].StartsWith("Proxy-")) 
                                reqMessage.Headers.TryAddWithoutValidation(p[0].Trim(), p[1].Trim());
                        }
                    }

                    // Forward Body if exists (POST/PUT)
                    var bodyIdx = rawReq.IndexOf("\r\n\r\n");
                    if (bodyIdx > 0 && bodyIdx + 4 < rawReq.Length) {
                        var bodyContent = rawReq.Substring(bodyIdx + 4);
                        reqMessage.Content = new StringContent(bodyContent);
                        logHttp.ReqBody = bodyContent;
                    }

                    using (var httpClient = new HttpClient()) {
                        var response = await httpClient.SendAsync(reqMessage);
                        logHttp.Status = (int)response.StatusCode;
                        
                        // Send Response back to Client
                        var respLine = $"HTTP/1.1 {(int)response.StatusCode} {response.ReasonPhrase}\r\n";
                        var headerSb = new StringBuilder(respLine);
                        headerSb.Append(response.Headers.ToString());
                        headerSb.Append(response.Content.Headers.ToString());
                        headerSb.Append("\r\n");

                        var headBytes = Encoding.UTF8.GetBytes(headerSb.ToString());
                        await stream.WriteAsync(headBytes, 0, headBytes.Length);
                        
                        var respBody = await response.Content.ReadAsByteArrayAsync();
                        await stream.WriteAsync(respBody, 0, respBody.Length);

                        logHttp.ResBody = Encoding.UTF8.GetString(respBody);
                        logHttp.ResHeaders = headerSb.ToString();
                    }
                } catch (Exception ex) {
                    logHttp.ResBody = "Proxy Error: " + ex.Message;
                }
                
                OnRequestCaptured?.Invoke(logHttp);
            }
        }
    }
}
"@

# Compilation
try {
    Add-Type -TypeDefinition $csharpSource -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Net.Http
}
catch {
    Write-Host "Compile Error:" -ForegroundColor Red
    Write-Host $_.Exception.Message
    $_.Exception.LoaderExceptions | ForEach-Object { Write-Host $_.Message }
    Pause
    Exit
}

# Execution
[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object OmniFlow.MainForm
[System.Windows.Forms.Application]::Run($form)

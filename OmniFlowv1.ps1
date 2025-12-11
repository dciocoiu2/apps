<#
.SYNOPSIS
    OmniFlow - A portable, single-file .NET HTTP Debugger and API Client.
    
.DESCRIPTION
    This script compiles a C# Windows Forms application on the fly to provide
    a GUI for testing REST APIs, viewing responses, and tracking request history.
    It requires no external dependencies other than the standard .NET Framework
    pre-installed on Windows.

.NOTES
    File Name : OmniFlow.ps1
    Author    : Gemini
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

$csharpSource = @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace OmniFlow
{
    public class MainForm : Form
    {
        // UI Controls
        private ComboBox methodBox;
        private TextBox urlBox;
        private Button sendButton;
        private ListBox historyList;
        private TabControl requestTabs;
        private TabControl responseTabs;
        private TextBox reqBodyBox;
        private TextBox reqHeadersBox;
        private TextBox resBodyBox;
        private TextBox resHeadersBox;
        private Label statusLabel;
        
        // Logic
        private HttpClient client;
        private List<RequestLog> logs;

        public MainForm()
        {
            this.Text = "OmniFlow | Portable Network Client";
            this.Size = new Size(1000, 700);
            this.StartPosition = FormStartPosition.CenterScreen;
            this.Font = new Font("Segoe UI", 9F, FontStyle.Regular);
            
            client = new HttpClient();
            logs = new List<RequestLog>();

            InitializeUI();
        }

        private void InitializeUI()
        {
            // --- Layout Panels ---
            var mainSplit = new SplitContainer { Dock = DockStyle.Fill, SplitterDistance = 250 };
            var rightSplit = new SplitContainer { Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, SplitterDistance = 300 };
            var topPanel = new Panel { Dock = DockStyle.Top, Height = 50, Padding = new Padding(10) };
            
            this.Controls.Add(mainSplit);
            this.Controls.Add(topPanel);

            // --- Top Bar ---
            methodBox = new ComboBox { 
                Parent = topPanel, 
                Left = 10, Top = 12, Width = 80, 
                DropDownStyle = ComboBoxStyle.DropDownList 
            };
            methodBox.Items.AddRange(new object[] { "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS" });
            methodBox.SelectedIndex = 0;

            sendButton = new Button { 
                Parent = topPanel, 
                Text = "SEND", 
                Left = 880, Top = 11, Width = 90, Height = 28,
                BackColor = Color.FromArgb(0, 122, 204),
                ForeColor = Color.White,
                FlatStyle = FlatStyle.Flat
            };
            sendButton.Click += async (s, e) => await SendRequest();

            urlBox = new TextBox { 
                Parent = topPanel, 
                Left = 100, Top = 12, Width = 770, Height = 25,
                Text = "https://httpbin.org/get" 
            };
            urlBox.Anchor = AnchorStyles.Left | AnchorStyles.Right; // allow resize
            sendButton.Anchor = AnchorStyles.Right;

            // --- Left Sidebar (History) ---
            historyList = new ListBox { 
                Dock = DockStyle.Fill, 
                BorderStyle = BorderStyle.None,
                BackColor = Color.FromArgb(245, 245, 245),
                Font = new Font("Consolas", 9F)
            };
            historyList.SelectedIndexChanged += LoadHistoryItem;
            mainSplit.Panel1.Controls.Add(historyList);

            // --- Right Top (Request) ---
            requestTabs = new TabControl { Dock = DockStyle.Fill };
            var tabReqBody = new TabPage("Body");
            var tabReqHeader = new TabPage("Headers");
            
            reqBodyBox = CreateEditor();
            reqHeadersBox = CreateEditor();
            
            tabReqBody.Controls.Add(reqBodyBox);
            tabReqHeader.Controls.Add(reqHeadersBox);
            
            requestTabs.TabPages.Add(tabReqHeader); // Headers first usually
            requestTabs.TabPages.Add(tabReqBody);
            
            rightSplit.Panel1.Controls.Add(requestTabs);

            // --- Right Bottom (Response) ---
            responseTabs = new TabControl { Dock = DockStyle.Fill };
            var tabResBody = new TabPage("Response Body");
            var tabResHeader = new TabPage("Response Headers");
            
            resBodyBox = CreateEditor();
            resBodyBox.ReadOnly = true;
            resBodyBox.BackColor = Color.White;
            
            resHeadersBox = CreateEditor();
            resHeadersBox.ReadOnly = true;

            tabResBody.Controls.Add(resBodyBox);
            tabResHeader.Controls.Add(resHeadersBox);

            responseTabs.TabPages.Add(tabResBody);
            responseTabs.TabPages.Add(tabResHeader);

            // Status Bar area in response panel
            statusLabel = new Label { 
                Dock = DockStyle.Bottom, 
                Height = 25, 
                Text = "Ready", 
                TextAlign = ContentAlignment.MiddleLeft,
                BackColor = Color.FromArgb(240, 240, 240)
            };

            rightSplit.Panel2.Controls.Add(responseTabs);
            rightSplit.Panel2.Controls.Add(statusLabel);

            mainSplit.Panel2.Controls.Add(rightSplit);
        }

        private TextBox CreateEditor()
        {
            return new TextBox {
                Multiline = true,
                Dock = DockStyle.Fill,
                ScrollBars = ScrollBars.Vertical,
                Font = new Font("Consolas", 10F),
                BorderStyle = BorderStyle.None
            };
        }

        private async Task SendRequest()
        {
            sendButton.Enabled = false;
            sendButton.Text = "...";
            statusLabel.Text = "Sending...";
            
            var method = new HttpMethod(methodBox.SelectedItem.ToString());
            var url = urlBox.Text;

            // Create Request
            var request = new HttpRequestMessage(method, url);

            // Parse Headers
            try {
                if (!string.IsNullOrWhiteSpace(reqHeadersBox.Text)) {
                    foreach (var line in reqHeadersBox.Lines) {
                        if (string.IsNullOrWhiteSpace(line)) continue;
                        var parts = line.Split(new[] { ':' }, 2);
                        if (parts.Length == 2) {
                            request.Headers.TryAddWithoutValidation(parts[0].Trim(), parts[1].Trim());
                        }
                    }
                }
            } catch { /* Simple ignore for bad headers */ }

            // Add Body
            if ((method == HttpMethod.Post || method == HttpMethod.Put || method.Method == "PATCH") && !string.IsNullOrEmpty(reqBodyBox.Text))
            {
                request.Content = new StringContent(reqBodyBox.Text, Encoding.UTF8, "application/json");
                // Attempt to add content headers if manually specified, otherwise defaults to json/plain
            }

            var watch = System.Diagnostics.Stopwatch.StartNew();
            string statusStr = "";
            string bodyStr = "";
            string headersStr = "";
            int statusCode = 0;

            try
            {
                var response = await client.SendAsync(request);
                watch.Stop();
                
                statusCode = (int)response.StatusCode;
                statusStr = $"{statusCode} {response.ReasonPhrase}";
                
                bodyStr = await response.Content.ReadAsStringAsync();
                headersStr = response.Headers.ToString() + response.Content.Headers.ToString();

                statusLabel.Text = $"{statusStr} | Time: {watch.ElapsedMilliseconds}ms | Size: {bodyStr.Length} bytes";
                statusLabel.ForeColor = (statusCode >= 200 && statusCode < 300) ? Color.DarkGreen : Color.DarkRed;

            }
            catch (Exception ex)
            {
                statusStr = "Error";
                bodyStr = ex.Message;
                statusLabel.Text = "Request Failed";
                statusLabel.ForeColor = Color.Red;
            }
            finally
            {
                sendButton.Enabled = true;
                sendButton.Text = "SEND";
            }

            // Update UI
            resBodyBox.Text = bodyStr;
            resHeadersBox.Text = headersStr;

            // Log
            var log = new RequestLog {
                Method = method.Method,
                Url = url,
                Status = statusCode,
                TimeMs = watch.ElapsedMilliseconds,
                ReqBody = reqBodyBox.Text,
                ReqHeaders = reqHeadersBox.Text,
                ResBody = bodyStr,
                ResHeaders = headersStr
            };
            logs.Add(log);
            historyList.Items.Add(log.ToString());
            historyList.SelectedIndex = historyList.Items.Count - 1;
        }

        private void LoadHistoryItem(object sender, EventArgs e)
        {
            if (historyList.SelectedIndex == -1) return;
            var log = logs[historyList.SelectedIndex];
            
            methodBox.SelectedItem = log.Method;
            urlBox.Text = log.Url;
            reqBodyBox.Text = log.ReqBody;
            reqHeadersBox.Text = log.ReqHeaders;
            resBodyBox.Text = log.ResBody;
            resHeadersBox.Text = log.ResHeaders;
            statusLabel.Text = $"Status: {log.Status} | Time: {log.TimeMs}ms";
        }
    }

    public class RequestLog
    {
        public string Method { get; set; }
        public string Url { get; set; }
        public int Status { get; set; }
        public long TimeMs { get; set; }
        public string ReqBody { get; set; }
        public string ReqHeaders { get; set; }
        public string ResBody { get; set; }
        public string ResHeaders { get; set; }

        public override string ToString()
        {
            return $"[{Method}] {Status} - {Url}";
        }
    }
}
"@

# Compile the C# code
try {
    Add-Type -TypeDefinition $csharpSource -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Net.Http
}
catch {
    Write-Host "Failed to compile. Ensure you have .NET installed."
    Write-Host $_.Exception.Message
    Pause
    Exit
}

# Run the Application
[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object OmniFlow.MainForm
[System.Windows.Forms.Application]::Run($form)

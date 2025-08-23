param(
    [string]$ComputerName = "localhost",
    [switch]$Help
)

if ($Help) {
    Write-Host "Usage: script.ps1 [-ComputerName <name>] [-Help]"
    Write-Host "Auto-detects IIS endpoints (local or remote) and tests REST, SOAP, WCF, gRPC, WebSocket"
    exit
}

Add-Type -AssemblyName "Microsoft.Web.Administration"
$endpoints = @()
$sm = if ($ComputerName -eq "localhost") {
    [Microsoft.Web.Administration.ServerManager]::new()
} else {
    [Microsoft.Web.Administration.ServerManager]::OpenRemote($ComputerName)
}

foreach ($site in $sm.Sites) {
    foreach ($binding in $site.Bindings) {
        $protocol = $binding.Protocol
        $ip = if ($binding.EndPoint) { $binding.EndPoint.Address.ToString() } else { "localhost" }
        $port = $binding.EndPoint.Port
        $host = if ($binding.Host -and $binding.Host.Length -gt 0) { $binding.Host } else { $ip }
        $baseUrl = "{0}://{1}:{2}" -f $protocol, $host, $port
        foreach ($app in $site.Applications) {
            foreach ($vdir in $app.VirtualDirectories) {
                $path = $app.Path.Trim("/")
                $url = if ($path.Length -gt 0) { "$baseUrl/$path/" } else { "$baseUrl/" }
                $phys = $vdir.PhysicalPath
                if ([System.IO.Directory]::Exists($phys)) {
                    $files = [System.IO.Directory]::EnumerateFiles($phys, "*.*", [System.IO.SearchOption]::TopDirectoryOnly)
                    foreach ($f in $files) {
                        $ext = [System.IO.Path]::GetExtension($f)
                        switch -Regex ($ext) {
                            "\.svc"   { $endpoints += @{ Type="WCF";  Url=$url+([System.IO.Path]::GetFileName($f)) } }
                            "\.asmx"  { $endpoints += @{ Type="SOAP"; Url=$url+([System.IO.Path]::GetFileName($f)) } }
                            "\.proto" { $endpoints += @{ Type="gRPC"; Url=$url } }
                            default   { $endpoints += @{ Type="REST"; Url=$url } }
                        }
                    }
                } else {
                    $endpoints += @{ Type="REST"; Url=$url }
                }
            }
        }
    }
}

Add-Type -TypeDefinition @"
using System;
using System.Net.Http;
using System.Threading.Tasks;
using System.Net.WebSockets;
using System.Text;

public class Tester {
    public static async Task<string> TestRest(string url) {
        try {
            using (var client = new HttpClient()) {
                var resp = await client.GetAsync(url);
                return url + " REST " + ((int)resp.StatusCode).ToString();
            }
        } catch (Exception ex) { return url + " REST FAIL " + ex.Message; }
    }
    public static async Task<string> TestSoap(string url) {
        try {
            using (var client = new HttpClient()) {
                var resp = await client.GetAsync(url+"?wsdl");
                return url + " SOAP " + ((int)resp.StatusCode).ToString();
            }
        } catch (Exception ex) { return url + " SOAP FAIL " + ex.Message; }
    }
    public static async Task<string> TestWcf(string url) {
        try {
            using (var client = new HttpClient()) {
                var resp = await client.GetAsync(url+"?wsdl");
                return url + " WCF " + ((int)resp.StatusCode).ToString();
            }
        } catch (Exception ex) { return url + " WCF FAIL " + ex.Message; }
    }
    public static async Task<string> TestGrpc(string url) {
        try {
            using (var client = new HttpClient()) {
                client.DefaultRequestHeaders.Add("te","trailers");
                client.DefaultRequestHeaders.Add("Content-Type","application/grpc");
                var resp = await client.PostAsync(url, new StringContent(""));
                return url + " gRPC " + ((int)resp.StatusCode).ToString();
            }
        } catch (Exception ex) { return url + " gRPC FAIL " + ex.Message; }
    }
    public static async Task<string> TestWebSocket(string url) {
        try {
            var ws = new ClientWebSocket();
            var uri = new Uri(url.Replace("http","ws"));
            await ws.ConnectAsync(uri, System.Threading.CancellationToken.None);
            if (ws.State == WebSocketState.Open) {
                await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "ok", System.Threading.CancellationToken.None);
                return url + " WS OK";
            }
            return url + " WS FAIL";
        } catch (Exception ex) { return url + " WS FAIL " + ex.Message; }
    }
}
"@ -Language CSharp

$tasks = @()
foreach ($ep in $endpoints) {
    switch ($ep.Type) {
        "REST"  { $tasks += [Tester]::TestRest($ep.Url) }
        "SOAP"  { $tasks += [Tester]::TestSoap($ep.Url) }
        "WCF"   { $tasks += [Tester]::TestWcf($ep.Url) }
        "gRPC"  { $tasks += [Tester]::TestGrpc($ep.Url) }
        default { $tasks += [Tester]::TestWebSocket($ep.Url) }
    }
}
[System.Threading.Tasks.Task]::WhenAll($tasks).Result | ForEach-Object { Write-Host $_ }
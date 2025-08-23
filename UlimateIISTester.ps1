param(
    [string]$ComputerName="localhost",
    [int[]]$Ports=@(80,443),
    [switch]$TestREST=$true,
    [switch]$TestSOAP=$true,
    [switch]$TestWCF=$true,
    [switch]$TestGRPC=$true,
    [switch]$TestWebSocket=$true,
    [ValidateSet("GET","POST","PUT","DELETE")] [string]$HttpMethod="GET",
    [int]$Timeout=5000,
    [int]$MaxConcurrency=10,
    [int]$RetryCount=2,
    [string]$Username="",
    [string]$Password="",
    [string]$BearerToken="",
    [string]$Payload="",
    [string]$ContentType="application/json",
    [int]$MaxLatency=0,
    [string[]]$Headers=@(),
    [string]$OutputLog="",
    [switch]$UseWebGUI,
    [ValidateSet("Sequential","Parallel")] [string]$ConcurrencyMode="Parallel",
    [switch]$DiscoverApis,
    [switch]$Help
)

function Show-Help{
    [Console]::WriteLine("IIS API Tester - fully automated endpoint tester")
    [Console]::WriteLine("Parameters:")
    [Console]::WriteLine(" -ComputerName <name> : Target IIS server")
    [Console]::WriteLine(" -Ports <int,int,...> : Ports to scan")
    [Console]::WriteLine(" -TestREST -TestSOAP -TestWCF -TestGRPC -TestWebSocket : Endpoint types")
    [Console]::WriteLine(" -HttpMethod <GET|POST|PUT|DELETE>")
    [Console]::WriteLine(" -Timeout <ms>")
    [Console]::WriteLine(" -MaxConcurrency <int>")
    [Console]::WriteLine(" -RetryCount <int>")
    [Console]::WriteLine(" -Username <string> / -Password <string> / -BearerToken <string>")
    [Console]::WriteLine(" -Payload <string> / -ContentType <string>")
    [Console]::WriteLine(" -MaxLatency <ms>")
    [Console]::WriteLine(" -Headers <string[]> in 'Key:Value' format")
    [Console]::WriteLine(" -OutputLog <file>")
    [Console]::WriteLine(" -UseWebGUI")
    [Console]::WriteLine(" -ConcurrencyMode <Sequential|Parallel>")
    [Console]::WriteLine(" -DiscoverApis : Enable auto-discovery from WSDL/Swagger/.proto")
    [Console]::WriteLine(" -Help : Show this help")
    [Console]::WriteLine("Examples:")
    [Console]::WriteLine("  .\IISApiTester.ps1 -ComputerName localhost -Ports 80,8080 -TestREST -HttpMethod GET")
    [Console]::WriteLine("  .\IISApiTester.ps1 -UseWebGUI")
    exit
}

if($Help){Show-Help}

if($UseWebGUI){
    Add-Type -AssemblyName System.Net.HttpListener
    $listener = New-Object System.Net.HttpListener
    $port = (Get-Random -Minimum 1024 -Maximum 65535)
    $listener.Prefixes.Add("http://localhost:$port/")
    $listener.Start()
    Write-Host "Pixel Web GUI running at http://localhost:$port/"
    $global:GuiResults = New-Object System.Collections.Generic.List[PSObject]
    Start-Job -ScriptBlock {
        param($listener)
        while($listener.IsListening){
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response
            if($request.HttpMethod -eq "POST"){
                $reader = New-Object System.IO.StreamReader($request.InputStream)
                $body = $reader.ReadToEnd()
                $params = @{}
                $body.Split("&") | ForEach-Object {
                    $kv = $_.Split("=")
                    $params[$kv[0]] = [System.Net.WebUtility]::UrlDecode($kv[1])
                }
                $Script:ComputerName = $params["ComputerName"]
                $Script:Ports = $params["Ports"].Split(",") | % {[int]$_}
                $Script:TestREST = $params["TestREST"] -eq "on"
                $Script:TestSOAP = $params["TestSOAP"] -eq "on"
                $Script:TestWCF = $params["TestWCF"] -eq "on"
                $Script:TestGRPC = $params["TestGRPC"] -eq "on"
                $Script:TestWebSocket = $params["TestWebSocket"] -eq "on"
                $Script:HttpMethod = $params["HttpMethod"]
                $Script:Timeout = [int]$params["Timeout"]
                $Script:MaxConcurrency = [int]$params["MaxConcurrency"]
                $Script:RetryCount = [int]$params["RetryCount"]
                $Script:OutputLog = $params["OutputLog"]
                $Script:Username = $params["Username"]
                $Script:Password = $params["Password"]
                $Script:BearerToken = $params["BearerToken"]
                $Script:Payload = $params["Payload"]
                $Script:ContentType = $params["ContentType"]
                $respStr = "<html><body><h2>Configuration received. Running tests...</h2></body></html>"
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($respStr)
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer,0,$buffer.Length)
                $response.OutputStream.Close()
                break
            }
            else {
                $html = @"
<html>
<head><title>Pixel Web GUI</title></head>
<body>
<h2>IIS API Tester Configuration</h2>
<form method='post'>
ComputerName: <input name='ComputerName' value='$ComputerName'/><br/>
Ports: <input name='Ports' value='$($Ports -join ",")'/><br/>
TestREST: <input type='checkbox' name='TestREST' checked='$TestREST'/><br/>
TestSOAP: <input type='checkbox' name='TestSOAP' checked='$TestSOAP'/><br/>
TestWCF: <input type='checkbox' name='TestWCF' checked='$TestWCF'/><br/>
TestGRPC: <input type='checkbox' name='TestGRPC' checked='$TestGRPC'/><br/>
TestWebSocket: <input type='checkbox' name='TestWebSocket' checked='$TestWebSocket'/><br/>
HttpMethod: <input name='HttpMethod' value='$HttpMethod'/><br/>
Timeout: <input name='Timeout' value='$Timeout'/><br/>
MaxConcurrency: <input name='MaxConcurrency' value='$MaxConcurrency'/><br/>
RetryCount: <input name='RetryCount' value='$RetryCount'/><br/>
Username: <input name='Username' value='$Username'/><br/>
Password: <input type='password' name='Password' value='$Password'/><br/>
BearerToken: <input name='BearerToken' value='$BearerToken'/><br/>
Payload: <input name='Payload' value='$Payload'/><br/>
ContentType: <input name='ContentType' value='$ContentType'/><br/>
OutputLog: <input name='OutputLog' value='$OutputLog'/><br/>
<input type='submit' value='Run Test'/>
</form>
</body>
</html>
"@
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
                $response.ContentLength64 = $buffer.Length
                $response.OutputStream.Write($buffer,0,$buffer.Length)
                $response.OutputStream.Close()
            }
        }
    } -ArgumentList $listener | Out-Null
}

[void][Reflection.Assembly]::LoadWithPartialName("Microsoft.Web.Administration")
$sm=if($ComputerName -eq "localhost"){New-Object Microsoft.Web.Administration.ServerManager}else{[Microsoft.Web.Administration.ServerManager]::OpenRemote($ComputerName)}
$endpoints=New-Object System.Collections.Generic.List[System.Object]
foreach($site in $sm.Sites){
    foreach($binding in $site.Bindings){
        $protocol=$binding.Protocol
        $ip=if($binding.EndPoint){$binding.EndPoint.Address.ToString()}else{"localhost"}
        foreach($p in $Ports){
            $baseUrl="{0}://{1}:{2}" -f $protocol,$ip,$p
            foreach($app in $site.Applications){
                foreach($vdir in $app.VirtualDirectories){
                    $path=$app.Path.Trim("/")
                    $url=if($path.Length -gt 0){"$baseUrl/$path/"}else{"$baseUrl/"}
                    $phys=$vdir.PhysicalPath
                    if([System.IO.Directory]::Exists($phys)){
                        $files=[System.IO.Directory]::GetFiles($phys,"*.*",[System.IO.SearchOption]::TopDirectoryOnly)
                        foreach($f in $files){
                            $ext=[System.IO.Path]::GetExtension($f)
                            switch($ext){
                                ".svc" {if($TestWCF){$endpoints.Add(@{Type="WCF";Url=$url;Protocol=$protocol;Port=$p})}}
                                ".asmx" {if($TestSOAP){$endpoints.Add(@{Type="SOAP";Url=$url;Protocol=$protocol;Port=$p})}}
                                ".proto" {if($TestGRPC){$endpoints.Add(@{Type="gRPC";Url=$url;Protocol=$protocol;Port=$p})}}
                                ".json" {if($DiscoverApis){$endpoints.Add(@{Type="REST";Url=$url;Protocol=$protocol;Port=$p})}}
                                default {if($TestREST){$endpoints.Add(@{Type="REST";Url=$url;Protocol=$protocol;Port=$p})}}
                            }
                        }
                    }else{if($TestREST){$endpoints.Add(@{Type="REST";Url=$url;Protocol=$protocol;Port=$p})}}
                }
            }
        }
    }
}

function Invoke-HttpRequest([string]$url,[string]$method,[int]$timeout,[int]$retry){
    for($i=0;$i-le $retry;$i++){
        $sw=[Diagnostics.Stopwatch]::StartNew()
        try{
            $req=[System.Net.HttpWebRequest]::Create($url)
            $req.Method=$method
            $req.Timeout=$timeout
            if($Username){$req.Credentials = New-Object System.Net.NetworkCredential($Username,$Password)}
            if($BearerToken){$req.Headers.Add("Authorization","Bearer $BearerToken")}
            foreach($h in $Headers){$kv=$h.Split(":");$req.Headers.Add($kv[0],$kv[1])}
            if($method -in "POST","PUT"){
                $bytes=[System.Text.Encoding]::UTF8.GetBytes($Payload)
                $req.ContentType=$ContentType
                $req.ContentLength=$bytes.Length
                $stream=$req.GetRequestStream()
                $stream.Write($bytes,0,$bytes.Length)
                $stream.Close()
            }
            $resp=$req.GetResponse()
            $sw.Stop()
            $status=[int]$resp.StatusCode
            $resp.Close()
            $result = if($MaxLatency -gt 0 -and $sw.ElapsedMilliseconds -gt $MaxLatency){"FAIL"}else{"OK"}
            return @{Url=$url;Type="HTTP";Method=$method;Status=$status;Result=$result;Latency=$sw.ElapsedMilliseconds}
        }catch{if($i -eq $retry){$sw.Stop();return @{Url=$url;Type="HTTP";Method=$method;Status=0;Result="FAIL";Message=$_.Exception.Message;Latency=$sw.ElapsedMilliseconds}}}
    }
}

function Invoke-WebSocket([string]$url,[int]$timeout,[int]$retry){
    for($i=0;$i-le $retry;$i++){
        $sw=[Diagnostics.Stopwatch]::StartNew()
        try{
            $client=New-Object System.Net.WebSockets.ClientWebSocket
            $uri=[Uri]::new($url.Replace("http","ws"))
            $task=$client.ConnectAsync($uri,[Threading.CancellationToken]::None)
            $task.Wait($timeout)
            $sw.Stop()
            if($client.State -eq [System.Net.WebSockets.WebSocketState]::Open){
                $client.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,"ok",[Threading.CancellationToken]::None).Wait($timeout)
                return @{Url=$url;Type="WebSocket";Result="OK";Latency=$sw.ElapsedMilliseconds}}
            if($i -eq $retry){return @{Url=$url;Type="WebSocket";Result="FAIL";Latency=$sw.ElapsedMilliseconds}}
        }catch{if($i -eq $retry){$sw.Stop();return @{Url=$url;Type="WebSocket";Result="FAIL";Message=$_.Exception.Message;Latency=$sw.ElapsedMilliseconds}}}
    }
}

function Invoke-gRPC([string]$url,[int]$timeout,[int]$retry){
    for($i=0;$i-le $retry;$i++){
        $sw=[Diagnostics.Stopwatch]::StartNew()
        try{
            $req=[System.Net.HttpWebRequest]::Create($url)
            $req.Method="HEAD"
            $req.Timeout=$timeout
            $req.ProtocolVersion=[Version]::Parse("2.0")
            $resp=$req.GetResponse()
            $sw.Stop()
            $resp.Close()
            return @{Url=$url;Type="gRPC";Result="OK";Latency=$sw.ElapsedMilliseconds}
        }catch{if($i -eq $retry){$sw.Stop();return @{Url=$url;Type="gRPC";Result="FAIL";Message=$_.Exception.Message;Latency=$sw.ElapsedMilliseconds}}}
    }
}
function Generate-HTMLReport([System.Collections.Generic.List[object]]$Results, [string]$FilePath){
    $htmlHeader = @"
<html>
<head>
<title>IIS API Test Report</title>
<style>
body{font-family:Arial;}
table{border-collapse:collapse;width:100%;}
th,td{border:1px solid #ddd;padding:8px;text-align:left;}
th{background-color:#4CAF50;color:white;cursor:pointer;}
tr:nth-child(even){background-color:#f2f2f2;}
.ok{background-color:#c6efce;color:#006100;}
.fail{background-color:#ffc7ce;color:#9c0006;}
</style>
<script>
function sortTable(n){
    var table=document.getElementsByTagName('table')[0];
    var rows=Array.from(table.rows).slice(1);
    var asc=true;
    if(table.getAttribute('data-sort-col')==n){asc=!JSON.parse(table.getAttribute('data-sort-asc'))}
    rows.sort(function(a,b){
        var x=a.cells[n].innerText.toLowerCase();var y=b.cells[n].innerText.toLowerCase();
        return asc?x.localeCompare(y):y.localeCompare(x);
    });
    for(var i=0;i<rows.length;i++){table.appendChild(rows[i]);}
    table.setAttribute('data-sort-col',n);table.setAttribute('data-sort-asc',asc);
}
</script>
</head>
<body>
<h2>IIS API Test Report</h2>
<table>
<tr><th onclick='sortTable(0)'>Type</th><th onclick='sortTable(1)'>URL</th><th onclick='sortTable(2)'>Method</th><th onclick='sortTable(3)'>Status/Result</th><th onclick='sortTable(4)'>Latency(ms)</th><th onclick='sortTable(5)'>Message</th></tr>
"@
    $htmlRows = ""
    foreach($r in $Results){
        $statusClass = if($r.Result -eq "OK"){"ok"}else{"fail"}
        $method = if($r.Method){$r.Method}else{"N/A"}
        $msg = if($r.Message){$r.Message}else{""}
        $htmlRows += "<tr class='$statusClass'><td>$($r.Type)</td><td>$($r.Url)</td><td>$method</td><td>$($r.Result)</td><td>$($r.Latency)</td><td>$msg</td></tr>`n"
    }
    $htmlFooter="</table></body></html>"
    $fullHtml=$htmlHeader + $htmlRows + $htmlFooter
    [System.IO.File]::WriteAllText($FilePath,$fullHtml)
}

$results = New-Object System.Collections.Generic.List[PSObject]
$jobs = @()
foreach($ep in $endpoints){
    if($ConcurrencyMode -eq "Parallel"){
        $jobs += Start-Job -ScriptBlock {
            param($ep,$Timeout,$RetryCount,$HttpMethod,$Payload,$ContentType,$Username,$Password,$BearerToken,$Headers,$MaxLatency)
            switch($ep.Type){
                "REST" {Invoke-HttpRequest $ep.Url $HttpMethod $Timeout $RetryCount}
                "SOAP" {Invoke-HttpRequest $ep.Url $HttpMethod $Timeout $RetryCount}
                "WCF" {Invoke-HttpRequest $ep.Url $HttpMethod $Timeout $RetryCount}
                "WebSocket" {Invoke-WebSocket $ep.Url $Timeout $RetryCount}
                "gRPC" {Invoke-gRPC $ep.Url $Timeout $RetryCount}
            }
        } -ArgumentList $ep,$Timeout,$RetryCount,$HttpMethod,$Payload,$ContentType,$Username,$Password,$BearerToken,$Headers,$MaxLatency
        if($jobs.Count -ge $MaxConcurrency){
            $completed = Wait-Job -Job $jobs -Any -Timeout 5
            foreach($c in $completed){$results.Add(Receive-Job $c);Remove-Job $c}
        }
    }
    else{
        $res = switch($ep.Type){
            "REST" {Invoke-HttpRequest $ep.Url $HttpMethod $Timeout $RetryCount}
            "SOAP" {Invoke-HttpRequest $ep.Url $HttpMethod $Timeout $RetryCount}
            "WCF" {Invoke-HttpRequest $ep.Url $HttpMethod $Timeout $RetryCount}
            "WebSocket" {Invoke-WebSocket $ep.Url $Timeout $RetryCount}
            "gRPC" {Invoke-gRPC $ep.Url $Timeout $RetryCount}
        }
        $results.Add($res)
    }
}

if($ConcurrencyMode -eq "Parallel"){
    $jobs | Wait-Job | ForEach-Object {
        $results.Add(Receive-Job $_)
        Remove-Job $_
    }
}

if($OutputLog){
    $results | ForEach-Object {
        $line = "$($_.Type) $($_.Url) $($_.Method) $($_.Status) $($_.Result) $($_.Latency) $($_.Message)"
        [System.IO.File]::AppendAllText($OutputLog,$line + "`n")
    }
}

$timestamp = (Get-Date -Format "yyyyMMdd_HHmmss")
$reportFile = "IISApiReport_$timestamp.html"
Generate-HTMLReport $results $reportFile
Write-Host "Report generated: $reportFile"
if($UseWebGUI){$listener.Stop();Write-Host "Web GUI stopped."}

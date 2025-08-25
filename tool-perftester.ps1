Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName System.Net.Http

$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$serializer.MaxJsonLength = 1024 * 1024 * 64

function ExpandVars($text, $vars) {
    if (-not $text) { return $text }
    return [System.Text.RegularExpressions.Regex]::Replace($text, '\$\{([^\}]+)\}', { param($m)
        $key = $m.Groups[1].Value
        if ($vars -and $vars.ContainsKey($key)) { return $vars[$key] }
        return $m.Value
    })
}

function ParsePairs($text, $kvSep, $itemSep) {
    $d = @{}
    if ([string]::IsNullOrWhiteSpace($text)) { return $d }
    foreach ($pair in $text -split $itemSep) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        if ($pair.Contains($kvSep)) {
            $k, $v = $pair.Split($kvSep,2)
            $d[$k.Trim()] = $v.Trim()
        }
    }
    return $d
}

$form = New-Object Windows.Forms.Form
$form.Text = "DotNetLoad Designer"
$form.Size = New-Object Drawing.Size(1000,800)
$form.StartPosition = "CenterScreen"

$lblThreads = New-Object Windows.Forms.Label
$lblThreads.Text = "Threads:"
$lblThreads.Location = New-Object Drawing.Point(10,10)
$form.Controls.Add($lblThreads)

$numThreads = New-Object Windows.Forms.NumericUpDown
$numThreads.Location = New-Object Drawing.Point(80,10)
$numThreads.Minimum = 1
$numThreads.Maximum = 1000
$numThreads.Value   = 10
$form.Controls.Add($numThreads)

$lblRamp = New-Object Windows.Forms.Label
$lblRamp.Text = "Ramp-up (sec):"
$lblRamp.Location = New-Object Drawing.Point(160,10)
$form.Controls.Add($lblRamp)

$numRamp = New-Object Windows.Forms.NumericUpDown
$numRamp.Location = New-Object Drawing.Point(260,10)
$numRamp.Minimum = 0
$numRamp.Maximum = 600
$numRamp.Value   = 5
$form.Controls.Add($numRamp)

$lblDuration = New-Object Windows.Forms.Label
$lblDuration.Text = "Duration (sec):"
$lblDuration.Location = New-Object Drawing.Point(360,10)
$form.Controls.Add($lblDuration)

$numDuration = New-Object Windows.Forms.NumericUpDown
$numDuration.Location = New-Object Drawing.Point(460,10)
$numDuration.Minimum = 0
$numDuration.Maximum = 86400
$numDuration.Value   = 60
$form.Controls.Add($numDuration)

$lblBaseUrl = New-Object Windows.Forms.Label
$lblBaseUrl.Text = "Base URL:"
$lblBaseUrl.Location = New-Object Drawing.Point(10,40)
$form.Controls.Add($lblBaseUrl)

$txtBaseUrl = New-Object Windows.Forms.TextBox
$txtBaseUrl.Location = New-Object Drawing.Point(80,40)
$txtBaseUrl.Size     = New-Object Drawing.Size(880,20)
$txtBaseUrl.Text     = "https://example.com"
$form.Controls.Add($txtBaseUrl)

$lblHeaders = New-Object Windows.Forms.Label
$lblHeaders.Text = "Global Headers (key:value; ...):"
$lblHeaders.Location = New-Object Drawing.Point(10,70)
$form.Controls.Add($lblHeaders)

$txtHeaders = New-Object Windows.Forms.TextBox
$txtHeaders.Location = New-Object Drawing.Point(190,70)
$txtHeaders.Size     = New-Object Drawing.Size(770,20)
$form.Controls.Add($txtHeaders)

$lblVars = New-Object Windows.Forms.Label
$lblVars.Text = "Global Variables (key=value; ...):"
$lblVars.Location = New-Object Drawing.Point(10,100)
$form.Controls.Add($lblVars)

$txtVars = New-Object Windows.Forms.TextBox
$txtVars.Location = New-Object Drawing.Point(190,100)
$txtVars.Size     = New-Object Drawing.Size(770,20)
$form.Controls.Add($txtVars)

$lblSamplers = New-Object Windows.Forms.Label
$lblSamplers.Text = "Samplers:"
$lblSamplers.Location = New-Object Drawing.Point(10,130)
$form.Controls.Add($lblSamplers)

$lstSamplers = New-Object Windows.Forms.ListBox
$lstSamplers.Location = New-Object Drawing.Point(80,130)
$lstSamplers.Size     = New-Object Drawing.Size(880,220)
$form.Controls.Add($lstSamplers)

$btnAddSampler = New-Object Windows.Forms.Button
$btnAddSampler.Text     = "Add Sampler"
$btnAddSampler.Location = New-Object Drawing.Point(10,360)
$form.Controls.Add($btnAddSampler)

$btnEditSampler = New-Object Windows.Forms.Button
$btnEditSampler.Text     = "Edit"
$btnEditSampler.Location = New-Object Drawing.Point(120,360)
$form.Controls.Add($btnEditSampler)

$btnRemoveSampler = New-Object Windows.Forms.Button
$btnRemoveSampler.Text     = "Remove"
$btnRemoveSampler.Location = New-Object Drawing.Point(190,360)
$form.Controls.Add($btnRemoveSampler)

$btnSavePlan = New-Object Windows.Forms.Button
$btnSavePlan.Text     = "Save Plan"
$btnSavePlan.Location = New-Object Drawing.Point(10,400)
$form.Controls.Add($btnSavePlan)

$btnLoadPlan = New-Object Windows.Forms.Button
$btnLoadPlan.Text     = "Load Plan"
$btnLoadPlan.Location = New-Object Drawing.Point(110,400)
$form.Controls.Add($btnLoadPlan)

$lblCsv = New-Object Windows.Forms.Label
$lblCsv.Text     = "Results CSV:"
$lblCsv.Location = New-Object Drawing.Point(10,440)
$form.Controls.Add($lblCsv)

$txtCsv = New-Object Windows.Forms.TextBox
$txtCsv.Location = New-Object Drawing.Point(90,440)
$txtCsv.Size     = New-Object Drawing.Size(800,20)
$txtCsv.Text     = "results.csv"
$form.Controls.Add($txtCsv)

$btnCsv = New-Object Windows.Forms.Button
$btnCsv.Text     = "Browse"
$btnCsv.Location = New-Object Drawing.Point(900,440)
$form.Controls.Add($btnCsv)

$btnRunTest = New-Object Windows.Forms.Button
$btnRunTest.Text     = "Run Test"
$btnRunTest.Location = New-Object Drawing.Point(10,480)
$form.Controls.Add($btnRunTest)

$btnStop = New-Object Windows.Forms.Button
$btnStop.Text     = "Stop"
$btnStop.Enabled  = $false
$btnStop.Location = New-Object Drawing.Point(110,480)
$form.Controls.Add($btnStop)

$txtLog = New-Object Windows.Forms.RichTextBox
$txtLog.Location = New-Object Drawing.Point(10,520)
$txtLog.Size     = New-Object Drawing.Size(960,240)
$txtLog.ReadOnly = $true
$form.Controls.Add($txtLog)

$samplers = @()

function Log($msg) {
    $txtLog.AppendText("$msg`r`n")
    $txtLog.ScrollToCaret()
}

function SamplerDialog($existing) {
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = if ($existing) { "Edit Sampler" } else { "New Sampler" }
    $dlg.Size = New-Object Drawing.Size(640,380)
    $dlg.StartPosition = "CenterParent"

    $l1 = New-Object Windows.Forms.Label
    $l1.Text = "Label:"
    $l1.Location = New-Object Drawing.Point(10,10)
    $dlg.Controls.Add($l1)
    $t1 = New-Object Windows.Forms.TextBox
    $t1.Location = New-Object Drawing.Point(80,10)
    $t1.Size = New-Object Drawing.Size(530,20)
    if ($existing) { $t1.Text = $existing.label }
    $dlg.Controls.Add($t1)

    $l2 = New-Object Windows.Forms.Label
    $l2.Text = "Method:"
    $l2.Location = New-Object Drawing.Point(10,40)
    $dlg.Controls.Add($l2)
    $c2 = New-Object Windows.Forms.ComboBox
    $c2.Location = New-Object Drawing.Point(80,40)
    $c2.DropDownStyle = "DropDownList"
    $c2.Items.AddRange(@("GET","POST","PUT","DELETE","PATCH"))
    if ($existing -and $existing.method) { $c2.SelectedItem = $existing.method } else { $c2.SelectedIndex = 0 }
    $dlg.Controls.Add($c2)

    $l3 = New-Object Windows.Forms.Label
    $l3.Text = "Path:"
    $l3.Location = New-Object Drawing.Point(10,70)
    $dlg.Controls.Add($l3)
    $t3 = New-Object Windows.Forms.TextBox
    $t3.Location = New-Object Drawing.Point(80,70)
    $t3.Size = New-Object Drawing.Size(530,20)
    if ($existing) { $t3.Text = $existing.path }
    $dlg.Controls.Add($t3)

    $l4 = New-Object Windows.Forms.Label
    $l4.Text = "URL (optional):"
    $l4.Location = New-Object Drawing.Point(10,100)
    $dlg.Controls.Add($l4)
    $t4 = New-Object Windows.Forms.TextBox
    $t4.Location = New-Object Drawing.Point(110,100)
    $t4.Size = New-Object Drawing.Size(500,20)
    if ($existing) { $t4.Text = $existing.url }
    $dlg.Controls.Add($t4)

    $l5 = New-Object Windows.Forms.Label
    $l5.Text = "Headers (k:v; ...):"
    $l5.Location = New-Object Drawing.Point(10,130)
    $dlg.Controls.Add($l5)
    $t5 = New-Object Windows.Forms.TextBox
    $t5.Location = New-Object Drawing.Point(130,130)
    $t5.Size = New-Object Drawing.Size(480,20)
    if ($existing -and $existing.headers) {
        $pairs = @()
        foreach ($e in $existing.headers.GetEnumerator()) { $pairs += "$($e.Key):$($e.Value)" }
        $t5.Text = $pairs -join ";"
    }
    $dlg.Controls.Add($t5)

    $l6 = New-Object Windows.Forms.Label
    $l6.Text = "Body:"
    $l6.Location = New-Object Drawing.Point(10,160)
    $dlg.Controls.Add($l6)
    $t6 = New-Object Windows.Forms.TextBox
    $t6.Location = New-Object Drawing.Point(80,160)
    $t6.Size = New-Object Drawing.Size(530,60)
    $t6.Multiline = $true
    if ($existing) { $t6.Text = $existing.body }
    $dlg.Controls.Add($t6)

    $l7 = New-Object Windows.Forms.Label
    $l7.Text = "Assert status ="
    $l7.Location = New-Object Drawing.Point(10,230)
    $dlg.Controls.Add($l7)
    $t7 = New-Object Windows.Forms.TextBox
    $t7.Location = New-Object Drawing.Point(110,230)
    $t7.Size = New-Object Drawing.Size(60,20)
    if ($existing -and $existing.assertions) {
        foreach ($a in $existing.assertions) { if ($a.type -eq "status") { $t7.Text = $a.equals } }
    }
    $dlg.Controls.Add($t7)

    $l8 = New-Object Windows.Forms.Label
    $l8.Text = "Assert body contains"
    $l8.Location = New-Object Drawing.Point(180,230)
    $dlg.Controls.Add($l8)
    $t8 = New-Object Windows.Forms.TextBox
    $t8.Location = New-Object Drawing.Point(330,230)
    $t8.Size = New-Object Drawing.Size(280,20)
    if ($existing -and $existing.assertions) {
        foreach ($a in $existing.assertions) { if ($a.type -eq "bodyContains") { $t8.Text = $a.text } }
    }
    $dlg.Controls.Add($t8)

    $ok = New-Object Windows.Forms.Button
    $ok.Text = "OK"
    $ok.Location = New-Object Drawing.Point(520,300)
    $dlg.Controls.Add($ok)
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = "Cancel"
    $cancel.Location = New-Object Drawing.Point(430,300)
    $dlg.Controls.Add($cancel)

    $ok.Add_Click({
        $hdr = ParsePairs $t5.Text ":" ";"
        $as = @()
        if ($t7.Text) { $as += @{ type="status"; equals=[int]$t7.Text } }
        if ($t8.Text) { $as += @{ type="bodyContains"; text=$t8.Text } }
        $sam = @{
            label      = $t1.Text
            method     = $c2.Text
            path       = $t3.Text
            url        = $t4.Text
            headers    = $hdr
            body       = $t6.Text
            assertions = $as
        }
        $dlg.Tag = $sam
        $dlg.Close()
    })
    $cancel.Add_Click({ $dlg.Tag = $null; $dlg.Close() })

    $dlg.ShowDialog() | Out-Null
    return $dlg.Tag
}

$btnAddSampler.Add_Click({
    $s = SamplerDialog $null
    if ($s) {
        $samplers += $s
        $lstSamplers.Items.Add($s.label) | Out-Null
    }
})

$btnEditSampler.Add_Click({
    $i = $lstSamplers.SelectedIndex
    if ($i -ge 0) {
        $s = SamplerDialog $samplers[$i]
        if ($s) {
            $samplers[$i] = $s
            $lstSamplers.Items[$i] = $s.label
        }
    }
})

$btnRemoveSampler.Add_Click({
    $i = $lstSamplers.SelectedIndex
    if ($i -ge 0) {
        $samplers = @($samplers[0..($i-1)] + $samplers[($i+1)..($samplers.Count-1)]) 2>$null
        $lstSamplers.Items.RemoveAt($i)
    }
})
function NewHttpClient([int]$timeoutMs, [bool]$followRedirects, $cookieJar) {
    $h = [System.Net.Http.SocketsHttpHandler]::new()
    $h.AllowAutoRedirect    = $followRedirects
    $h.ConnectTimeout       = [TimeSpan]::FromMilliseconds($timeoutMs)
    $h.CookieContainer      = $cookieJar
    $h.AutomaticDecompression = `
        [System.Net.DecompressionMethods]::GZip -bor `
        [System.Net.DecompressionMethods]::Deflate -bor `
        [System.Net.DecompressionMethods]::Brotli
    $c = [System.Net.Http.HttpClient]::new($h)
    $c.Timeout = [TimeSpan]::FromMilliseconds($timeoutMs)
    return $c
}

function BuildRequest($sampler, $globalHeaders, $vars, $baseUrl) {
    $method = $sampler.method.ToUpperInvariant()
    if ($sampler.url) {
        $url = ExpandVars $sampler.url $vars
    } else {
        $url = $baseUrl.TrimEnd('/') + '/' + $sampler.path.TrimStart('/')
        $url = ExpandVars $url $vars
    }
    $req = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::new($method), $url
    )
    foreach ($h in $globalHeaders.GetEnumerator()) {
        $req.Headers.TryAddWithoutValidation($h.Key, ExpandVars $h.Value $vars) | Out-Null
    }
    if ($sampler.body) {
        $b = ExpandVars $sampler.body $vars
        $req.Content = [System.Net.Http.StringContent]::new($b, [System.Text.Encoding]::UTF8)
    }
    return $req
}

function EvaluateAssertions($asserts, [int]$status, [double]$elapsed, $body) {
    $ok = $true
    $msg = ""
    foreach ($a in $asserts) {
        switch ($a.type) {
            "status" {
                if ($status -ne [int]$a.equals) { $ok = $false; $msg = "status != $($a.equals)" }
            }
            "bodyContains" {
                if (-not $body.Contains($a.text)) { $ok = $false; $msg = "body missing '$($a.text)'" }
            }
        }
        if (-not $ok) { break }
    }
    return ,$ok,$msg
}

function CsvEscape([string]$s) {
    if ($null -eq $s) { return "" }
    $q = $s.Replace('"','""')
    if ($q.Contains(",") -or $q.Contains("`n") -or $q.Contains("`r")) {
        return '"' + $q + '"'
    }
    return $q
}

$btnCsv.Add_Click({
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter = "CSV files (*.csv)|*.csv"
    if ($dlg.ShowDialog() -eq "OK") {
        $txtCsv.Text = $dlg.FileName
    }
})

$btnSavePlan.Add_Click({
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter = "JSON files (*.json)|*.json"
    if ($dlg.ShowDialog() -eq "OK") {
        $plan = @{
            threads     = [int]$numThreads.Value
            rampUpSec   = [int]$numRamp.Value
            durationSec = [int]$numDuration.Value
            global      = @{
                baseUrl         = $txtBaseUrl.Text
                timeoutMs       = 30000
                followRedirects = $true
                headers         = ParsePairs $txtHeaders.Text ":" ";"
                variables       = ParsePairs $txtVars.Text "=" ";"
                thinkTimeMs     = @{ min = 50; max = 150 }
            }
            samplers = $samplers
        }
        $json = $serializer.Serialize($plan)
        [System.IO.File]::WriteAllText($dlg.FileName, $json, [System.Text.Encoding]::UTF8)
        Log "Saved plan to $($dlg.FileName)"
    }
})

$btnLoadPlan.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = "JSON files (*.json)|*.json"
    if ($dlg.ShowDialog() -eq "OK") {
        $json = [System.IO.File]::ReadAllText($dlg.FileName, [System.Text.Encoding]::UTF8)
        $plan = $serializer.DeserializeObject($json)
        $numThreads.Value   = $plan.threads
        $numRamp.Value      = $plan.rampUpSec
        $numDuration.Value  = $plan.durationSec
        $txtBaseUrl.Text    = $plan.global.baseUrl
        $txtHeaders.Text    = ($plan.global.headers.GetEnumerator() |
                                ForEach-Object { "$($_.Key):$($_.Value)" }) -join ";"
        $txtVars.Text       = ($plan.global.variables.GetEnumerator() |
                                ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ";"
        $samplers.Clear()
        $lstSamplers.Items.Clear()
        foreach ($s in $plan.samplers) {
            $samplers += $s
            $lstSamplers.Items.Add($s.label) | Out-Null
        }
        Log "Loaded plan from $($dlg.FileName)"
    }
})

$results = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$tasks   = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
$cts     = $null

$btnRunTest.Add_Click({
    $results.Clear()
    $tasks.Clear()
    $cts = [System.Threading.CancellationTokenSource]::new()
    $threads   = [int]$numThreads.Value
    $rampMs    = [int]($numRamp.Value * 1000)
    $duration  = [int]$numDuration.Value
    $endTime   = if ($duration -gt 0) { [DateTime]::UtcNow.AddSeconds($duration) } else { [DateTime]::MaxValue }
    $gHdr      = ParsePairs $txtHeaders.Text ":" ";"
    $gVar      = ParsePairs $txtVars.Text "=" ";"
    $base      = $txtBaseUrl.Text
    $timeout   = 30000
    $follow    = $true
    Log "Starting test: $threads threads, ramp $($numRamp.Value)s, duration $duration s"

    for ($i = 0; $i -lt $threads; $i++) {
        $idx  = $i
        $task = [System.Threading.Tasks.Task]::Run([System.Action]{
            Start-Sleep -Milliseconds ([int]([Math]::Round($idx / $threads * $rampMs)))
            $jar    = [System.Net.CookieContainer]::new()
            $client = NewHttpClient $timeout $follow $jar
            $vars   = [System.Collections.Generic.Dictionary[string,string]]::new()
            foreach ($kv in $gVar.GetEnumerator()) { $vars[$kv.Key] = $kv.Value }
            $rand   = [System.Random]::new()
            while (-not $cts.IsCancellationRequested -and [DateTime]::UtcNow -lt $endTime) {
                foreach ($s in $samplers) {
                    $req = BuildRequest $s $gHdr $vars $base
                    $ts  = [DateTime]::UtcNow
                    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        $resp = $client.SendAsync($req, $cts.Token).GetAwaiter().GetResult()
                        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                        $sw.Stop()
                        $code, $ok, $msg = $null, $false, ""
                        $code = [int]$resp.StatusCode
                        $ok,$msg = EvaluateAssertions $s.assertions $code $sw.Elapsed.TotalMilliseconds $body
                        $rec = [ordered]@{
                            timeStamp    = $ts
                            label        = $s.label
                            elapsedMs    = [double]$sw.Elapsed.TotalMilliseconds
                            responseCode = $code
                            success      = $ok
                            failureMsg   = $msg
                            threadName   = "T$([int]($idx+1))"
                        }
                        $results.Enqueue([System.Collections.Generic.Dictionary[string,object]]::new($rec)) | Out-Null
                        $logMsg = "$($s.label) $code $([math]::Round($sw.Elapsed.TotalMilliseconds,2))ms " +
                                  (if ($ok) { "OK" } else { "FAIL:$msg" })
                        $form.Invoke([Action]{ Log $logMsg })
                        $resp.Dispose()
                    } catch {
                        $sw.Stop()
                        $form.Invoke([Action]{ Log "$($s.label) ERROR $($_.Exception.Message)" })
                    } finally {
                        $req.Dispose()
                    }
                    Start-Sleep -Milliseconds $rand.Next(50,150)
                    if ([DateTime]::UtcNow -ge $endTime) { break }
                }
            }
            $client.Dispose()
        }, $cts.Token)
        $tasks.Add($task)
    }
    $btnRunTest.Enabled = $false
    $btnStop.Enabled   = $true
})

$btnStop.Add_Click({
    if ($cts) { $cts.Cancel() }
    try { [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray(),5000) } catch {}
    $btnStop.Enabled    = $false
    $btnRunTest.Enabled = $true
    $swCsv = [System.IO.StreamWriter]::new($txtCsv.Text, $false, [System.Text.Encoding]::UTF8)
    $swCsv.WriteLine("timeStamp,label,elapsedMs,responseCode,success,failureMsg,threadName")
    $item = $null
    while ($results.TryDequeue([ref]$item)) {
        $line = "{0},{1},{2},{3},{4},{5},{6}" -f
            $item["timeStamp"].ToString("o"),
            CsvEscape([string]$item["label"]),
            [double]$item["elapsedMs"],
            [int]$item["responseCode"],
            ([bool]$item["success"]),
            CsvEscape([string]$item["failureMsg"]),
            CsvEscape([string]$item["threadName"])
        $swCsv.WriteLine($line)
    }
    $swCsv.Close()
    Log "Saved results to $($txtCsv.Text)"
})

$form.Add_FormClosing({ if ($cts) { $cts.Cancel() } })
[void]$form.ShowDialog()

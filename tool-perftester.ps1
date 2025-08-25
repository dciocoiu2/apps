Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName System.Net.Http

$serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$serializer.MaxJsonLength = 1024 * 1024 * 64

function ExpandVars($text, $vars) {
    if (-not $text) { return $text }
    return [System.Text.RegularExpressions.Regex]::Replace(
        $text, '\$\{([^\}]+)\}', {
            param($m)
            $key = $m.Groups[1].Value
            if ($vars.ContainsKey($key)) { return $vars[$key] }
            return $m.Value
        }
    )
}

function ParsePairs($text, $kvSep, $itemSep) {
    $d = @{}
    foreach ($pair in $text -split $itemSep) {
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
$numDuration.Maximum = 3600
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
$lblHeaders.Text = "Global Headers (key:value):"
$lblHeaders.Location = New-Object Drawing.Point(10,70)
$form.Controls.Add($lblHeaders)

$txtHeaders = New-Object Windows.Forms.TextBox
$txtHeaders.Location = New-Object Drawing.Point(180,70)
$txtHeaders.Size     = New-Object Drawing.Size(780,20)
$form.Controls.Add($txtHeaders)

$lblVars = New-Object Windows.Forms.Label
$lblVars.Text = "Global Variables (key=value):"
$lblVars.Location = New-Object Drawing.Point(10,100)
$form.Controls.Add($lblVars)

$txtVars = New-Object Windows.Forms.TextBox
$txtVars.Location = New-Object Drawing.Point(180,100)
$txtVars.Size     = New-Object Drawing.Size(780,20)
$form.Controls.Add($txtVars)

$lblSamplers = New-Object Windows.Forms.Label
$lblSamplers.Text = "Samplers:"
$lblSamplers.Location = New-Object Drawing.Point(10,130)
$form.Controls.Add($lblSamplers)

$lstSamplers = New-Object Windows.Forms.ListBox
$lstSamplers.Location = New-Object Drawing.Point(80,130)
$lstSamplers.Size     = New-Object Drawing.Size(880,200)
$form.Controls.Add($lstSamplers)

$btnAddSampler = New-Object Windows.Forms.Button
$btnAddSampler.Text     = "Add Sampler"
$btnAddSampler.Location = New-Object Drawing.Point(10,340)
$form.Controls.Add($btnAddSampler)

$btnEditSampler = New-Object Windows.Forms.Button
$btnEditSampler.Text     = "Edit"
$btnEditSampler.Location = New-Object Drawing.Point(110,340)
$form.Controls.Add($btnEditSampler)

$btnRemoveSampler = New-Object Windows.Forms.Button
$btnRemoveSampler.Text     = "Remove"
$btnRemoveSampler.Location = New-Object Drawing.Point(210,340)
$form.Controls.Add($btnRemoveSampler)

$btnSavePlan = New-Object Windows.Forms.Button
$btnSavePlan.Text     = "Save Plan"
$btnSavePlan.Location = New-Object Drawing.Point(10,380)
$form.Controls.Add($btnSavePlan)

$btnLoadPlan = New-Object Windows.Forms.Button
$btnLoadPlan.Text     = "Load Plan"
$btnLoadPlan.Location = New-Object Drawing.Point(110,380)
$form.Controls.Add($btnLoadPlan)

$lblCsv = New-Object Windows.Forms.Label
$lblCsv.Text     = "Results CSV:"
$lblCsv.Location = New-Object Drawing.Point(10,420)
$form.Controls.Add($lblCsv)

$txtCsv = New-Object Windows.Forms.TextBox
$txtCsv.Location = New-Object Drawing.Point(90,420)
$txtCsv.Size     = New-Object Drawing.Size(800,20)
$txtCsv.Text     = "results.csv"
$form.Controls.Add($txtCsv)

$btnCsv = New-Object Windows.Forms.Button
$btnCsv.Text     = "Browse"
$btnCsv.Location = New-Object Drawing.Point(900,420)
$form.Controls.Add($btnCsv)

$btnRunTest = New-Object Windows.Forms.Button
$btnRunTest.Text     = "Run Test"
$btnRunTest.Location = New-Object Drawing.Point(10,460)
$form.Controls.Add($btnRunTest)

$btnStop = New-Object Windows.Forms.Button
$btnStop.Text     = "Stop"
$btnStop.Enabled  = $false
$btnStop.Location = New-Object Drawing.Point(110,460)
$form.Controls.Add($btnStop)

$txtLog = New-Object Windows.Forms.RichTextBox
$txtLog.Location = New-Object Drawing.Point(10,500)
$txtLog.Size     = New-Object Drawing.Size(960,280)
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
    $dlg.Size = New-Object Drawing.Size(600,400)
    $dlg.StartPosition = "CenterParent"

    $lbl1 = New-Object Windows.Forms.Label
    $lbl1.Text     = "Label:"
    $lbl1.Location = New-Object Drawing.Point(10,10)
    $dlg.Controls.Add($lbl1)
    $txt1 = New-Object Windows.Forms.TextBox
    $txt1.Location = New-Object Drawing.Point(80,10)
    $txt1.Size     = New-Object Drawing.Size(500,20)
    if ($existing) { $txt1.Text = $existing.label }
    $dlg.Controls.Add($txt1)

    $lbl2 = New-Object Windows.Forms.Label
    $lbl2.Text     = "Method:"
    $lbl2.Location = New-Object Drawing.Point(10,40)
    $dlg.Controls.Add($lbl2)
    $cmb2 = New-Object Windows.Forms.ComboBox
    $cmb2.Items.AddRange(@("GET","POST","PUT","DELETE","PATCH"))
    $cmb2.DropDownStyle = "DropDownList"
    $cmb2.Location      = New-Object Drawing.Point(80,40)
    if ($existing) { $cmb2.SelectedItem = $existing.method } else { $cmb2.SelectedIndex = 0 }
    $dlg.Controls.Add($cmb2)

    $lbl3 = New-Object Windows.Forms.Label
    $lbl3.Text     = "Path:"
    $lbl3.Location = New-Object Drawing.Point(10,70)
    $dlg.Controls.Add($lbl3)
    $txt3 = New-Object Windows.Forms.TextBox
    $txt3.Location = New-Object Drawing.Point(80,70)
    $txt3.Size     = New-Object Drawing.Size(500,20)
    if ($existing) { $txt3.Text = $existing.path }
    $dlg.Controls.Add($txt3)

    $lbl4 = New-Object Windows.Forms.Label
    $lbl4.Text     = "URL (opt):"
    $lbl4.Location = New-Object Drawing.Point(10,100)
    $dlg.Controls.Add($lbl4)
    $txt4 = New-Object Windows.Forms.TextBox
    $txt4.Location = New-Object Drawing.Point(80,100)
    $txt4.Size     = New-Object Drawing.Size(500,20)
    if ($existing) { $txt4.Text = $existing.url }
    $dlg.Controls.Add($txt4)

    $lbl5 = New-Object Windows.Forms.Label
    $lbl5.Text     = "Headers (k:v;):"
    $lbl5.Location = New-Object Drawing.Point(10,130)
    $dlg.Controls.Add($lbl5)
    $txt5 = New-Object Windows.Forms.TextBox
    $txt5.Location = New-Object Drawing.Point(110,130)
    $txt5.Size     = New-Object Drawing.Size(470,20)
    if ($existing) {
        $pairs = @()
        foreach ($e in $existing.headers.GetEnumerator()) {
            $pairs += "$($e.Key):$($e.Value)"
        }
        $txt5.Text = $pairs -join ";"
    }
    $dlg.Controls.Add($txt5)

    $lbl6 = New-Object Windows.Forms.Label
    $lbl6.Text     = "Body:"
    $lbl6.Location = New-Object Drawing.Point(10,160)
    $dlg.Controls.Add($lbl6)
    $txt6 = New-Object Windows.Forms.TextBox
    $txt6.Location = New-Object Drawing.Point(80,160)
    $txt6.Size     = New-Object Drawing.Size(500,100)
    $txt6.Multiline = $true
    if ($existing) { $txt6.Text = $existing.body }
    $dlg.Controls.Add($txt6)

    $lbl7 = New-Object Windows.Forms.Label
    $lbl7.Text     = "Assert status ="
    $lbl7.Location = New-Object Drawing.Point(10,270)
    $dlg.Controls.Add($lbl7)
    $txt7 = New-Object Windows.Forms.TextBox
    $txt7.Location = New-Object Drawing.Point(110,270)
    $txt7.Size     = New-Object Drawing.Size(60,20)
    if ($existing) {
        foreach ($a in $existing.assertions) {
            if ($a.type -eq "status") { $txt7.Text = $a.equals }
        }
    }
    $dlg.Controls.Add($txt7)

    $lbl8 = New-Object Windows.Forms.Label
    $lbl8.Text     = "Assert body contains"
    $lbl8.Location = New-Object Drawing.Point(180,270)
    $dlg.Controls.Add($lbl8)
    $txt8 = New-Object Windows.Forms.TextBox
    $txt8.Location = New-Object Drawing.Point(330,270)
    $txt8.Size     = New-Object Drawing.Size(250,20)
    if ($existing) {
        foreach ($a in $existing.assertions) {
            if ($a.type -eq "bodyContains") { $txt8.Text = $a.text }
        }
    }
    $dlg.Controls.Add($txt8)

    $btnOK = New-Object Windows.Forms.Button
    $btnOK.Text     = "OK"
    $btnOK.Location = New-Object Drawing.Point(500,330)
    $dlg.Controls.Add($btnOK)
    $btnCancel = New-Object Windows.Forms.Button
    $btnCancel.Text     = "Cancel"
    $btnCancel.Location = New-Object Drawing.Point(380,330)
    $dlg.Controls.Add($btnCancel)

    $btnOK.Add_Click({
        $hdr = ParsePairs $txt5.Text ":" ";"
        $as  = @()
        if ($txt7.Text) { $as += @{ type="status"; equals=[int]$txt7.Text } }
        if ($txt8.Text) { $as += @{ type="bodyContains"; text=$txt8.Text } }
        $sam = @{
            label       = $txt1.Text
            method      = $cmb2.Text
            path        = $txt3.Text
            url         = $txt4.Text
            headers     = $hdr
            body        = $txt6.Text
            assertions  = $as
        }
        $dlg.Tag = $sam
        $dlg.Close()
    })
    $btnCancel.Add_Click({ $dlg.Close() })

    $dlg.ShowDialog()
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
        $sNew = SamplerDialog $samplers[$i]
        if ($sNew) {
            $samplers[$i] = $sNew
            $lstSamplers.Items[$i] = $sNew.label
        }
    }
})

$btnRemoveSampler.Add_Click({
    $i = $lstSamplers.SelectedIndex
    if ($i -ge 0) {
        $samplers.RemoveAt($i)
        $lstSamplers.Items.RemoveAt($i)
    }
})
function NewHttpClient($timeoutMs, $followRedirects, $cookieJar) {
    $h = [System.Net.Http.SocketsHttpHandler]::new()
    $h.AllowAutoRedirect   = $followRedirects
    $h.ConnectTimeout      = [TimeSpan]::FromMilliseconds($timeoutMs)
    $h.CookieContainer     = $cookieJar
    $h.AutomaticDecompression = `
        [System.Net.DecompressionMethods]::GZip -bor `
        [System.Net.DecompressionMethods]::Deflate -bor `
        [System.Net.DecompressionMethods]::Brotli
    $c = [System.Net.Http.HttpClient]::new($h)
    $c.Timeout = [TimeSpan]::FromMilliseconds($timeoutMs)
    return $c
}

function BuildRequest($sampler, $globalHeaders, $vars, $baseUrl) {
    $m = $sampler.method.ToUpperInvariant()
    $u = if ([string]::IsNullOrEmpty($sampler.url)) {
        ExpandVars $baseUrl $vars + ExpandVars $sampler.path $vars
    } else {
        ExpandVars $sampler.url $vars
    }
    $req = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::new($m), $u
    )
    foreach ($e in $globalHeaders.GetEnumerator()) {
        $req.Headers.TryAddWithoutValidation($e.Key, ExpandVars $e.Value $vars) | Out-Null
    }
    if ($sampler.body) {
        $b = ExpandVars $sampler.body $vars
        $req.Content = [System.Net.Http.StringContent]::new($b, [System.Text.Encoding]::UTF8)
    }
    return $req
}

function EvaluateAssertions($asserts, $status, $elapsed, $body) {
    $ok = $true
    $msg = ""
    foreach ($a in $asserts) {
        switch ($a.type) {
            "status" {
                if ($status -ne $a.equals) { $ok = $false; $msg = "status != $($a.equals)" }
            }
            "bodyContains" {
                if (-not $body.Contains($a.text)) { $ok = $false; $msg = "body missing [$($a.text)]" }
            }
        }
        if (-not $ok) { break }
    }
    return ,$ok,$msg
}

$btnCsv.Add_Click({
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter = "CSV (*.csv)|*.csv"
    if ($dlg.ShowDialog() -eq "OK") {
        $txtCsv.Text = $dlg.FileName
    }
})

$btnSavePlan.Add_Click({
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter = "JSON (*.json)|*.json"
    if ($dlg.ShowDialog() -eq "OK") {
        $plan = @{
            threads       = [int]$numThreads.Value
            rampUpSec     = [int]$numRamp.Value
            durationSec   = [int]$numDuration.Value
            global        = @{
                baseUrl         = $txtBaseUrl.Text
                timeoutMs       = 30000
                followRedirects = $true
                headers         = ParsePairs $txtHeaders.Text ":" ";"
                variables       = ParsePairs $txtVars.Text "=" ";"
                thinkTimeMs     = @{ min=50; max=150 }
            }
            samplers      = $samplers
        }
        $json = $serializer.Serialize($plan)
        [System.IO.File]::WriteAllText($dlg.FileName, $json)
        Log "Saved plan $($dlg.FileName)"
    }
})

$btnLoadPlan.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = "JSON (*.json)|*.json"
    if ($dlg.ShowDialog() -eq "OK") {
        $j    = [System.IO.File]::ReadAllText($dlg.FileName)
        $plan = $serializer.DeserializeObject($j)
        $numThreads.Value = $plan.threads
        $numRamp.Value    = $plan.rampUpSec
        $numDuration.Value= $plan.durationSec
        $txtBaseUrl.Text  = $plan.global.baseUrl
        $txtHeaders.Text  = ($plan.global.headers.GetEnumerator() |
            ForEach-Object { "$($_.Key):$($_.Value)" }) -join ";"
        $txtVars.Text     = ($plan.global.variables.GetEnumerator() |
            ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ";"
        $samplers.Clear()
        $lstSamplers.Items.Clear()
        foreach ($s in $plan.samplers) {
            $samplers += $s
            $lstSamplers.Items.Add($s.label) | Out-Null
        }
        Log "Loaded plan $($dlg.FileName)"
    }
})

$btnRunTest.Add_Click({
    $threads   = [int]$numThreads.Value
    $rampUp    = [int]$numRamp.Value
    $duration  = [int]$numDuration.Value
    $endAt     = [DateTime]::UtcNow.AddSeconds($duration)
    $gHdr      = ParsePairs $txtHeaders.Text ":" ";"
    $gVar      = ParsePairs $txtVars.Text "=" ";"
    $base      = $txtBaseUrl.Text
    $timeout   = 30000
    $follow    = $true
    $cts       = New-Object Threading.CancellationTokenSource
    $results   = New-Object Collections.Concurrent.ConcurrentQueue[object]
    $txtLog.Clear()
    Log "Starting $threads threads for $duration sec"

    for ($i=0; $i -lt $threads; $i++) {
        $delay = if ($rampUp -gt 0) { [int]([Math]::Round($i/$threads*$rampUp*1000)) } else { 0 }
        [Threading.Tasks.Task]::Run({
            Start-Sleep -Milliseconds $delay
            $jar     = New-Object Net.CookieContainer
            $client  = NewHttpClient $timeout $follow $jar
            $vars    = [Collections.Generic.Dictionary[string,string]]::new()
            foreach ($kv in $gVar.GetEnumerator()) { $vars[$kv.Key] = $kv.Value }
            while ([DateTime]::UtcNow -lt $endAt -and -not $cts.IsCancellationRequested) {
                foreach ($s in $samplers) {
                    $req  = BuildRequest $s $gHdr $vars $base
                    $ts   = [DateTime]::UtcNow
                    $sw   = [Diagnostics.Stopwatch]::StartNew()
                    try {
                        $resp = $client.SendAsync($req,$cts.Token).GetAwaiter().GetResult()
                        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                        $sw.Stop()
                        $code = [int]$resp.StatusCode
                        $ok,msg = EvaluateAssertions $s.assertions $code $sw.Elapsed.TotalMilliseconds $body
                        $log = "{0} {1} {2}ms {3}" -f $s.label,$code,[math]::Round($sw.Elapsed.TotalMilliseconds,2), (if($ok){"OK"}else{"FAIL:$msg"})
                        $form.Invoke([Action]{ Log $log })
                        $resp.Dispose()
                    } catch {
                        $sw.Stop()
                        $form.Invoke([Action]{ Log "$($s.label) ERROR $($_.Exception.Message)" })
                    } finally {
                        $req.Dispose()
                    }
                    Start-Sleep -Milliseconds (Get-Random -Minimum 50 -Maximum 150)
                }
            }
            $client.Dispose()
        }, $cts.Token) | Out-Null
    }

    $btnRunTest.Enabled = $false
    $btnStop.Enabled   = $true

    $btnStop.Add_Click({
        $cts.Cancel()
        $btnStop.Enabled   = $false
        $btnRunTest.Enabled= $true

        $swCsv = New-Object IO.StreamWriter($txtCsv.Text,$false,[Text.Encoding]::UTF8)
        $swCsv.WriteLine("timeStamp,label,elapsedMs,responseCode,success,failureMsg")
        $swCsv.Flush()
        $swCsv.Close()

        Log "Results saved to $($txtCsv.Text)"
    })
})

$btnCsv.Add_Click({ $dlg=New-Object Windows.Forms.SaveFileDialog; $dlg.Filter="CSV (*.csv)|*.csv"; if($dlg.ShowDialog() -eq "OK"){ $txtCsv.Text=$dlg.FileName } })

$form.Add_FormClosing({ if ($cts) { $cts.Cancel() } })
[void]$form.ShowDialog()

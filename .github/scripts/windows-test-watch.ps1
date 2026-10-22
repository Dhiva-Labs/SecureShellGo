# Runs `flutter test` on a Windows runner and watches the machine while it
# runs. Probe build: every few seconds it records memory, commit charge,
# CPU, process, handle and TCP counts, the biggest processes and the tests
# that have started but not finished, prints that to the step log, and
# mirrors it into a check run through the API, so a runner that stops
# answering still leaves its last minutes behind.
#
# Usage: windows-test-watch.ps1 -TestArgs '...' (extra flutter test args)
param(
  [string]$TestArgs = '',
  [int]$Minutes = 25,
  [int]$Every = 5
)

$ErrorActionPreference = 'Continue'
$repo = $env:GITHUB_REPOSITORY
$api = "https://api.github.com/repos/$repo"
$headers = @{
  Authorization          = "Bearer $env:GH_TOKEN"
  Accept                 = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
}

function Post-Check([string]$Method, [string]$Uri, $Body) {
  try {
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -TimeoutSec 8 `
      -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 6 -Compress)
  } catch {
    Write-Host "check run $Method failed: $($_.Exception.Message)"
    return $null
  }
}

$checkName = "watch $env:ARCH $env:PROBE_LABEL"
$check = $null
if ($env:GH_TOKEN) {
  $check = Post-Check Post "$api/check-runs" @{
    name     = $checkName
    head_sha = $env:GITHUB_SHA
    status   = 'in_progress'
    output   = @{ title = 'starting'; summary = 'starting' }
  }
  if ($check) { "check run $($check.id) $($check.html_url)" }
}

$linuxOnly = 'device_storage_test.dart', 'log_tail_test.dart', 'public_key_push_test.dart', 'ssh_service_test.dart'
$tests = Get-ChildItem test -Filter *_test.dart |
  Where-Object { $linuxOnly -notcontains $_.Name } |
  ForEach-Object { "test/$($_.Name)" }
if ($env:TEST_FILES) { $tests = $env:TEST_FILES -split '\s+' | Where-Object { $_ } }
"$($tests.Count) test files; extra args: $TestArgs"

$out = Join-Path $env:RUNNER_TEMP 'flutter-test.out'
$err = Join-Path $env:RUNNER_TEMP 'flutter-test.err'
$json = Join-Path $env:RUNNER_TEMP 'flutter-test.json'
$timelineFile = Join-Path $env:RUNNER_TEMP 'watch-timeline.txt'
$flutter = (Get-Command flutter).Source
$p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
  -ArgumentList "/d /c call `"$flutter`" test $TestArgs --reporter expanded --file-reporter `"json:$json`" $($tests -join ' ') > `"$out`" 2> `"$err`" < NUL"
$null = $p.Handle  # keeps ExitCode readable once it exits

$os0 = Get-CimInstance Win32_OperatingSystem
"machine: $([math]::Round($os0.TotalVisibleMemorySize / 1MB, 1)) GB RAM, commit limit $([math]::Round($os0.TotalVirtualMemorySize / 1MB, 1)) GB, $([Environment]::ProcessorCount) CPUs, $($os0.Caption) $($os0.Version)"

$start = Get-Date
$timeline = New-Object System.Collections.Generic.List[string]
$suites = @{}
$running = @{}
$jsonPos = 0L
$killed = $null
$lastPatch = [datetime]::MinValue

function Read-Json {
  if (-not (Test-Path $json)) { return }
  try {
    $fs = [IO.File]::Open($json, 'Open', 'Read', 'ReadWrite')
  } catch { return }
  try {
    if ($fs.Length -le $script:jsonPos) { return }
    $fs.Position = $script:jsonPos
    $buf = New-Object byte[] ($fs.Length - $script:jsonPos)
    $n = $fs.Read($buf, 0, $buf.Length)
    $lastNl = [Array]::LastIndexOf($buf, [byte]10, $n - 1)
    if ($lastNl -lt 0) { return }
    $script:jsonPos += $lastNl + 1
    $text = [Text.Encoding]::UTF8.GetString($buf, 0, $lastNl + 1)
    foreach ($line in $text -split "`n") {
      if (-not $line) { continue }
      if ($line.Contains('"type":"testStart"')) {
        $e = $line | ConvertFrom-Json
        $file = $script:suites[[int]$e.test.suiteID]
        $script:running[[int]$e.test.id] = [pscustomobject]@{
          Name = $e.test.name; File = $file; Since = Get-Date
        }
      } elseif ($line.Contains('"type":"testDone"')) {
        $e = $line | ConvertFrom-Json
        $script:running.Remove([int]$e.testID)
      } elseif ($line.Contains('"type":"suite"')) {
        $e = $line | ConvertFrom-Json
        $script:suites[[int]$e.suite.id] = Split-Path -Leaf $e.suite.path
      }
    }
  } catch {
    Write-Host "json read: $($_.Exception.Message)"
  } finally { $fs.Dispose() }
}

function Snapshot {
  $os = Get-CimInstance Win32_OperatingSystem
  $procs = Get-Process
  $tcp = 0
  try { $tcp = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections().Count } catch {}
  $cpu = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
  [pscustomobject]@{
    MemUsed     = ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB
    MemTotal    = $os.TotalVisibleMemorySize / 1MB
    CommitUsed  = ($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB
    CommitTotal = $os.TotalVirtualMemorySize / 1MB
    Cpu         = $cpu
    Procs       = $procs.Count
    Handles     = ($procs | Measure-Object HandleCount -Sum).Sum
    Threads     = ($procs | ForEach-Object { $_.Threads.Count } | Measure-Object -Sum).Sum
    Tcp         = $tcp
    Dart        = @($procs | Where-Object { $_.Name -match '^(dart|dartvm|dartaotruntime|flutter_tester)$' }).Count
    Top         = $procs | Sort-Object PrivateMemorySize64 -Descending | Select-Object -First 6
    TopHandles  = $procs | Sort-Object HandleCount -Descending | Select-Object -First 3
  }
}

function Format-Running {
  $now = Get-Date
  $script:running.Values | Sort-Object Since | Select-Object -First 8 |
    ForEach-Object { '{0,4}s {1}: {2}' -f [int]($now - $_.Since).TotalSeconds, $_.File, $_.Name }
}

while ($true) {
  $done = $p.WaitForExit($Every * 1000)
  $t = [int]((Get-Date) - $start).TotalSeconds
  Read-Json
  $s = Snapshot
  $runningNow = @(Format-Running)
  $line = '{0,5}s mem {1:N1}/{2:N1}G commit {3:N1}/{4:N1}G cpu {5}% procs {6} thr {7} hnd {8} tcp {9} dart {10} running {11} | {12}' -f `
    $t, $s.MemUsed, $s.MemTotal, $s.CommitUsed, $s.CommitTotal, $s.Cpu, $s.Procs, $s.Threads, $s.Handles, $s.Tcp, $s.Dart, $running.Count,
    (($s.Top | Select-Object -First 3 | ForEach-Object { '{0}:{1}:{2:N0}M' -f $_.Name, $_.Id, ($_.PrivateMemorySize64 / 1MB) }) -join ' ')
  Write-Host $line
  $timeline.Add($line)
  Add-Content -Path $timelineFile -Value $line

  $reason = $null
  if ($s.CommitUsed / $s.CommitTotal -gt 0.85) { $reason = 'commit charge above 85%' }
  elseif ($s.MemUsed / $s.MemTotal -gt 0.92) { $reason = 'physical memory above 92%' }
  elseif ($s.Procs -gt 1500) { $reason = 'more than 1500 processes' }
  elseif (($s.Top | Select-Object -First 1).PrivateMemorySize64 -gt 5GB) { $reason = 'one process above 5 GB private' }
  elseif ($t -gt $Minutes * 60) { $reason = "still running after $Minutes minutes" }

  $detail = @(
    "running tests (oldest first):"
    $runningNow
    ''
    'top processes by private bytes:'
    $s.Top | ForEach-Object { '  {0} pid {1} private {2:N0} MB ws {3:N0} MB handles {4} threads {5}' -f $_.Name, $_.Id, ($_.PrivateMemorySize64 / 1MB), ($_.WorkingSet64 / 1MB), $_.HandleCount, $_.Threads.Count }
    'top processes by handles:'
    $s.TopHandles | ForEach-Object { '  {0} pid {1} handles {2}' -f $_.Name, $_.Id, $_.HandleCount }
    ''
    'last test output:'
    (Get-Content $out -Tail 12 -ErrorAction SilentlyContinue)
  ) -join "`n"

  if ($reason -and -not $done) {
    $killed = $reason
    Write-Host "::error::$reason; killing flutter test"
    Write-Host $detail
    $cim = Get-CimInstance Win32_Process |
      Where-Object { $_.Name -match 'dart|flutter' } |
      Select-Object ProcessId, ParentProcessId, Name, @{ n = 'PrivateMB'; e = { [int]($_.PrivatePageCount / 1MB) } }, CommandLine
    $cim | Format-List | Out-String -Width 400 | Write-Host
    $detail += "`n`nKILLED: $reason`n" + ($cim | Format-List | Out-String -Width 400)
  }

  $patchDue = ((Get-Date) - $lastPatch).TotalSeconds -ge 10 -or $done -or $killed
  if ($check -and $patchDue) {
    $lastPatch = Get-Date
    $tail = ($timeline | Select-Object -Last 300) -join "`n"
    $body = @{
      output = @{
        title   = ('{0}s {1}' -f $t, ($(if ($killed) { "killed: $killed" } elseif ($done) { "exited $($p.ExitCode)" } else { 'running' })))
        summary = '```' + "`n" + $line + "`n`n" + $detail + "`n" + '```'
        text    = '```' + "`n" + $tail + "`n" + '```'
      }
    }
    if ($done -or $killed) {
      $body.status = 'completed'
      $body.conclusion = $(if (-not $killed -and $p.ExitCode -eq 0) { 'success' } else { 'failure' })
    }
    $null = Post-Check Patch "$api/check-runs/$($check.id)" $body
  }

  if ($killed) { taskkill /F /T /PID $p.Id; break }
  if ($done) { break }
}

Get-Content $out -ErrorAction SilentlyContinue
Get-Content $err -ErrorAction SilentlyContinue
if ($killed) { exit 1 }
if ($p.ExitCode -ne 0) { exit $p.ExitCode }
if (-not (Select-String -Path $out -SimpleMatch 'All tests passed!' -Quiet)) {
  "::error::flutter test exited 0 without reporting that all tests passed."
  exit 1
}

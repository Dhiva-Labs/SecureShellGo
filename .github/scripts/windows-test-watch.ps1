# Runs `flutter test` on a Windows runner and watches the machine while it
# runs. Probe build: every couple of seconds it records memory, commit
# charge, CPU, disk, process, handle and TCP counts, every process that
# starts or ends, and the tests that have started but not finished. It
# prints that to the step log and mirrors it into a check run through the
# API, so a runner that stops answering still leaves its last seconds
# behind. If the API stops answering it kills the tests and keeps trying,
# to tell a dead machine from a cut network.
param(
  [string]$TestArgs = '',
  [int]$Minutes = 25,
  [int]$Every = 2,
  [int]$PatchEvery = 6
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
$names = @(Get-ChildItem test -Filter *_test.dart |
    Where-Object { $linuxOnly -notcontains $_.Name } |
    Sort-Object Name | ForEach-Object { $_.Name })
if ($env:SUBSET_FROM) { $names = @($names | Where-Object { $_ -ge $env:SUBSET_FROM }) }
if ($env:SUBSET_TO) { $names = @($names | Where-Object { $_ -le $env:SUBSET_TO }) }
if ($env:TEST_FILES) { $names = @($env:TEST_FILES -split '\s+' | Where-Object { $_ } | ForEach-Object { Split-Path -Leaf $_ }) }
$tests = $names | ForEach-Object { "test/$_" }
"$($tests.Count) test files ($($names[0]) .. $($names[-1])); extra args: $TestArgs"

$out = Join-Path $env:RUNNER_TEMP 'flutter-test.out'
$err = Join-Path $env:RUNNER_TEMP 'flutter-test.err'
$json = Join-Path $env:RUNNER_TEMP 'flutter-test.json'
$timelineFile = Join-Path $env:RUNNER_TEMP 'watch-timeline.txt'
$flutter = (Get-Command flutter).Source

$os0 = Get-CimInstance Win32_OperatingSystem
"machine: $([math]::Round($os0.TotalVisibleMemorySize / 1MB, 1)) GB RAM, commit limit $([math]::Round($os0.TotalVirtualMemorySize / 1MB, 1)) GB, $([Environment]::ProcessorCount) CPUs, $($os0.Caption) $($os0.Version), boot $($os0.LastBootUpTime)"
Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'Runner|provjob|sshd|agent' } |
  Select-Object ProcessId, ParentProcessId, Name, CommandLine | Format-Table -AutoSize | Out-String -Width 300

$repeat = [int]$(if ($env:REPEAT) { $env:REPEAT } else { 1 })
$one = "call `"$flutter`" test $TestArgs --reporter expanded --file-reporter `"json:$json`" $($tests -join ' ')"
$chain = (1..$repeat | ForEach-Object { $one }) -join ' & '
"running $repeat time(s): $one"
$p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
  -ArgumentList "/d /c ($chain) > `"$out`" 2> `"$err`" < NUL"
$null = $p.Handle  # keeps ExitCode readable once it exits

$start = Get-Date
$timeline = New-Object System.Collections.Generic.List[string]
$suites = @{}
$running = @{}
$jsonPos = 0L
$killed = $null
$lastPatch = [datetime]::MinValue
$patchFails = 0
$netLostAt = $null
$prev = $null
$prevCpu = $null
$prevTime = $null

function Note([string]$Line) {
  Write-Host $Line
  $script:timeline.Add($Line)
  Add-Content -Path $script:timelineFile -Value $Line
}

function Read-Json {
  if (-not (Test-Path $json)) { return }
  try {
    $fs = [IO.File]::Open($json, 'Open', 'Read', 'ReadWrite')
  } catch { return }
  try {
    if ($fs.Length -lt $script:jsonPos) { $script:jsonPos = 0L; $script:running.Clear() }
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

while ($true) {
  $done = $p.WaitForExit($Every * 1000)
  $t = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
  Read-Json

  $os = Get-CimInstance Win32_OperatingSystem
  $procs = Get-Process
  $now = @{}
  foreach ($q in $procs) { $now[$q.Id] = $q }
  $cpuSum = 0.0
  foreach ($q in $procs) { if ($q.TotalProcessorTime) { $cpuSum += $q.TotalProcessorTime.TotalSeconds } }
  $wall = Get-Date
  $cpu = 0
  if ($prevCpu -ne $null) {
    $cpu = [int](100 * ($cpuSum - $prevCpu) / (($wall - $prevTime).TotalSeconds * [Environment]::ProcessorCount))
  }
  $prevCpu = $cpuSum; $prevTime = $wall
  $tcp = 0
  try { $tcp = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections().Count } catch {}
  $udp = 0
  try { $udp = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveUdpListeners().Count } catch {}
  $freeC = 0; $freeD = 0
  try { $freeC = [IO.DriveInfo]::new('C').AvailableFreeSpace / 1GB } catch {}
  try { $freeD = [IO.DriveInfo]::new('D').AvailableFreeSpace / 1GB } catch {}
  $memUsed = ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB
  $memTotal = $os.TotalVisibleMemorySize / 1MB
  $commitUsed = ($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB
  $commitTotal = $os.TotalVirtualMemorySize / 1MB
  $handles = ($procs | Measure-Object HandleCount -Sum).Sum
  $runner = (@($procs | Where-Object { $_.Name -like 'Runner.*' }) | ForEach-Object { "$($_.Name -replace 'Runner\.', ''):$($_.Id)" }) -join ','
  $top = $procs | Sort-Object PrivateMemorySize64 -Descending | Select-Object -First 2

  Note ('{0,6}s mem {1:N1}/{2:N1}G commit {3:N1}/{4:N1}G cpu {5}% C {6:N0}G D {7:N0}G procs {8} hnd {9} tcp {10} udp {11} run {12} runner {13} api {14} | {15}' -f `
      $t, $memUsed, $memTotal, $commitUsed, $commitTotal, $cpu, $freeC, $freeD, $procs.Count, $handles, $tcp, $udp, $running.Count, $runner,
      $(if ($patchFails) { "FAIL$patchFails" } else { 'ok' }),
      (($top | ForEach-Object { '{0}:{1:N0}M' -f $_.Name, ($_.PrivateMemorySize64 / 1MB) }) -join ' '))

  if ($prev -ne $null) {
    $born = @($now.Keys | Where-Object { -not $prev.ContainsKey($_) })
    $gone = @($prev.Keys | Where-Object { -not $now.ContainsKey($_) })
    if ($born.Count) {
      $cims = @{}
      try {
        Get-CimInstance Win32_Process -Filter (($born | ForEach-Object { "ProcessId=$_" }) -join ' OR ') |
          ForEach-Object { $cims[[int]$_.ProcessId] = $_ }
      } catch {}
      foreach ($id in $born) {
        $c = $cims[[int]$id]
        $cmd = if ($c -and $c.CommandLine) { $c.CommandLine } else { '' }
        if ($cmd.Length -gt 220) { $cmd = $cmd.Substring(0, 220) + '...' }
        $parent = if ($c) { $c.ParentProcessId } else { '?' }
        $pname = if ($c -and $now.ContainsKey([int]$c.ParentProcessId)) { $now[[int]$c.ParentProcessId].Name } else { '' }
        Note ('         + {0} {1} <- {2} {3}: {4}' -f $now[$id].Name, $id, $pname, $parent, $cmd)
      }
    }
    foreach ($id in $gone) { Note ('         - {0} {1}' -f $prev[$id].Name, $id) }
  }
  $prev = $now

  $reason = $null
  if ($commitUsed / $commitTotal -gt 0.85) { $reason = 'commit charge above 85%' }
  elseif ($memUsed / $memTotal -gt 0.92) { $reason = 'physical memory above 92%' }
  elseif ($freeC -gt 0 -and $freeC -lt 4) { $reason = 'less than 4 GB free on C:' }
  elseif ($freeD -gt 0 -and $freeD -lt 4) { $reason = 'less than 4 GB free on D:' }
  elseif ($procs.Count -gt 1500) { $reason = 'more than 1500 processes' }
  elseif (($top | Select-Object -First 1).PrivateMemorySize64 -gt 5GB) { $reason = 'one process above 5 GB private' }
  elseif ($t -gt $Minutes * 60) { $reason = "still running after $Minutes minutes" }
  elseif ($patchFails -ge 3 -and -not $netLostAt) { $reason = "the API stopped answering ($patchFails failures)" }

  $nowT = Get-Date
  $runningNow = @($running.Values | Sort-Object Since | Select-Object -First 8 |
      ForEach-Object { '{0,4}s {1}: {2}' -f [int]($nowT - $_.Since).TotalSeconds, $_.File, $_.Name })

  if ($reason -and -not $done -and -not $killed) {
    $killed = $reason
    if ($reason -like 'the API*') { $netLostAt = $t }
    Note "::error::$reason; killing flutter test"
    $runningNow | ForEach-Object { Note "    running: $_" }
    Get-Content $out -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Note "    out: $_" }
    taskkill /F /T /PID $p.Id | Out-Null
  }

  $patchDue = ((Get-Date) - $lastPatch).TotalSeconds -ge $PatchEvery -or $done -or $killed
  if ($check -and $patchDue) {
    $lastPatch = Get-Date
    $detail = @(
      'running tests (oldest first):'
      $runningNow
      ''
      'last test output:'
      (Get-Content $out -Tail 10 -ErrorAction SilentlyContinue)
    ) -join "`n"
    $tail = ($timeline | Select-Object -Last 400) -join "`n"
    if ($tail.Length -gt 60000) { $tail = $tail.Substring($tail.Length - 60000) }
    $state = if ($killed) { "killed: $killed" } elseif ($done) { "exited $($p.ExitCode)" } else { 'running' }
    $body = @{
      output = @{
        title   = "${t}s $state"
        summary = '```' + "`n" + $timeline[$timeline.Count - 1] + "`n`n" + $detail + "`n" + '```'
        text    = '```' + "`n" + $tail + "`n" + '```'
      }
    }
    $final = ($done -or $killed) -and -not $netLostAt
    if ($final) {
      $body.status = 'completed'
      $body.conclusion = $(if (-not $killed -and $p.ExitCode -eq 0) { 'success' } else { 'failure' })
    }
    if (Post-Check Patch "$api/check-runs/$($check.id)" $body) {
      if ($netLostAt) {
        Note "the API answers again at ${t}s, $([int]($t - $netLostAt))s after the tests were killed"
        $netLostAt = $null
        $patchFails = 0
        continue
      }
      $patchFails = 0
    } else {
      $patchFails++
    }
    if ($final -and ($patchFails -eq 0 -or $patchFails -ge 3)) { break }
  }
  if ($netLostAt -and $t - $netLostAt -gt 180) { Note 'the API never came back'; break }
  if ($done -and -not $check) { break }
}

Get-Content $out -ErrorAction SilentlyContinue
Get-Content $err -ErrorAction SilentlyContinue
if ($killed) { exit 1 }
if ($p.ExitCode -ne 0) { exit $p.ExitCode }
if (-not (Select-String -Path $out -SimpleMatch 'All tests passed!' -Quiet)) {
  "::error::flutter test exited 0 without reporting that all tests passed."
  exit 1
}

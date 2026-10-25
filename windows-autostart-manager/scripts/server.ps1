# windows-autostart-manager - PowerShell backend (no dependencies, Windows 10/11 built-in)
# Same HTTP API as server.mjs. Run: powershell -NoProfile -ExecutionPolicy Bypass -File server.ps1
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$DataDir = Join-Path $env:APPDATA 'windows-autostart-manager'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null }
$ConfigFile = Join-Path $DataDir 'config.json'
if (-not (Test-Path $ConfigFile)) {
  '{"groups":{},"meta":{},"disabledRun":{},"advanced":false}' | Set-Content $ConfigFile -Encoding UTF8
}
function Load-Cfg { (Get-Content $ConfigFile -Raw -Encoding UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json }
function Save-Cfg($c) { $c | ConvertTo-Json -Depth 12 | Set-Content $ConfigFile -Encoding UTF8 }

$RunKeyUser = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunKeyMach = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
$StartupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$StartupOff = Join-Path $StartupDir '_已关闭自启'
$UiFile = Join-Path $PSScriptRoot '..\assets\index.html'

function Norm([string]$s) { if (-not $s) { '' } else { $s.Replace('/', '\').ToLower() } }
function Get-Targets([string]$cmd) {
  $re = [regex]'([a-z]:[^\s\x22\x27]+|[\w.\-]+\.(?:py|mjs|cjs|js|vbs|bat|cmd|exe))'
  $t = @($re.Matches($cmd) | ForEach-Object { $_.Value })
  $script = $t | Where-Object { $_ -match '\.(py|mjs|cjs|js|vbs|bat|cmd)$' } | Select-Object -First 1
  $exe = $t | Where-Object { $_ -match '\.exe$' } | Select-Object -First 1
  return @($script, $exe)
}
function Match-Pids($it, $procs, $selfSet) {
  $nk = ''; $base = ''; $tail2 = ''; $byName = $false
  if ($it.matchKey) {
    $nk = Norm $it.matchKey; $base = ($nk -split '\\')[-1]; $byName = $true
  } else {
    $tg = Get-Targets ($it.command)
    $key = if ($tg[0]) { $tg[0] } elseif ($tg[1]) { $tg[1] } else { return @() }
    $nk = Norm $key; $parts = $nk -split '\\'
    $base = $parts[-1]
    $tail2 = ($parts | Select-Object -Last 2) -join '\'
    $byName = (-not $tg[0]) -and [bool]$tg[1]
  }
  $r = @()
  foreach ($p in $procs) {
    if ($selfSet.Contains([int]$p.ProcessId)) { continue }
    $cl = Norm $p.CommandLine; $nm = ('' + $p.Name).ToLower()
    if ($cl.Contains($nk) -or ($tail2 -and $cl.Contains($tail2))) { $r += [int]$p.ProcessId; continue }
    if ($byName -and ($nm -eq $base -or $nm -eq ($base + '.exe'))) { $r += [int]$p.ProcessId }
  }
  return , $r
}

function Get-State {
  $cfg = Load-Cfg
  $items = New-Object System.Collections.ArrayList
  # 1) startup commands (registry Run + startup folders)
  try {
    foreach ($sc in (Get-CimInstance Win32_StartupCommand)) {
      $loc = '' + $sc.Location; $source = 'other'
      if ($loc -match 'HKU|HKCU') { $source = 'run-user' }
      elseif ($loc -match 'HKLM') { $source = 'run-machine' }
      elseif ($loc -eq 'Startup') { $source = 'startup-folder' }
      elseif ($loc -eq 'Common Startup') { $source = 'startup-folder-common' }
      [void]$items.Add([ordered]@{ id = "$source$($sc.Name)"; source = $source; name = '' + $sc.Name; command = '' + $sc.Command })
    }
  } catch { [void]$items.Add([ordered]@{ source = 'error'; name = '扫描启动项失败'; command = '' + $_.Exception.Message }) }
  # 1b) real file names in user startup folder
  $folderFiles = @()
  try { $folderFiles = @(Get-ChildItem -File $StartupDir -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) } catch {}
  foreach ($it in $items) {
    if ($it.source -eq 'startup-folder') {
      $hit = $folderFiles | Where-Object { $_ -eq $it.name -or [IO.Path]::GetFileNameWithoutExtension($_) -eq $it.name -or ($it.name + '.lnk') -eq $_ } | Select-Object -First 1
      if ($hit) { $it.file = $hit }
    }
  }
  # 1c) disabled/deleted-with-backup entries
  if ($cfg.disabledRun) {
    foreach ($pr in $cfg.disabledRun.PSObject.Properties) {
      $parts = $pr.Name -split '\|', 2
      [void]$items.Add([ordered]@{ id = "off$($pr.Name)"; source = "$($parts[0])-off"; name = $parts[1]; command = '' + $pr.Value })
    }
  }
  if (Test-Path $StartupOff) {
    foreach ($f in (Get-ChildItem -File $StartupOff -ErrorAction SilentlyContinue)) {
      [void]$items.Add([ordered]@{ id = "offdir$($f.Name)"; source = 'startup-folder-off'; name = $f.Name; file = $f.Name; command = '(已移出到 _已关闭自启 文件夹)' })
    }
  }
  # 2) non-svchost services
  foreach ($s in (Get-CimInstance Win32_Service)) {
    if (-not $s.PathName) { continue }
    if ($s.PathName -match 'System32\\|SysWOW64\\|windir' -and $s.PathName -notmatch 'DriverStore|sppsvc') { continue }
    [void]$items.Add([ordered]@{ id = "svc$($s.Name)"; source = 'service'; name = '' + $s.Name; display = '' + $s.DisplayName; command = '' + $s.PathName; state = '' + $s.State; startType = '' + $s.StartMode })
  }
  # 3) user scheduled tasks with boot/logon triggers
  try {
    foreach ($t in (Get-ScheduledTask | Where-Object { $_.TaskPath -notmatch '^\\Microsoft\\' })) {
      $trg = ($t.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ','
      if ($trg -notmatch 'Boot|Logon') { continue }
      $exec = ($t.Actions | ForEach-Object { '' + $_.Execute + ' ' + $_.Arguments }) -join ' | '
      [void]$items.Add([ordered]@{ id = "task$($t.TaskName)"; source = 'task'; name = '' + $t.TaskName; command = $exec.Trim(); state = '' + [int]$t.State; trigger = $trg })
    }
  } catch {}
  # processes + elevation
  $procs = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CommandLine)
  $selfSet = New-Object 'System.Collections.Generic.HashSet[int]'
  [void]$selfSet.Add($PID)
  $cur = $procs | Where-Object { $_.ProcessId -eq $PID } | Select-Object -First 1
  while ($cur) {
    [void]$selfSet.Add([int]$cur.ParentProcessId)
    $cur = $procs | Where-Object { $_.ProcessId -eq $cur.ParentProcessId } | Select-Object -First 1
  }
  $elev = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $meta = if ($cfg.meta) { $cfg.meta } else { [pscustomobject]@{} }
  $groups = if ($cfg.groups) { $cfg.groups } else { [pscustomobject]@{} }
  foreach ($it in $items) {
    $m = $meta.($it.name)
    $it.suggestion = if ($m -and $m.suggestion) { '' + $m.suggestion } else { $null }
    $it.userTags = if ($m -and $m.tags) { @($m.tags) } else { @() }
    $it.matchKey = if ($m -and $m.match) { '' + $m.match } else { $null }
    $it.startupType = switch -regex ($it.source) {
      '^run-' { '登录自启·注册表' }
      '^startup-folder' { '登录自启·启动文件夹' }
      '^task' { $trg2 = if ($it.trigger) { $it.trigger } else { '' }; '计划任务·' + $(if ($trg2 -match 'Boot' -and $trg2 -match 'Logon') { '开机+登录' } elseif ($trg2 -match 'Boot') { '开机' } else { '登录' }) }
      '^service' { $st = switch ('' + $it.startType) { 'Auto' { '自动' } 'Manual' { '手动' } 'Disabled' { '禁用' } default { $it.startType } }; "服务·$st" }
      default { '' }
    }
    $cmdline = ('' + $it.command) + ' ' + $it.name
    $tag = if ($it.source -eq 'run-machine' -or $cmdline -match 'system32|syswow64|windir') { '系统' }
      elseif ($it.source -eq 'service' -and $cmdline -match 'driverstore|nvidia|intel|realtek') { '驱动' }
      else { '第三方' }
    $it.tags = @(@($tag) + $it.userTags | Select-Object -Unique)
    $it.groupsOf = @($groups.PSObject.Properties | Where-Object { @($_.Value) -contains $it.name } | ForEach-Object { $_.Name })
    if ($it.source -eq 'service') { $it.running = ('' + $it.state -eq 'Running') }
    else { $pids = Match-Pids $it $procs $selfSet; $it.running = (@($pids).Count -gt 0); $it.pids = @($pids) }
  }
  $itemsJson = '[' + ((@($items) | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }) -join ',') + ']'
  $rest = [ordered]@{
    groups      = $groups
    disabledRun = $cfg.disabledRun
    elevated    = $elev
    advanced    = [bool]$cfg.advanced
  } | ConvertTo-Json -Depth 12
  if (-not $rest) { $rest = '{}' }
  return $rest.TrimEnd('}', [char]13, [char]10, ' ') + ',"items":' + $itemsJson + '}'
}

function Invoke-Action($body) {
  $cfg = Load-Cfg
  $op = '' + $body.op
  function RunPs($script) { Invoke-Expression $script }
  switch ($op) {
    'run-disable' {
      $key = if ($body.source -eq 'run-machine') { $RunKeyMach } else { $RunKeyUser }
      $val = ''
      if (Test-Path $key) { $val = (Get-Item $key).GetValue([string]$body.name) }
      if (-not $val) { throw '注册表中找不到该值' }
      if (-not $cfg.disabledRun) { $cfg | Add-Member -Force NoteProperty disabledRun ([pscustomobject]@{}) }
      $cfg.disabledRun | Add-Member -Force NoteProperty "$($body.source)|$($body.name)" $val
      Save-Cfg $cfg
      RunPs "Remove-ItemProperty -Path '$key' -Name $('' + $body.name -replace "'","''") -Force"
      return @{ ok = $true; msg = "已禁用并备份：$($body.name)" }
    }
    'run-enable' {
      $key = if ($body.source -eq 'run-machine') { $RunKeyMach } else { $RunKeyUser }
      $pname = "$($body.source)|$($body.name)"
      $saved = $cfg.disabledRun.$pname
      if (-not $saved) { throw '没有备份记录，无法恢复' }
      RunPs "New-ItemProperty -Path '$key' -Name $('' + $body.name -replace "'","''") -Value '$($saved -replace "'","''")' -PropertyType String -Force | Out-Null"
      $cfg.disabledRun.PSObject.Properties.Remove($pname)
      Save-Cfg $cfg
      return @{ ok = $true; msg = "已恢复自启：$($body.name)" }
    }
    'folder-disable' {
      $fn = if ($body.file) { $body.file } else { $body.name }
      $f = Join-Path $StartupDir $fn
      if (-not (Test-Path $f)) { throw "文件不存在: $f" }
      New-Item -ItemType Directory -Force -Path $StartupOff | Out-Null
      Move-Item -Force $f (Join-Path $StartupOff $fn)
      return @{ ok = $true; msg = "已移出启动文件夹：$fn" }
    }
    'folder-enable' {
      $fn = if ($body.file) { $body.file } else { $body.name }
      Move-Item -Force (Join-Path $StartupOff $fn) (Join-Path $StartupDir $fn)
      return @{ ok = $true; msg = "已放回启动文件夹：$fn" }
    }
    'task-disable' { Disable-ScheduledTask -TaskName $body.name | Out-Null; return @{ ok = $true; msg = "已禁用计划任务：$($body.name)" } }
    'task-enable' { Enable-ScheduledTask -TaskName $body.name | Out-Null; return @{ ok = $true; msg = "已启用计划任务：$($body.name)" } }
    'task-run' { Start-ScheduledTask -TaskName $body.name; return @{ ok = $true; msg = "已触发：$($body.name)" } }
    'svc-mode' {
      $map = @{ auto = 'Automatic'; manual = 'Manual'; delayed = 'Automatic'; disabled = 'Disabled' }
      $m = if ($map[$body.mode]) { $map[$body.mode] } else { $body.mode }
      Set-Service -Name $body.name -StartupType $m
      if ($body.mode -eq 'delayed') { sc.exe config $body.name start= delayed-auto | Out-Null }
      return @{ ok = $true; msg = "服务 $($body.name) 启动类型已改为 $($body.mode)" }
    }
    'svc-start' { Start-Service -Name $body.name; return @{ ok = $true; msg = "已启动服务：$($body.name)" } }
    'svc-stop' { Stop-Service -Name $body.name -Force; return @{ ok = $true; msg = "已停止服务：$($body.name)" } }
    'launch' {
      Start-Process cmd -ArgumentList '/c', [string]$body.command -WindowStyle Hidden
      return @{ ok = $true; msg = '已发出启动命令' }
    }
    'stop' {
      $procs = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CommandLine)
      $selfSet = New-Object 'System.Collections.Generic.HashSet[int]'; [void]$selfSet.Add($PID)
      $cur = $procs | Where-Object { $_.ProcessId -eq $PID } | Select-Object -First 1
      while ($cur) { [void]$selfSet.Add([int]$cur.ParentProcessId); $cur = $procs | Where-Object { $_.ProcessId -eq $cur.ParentProcessId } | Select-Object -First 1 }
      $m = if ($cfg.meta -and $cfg.meta.($body.name) -and $cfg.meta.($body.name).match) { '' + $cfg.meta.($body.name).match } else { $null }
      $it = @{ command = ('' + $body.command); matchKey = $m }
      $pids = @(Match-Pids $it $procs $selfSet)
      if (-not $pids.Count) { throw '未找到该项目的运行中进程' }
      foreach ($p in $pids) { taskkill /PID $p /T /F 2>$null | Out-Null }
      return @{ ok = $true; msg = "已停止 $($pids.Count) 个进程：$($body.name)" }
    }
    'delete' {
      $s = '' + $body.source
      if (($s -eq 'task' -or $s -eq 'service') -and -not [bool]$cfg.advanced) {
        throw "永久删除计划任务/服务属于高危操作：请先在配置文件的 advanced 字段开启高级模式（$ConfigFile）"
      }
      switch ($s) {
        { $_ -in 'run-user', 'run-machine' } {
          $key = if ($s -eq 'run-machine') { $RunKeyMach } else { $RunKeyUser }
          $val = if (Test-Path $key) { (Get-Item $key).GetValue([string]$body.name) } else { '' }
          if (-not $val) { throw '注册表中找不到该值' }
          if (-not $cfg.disabledRun) { $cfg | Add-Member -Force NoteProperty disabledRun ([pscustomobject]@{}) }
          $cfg.disabledRun | Add-Member -Force NoteProperty "$s|$($body.name)" $val
          Save-Cfg $cfg
          RunPs "Remove-ItemProperty -Path '$key' -Name $('' + $body.name -replace "'","''") -Force"
          return @{ ok = $true; msg = "已删除自启项（已备份，可在列表恢复）：$($body.name)" }
        }
        { $_ -in 'startup-folder', 'startup-folder-common' } {
          $dir = if ($s -eq 'startup-folder') { $StartupDir } else { Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup' }
          $fn = if ($body.file) { $body.file } else { $body.name }
          $f = Join-Path $dir $fn
          if (-not (Test-Path $f)) { throw "文件不存在: $f" }
          Add-Type -AssemblyName Microsoft.VisualBasic
          [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f, 'OnlyErrorDialogs', 'SendToRecycleBin')
          return @{ ok = $true; msg = "已删除，文件已放入回收站：$fn" }
        }
        'startup-folder-off' {
          $fn = if ($body.file) { $body.file } else { $body.name }
          Add-Type -AssemblyName Microsoft.VisualBasic
          [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile((Join-Path $StartupOff $fn), 'OnlyErrorDialogs', 'SendToRecycleBin')
          return @{ ok = $true; msg = '已删除（文件在回收站）' }
        }
        { $_ -in 'run-user-off', 'run-machine-off' } {
          $cfg.disabledRun.PSObject.Properties.Remove(($s -replace '-off', '') + '|' + $body.name)
          Save-Cfg $cfg
          return @{ ok = $true; msg = "已删除备份记录：$($body.name)" }
        }
        'task' { Unregister-ScheduledTask -TaskName $body.name -Confirm:$false; return @{ ok = $true; msg = "已永久删除计划任务：$($body.name)" } }
        'service' { sc.exe stop $body.name | Out-Null; sc.exe delete $body.name | Out-Null; return @{ ok = $true; msg = "已删除服务注册：$($body.name)" } }
        default { throw "该来源不支持删除: $s" }
      }
    }
    'relaunch-elevated' {
      $self = Join-Path $PSScriptRoot 'server.ps1'
      Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$self,'--takeover',"$PID" -Verb RunAs
      Start-Sleep -Milliseconds 300
      return @{ ok = $true; msg = '新实例正在以管理员身份接管端口，3 秒后刷新页面即可。' }
    }
    'set-tags' {
      if (-not $cfg.meta) { $cfg | Add-Member -Force NoteProperty meta ([pscustomobject]@{}) }
      $old = $cfg.meta.($body.name)
      $new = [pscustomobject]@{ tags = @($body.tags) }
      if ($old) { $new = [pscustomobject]@{ tags = @($body.tags); suggestion = $old.suggestion; match = $old.match; note = $old.note } }
      $cfg.meta | Add-Member -Force NoteProperty "$($body.name)" $new
      Save-Cfg $cfg
      return @{ ok = $true; msg = "标签已更新：$($body.name)" }
    }
    'save-groups' {
      $cfg | Add-Member -Force NoteProperty groups $body.groups
      Save-Cfg $cfg
      return @{ ok = $true; msg = '分组已保存' }
    }
    'save-meta' {
      if (-not $cfg.meta) { $cfg | Add-Member -Force NoteProperty meta ([pscustomobject]@{}) }
      foreach ($pr in $body.meta.PSObject.Properties) {
        $old = $cfg.meta.($pr.Name); $merged = @{}
        if ($old) { foreach ($p2 in $old.PSObject.Properties) { $merged[$p2.Name] = $p2.Value } }
        foreach ($p2 in $pr.Value.PSObject.Properties) { $merged[$p2.Name] = $p2.Value }
        $cfg.meta | Add-Member -Force NoteProperty $pr.Name ([pscustomobject]$merged)
      }
      Save-Cfg $cfg
      return @{ ok = $true; msg = '分类已保存' }
    }
    default { throw "未知操作: $op" }
  }
}

# ---------- HTTP ----------
if ($args.Count -ge 2 -and $args[0] -eq '--takeover') {
  try { Stop-Process -Id ([int]$args[1]) -Force -ErrorAction SilentlyContinue } catch {}
  Start-Sleep -Milliseconds 700
}
$listener = $null
$port = 0
foreach ($p in 28788..28808) {
  try {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://127.0.0.1:$p/")
    $l.Start(); $listener = $l; $port = $p; break
  } catch {}
}
if (-not $listener) { Write-Output 'ERROR: 端口 28788-28808 都被占用'; exit 1 }
Write-Output "OK windows-autostart-manager http://127.0.0.1:$port/"
while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  try {
    $req = $ctx.Request; $res = $ctx.Response
    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    $path = $req.Url.AbsolutePath
    if ($path -eq '/') {
      $bytes = [Text.Encoding]::UTF8.GetBytes((Get-Content $UiFile -Raw -Encoding UTF8))
      $res.ContentType = 'text/html; charset=utf-8'
    } elseif ($path -eq '/api/state') {
      $bytes = [Text.Encoding]::UTF8.GetBytes((Get-State))
      $res.ContentType = 'application/json; charset=utf-8'
    } elseif ($path -eq '/api/action' -and $req.HttpMethod -eq 'POST') {
      $reader = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
      $bodyText = $reader.ReadToEnd()
      $body = if ($bodyText) { $bodyText | ConvertFrom-Json } else { [pscustomobject]@{} }
      try {
        $r = Invoke-Action $body
        $bytes = [Text.Encoding]::UTF8.GetBytes(($r | ConvertTo-Json -Depth 6 -Compress))
      } catch {
        $res.StatusCode = 500
        $bytes = [Text.Encoding]::UTF8.GetBytes((@{ error = ("" + $_.Exception.Message).Substring(0, [Math]::Min(500, ("" + $_.Exception.Message).Length)) } | ConvertTo-Json -Compress))
      }
      $res.ContentType = 'application/json; charset=utf-8'
    } else {
      $res.StatusCode = 404
      $bytes = [Text.Encoding]::UTF8.GetBytes('not found')
    }
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.Close()
  } catch { Write-Host ('ERR ' + $_.Exception.Message); try { $ctx.Response.Abort() } catch {} }
}

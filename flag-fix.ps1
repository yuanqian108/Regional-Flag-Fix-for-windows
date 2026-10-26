<#
.SYNOPSIS
    Windows 11 地区旗帜 emoji 一键修复工具
.DESCRIPTION
    安装 / 还原 Segoe UI Emoji 字体，使地区旗帜 emoji 正常显示。
    自动处理：管理员提权、字体缓存刷新、同名冲突清理、重启提示。
.PARAMETER Action
    install   安装补丁字体（全部 emoji + 259 面地区旗帜）  [默认]
              首次安装会自动备份系统原版到 backup\
    restore   从备份还原为系统原版字体
    diagnose  只诊断当前状态，不做任何修改
.PARAMETER NoRestart
    只提示不自动重启
.EXAMPLE
    .\flag-fix.ps1              # 安装（默认）
    .\flag-fix.ps1 diagnose     # 诊断
    .\flag-fix.ps1 restore      # 还原
#>
param(
    [Parameter(Position=0)]
    [ValidateSet('install','restore','diagnose','menu')]
    [string]$Action = 'menu',
    [switch]$NoRestart
)

$ErrorActionPreference = 'Continue'

# 顶层异常捕获：任何未处理错误都提示用户，而不是静默退出
trap {
  Write-Host ''
  Write-Host '  [X]  发生错误，操作未完成' -ForegroundColor Red
  Write-Host ('       ' + $_.Exception.Message) -ForegroundColor Gray
  Write-Host ''
  Write-Host '  如果问题持续，请把上面的信息反馈到 GitHub Issues：' -ForegroundColor Yellow
  Write-Host '  https://github.com/yuanqian108/Regional-Flag-Fix-for-windows/issues' -ForegroundColor Gray
  Write-Host ''
  Read-Host '按 Enter 退出' | Out-Null
  exit 1
}
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CoreDir   = Join-Path $ScriptDir 'core'
$BackupDir = Join-Path $ScriptDir 'backup'
$BackupFile = Join-Path $BackupDir 'seguiemj_original.ttf'
$FontsDir  = Join-Path $env:WINDIR 'Fonts'
$FontReg   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$RegName   = 'Segoe UI Emoji (TrueType)'
$PendingKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'

$LogFile = Join-Path $ScriptDir 'last-run.log'
function Say($m,$c='Gray'){
  Write-Host $m -ForegroundColor $c
  try { Add-Content -Path $LogFile -Value $m -Encoding UTF8 -EA SilentlyContinue } catch { }
}
if (Test-Path $LogFile) { Remove-Item $LogFile -Force -EA SilentlyContinue }
function Ok($m){ Say ('  [OK] ' + $m) 'Green' }
function Warn($m){ Say ('  [!]  ' + $m) 'Yellow' }
function Fail($m){ Say ('  [X]  ' + $m) 'Red' }
function Step($m){ Say ("`n>> " + $m) 'Cyan' }

function Test-Admin {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-EmojiFonts {
  $out = @()
  $dirs = @($FontsDir, (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'))
  foreach ($d in $dirs) {
    if (-not (Test-Path $d)) { continue }
    foreach ($f in Get-ChildItem $d -Filter '*.ttf' -ErrorAction SilentlyContinue) {
      $out += $f
    }
  }
  $out
}

function Get-FamilyName([string]$Path) {
  try {
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $pfc = New-Object System.Drawing.Text.PrivateFontCollection
    $pfc.AddFontFile($Path)
    if ($pfc.Families.Count -gt 0) {
      $n = $pfc.Families[0].Name
      $pfc.Dispose()
      return $n
    }
    $pfc.Dispose()
  } catch { }
  return $null
}

function Stop-FC { foreach($s in @('FontCache3.0.0.0','FontCache')){ $x=Get-Service $s -EA SilentlyContinue; if($x -and $x.Status -eq 'Running'){ try{Stop-Service $s -Force -EA Stop}catch{} } } }
function Start-FC { foreach($s in @('FontCache3.0.0.0','FontCache')){ $x=Get-Service $s -EA SilentlyContinue; if($x -and $x.Status -ne 'Running'){ try{Start-Service $s -EA Stop}catch{} } } }
function Stop-Shell { $n=@('explorer','dwm','SearchHost','StartMenuExperienceHost','RuntimeBroker','TextInputHost','ShellExperienceHost','ApplicationFrameHost','chrome','msedge','notepad'); Get-Process $n -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue }
function Start-Shell { Start-Sleep -Milliseconds 500; if(-not(Get-Process explorer -EA SilentlyContinue)){ Start-Process explorer.exe } }

function Queue-Delete([string]$Path) {
  # 登记重启删除。失败时静默返回 false（不影响主流程）
  if (-not (Test-Path $Path)) { return $false }
  try {
    $cur=(Get-ItemProperty -Path $PendingKey -Name PendingFileRenameOperations -EA SilentlyContinue).PendingFileRenameOperations
    $l=@(); if($cur){ $l=@($cur) }
    $leaf=Split-Path $Path -Leaf
    foreach($e in $l){ if($e -and $e.Contains($leaf)){ return $true } }
    $l += ('\??\' + $Path)
    $l += ''
    Set-ItemProperty -Path $PendingKey -Name PendingFileRenameOperations -Value $l -Type MultiString -EA Stop
    return $true
  } catch {
    return $false
  }
}

function Backup-OriginalFont {
  # 备份系统原版字体（仅首次，不覆盖已有备份）
  $sysFont = Join-Path $FontsDir 'seguiemj.ttf'
  if (-not (Test-Path $sysFont)) {
    Fail '找不到系统字体 seguiemj.ttf，无法备份'
    return $false
  }

  if (Test-Path $BackupFile) {
    Ok ('已有备份，跳过 (' + ('{0:N0}' -f (Get-Item $BackupFile).Length) + ' 字节)')
    return $true
  }

  $sz = (Get-Item $sysFont).Length
  # 我们的补丁约 6MB，系统原版 11~13MB。小于 10MB 说明可能已被替换过
  if ($sz -lt 10MB) {
    Warn ('当前 seguiemj.ttf 只有 ' + ('{0:N1}' -f ($sz/1MB)) + ' MB，可能已被修改过')
    Warn '备份的将不是纯净原版，还原后可能仍是修改版'
  } else {
    Say ('  当前系统字体: ' + ('{0:N0}' -f $sz) + ' 字节（正常范围）')
  }

  if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }

  try {
    Copy-Item $sysFont $BackupFile -Force -EA Stop
    Ok ('已备份到 backup\seguiemj_original.ttf (' + ('{0:N0}' -f (Get-Item $BackupFile).Length) + ' 字节)')
    return $true
  } catch {
    Fail ('备份失败: ' + $_.Exception.Message)
    return $false
  }
}

function Show-Diagnose {
  Step '当前状态'
  $reg=(Get-Item $FontReg).GetValue($RegName)
  Say ('  注册表指向: ' + $reg)

  Step '自称 Segoe UI Emoji 的字体文件'
  $emojiFiles=@()
  foreach($f in (Find-EmojiFonts)){
    $fam = Get-FamilyName $f.FullName
    if ($fam -eq 'Segoe UI Emoji') { $emojiFiles += $f }
  }
  if ($emojiFiles.Count -eq 0) { Warn '未找到任何 Segoe UI Emoji 字体文件' }
  foreach($f in $emojiFiles){
    $mark = ''
    if ($f.Name -eq $reg) { $mark = '   <- 生效' }
    Say ('  ' + $f.Directory.Name.PadRight(6) + '\' + $f.Name.PadRight(30) + ('{0,10:N0}' -f $f.Length) + $mark)
  }

  Step '同名冲突检查'
  # seguiemj.ttf 是系统原版，必须保留（DirectWrite 回退用），不算冲突
  # 真正的冲突是「多个 segoeemj*.ttf 补丁文件共用同一家族名」
  $patches=@($emojiFiles | Where-Object { $_.Name -match '(?i)^segoeemj' })
  $orig=@($emojiFiles | Where-Object { $_.Name -eq 'seguiemj.ttf' })
  if($patches.Count -gt 1){
    Warn ('有 ' + $patches.Count + ' 个补丁文件共用同一家族名，DirectWrite 选择不确定：')
    foreach($d in $patches){ Say ('    ' + $d.Name) }
    Warn '运行 install 会自动清理多余补丁'
  } elseif($patches.Count -eq 1){
    Ok ('补丁唯一: ' + $patches[0].Name)
  } else {
    Warn '未安装补丁（当前用系统原版）'
  }
  if($orig.Count -gt 0){ Ok ('系统原版存在: ' + $orig[0].Name) } else { Warn '系统原版 seguiemj.ttf 缺失！' }
  Step '待重启清理'
  $pend=(Get-ItemProperty -Path $PendingKey -Name PendingFileRenameOperations -EA SilentlyContinue).PendingFileRenameOperations
  $fp=@(); if($pend){ $fp=@($pend | Where-Object { $_ -and ($_.Contains('segoeemj') -or $_.Contains('seguiemj')) }) }
  if($fp.Count -gt 0){ Warn ('有 ' + $fp.Count + ' 项等待重启：'); foreach($x in $fp){ Say ('    '+$x) } }
  else { Ok '无待重启操作' }

  Step '文件检查'
  $patch=Join-Path $CoreDir 'segoeemj_patched.ttf'
  if(Test-Path $patch){ Ok ('补丁字体: segoeemj_patched.ttf (' + ('{0:N0}' -f (Get-Item $patch).Length) + ' 字节)') }
  else { Fail '补丁字体缺失（core\segoeemj_patched.ttf）' }

  if(Test-Path $BackupFile){
    Ok ('原版备份: backup\seguiemj_original.ttf (' + ('{0:N0}' -f (Get-Item $BackupFile).Length) + ' 字节)')
  } else {
    Warn '尚未备份系统原版（首次 install 时会自动备份）'
  }
}

function Do-Install([string]$Mode) {
  $map=@{
    install=@{F='segoeemj_patched.ttf'; D='地区旗帜修复版（全 emoji + 259 面地区旗帜）'; T='segoeemj.ttf'; From='core'}
    restore=@{F='seguiemj_original.ttf'; D='系统原版（从备份还原）'; T=$null; From='backup'}
  }
  $c=$map[$Mode]
  $src = if ($c.From -eq 'backup') { $BackupFile } else { Join-Path $CoreDir $c.F }
  Step ('任务: '+$c.D)
  Say ('  源: '+$c.F+'  ('+('{0:N0}' -f (Get-Item $src).Length)+' 字节)')

  Step '停止字体缓存与相关进程'
  Stop-FC; Stop-Shell; Start-Sleep -Seconds 4
  Ok '已停止'

  # 清理所有补丁字体
  # ---- 1. 备份系统原版（首次安装时）----
  if($Mode -eq 'install'){
    Step '备份系统原版'
    if (-not (Backup-OriginalFont)) {
      Fail '备份失败，为安全起见已中止安装'
      Start-FC; Start-Shell
      exit 1
    }
  }

  # ---- 2. 执行安装或还原 ----
  if($Mode -eq 'restore'){
    Step '从备份还原系统原版'
    if(-not(Test-Path $BackupFile)){
      Fail '没有备份文件，无法还原'
      Say '  请先运行一次 install（会自动备份），或手动放置 backup\seguiemj_original.ttf' 'Yellow'
      Start-FC; Start-Shell
      exit 1
    }
    $tgt=Join-Path $FontsDir 'seguiemj.ttf'
    try{ takeown /f ('"'+$tgt+'"') 2>&1|Out-Null }catch{}
    try{ icacls ('"'+$tgt+'"') /grant ('"'+$env:USERNAME+':(F)"') 2>&1|Out-Null }catch{}
    $done=$false
    for($i=1;$i -le 6;$i++){
      try{ Copy-Item $BackupFile $tgt -Force -EA Stop; if((Get-Item $tgt).Length -eq (Get-Item $BackupFile).Length){$done=$true;break} }catch{ Start-Sleep -Seconds 2 }
    }
    if($done){ Ok ('已还原 ('+('{0:N0}' -f (Get-Item $tgt).Length)+' 字节)') }
    else{ Fail '文件被占用，请重启后再运行一次 restore' ; Start-FC; Start-Shell; exit 1 }
    Set-ItemProperty -Path $FontReg -Name $RegName -Value 'seguiemj.ttf'
    Ok '注册表 -> seguiemj.ttf'
  }
  else {
    Step ('安装为 ' + $c.T)
    $activeName = (Get-Item $FontReg).GetValue($RegName)
    $tgt = Join-Path $FontsDir $c.T
    $skipCopy = $false
    # 若目标已存在且大小一致，说明已是当前版本，无需重复安装
    if((Test-Path $tgt) -and ((Get-Item $tgt).Length -eq (Get-Item $src).Length)){
      $sameHash = $false
      try{
        $h1 = (Get-FileHash $tgt -Algorithm MD5).Hash
        $h2 = (Get-FileHash $src -Algorithm MD5).Hash
        $sameHash = ($h1 -eq $h2)
      } catch { }
      if($sameHash){
        Ok ('已是当前版本，无需重复安装 (' + ('{0:N0}' -f (Get-Item $tgt).Length) + ' 字节)')
        Set-ItemProperty -Path $FontReg -Name $RegName -Value $c.T
        Ok ('注册表 -> ' + $c.T)
        $skipCopy = $true
      }
    }
    if(-not $skipCopy){
      $copied = $false
      for($i=1;$i -le 3;$i++){
        try{
          Copy-Item $src $tgt -Force -EA Stop
          if((Get-Item $tgt).Length -eq (Get-Item $src).Length){ $copied=$true; break }
        } catch { Start-Sleep -Seconds 2 }
      }

      # 关键：旧版本字体正在被系统使用，无法覆盖（升级场景常见）
      # 改用新文件名安装，并切换注册表指向
      if(-not $copied){
        Warn ($c.T + ' 被系统占用，改用新文件名安装')
        $altName = $null
        for($n=2; $n -le 9; $n++){
          $candidate = 'segoeemj_v' + $n + '.ttf'
          $candidatePath = Join-Path $FontsDir $candidate
          # 找出一个未被注册表指向、且能写入的名字
          if($candidate -eq $activeName){ continue }
          $wrote = $false
          for($k=1; $k -le 2; $k++){
            try{
              if(Test-Path $candidatePath){ Remove-Item $candidatePath -Force -EA Stop }
              Copy-Item $src $candidatePath -Force -EA Stop
              if((Get-Item $candidatePath).Length -eq (Get-Item $src).Length){ $wrote = $true; break }
            } catch { Start-Sleep -Seconds 1 }
          }
          if($wrote){ $altName = $candidate; $tgt = $candidatePath; break }
        }
        if(-not $altName){
          Fail '无法写入字体目录'
          Say ''
          Say '  请以管理员身份重新运行，或重启后再试' 'Yellow'
          Start-FC; Start-Shell
          Read-Host '按 Enter 退出' | Out-Null
          exit 1
        }
        $c.T = $altName
        $copied = $true
        Ok ('已写入新文件: ' + $altName)
      }

      if($copied){
        Ok ('已写入 (' + ('{0:N0}' -f (Get-Item $tgt).Length) + ' 字节)')
        Set-ItemProperty -Path $FontReg -Name $RegName -Value $c.T
        Ok ('注册表 -> ' + $c.T)
      }
    }
  }
  # ---- 3. 清理多余补丁（严格保护正在生效的文件）----
  Step '清理多余补丁'
  $activeFile = (Get-Item $FontReg).GetValue($RegName)
  Ok ('当前生效: ' + $activeFile)
  $removed = 0
  foreach($f in Get-ChildItem $FontsDir -Filter 'segoeemj*.ttf' -EA SilentlyContinue){
    # 绝不删除注册表正在指向的文件
    if($f.Name -eq $activeFile){
      Say ('  保留生效文件: ' + $f.Name) 'DarkGray'
      continue
    }
    try{
      Remove-Item $f.FullName -Force -EA Stop
      $removed++
      Ok ('删除多余: '+$f.Name)
    }
    catch{
      if(Queue-Delete $f.FullName){ Warn ('登记重启删除: '+$f.Name) } else { Warn ('占用中，暂不处理: '+$f.Name) }
    }
  }
  if($removed -eq 0){ Ok '无多余补丁' }

  # 安全检查：确认生效文件确实存在
  $activePath = Join-Path $FontsDir $activeFile
  if(-not (Test-Path $activePath)){
    Fail ('严重错误：注册表指向的 ' + $activeFile + ' 不存在！')
    Say '  正在回滚注册表...' 'Yellow'
    $fb = Get-ChildItem $FontsDir -Filter 'segoeemj*.ttf' -EA SilentlyContinue | Select-Object -First 1
    if($fb){
      Set-ItemProperty -Path $FontReg -Name $RegName -Value $fb.Name
      Ok ('已改为指向: ' + $fb.Name)
    } else {
      Set-ItemProperty -Path $FontReg -Name $RegName -Value 'seguiemj.ttf'
      Warn '已回退到系统原版（emoji 将显示为黑白，但不会缺失）'
    }
  } else {
    Ok ('生效文件已确认存在 (' + ('{0:N0}' -f (Get-Item $activePath).Length) + ' 字节)')
  }

  Step '恢复环境'
  Start-FC; Start-Shell
  Ok '已恢复'

  Step '结果'
  $reg=(Get-Item $FontReg).GetValue($RegName)
  Ok ('生效字体: '+$reg)
  $ef=@()
  foreach($f in (Find-EmojiFonts)){ if((Get-FamilyName $f.FullName) -eq 'Segoe UI Emoji'){ $ef += $f } }
  foreach($f in $ef){ $m=''; if($f.Name -eq $reg){$m='  <- 生效'}; Say ('  '+$f.Name.PadRight(24)+('{0,10:N0}' -f $f.Length)+$m) }
  return $true
}

function Show-Menu {
  Say ''
  Say '=========================================' 'Cyan'
  Say '  Windows 11 地区旗帜 Emoji 修复工具' 'Cyan'
  Say '=========================================' 'Cyan'
  Say ''
  $reg = (Get-Item $FontReg).GetValue($RegName)
  $hasBackup = Test-Path $BackupFile
  Say ('  当前生效: ' + $reg) 'Gray'
  if ($hasBackup) {
    Say ('  原版备份: 已存在 (' + ('{0:N0}' -f (Get-Item $BackupFile).Length) + ' 字节)') 'DarkGray'
  } else {
    Say '  原版备份: 尚无（首次安装时自动创建）' 'DarkGray'
  }
  Say ''
  Say '-----------------------------------------'
  Say '   [1] 安装修复版字体'
  Say '       -> 全 emoji + 259 面地区旗帜'
  Say '       -> 自动先备份原版'
  Say ''
  Say '   [2] 还原系统原版字体'
  Say '       -> 从备份恢复（需先备份过）'
  Say ''
  Say '   [3] 查看当前状态'
  Say '       -> 只诊断，不做任何修改'
  Say ''
  Say '   [0] 退出'
  Say '-----------------------------------------'
  Say ''
  while ($true) {
    $choice = Read-Host '请输入选项 (1/2/3/0)'
    switch ($choice.Trim()) {
      '1' { return 'install' }
      '2' { return 'restore' }
      '3' { return 'diagnose' }
      '0' { return 'exit' }
      default { Say '  无效选项，请重新输入' 'Yellow' }
    }
  }
}

# ---- 分发处理 ----
$action = if ($Action -eq 'menu') { Show-Menu } else { $Action }
if (-not $action -or $action -eq 'exit') { exit 0 }

# 诊断：不需要管理员，直接跑
if ($action -eq 'diagnose') {
  Show-Diagnose
  Say ''
  Say '诊断完成（未做任何修改）' 'Cyan'
  Read-Host '按 Enter 退出' | Out-Null
  exit 0
}

# 还原前必须有备份
if ($action -eq 'restore' -and -not (Test-Path $BackupFile)) {
  Say ''
  Warn '尚未备份系统原版，无法还原'
  Say ''
  Say '  请先执行一次「安装」—— 安装流程会自动备份原版字体。' 'Yellow'
  Say ''
  Read-Host '按 Enter 退出' | Out-Null
  exit 1
}

# 安装 / 还原都需要管理员
if (-not (Test-Admin)) {
  Say ''
  Say '需要管理员权限，正在请求提权...' 'Yellow'
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'), $action)
  if ($NoRestart) { $argList += '-NoRestart' }
  $elevated = $false
  try {
    $proc = Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait -PassThru -EA Stop
    $elevated = $true
    if ($proc -and $proc.ExitCode -ne 0) {
      Say ''
      # 0xC000013A = 用户按了 Ctrl+C 或关闭了窗口，不算错误
      if ($proc.ExitCode -eq -1073741510) {
        Warn '管理员窗口被关闭（按了 Ctrl+C 或点了关闭按钮）'
        Say '  操作可能未完成，建议重新运行一次。' 'Yellow'
      } else {
        Warn ('管理员进程退出码: ' + $proc.ExitCode + ' (0x' + ('{0:X8}' -f $proc.ExitCode) + ')')
        Say '  操作未成功完成，请查看日志或反馈问题。' 'Yellow'
      }
    } else {
      Say ''
      Say '操作已完成。' 'Green'
    }
  } catch {
    Fail '提权失败或被取消'
    Say ''
    Say '  可能原因：' 'Yellow'
    Say '    1. 在 UAC 提示里点了「否」' 'Gray'
    Say '    2. 当前账户不是管理员账户' 'Gray'
    Say '    3. 组策略禁止提权' 'Gray'
    Say ''
    Say '  建议：右键 启动.cmd -> 以管理员身份运行' 'Cyan'
    Read-Host '按 Enter 退出' | Out-Null
    exit 1
  }
  exit
}

$result = Do-Install $action

Say ''
Say '=========================================' 'Green'
Say '  完成！重启后所有程序才会生效' 'Green'
Say '=========================================' 'Green'
Say ''
Say '重启后请检查：开始菜单 / 文件管理器 / 记事本' 'Gray'
if (-not $NoRestart) {
  Say ''
  $answer = Read-Host '现在重启吗？(Y/n)'
  if ($answer -eq '' -or $answer -match '^[Yy]') {
    Say '正在重启...' 'Yellow'
    Start-Sleep -Seconds 2
    Restart-Computer -Force
  } else {
    Say ''
    Say '请稍后手动重启。' 'Yellow'
    Read-Host '按 Enter 退出' | Out-Null
  }
} else {
  Read-Host '按 Enter 退出' | Out-Null
}
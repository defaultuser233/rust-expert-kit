#Requires -Version 5.1
<#
.SYNOPSIS
    一键恢复 / 检查 Rust 开发环境（Windows）

.DESCRIPTION
    幂等脚本 —— 已装好的部分会跳过，只补缺失的，可安全重复运行。

    做这些事：
      1. 决定安装位置（默认 %USERPROFILE%\Rust，无需管理员权限）
      2. 配置镜像（auto 会实测延迟选最快）
      3. 设置 RUSTUP_HOME / CARGO_HOME / PATH
      4. 安装或修复 rustup 与 stable 工具链（含 clippy / rustfmt）
      5. 写 cargo 的 crates.io 镜像 配置
      6. 检查 PSReadLine（VS Code shell integration 需要 2.1+）
      7. 端到端验证：新建临时项目、拉真实依赖、编译、跑 clippy

.PARAMETER InstallRoot
    工具链安装根目录。
    默认：%USERPROFILE%\Rust（用户目录，通用且无需管理员权限）
    想放到数据盘：-InstallRoot "D:\software\Rust"

.PARAMETER Mirror
    auto（默认，实测延迟）/ tuna / rsproxy / ustc / none（官方源）

.PARAMETER SkipVerify
    跳过端到端编译验证

.PARAMETER SkipPsReadLine
    跳过 PSReadLine 检查

.EXAMPLE
    .\setup-rust.ps1
    .\setup-rust.ps1 -InstallRoot "E:\Dev\Rust" -Mirror rsproxy
    .\setup-rust.ps1 -SkipVerify -SkipPsReadLine
#>
[CmdletBinding()]
param(
    [string] $InstallRoot,
    [ValidateSet('auto', 'tuna', 'rsproxy', 'ustc', 'none')]
    [string] $Mirror = 'auto',
    [switch] $SkipVerify,
    [switch] $SkipPsReadLine
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # 让 Invoke-WebRequest 快很多

# 控制台用 UTF-8，避免中文乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ─────────────────────────────────────────────────────────────
# 输出 helper（只用 ASCII 符号，避免终端字体缺字）
# ─────────────────────────────────────────────────────────────
$script:StepNo = 0
function Step($msg) {
    $script:StepNo++
    Write-Host ''
    Write-Host ("-" * 64) -ForegroundColor DarkGray
    Write-Host (" [{0}] {1}" -f $script:StepNo, $msg) -ForegroundColor Cyan
    Write-Host ("-" * 64) -ForegroundColor DarkGray
}
function Ok($msg)   { Write-Host "  [ok] $msg" -ForegroundColor Green }
function Info($msg) { Write-Host "  [..] $msg" -ForegroundColor Gray }
function Warn($msg) { Write-Host "  [!!] $msg" -ForegroundColor Yellow }
function Bad($msg)  { Write-Host "  [xx] $msg" -ForegroundColor Red }

# 安全执行原生命令：
# 关键 —— 原生命令（rustup/cargo）会把进度写到 stderr，
# PowerShell 会把它包成 ErrorRecord，配合 $ErrorActionPreference='Stop' 会直接中止脚本。
# 所以执行期间临时切到 Continue，并返回输出 + 退出码。
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]   $Exe,
        [Parameter(ValueFromRemainingArguments)][string[]] $Args,
        [switch] $Quiet
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Args 2>&1
        $code = $LASTEXITCODE
        if (-not $Quiet) {
            foreach ($line in @($out)) { Info "$line" }
        }
        return [pscustomobject]@{ Output = @($out); ExitCode = $code }
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

# ─────────────────────────────────────────────────────────────
# 1. 安装位置
# ─────────────────────────────────────────────────────────────
Step '确定安装位置'

if (-not $InstallRoot) {
    # 默认放用户目录：通用、无需管理员权限、不依赖某个盘符是否存在
    $InstallRoot = Join-Path $env:USERPROFILE 'Rust'
    Info "默认安装位置：$InstallRoot"
    if (Test-Path 'D:\') {
        Info "检测到 D: 盘。如需把工具链放到数据盘，用：-InstallRoot 'D:\software\Rust'"
    }
}
$RustupHome = Join-Path $InstallRoot 'rustup'
$CargoHome  = Join-Path $InstallRoot 'cargo'
Info "RUSTUP_HOME = $RustupHome"
Info "CARGO_HOME  = $CargoHome"

# ─────────────────────────────────────────────────────────────
# 2. 镜像选型
# ─────────────────────────────────────────────────────────────
Step '选择镜像'

$mirrorMap = [ordered]@{
    'tuna'    = 'https://mirrors.tuna.tsinghua.edu.cn/rustup'
    'rsproxy' = 'https://rsproxy.cn'
    'ustc'    = 'https://mirrors.ustc.edu.cn/rust-static'
}
$DistServer  = $null
$CratesIndex = $null

if ($Mirror -eq 'none') {
    Info '使用官方源（static.rust-lang.org / crates.io）'
}
else {
    $chosen = $Mirror
    if ($Mirror -eq 'auto') {
        Info '实测各镜像延迟…'
        $best = $null; $bestMs = [int]::MaxValue
        foreach ($name in $mirrorMap.Keys) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                Invoke-WebRequest "$($mirrorMap[$name])/dist/channel-rust-stable.toml" `
                    -TimeoutSec 15 -UseBasicParsing | Out-Null
                $sw.Stop()
                $ms = [int]$sw.ElapsedMilliseconds
                Info ("  {0,-8} {1,6} ms" -f $name, $ms)
                if ($ms -lt $bestMs) { $bestMs = $ms; $best = $name }
            }
            catch {
                Warn ("  {0,-8} 不可达" -f $name)
            }
        }
        if ($best) { $chosen = $best; Info "选中 -> $best ($bestMs ms)" }
        else       { $chosen = 'none'; Warn '国内镜像全部不可达 -> 改用官方源' }
    }

    if ($chosen -ne 'none') {
        $DistServer = $mirrorMap[$chosen]
        # crates.io：只有 rsproxy 的下载也走自家 CDN；其它镜像的 dl 仍指向国外
        $CratesIndex = 'sparse+https://rsproxy.cn/index/'
        if ($chosen -ne 'rsproxy') {
            Info "rustup 用 $chosen；crates.io 用 rsproxy（下载走国内 CDN）"
        }
    }
}

# ─────────────────────────────────────────────────────────────
# 3. 环境变量
# ─────────────────────────────────────────────────────────────
Step '设置环境变量'

foreach ($key in @('RUSTUP_HOME', 'CARGO_HOME')) {
    $val = if ($key -eq 'RUSTUP_HOME') { $RustupHome } else { $CargoHome }
    if ([Environment]::GetEnvironmentVariable($key, 'User') -eq $val) {
        Ok "$key 已是目标值"
    }
    else {
        [Environment]::SetEnvironmentVariable($key, $val, 'User')
        Ok "$key -> $val"
    }
    Set-Item -Path "Env:$key" -Value $val
}

if ($DistServer) {
    [Environment]::SetEnvironmentVariable('RUSTUP_DIST_SERVER', $DistServer, 'User')
    [Environment]::SetEnvironmentVariable('RUSTUP_UPDATE_ROOT', "$DistServer/rustup", 'User')
    Set-Item -Path 'Env:RUSTUP_DIST_SERVER' -Value $DistServer
    Set-Item -Path 'Env:RUSTUP_UPDATE_ROOT' -Value "$DistServer/rustup"
    Ok "RUSTUP_DIST_SERVER -> $DistServer"
}
else {
    [Environment]::SetEnvironmentVariable('RUSTUP_DIST_SERVER', $null, 'User')
    [Environment]::SetEnvironmentVariable('RUSTUP_UPDATE_ROOT', $null, 'User')
    Remove-Item 'Env:RUSTUP_DIST_SERVER' -ErrorAction SilentlyContinue
    Remove-Item 'Env:RUSTUP_UPDATE_ROOT'  -ErrorAction SilentlyContinue
    Ok '已清除镜像变量（走官方源）'
}

# PATH：加 cargo\bin，并清理指向旧位置的死路径（备份后再改）
$cargoBin = Join-Path $CargoHome 'bin'
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$items    = @($userPath -split ';' | Where-Object { $_ -ne '' })
$stale    = @($items | Where-Object { $_ -match '\\\.cargo\\bin$' -and $_ -ne $cargoBin })

if ($stale.Count -gt 0) {
    $backup = Join-Path $env:TEMP ("user-path-backup-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [System.IO.File]::WriteAllText($backup, $userPath, (New-Object System.Text.UTF8Encoding($false)))
    Info "已备份原 User PATH -> $backup"
    foreach ($s in $stale) {
        $items = @($items | Where-Object { $_ -ne $s })
        Warn "从 User PATH 移除旧路径: $s"
    }
}

if ($items -notcontains $cargoBin) {
    $items = @($cargoBin) + $items
    Ok "User PATH += $cargoBin"
}
else { Ok "User PATH 已含 $cargoBin" }

[Environment]::SetEnvironmentVariable('PATH', ($items -join ';'), 'User')
$env:PATH = "$cargoBin;" + $env:PATH

# ─────────────────────────────────────────────────────────────
# 4. rustup
# ─────────────────────────────────────────────────────────────
Step '安装 / 检查 rustup'

$rustupExe = Join-Path $cargoBin 'rustup.exe'

if (Test-Path $rustupExe) {
    Ok 'rustup 已存在'
}
else {
    $initUrl = if ($DistServer) {
        "$DistServer/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe"
    } else {
        'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe'
    }
    $initExe = Join-Path $env:TEMP 'rustup-init.exe'
    Info "下载 $initUrl"
    try {
        Invoke-WebRequest $initUrl -OutFile $initExe -UseBasicParsing
        Ok "已下载 $([math]::Round((Get-Item $initExe).Length / 1MB, 1)) MB"
    }
    catch {
        Bad "下载失败：$($_.Exception.Message)"
        throw '无法下载 rustup-init.exe。若在中国大陆，请用 -Mirror 指定镜像。'
    }

    Info '静默安装（-y --no-modify-path，PATH 由本脚本管理）'
    $r = Invoke-Native $initExe '-y' '--no-modify-path' '--default-toolchain' 'none'
    Remove-Item $initExe -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $rustupExe)) { throw 'rustup 安装后仍未找到可执行文件' }
    Ok 'rustup 安装完成'
}

# ─────────────────────────────────────────────────────────────
# 5. stable 工具链
# ─────────────────────────────────────────────────────────────
Step '安装 stable 工具链（含 clippy / rustfmt）'
Info '（首次安装约 130 MB）'

$r = Invoke-Native 'rustup' 'toolchain' 'install' 'stable' '--profile' 'default' '-c' 'rustfmt' '-c' 'clippy'
if ($r.ExitCode -ne 0) { Warn "rustup toolchain install 退出码 $($r.ExitCode)" }
$r = Invoke-Native 'rustup' 'default' 'stable'

# 若之前是损坏状态，强制重装一次
$probe = ((Invoke-Native 'rustc' '--version' -Quiet).Output) -join ' '
if ($probe -notmatch '^rustc \d') {
    Warn "工具链异常：$probe"
    Warn '尝试强制重装…'
    $r = Invoke-Native 'rustup' 'toolchain' 'install' 'stable' '--force' '--profile' 'default' '-c' 'rustfmt' '-c' 'clippy'
    $probe = ((Invoke-Native 'rustc' '--version' -Quiet).Output) -join ' '
}
if ($probe -match '^rustc \d') { Ok $probe } else { Bad "rustc 仍不可用：$probe" }

# ─────────────────────────────────────────────────────────────
# 6. cargo 的 crates.io 镜像
# ─────────────────────────────────────────────────────────────
Step '配置 crates.io 镜像'

$cargoConfig = Join-Path $CargoHome 'config.toml'

if ($CratesIndex) {
    $content = @"
# 由 setup-rust.ps1 生成 -- 国内镜像加速
# 索引与下载均走 rsproxy CDN（其它国内镜像的 dl 仍指向国外）

[source.crates-io]
replace-with = "rsproxy-sparse"

[source.rsproxy-sparse]
registry = "$CratesIndex"

[registries.rsproxy]
index = "$CratesIndex"

[net]
git-fetch-with-cli = true
retry = 3
"@
    if ((Test-Path $cargoConfig) -and
        ((Get-Content $cargoConfig -Raw -Encoding UTF8) -eq $content)) {
        Ok 'config.toml 内容已是最新'
    }
    else {
        # 必须写「无 BOM 的 UTF-8」：PS 5.1 的 Set-Content -Encoding UTF8 会加 BOM，
        # 而 cargo 解析带 BOM 的 TOML 可能失败
        [System.IO.File]::WriteAllText($cargoConfig, $content, (New-Object System.Text.UTF8Encoding($false)))
        Ok "已写入 $cargoConfig（UTF-8 无 BOM）"
    }
}
else {
    if (Test-Path $cargoConfig) { Remove-Item $cargoConfig -Force; Ok '已移除镜像配置（走官方源）' }
    else { Ok '无需镜像配置' }
}

# ─────────────────────────────────────────────────────────────
# 7. PSReadLine（可选）
# ─────────────────────────────────────────────────────────────
if (-not $SkipPsReadLine) {
    Step '检查 PSReadLine'

    $psrl = Get-Module PSReadLine -ListAvailable |
            Sort-Object Version -Descending | Select-Object -First 1
    if ($psrl) {
        Info "当前最高版本：$($psrl.Version)"
        $sup = (& powershell -NoProfile -Command `
            "Import-Module PSReadLine; (Get-Command Get-PSReadLineKeyHandler).Parameters.ContainsKey('Chord')" 2>&1) -join ''
        if ($sup -match 'True') {
            Ok '支持 -Chord，无问题'
        }
        else {
            Warn 'Get-PSReadLineKeyHandler 缺少 -Chord：VS Code shell integration 会静默报错'
            Info '安装 PSReadLine 2.3.6（用户级）…'
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Install-Module PSReadLine -RequiredVersion 2.3.6 -Scope CurrentUser `
                    -Force -SkipPublisherCheck -AllowClobber -ErrorAction Stop
                Ok 'PSReadLine 2.3.6 安装完成'
            }
            catch { Warn "安装失败（不影响 rustup 环境）：$($_.Exception.Message)" }
        }
    }
    else { Warn 'PSReadLine 未找到，跳过' }
}

# ─────────────────────────────────────────────────────────────
# 8. 端到端验证
# ─────────────────────────────────────────────────────────────
if (-not $SkipVerify) {
    Step '端到端验证'

    $tmp = Join-Path $env:TEMP ("rust-verify-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        Info "创建临时项目：$tmp"
        $r = Invoke-Native 'cargo' 'new' $tmp '--bin' '-q'
        if ($r.ExitCode -ne 0) { throw 'cargo new 失败' }

        Push-Location $tmp
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Info '拉取依赖 serde…'
            $r = Invoke-Native 'cargo' 'add' 'serde' '--features' 'derive' '-q'
            $sw.Stop()
            if ($r.ExitCode -eq 0) { Ok "cargo add 成功（$([int]$sw.Elapsed.TotalSeconds)s）" }
            else { Warn "cargo add 退出码 $($r.ExitCode)" }

            $sw = [Diagnostics.Stopwatch]::StartNew()
            Info '编译…'
            $r = Invoke-Native 'cargo' 'build' '-q' -Quiet
            $sw.Stop()
            if ($r.ExitCode -eq 0) { Ok "cargo build 成功（$([int]$sw.Elapsed.TotalSeconds)s）" }
            else { Bad "cargo build 失败（退出码 $($r.ExitCode)）"; $r.Output | ForEach-Object { Info $_ } }

            $r = Invoke-Native 'cargo' 'clippy' '--all-targets' -Quiet
            if ($r.ExitCode -eq 0) { Ok 'cargo clippy 通过' } else { Warn "cargo clippy 退出码 $($r.ExitCode)" }

            $r = Invoke-Native 'cargo' 'fmt' '--check' -Quiet
            Ok 'cargo fmt 可执行'
            $r = Invoke-Native 'cargo' 'test' '-q' -Quiet
            Ok 'cargo test 可执行'
        }
        finally { Pop-Location }
    }
    catch { Bad "验证失败：$($_.Exception.Message)" }
    finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ─────────────────────────────────────────────────────────────
# 汇总
# ─────────────────────────────────────────────────────────────
Step '完成'

Write-Host ''
Info "RUSTUP_HOME = $RustupHome"
Info "CARGO_HOME  = $CargoHome"
Info "PATH        = $cargoBin"
Write-Host ''
Ok ((Invoke-Native 'rustc'   '--version' -Quiet).Output -join '')
Ok ((Invoke-Native 'cargo'   '--version' -Quiet).Output -join '')
Ok ((Invoke-Native 'rustfmt' '--version' -Quiet).Output -join '')
$cl = (Invoke-Native 'cargo' 'clippy' '--version' -Quiet).Output -join ''
if ($cl -match 'clippy') { Ok $cl } else { Warn 'clippy 不可用' }
Write-Host ''
if ($DistServer)  { Info "镜像 rustup     : $DistServer" }
if ($CratesIndex) { Info "镜像 crates.io  : $CratesIndex" }
Write-Host ''
Warn '若当前 VS Code 终端未生效，请重启 VS Code（环境变量需新进程才能读到）'
Write-Host ''

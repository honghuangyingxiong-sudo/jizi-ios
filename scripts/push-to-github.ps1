<#
  一条命令：建仓库 -> 推源码 -> 等 GitHub 云端 Mac 编译 -> 把 IPA 拉回本地。

  用法：
    powershell -ExecutionPolicy Bypass -File scripts\push-to-github.ps1 -User 你的用户名 -Token ghp_xxxxxxxx

  Token 去哪弄：https://github.com/settings/tokens -> Tokens (classic) -> Generate new token (classic)
    勾 repo 和 workflow 两项即可。有效期设 7 天。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$Repo = "jizi-ios",
    [string]$Branch = "main",
    [switch]$SkipWait
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# PS 5.1 默认的 TLS 1.0 会被 GitHub 直接拒掉
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "    $m" -ForegroundColor DarkGray }

# --- 找 git ---
$git = "git"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $candidates = @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"
    )
    $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($found) { $git = $found } else { throw "找不到 git，先装 Git for Windows 再重开一个终端。" }
}
Say ("git = " + $git)

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "jizi-build"
}

function Api {
    param([string]$Uri, [string]$Method = "GET", $Body = $null)
    if ($Body) {
        return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers -Body $Body -ContentType "application/json"
    }
    return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers
}

# ---------- 0. token 是谁的 ----------
Say "验证 token"
$me = Api "https://api.github.com/user"
if ($me.login -ne $User) {
    Warn ("注意：token 属于 '" + $me.login + "'，你填的是 '" + $User + "'，按 token 的归属继续。")
    $User = $me.login
}

# ---------- 1. 仓库 ----------
$repoExists = $true
try { Api "https://api.github.com/repos/$User/$Repo" | Out-Null } catch { $repoExists = $false }

if ($repoExists) {
    Say "仓库已存在：$User/$Repo"
}
else {
    Say "创建仓库 $User/$Repo"
    $body = @{ name = $Repo; private = $false; auto_init = $false } | ConvertTo-Json -Compress
    try {
        Api "https://api.github.com/user/repos" "POST" $body | Out-Null
    }
    catch {
        throw ("建仓库失败：" + $_.Exception.Message + " —— 多半是 token 少了建仓库的权限，或者自己在网页上先建一个空的 " + $Repo + " 仓库再来。")
    }
    Start-Sleep -Seconds 3
}

# ---------- 2. 推源码 ----------
Say "提交并推送"

# PS 5.1 里 $ErrorActionPreference='Stop' 会把 git 写到 stderr 的任何东西
# （包括无害的 "No such remote"）变成终止性错误，所以原生命令一律单独跑并查退出码。
function Invoke-Git {
    param([string[]]$Args)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = & $git @Args 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    foreach ($line in $out) { Warn $line }
    return $code
}

if (-not (Test-Path ".git")) {
    [void](Invoke-Git @("init"))
    [void](Invoke-Git @("branch", "-M", $Branch))
}

[void](Invoke-Git @("add", "-A"))
[void](Invoke-Git @("-c", "user.name=$User", "-c", "user.email=$User@users.noreply.github.com",
                   "commit", "-m", "JiZi 1.0.0"))

$remoteUrl = "https://github.com/$User/$Repo.git"
$remoteList = ""
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$remoteList = & $git remote 2>&1
$ErrorActionPreference = $prevEap

if ($remoteList -contains "origin") {
    [void](Invoke-Git @("remote", "set-url", "origin", $remoteUrl))
}
else {
    [void](Invoke-Git @("remote", "add", "origin", $remoteUrl))
}

$pushCode = Invoke-Git @("push", "-u", "origin", $Branch, "--force")
if ($pushCode -ne 0) { throw "push 失败（退出码 $pushCode），检查 token 的 Contents 权限。" }

$actionsUrl = "https://github.com/$User/$Repo/actions"
if ($SkipWait) { Say "已推送，编译看这里：$actionsUrl"; return }

# ---------- 3. 等编译 ----------
Say "等云端 Mac 编译（第一次一般 4-8 分钟）"
$runId = $null
$conclusion = $null
for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Seconds 10
    try {
        $runs = Api "https://api.github.com/repos/$User/$Repo/actions/runs?branch=$Branch&per_page=1"
    }
    catch { Warn "查询失败，重试 ..."; continue }

    if ($runs.total_count -gt 0) {
        $r = $runs.workflow_runs[0]
        if ($r.status -eq "completed") { $runId = $r.id; $conclusion = $r.conclusion; break }
        Warn ("状态：" + $r.status)
    }
    else {
        Warn "还没排上队 ..."
    }
}

if (-not $runId) { Say "等超时了，自己去网页看：$actionsUrl"; return }

if ($conclusion -ne "success") {
    Write-Host ""
    Say ("编译失败（" + $conclusion + "）")
    Write-Host "打开这个链接，把带 error: 的行发给 AI 修：" -ForegroundColor Yellow
    Write-Host "https://github.com/$User/$Repo/actions/runs/$runId" -ForegroundColor Yellow
    return
}

# ---------- 4. 拉 IPA ----------
Say "编译成功，下载产物"
$arts = Api "https://api.github.com/repos/$User/$Repo/actions/runs/$runId/artifacts"
if ($arts.total_count -eq 0) {
    Say "没找到 artifact，去网页看看：https://github.com/$User/$Repo/actions/runs/$runId"
    return
}

$zip = Join-Path $root "JiZi-unsigned.zip"
$out = Join-Path $root "ipa-out"
if (Test-Path $zip) { Remove-Item $zip -Force }
if (Test-Path $out) { Remove-Item $out -Recurse -Force }

# artifact 会 302 到签名地址。签名地址不需要 token，但跟着跳转会把认证头丢掉，所以手动跟一次。
$url = $arts.artifacts[0].archive_download_url
$req = [System.Net.HttpWebRequest]::Create($url)
$req.Method = "GET"
$req.UserAgent = "jizi-build"                      # User-Agent 是受限头，必须走属性
$req.Headers.Add("Authorization", "Bearer $Token") # Authorization 可以走 Headers
$req.AllowAutoRedirect = $false

$resp = $null
try { $resp = $req.GetResponse() }
catch [System.Net.WebException] { $resp = $_.Exception.Response }

if ($null -eq $resp) { throw "下载 artifact 失败：拿不到响应。" }

$loc = $resp.Headers["Location"]
if ([string]::IsNullOrEmpty($loc)) {
    $stream = $resp.GetResponseStream()
    $fs = [IO.File]::Create($zip)
    $stream.CopyTo($fs)
    $fs.Close(); $stream.Close(); $resp.Close()
}
else {
    $resp.Close()
    Invoke-WebRequest -Uri $loc -OutFile $zip -UseBasicParsing
}

Expand-Archive -Path $zip -DestinationPath $out -Force
$ipa = Get-ChildItem $out -Recurse -Filter *.ipa | Select-Object -First 1
if ($ipa) {
    $target = Join-Path $root "JiZi.ipa"
    Copy-Item $ipa.FullName $target -Force
    Write-Host ""
    Say ("搞定：" + $target)
    Warn ("大小：" + [math]::Round((Get-Item $target).Length / 1MB, 2) + " MB")
    Write-Host ""
    Write-Host "下一步：用 Sideloadly 把这个 IPA 签上你自己的 Apple ID 装进手机。" -ForegroundColor Green
    Write-Host "（免费 Apple ID 签名 7 天有效，过期重签一次）" -ForegroundColor DarkGray
}
else {
    Say ("解压后没找到 .ipa，看看 " + $out + " 里有什么")
}

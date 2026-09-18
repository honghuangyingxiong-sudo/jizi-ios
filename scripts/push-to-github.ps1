<#
  一条命令：建仓库 -> 推源码 -> 等 GitHub 云端 Mac 编译 -> 把 IPA 拉回本地。

  用法：
    powershell -ExecutionPolicy Bypass -File scripts\push-to-github.ps1 -User 你的用户名 -Token ghp_xxxxxxxx

  Token 去哪弄：https://github.com/settings/personal-access-tokens
    需要这几项 Repository permissions（细粒度 token）：
      Contents       Read and write   推源码
      Workflows      Read and write   推 .github/workflows/ 下的文件（少这项会被 GitHub 拒绝）
      Actions        Read and write   查编译状态、下载产物
      Administration Read and write   自动建仓库（不想给就自己在网页上先建空仓库）
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
$env:GIT_TERMINAL_PROMPT = "0"
$env:GCM_INTERACTIVE = "never"

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "    $m" -ForegroundColor DarkGray }

# ---------- 找 git ----------
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

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# ---------- git 助手 ----------
# 参数不能叫 $Args —— 那是 PowerShell 的自动变量，会让 @Args 展开成空，
# 结果 git 收到空参数、打印一堆帮助文档。（踩过的坑）
function Invoke-Git {
    param([string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = & $git @GitArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    foreach ($line in $out) { Warn ($line -replace [regex]::Escape($Token), "<TOKEN>") }
    return $code
}

$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "jizi-build"
}

function Api {
    param([string]$Uri, [string]$Method = "GET", $Body = $null)
    if ($Body) { return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers -Body $Body -ContentType "application/json" }
    return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers
}

# ---------- 0. token 是谁的 ----------
Say "验证 token"
$me = Api "https://api.github.com/user"
if ($me.login -ne $User) {
    Warn ("token 属于 '" + $me.login + "'，按它的归属继续。")
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
    try { Api "https://api.github.com/user/repos" "POST" $body | Out-Null }
    catch { throw ("建仓库失败：" + $_.Exception.Message + " —— 给 token 加 Administration 权限，或自己在网页上先建一个空的 " + $Repo + " 仓库。") }
    Start-Sleep -Seconds 3
}

# ---------- 2. 推源码 ----------
Say "提交并推送"

if (-not (Test-Path ".git")) {
    [void](Invoke-Git @("init"))
    [void](Invoke-Git @("branch", "-M", $Branch))
}

[void](Invoke-Git @("add", "-A"))
[void](Invoke-Git @("-c", "user.name=$User", "-c", "user.email=$User@users.noreply.github.com",
                   "commit", "-m", ("JiZi build " + (Get-Date -Format "yyyy-MM-dd HH:mm"))))

# 凭据放 URL 里 + 关掉凭据助手。
# 走 http.extraheader 的话细粒度 PAT 会拿到 401，然后 git 去叫 Git Credential Manager 弹窗，
# 没有交互界面就无限期挂住。（也踩过）
$pushUrl = "https://x-access-token:$Token@github.com/$User/$Repo.git"
$pushCode = Invoke-Git @("-c", "credential.helper=", "push", "-u", $pushUrl, $Branch, "--force")

if ($pushCode -ne 0) {
    throw "push 失败（退出码 $pushCode）。最常见原因：token 少了 Workflows 权限，而仓库里有 .github/workflows/ 下的文件。"
}

$actionsUrl = "https://github.com/$User/$Repo/actions"
if ($SkipWait) { Say "已推送，编译看这里：$actionsUrl"; return }

# ---------- 3. 等编译 ----------
Say "等云端 Mac 编译（第一次一般 4-8 分钟）"
$runId = $null
$conclusion = $null
for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Seconds 10
    try { $runs = Api "https://api.github.com/repos/$User/$Repo/actions/runs?branch=$Branch&per_page=1" }
    catch { Warn "查询失败，重试 ..."; continue }

    if ($runs.total_count -gt 0) {
        $r = $runs.workflow_runs[0]
        if ($r.status -eq "completed") { $runId = $r.id; $conclusion = $r.conclusion; break }
        Warn ("状态：" + $r.status)
    }
    else { Warn "还没排上队 ..." }
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
    Say "没找到 artifact：https://github.com/$User/$Repo/actions/runs/$runId"
    return
}

$zip = Join-Path $root "JiZi-unsigned.zip"
$out = Join-Path $root "ipa-out"
if (Test-Path $zip) { Remove-Item $zip -Force }
if (Test-Path $out) { Remove-Item $out -Recurse -Force }

$url = $arts.artifacts[0].archive_download_url
$req = [System.Net.HttpWebRequest]::Create($url)
$req.Method = "GET"
$req.UserAgent = "jizi-build"
$req.Headers.Add("Authorization", "Bearer $Token")
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
}
else {
    Say ("解压后没找到 .ipa，看看 " + $out + " 里有什么")
}

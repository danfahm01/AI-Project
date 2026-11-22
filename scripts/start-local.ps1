<#
.SYNOPSIS
    Runs the whole app on this computer: the backend API and the web app,
    together at http://localhost:8000.

.DESCRIPTION
    The first run asks for the AI provider key (hidden input) and creates .env
    (with the key and a random JWT_SECRET), a Python virtual
    environment in backend\.venv, the SQLite database and the web build. Later
    runs reuse them and only redo what changed.

    The AI provider key (OPENAI_API_KEY or GEMINI_API_KEY) goes into .env in the
    repository root. It stays on the server side and is never sent to the browser.

    Needs: Python 3.12+, and Flutter (only to build the web app once). No Docker,
    Visual Studio or Nginx.

.PARAMETER Port
    Port of http://localhost:<Port> (default 8000).

.PARAMETER RebuildWeb
    Rebuild the web app even if it looks up to date.

.PARAMETER NoBrowser
    Do not open the browser when the server is ready.

.PARAMETER AddKey
    Ask for a Gemini, Claude or OpenAI key even if a provider is already set up,
    for example to add Gemini (voice mode) or Claude next to local Ollama models.

.EXAMPLE
    .\start-local.cmd

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\start-local.ps1 -Port 8080
#>
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)] [int] $Port = 8000,
    [switch] $RebuildWeb,
    [switch] $NoBrowser,
    [switch] $AddKey
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$backend = Join-Path $root 'backend'
$appDir = Join-Path $root 'apps\flutter_app'
# The web app is built from a copy without the desktop/mobile platform folders:
# with windows\ and linux\ present, Flutter needs symlinks for plugins, which
# Windows only allows with Developer Mode. The web build doesn't need them.
$webSource = Join-Path $appDir 'build\local-web'
$webDir = Join-Path $webSource 'build\web'
$webStamp = Join-Path $appDir 'build\local-web.stamp'
$envFile = Join-Path $root '.env'
$webBuildArgs = @('build', 'web', '--release', '--no-web-resources-cdn', '--web-content-hash', '--csp', '--dart-define=API_BASE_URL=/')
$utf8 = New-Object System.Text.UTF8Encoding $false

function Write-Step([string] $Text) { Write-Host "==> $Text" -ForegroundColor Cyan }

function Stop-WithError([string] $Text) {
    Write-Host "ERROR: $Text" -ForegroundColor Red
    exit 1
}

# A program from PATH, else the first existing candidate path.
function Find-Tool([string] $Name, [string[]] $Candidates) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

function Test-ProviderKey([string] $EnvText) {
    if ($env:OPENAI_API_KEY -or $env:GEMINI_API_KEY -or $env:ANTHROPIC_API_KEY -or $env:OLLAMA_BASE_URL) { return $true }
    return $EnvText -match '(?m)^[ \t]*(OPENAI_API_KEY|GEMINI_API_KEY|ANTHROPIC_API_KEY|OLLAMA_BASE_URL)[ \t]*=[ \t]*[^\s#]'
}

# The value of NAME=value in .env (process environment wins), or $null.
function Get-EnvValue([string] $EnvText, [string] $Name) {
    $fromProcess = [Environment]::GetEnvironmentVariable($Name)
    if ($fromProcess) { return $fromProcess }
    $match = [regex]::Match($EnvText, "(?m)^[ \t]*$Name[ \t]*=[ \t]*([^\s#][^\r\n]*?)[ \t]*\r?$")
    if ($match.Success) { return $match.Groups[1].Value.Trim('"', "'") }
    return $null
}

function Set-EnvValue([string] $EnvText, [string] $Name, [string] $Value) {
    $line = "$Name=$Value"
    $pattern = "(?m)^[ \t]*$Name[ \t]*=[^\r\n]*"
    if ($EnvText -match $pattern) { return [regex]::Replace($EnvText, $pattern, { param($match) $line }) }
    return $EnvText.TrimEnd() + "`n$line`n"
}

# Installed Ollama models (names), or $null when Ollama does not answer.
function Get-OllamaModels([string] $BaseUrl) {
    try {
        $tags = Invoke-RestMethod -Uri ($BaseUrl.TrimEnd('/') + '/api/tags') -TimeoutSec 3
        return @($tags.models | ForEach-Object { $_.name })
    } catch {
        return $null
    }
}

$localOllama = 'http://127.0.0.1:11434'

# Asks the provider whether it accepts the key (a cheap list-models call):
# $true, $false (rejected) or $null (could not check, e.g. offline).
function Test-KeyWithProvider([string] $KeyName, [string] $Key) {
    if ($KeyName -eq 'GEMINI_API_KEY') {
        $uri = 'https://generativelanguage.googleapis.com/v1beta/models?pageSize=1'
        $headers = @{ 'x-goog-api-key' = $Key }
    } elseif ($KeyName -eq 'ANTHROPIC_API_KEY') {
        # Listing models costs nothing, so a key without credit still passes here.
        $uri = 'https://api.anthropic.com/v1/models?limit=1'
        $headers = @{ 'x-api-key' = $Key; 'anthropic-version' = '2026-10-21' }
    } else {
        $uri = 'https://api.openai.com/v1/models'
        $headers = @{ Authorization = "Bearer $Key" }
    }
    try {
        Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15 | Out-Null
        return $true
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -in 400, 401, 403) { return $false }
        return $null
    }
}

# --- 1. Configuration ---------------------------------------------------------------
Write-Step 'Configuration (.env)'
if (-not (Test-Path $envFile)) {
    Copy-Item (Join-Path $root '.env.example') $envFile
    Write-Host 'Created .env from .env.example'
}
$envText = [IO.File]::ReadAllText($envFile)

# A fixed JWT_SECRET keeps sign-ins valid when the server restarts.
if ($envText -notmatch '(?m)^[ \t]*JWT_SECRET[ \t]*=[ \t]*[^\s#]') {
    $bytes = New-Object byte[] 48
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    $secret = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    if ($envText -match '(?m)^[ \t]*JWT_SECRET[ \t]*=[ \t]*\r?$') {
        $envText = [regex]::Replace($envText, '(?m)^[ \t]*JWT_SECRET[ \t]*=[ \t]*(?=\r?$)', "JWT_SECRET=$secret")
    } else {
        $envText = $envText.TrimEnd() + "`nJWT_SECRET=$secret`n"
    }
    [IO.File]::WriteAllText($envFile, $envText, $utf8)
    Write-Host 'Generated JWT_SECRET'
}

# No key yet, but Ollama runs on this PC: use its models, no key needed.
if (-not (Test-ProviderKey $envText) -and ($null -ne (Get-OllamaModels $localOllama))) {
    $envText = Set-EnvValue $envText 'OLLAMA_BASE_URL' $localOllama
    [IO.File]::WriteAllText($envFile, $envText, $utf8)
    Write-Host "Found Ollama on this PC: using its models (OLLAMA_BASE_URL=$localOllama in .env)"
}

if ($AddKey -or -not (Test-ProviderKey $envText)) {
    Write-Host ''
    if ($AddKey) {
        Write-Host 'Add an API key (replaces an earlier key of the same provider):' -ForegroundColor Yellow
        Write-Host '  Gemini (free tier, also enables voice mode): https://aistudio.google.com/apikey'
        Write-Host '  Claude (paid per use, text chat): https://platform.claude.com/settings/keys'
        Write-Host '  OpenAI: https://platform.openai.com/api-keys'
    } else {
        Write-Host 'The app needs an AI model to answer. Either:' -ForegroundColor Yellow
        Write-Host '  a) a free local model, no key: install Ollama from https://ollama.com/download,'
        Write-Host '     run "ollama pull gemma4:e4b", then press Ctrl+C here and run this again; or'
        Write-Host '  b) an API key: https://aistudio.google.com/apikey (Gemini, free tier),'
        Write-Host '     https://platform.claude.com/settings/keys (Claude) or https://platform.openai.com/api-keys (OpenAI).'
    }
    Write-Host '  The key is saved only in .env on this PC and never sent to the browser.'
    Write-Host ''
    # Hidden input: the key is not shown on screen or kept in the console history.
    $secure = Read-Host 'Paste the key and press Enter (nothing is shown while you paste)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $raw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    # Terminals that use "bracketed paste" wrap pasted text in ESC[200~ ... ESC[201~;
    # drop those markers and other control characters, then surrounding spaces and quotes.
    $key = ($raw -replace '\x1b\[20[01]~', '' -replace '[\x00-\x1f\x7f]', '').Trim().Trim('"', "'")
    $raw = $null
    if ($key -notmatch '^[\x21-\x7e]{20,512}$') {
        # Never echo the input: it may be a real key with a typo.
        Stop-WithError ("The pasted text ($($key.Length) characters, with spaces or other characters keys do not have) is not an API key. " +
            'Copy the key itself from the provider''s website and run this again.')
    }
    if ($key.StartsWith('sk-ant-admin')) {
        Stop-WithError ('This is a Claude Admin API key, which cannot chat. Create a normal API key at ' +
            'https://platform.claude.com/settings/keys and run this again.')
    } elseif ($key.StartsWith('sk-ant-')) {
        $keyName = 'ANTHROPIC_API_KEY'  # Claude API key (Claude Console)
    } elseif ($key.StartsWith('sk-')) {
        $keyName = 'OPENAI_API_KEY'
    } elseif ($key.StartsWith('AIza')) {
        $keyName = 'GEMINI_API_KEY'  # a standard Google API key
    } else {
        # Gemini "auth keys" (every key AI Studio creates since 2026-05-28) have another format.
        $answer = Read-Host 'Is this a Gemini key or an OpenAI key? Type G or O and press Enter [G]'
        $keyName = if ($answer -match '^\s*[oO]') { 'OPENAI_API_KEY' } else { 'GEMINI_API_KEY' }
    }

    Write-Host 'Checking the key with the provider...'
    $accepted = Test-KeyWithProvider $keyName $key
    if ($accepted -eq $false) {
        $key = $null
        $hint = switch ($keyName) {
            'GEMINI_API_KEY' { 'Create a new key at https://aistudio.google.com/apikey (Google rejects unrestricted older keys).' }
            'ANTHROPIC_API_KEY' { 'Check the key at https://platform.claude.com/settings/keys (it may be disabled or deleted).' }
            default { 'Check the key and that the OpenAI account has credit.' }
        }
        Stop-WithError "The provider rejected this key, so it was not saved. $hint"
    }
    if ($null -eq $accepted) {
        Write-Host 'Could not reach the provider to check the key (no internet?). Saving it anyway.' -ForegroundColor Yellow
    } else {
        Write-Host 'The provider accepted the key.'
    }
    $envText = Set-EnvValue $envText $keyName $key
    $key = $null
    if ($keyName -eq 'ANTHROPIC_API_KEY' -and -not (Get-EnvValue $envText 'DEFAULT_AI_PROVIDER')) {
        # New chats start with Claude; other models stay one click away in the app.
        $envText = Set-EnvValue $envText 'DEFAULT_AI_PROVIDER' 'anthropic'
        Write-Host 'New chats now start with Claude (DEFAULT_AI_PROVIDER=anthropic in .env).'
    }
    [IO.File]::WriteAllText($envFile, $envText, $utf8)
    Write-Host "Saved $keyName in .env"
    if ($keyName -eq 'ANTHROPIC_API_KEY') {
        Write-Host ('Claude is billed per use from the API credit at https://platform.claude.com ' +
            '(separate from a claude.ai subscription).') -ForegroundColor Yellow
    }
}

# Ollama configured: say so now if it is not running or has no model yet.
$ollamaUrl = Get-EnvValue $envText 'OLLAMA_BASE_URL'
if ($ollamaUrl) {
    $ollamaModels = Get-OllamaModels $ollamaUrl
    if ($null -eq $ollamaModels) {
        Write-Host "Ollama does not answer at $ollamaUrl. Start Ollama from the Start menu; the app picks it up when it runs." -ForegroundColor Yellow
    } elseif ($ollamaModels.Count -eq 0) {
        Write-Host 'Ollama has no model yet. In another terminal run: ollama pull gemma4:e4b' -ForegroundColor Yellow
    } else {
        Write-Host ('Ollama models: ' + ($ollamaModels -join ', '))
    }
}

# --- 2. Python environment ------------------------------------------------------------
Write-Step 'Python environment (backend\.venv)'
$venv = Join-Path $backend '.venv'
$python = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $python)) {
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        & $launcher.Source -3 -m venv $venv
    } else {
        $system = Get-Command python -ErrorAction SilentlyContinue
        if (-not $system) { Stop-WithError 'Python 3.12 or newer is required: https://www.python.org/downloads/' }
        & $system.Source -m venv $venv
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $python)) { Stop-WithError 'Could not create backend\.venv' }
}
& $python -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)'
if ($LASTEXITCODE -ne 0) {
    Stop-WithError 'backend\.venv uses a Python older than 3.12. Install Python 3.12+, delete backend\.venv and run this again.'
}

# Reinstall only when requirements.txt changed.
$requirements = Join-Path $backend 'requirements.txt'
$requirementsStamp = Join-Path $venv 'requirements.sha256'
$requirementsHash = (Get-FileHash $requirements -Algorithm SHA256).Hash
if (-not (Test-Path $requirementsStamp) -or ([IO.File]::ReadAllText($requirementsStamp).Trim() -ne $requirementsHash)) {
    Write-Host 'Installing backend packages...'
    & $python -m pip install --disable-pip-version-check --quiet -r $requirements
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'Installing the backend packages failed (see the messages above)' }
    [IO.File]::WriteAllText($requirementsStamp, $requirementsHash, $utf8)
}

# --- 3. Database ----------------------------------------------------------------------
Write-Step 'Database (backend\data)'
Push-Location $backend
try {
    & $python -m alembic upgrade head
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'Database migration failed (see the messages above)' }
} finally {
    Pop-Location
}

# --- 4. Web app -----------------------------------------------------------------------
Write-Step 'Web app (apps\flutter_app\build\web)'
$index = Join-Path $webDir 'index.html'
# Names the post-build step too, so builds from before it are redone.
$wantedStamp = ($webBuildArgs -join ' ') + ' + tool/fixed_name_web_assets.dart'
$needBuild = $RebuildWeb -or -not (Test-Path $index) -or -not (Test-Path $webStamp)
if (-not $needBuild) {
    # Built by this script (same-origin API), and nothing changed since?
    $needBuild = [IO.File]::ReadAllText($webStamp).Trim() -ne $wantedStamp
}
if (-not $needBuild) {
    $builtAt = (Get-Item $index).LastWriteTimeUtc
    $sources = @()
    foreach ($folder in 'lib', 'web', 'assets', 'tool') {
        $path = Join-Path $appDir $folder
        if (Test-Path $path) { $sources += Get-ChildItem $path -Recurse -File }
    }
    $sources += Get-Item (Join-Path $appDir 'pubspec.yaml'), (Join-Path $appDir 'pubspec.lock')
    $needBuild = [bool]($sources | Where-Object { $_.LastWriteTimeUtc -gt $builtAt } | Select-Object -First 1)
}
if ($needBuild) {
    $flutter = Find-Tool 'flutter' @(
        $(if ($env:FLUTTER_ROOT) { Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat' }),
        'C:\src\flutter\bin\flutter.bat',
        (Join-Path $env:USERPROFILE 'develop\flutter\bin\flutter.bat'),
        (Join-Path $env:USERPROFILE 'flutter\bin\flutter.bat')
    )
    if (-not $flutter) {
        Stop-WithError 'Flutter is needed once to build the web app: https://docs.flutter.dev/get-started/install/windows'
    }
    # The Flutter tool itself needs Git.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $git = Find-Tool 'git' @(
            'C:\src\git\cmd\git.exe',
            (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
        )
        if (-not $git) { Stop-WithError 'Flutter needs Git: https://git-scm.com/download/win' }
        $env:Path = (Split-Path $git) + ';' + $env:Path
    }
    Write-Host 'Building the web app (a few minutes the first time)...'
    # Mirror the app's sources (timestamps kept, so later builds are incremental).
    # Excluded folders are neither copied nor deleted in the copy (its .dart_tool, build).
    & robocopy.exe $appDir $webSource /MIR /XD windows linux macos ios android build .dart_tool test .idea `
        /XF *.iml .flutter-plugins-dependencies /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Stop-WithError "Copying the app sources to $webSource failed" }
    Push-Location $webSource
    try {
        & $flutter @webBuildArgs
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $index)) { Stop-WithError 'flutter build web failed (see the messages above)' }
        # Plugin scripts that voice mode loads by a fixed name (microphone, playback)
        # get that name back next to the content-hashed file.
        $dart = Join-Path (Split-Path $flutter) 'dart.bat'
        if (-not (Test-Path $dart)) { $dart = 'dart' }
        & $dart run tool/fixed_name_web_assets.dart build/web
        if ($LASTEXITCODE -ne 0) { Stop-WithError 'Preparing the web build for voice mode failed (see the messages above)' }
    } finally {
        Pop-Location
    }
    [IO.File]::WriteAllText($webStamp, $wantedStamp, $utf8)
} else {
    Write-Host 'Up to date'
}

# --- 5. Server ------------------------------------------------------------------------
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    $otherPort = if ($Port -eq 8080) { 8081 } else { 8080 }
    Stop-WithError ("Port $Port is already in use. If the app already runs in another window, use it at " +
        "http://localhost:$Port or close that window (Ctrl+C) first. Otherwise run with -Port $otherPort.")
}
$url = "http://localhost:$Port"
Write-Step "Starting $url  (press Ctrl+C to stop)"
$env:WEB_APP_DIR = $webDir
$uvicornArgs = @('-m', 'uvicorn', 'app.main:create_app', '--factory', '--host', '127.0.0.1', '--port', "$Port", '--no-server-header')
$server = Start-Process -FilePath $python -ArgumentList $uvicornArgs -WorkingDirectory $backend -NoNewWindow -PassThru
try {
    $ready = $false
    for ($i = 0; $i -lt 120 -and -not $server.HasExited; $i++) {
        try {
            Invoke-WebRequest "http://127.0.0.1:$Port/health/ready" -UseBasicParsing -TimeoutSec 2 | Out-Null
            $ready = $true
            break
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $ready) { Stop-WithError 'The server did not start (see the messages above)' }

    Write-Host ''
    Write-Host "Ready: $url" -ForegroundColor Green
    Write-Host 'Create an account in the app (it is stored only on this computer) and start chatting.'
    Write-Host 'Keep this window open while you use the app.'
    Write-Host ''
    if (-not $NoBrowser) { Start-Process $url }
    Wait-Process -Id $server.Id
} finally {
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -ErrorAction SilentlyContinue }
}

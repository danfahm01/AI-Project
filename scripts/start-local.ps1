<#
.SYNOPSIS
    Runs the whole app on this computer: the backend API and the web app,
    together at http://localhost:8000.

.DESCRIPTION
    The first run creates .env (with a random JWT_SECRET), a Python virtual
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

.EXAMPLE
    .\start-local.cmd

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\start-local.ps1 -Port 8080
#>
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)] [int] $Port = 8000,
    [switch] $RebuildWeb,
    [switch] $NoBrowser
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
    if ($env:OPENAI_API_KEY -or $env:GEMINI_API_KEY) { return $true }
    return $EnvText -match '(?m)^[ \t]*(OPENAI_API_KEY|GEMINI_API_KEY)[ \t]*=[ \t]*[^\s#]'
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

if (-not (Test-ProviderKey $envText)) {
    Write-Host ''
    Write-Host 'The app needs an AI provider key to answer.' -ForegroundColor Yellow
    Write-Host '  1. Create a key: https://platform.openai.com/api-keys'
    Write-Host '     (or a Gemini key: https://aistudio.google.com/apikey)'
    Write-Host '  2. In the .env file that opens now, paste it right after OPENAI_API_KEY='
    Write-Host '     (or GEMINI_API_KEY=), then save and close Notepad.'
    Write-Host ''
    Start-Process notepad.exe -ArgumentList "`"$envFile`"" -Wait
    $envText = [IO.File]::ReadAllText($envFile)
    if (-not (Test-ProviderKey $envText)) {
        Stop-WithError 'No OPENAI_API_KEY or GEMINI_API_KEY in .env. Add one and run this again.'
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
$wantedStamp = $webBuildArgs -join ' '
$needBuild = $RebuildWeb -or -not (Test-Path $index) -or -not (Test-Path $webStamp)
if (-not $needBuild) {
    # Built by this script (same-origin API), and nothing changed since?
    $needBuild = [IO.File]::ReadAllText($webStamp).Trim() -ne $wantedStamp
}
if (-not $needBuild) {
    $builtAt = (Get-Item $index).LastWriteTimeUtc
    $sources = @()
    foreach ($folder in 'lib', 'web', 'assets') {
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
    } finally {
        Pop-Location
    }
    [IO.File]::WriteAllText($webStamp, $wantedStamp, $utf8)
} else {
    Write-Host 'Up to date'
}

# --- 5. Server ------------------------------------------------------------------------
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    Stop-WithError "Port $Port is already in use. Close the other program, or run with -Port 8080."
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

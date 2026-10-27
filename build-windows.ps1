# Local Writely build. No GitHub Actions runner or release signing key is used.
param([string]$BuildRoot = (Join-Path $env:LOCALAPPDATA 'WritelyBuild'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$branch = 'codex/cloud-updates'

function Refresh-ProcessPath {
    $extra = @((Join-Path $env:USERPROFILE '.cargo\bin'), (Join-Path $env:ProgramFiles 'GitHub CLI'), (Join-Path $env:ProgramFiles 'nodejs'))
    $env:PATH = ($extra + @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User'), $env:PATH)) -join ';'
}
function Run-Native([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE. The build was stopped." }
}
function Install-Tool([string]$Id, [string[]]$Extra = @()) {
    Write-Host "Installing build dependency: $Id"
    & winget install --exact --id $Id --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity @Extra
    if ($LASTEXITCODE -eq 3010 -or $LASTEXITCODE -eq 1641) { throw 'A dependency requires a Windows restart. Restart, then run this script again.' }
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) { throw "Dependency installation failed: $Id ($LASTEXITCODE)" }
    Refresh-ProcessPath
}

try {
    if (![Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -notin @('AMD64', 'x86')) { throw 'This build supports Windows x64 only.' }
    if (!(Get-Command winget -ErrorAction SilentlyContinue)) { throw 'Install or update App Installer from Microsoft Store to enable winget, then retry.' }
    $drive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($BuildRoot))
    if (([IO.DriveInfo]::new($drive)).AvailableFreeSpace -lt 25GB) { throw 'The build needs at least 25 GB of free space on its drive.' }
    Write-Host 'Writely local build: source stays private; release signing stays on the Mac.'
    Write-Host 'First run installs missing Git, GitHub CLI, Node.js, Python, Rust, C++ Build Tools and LLVM.'
    Write-Host 'Windows may ask for administrator approval for build dependencies. Keep this window open.'
    Refresh-ProcessPath
    if (!(Get-Command git -ErrorAction SilentlyContinue)) { Install-Tool 'Git.Git' }
    if (!(Get-Command gh -ErrorAction SilentlyContinue)) { Install-Tool 'GitHub.cli' }
    $nodeOk = $false
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $nodeOk = [version]((& node -p 'process.versions.node') | Select-Object -Last 1) -ge [version]'20.18.0'
    }
    if (!$nodeOk) { Install-Tool 'OpenJS.NodeJS.22' }
    $pythonExe = $null
    if (Get-Command py -ErrorAction SilentlyContinue) {
        try {
            $pythonExe = & py -3.12 -c 'import sys; print(sys.executable)' 2>$null
            if ($LASTEXITCODE -ne 0) { $pythonExe = $null }
        } catch { $pythonExe = $null }
    }
    if (!$pythonExe) {
        Install-Tool 'Python.Python.3.12'
        $pythonExe = & py -3.12 -c 'import sys; print(sys.executable)'
        if ($LASTEXITCODE -ne 0) { throw 'Python 3.12 is unavailable. Open a new PowerShell window and retry.' }
    }
    if (!(Get-Command rustup -ErrorAction SilentlyContinue)) { Install-Tool 'Rustlang.Rustup' }
    Run-Native 'rustup' @('toolchain', 'install', '1.96.0', '--profile', 'minimal', '--component', 'rustfmt,clippy')
    Run-Native 'rustup' @('target', 'add', 'x86_64-pc-windows-msvc', '--toolchain', '1.96.0')
    $env:RUSTUP_TOOLCHAIN = '1.96.0'
    $env:CARGO_BUILD_JOBS = '2'
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $visualStudio = $null
    if (Test-Path -LiteralPath $vswhere) {
        $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
    if (!$visualStudio) {
        Install-Tool 'Microsoft.VisualStudio.2022.BuildTools' @('--override', '--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended')
        $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
    if (!$visualStudio) { throw 'Microsoft C++ Build Tools with the Desktop development with C++ workload are required.' }
    $devShell = Join-Path $visualStudio 'Common7\Tools\Launch-VsDevShell.ps1'
    & $devShell -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
    $llvm = Join-Path $env:ProgramFiles 'LLVM\bin'
    if (!(Test-Path -LiteralPath (Join-Path $llvm 'libclang.dll'))) { Install-Tool 'LLVM.LLVM' }
    if (!(Test-Path -LiteralPath (Join-Path $llvm 'libclang.dll'))) { throw 'LLVM libclang.dll is unavailable.' }
    $env:LIBCLANG_PATH = $llvm
    $env:PATH = "$llvm;$env:PATH"
    # Public users never need this login. Only the owner's build computer needs
    # access to the closed source repository; credentials stay in system storage.
    $loggedIn = $false
    try { & gh auth status --hostname github.com *> $null; $loggedIn = $LASTEXITCODE -eq 0 } catch { $loggedIn = $false }
    if (!$loggedIn) { Run-Native 'gh' @('auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web') }
    Run-Native 'gh' @('auth', 'setup-git', '--hostname', 'github.com')
    $commit = & gh api "repos/dmmhm/stats/commits/$branch" --jq '.sha'
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[a-f0-9]{40}$') { throw 'Unable to read the private Writely source commit.' }
    $source = Join-Path $BuildRoot ('source-' + $commit.Substring(0, 12))
    if (!(Test-Path -LiteralPath $source)) {
        $null = New-Item -ItemType Directory -Path $BuildRoot -Force
        Run-Native 'gh' @('repo', 'clone', 'dmmhm/stats', $source, '--', '--branch', $branch, '--single-branch', '--depth', '1', '--config', 'core.autocrlf=false')
    }
    Push-Location -LiteralPath $source
    try {
        $actual = & git rev-parse HEAD
        if ($LASTEXITCODE -ne 0 -or $actual -ne $commit) { throw 'The local source does not match the intended release commit.' }
        $appVersion = (Get-Content -LiteralPath 'src-tauri/tauri.conf.json' -Raw -Encoding UTF8 | ConvertFrom-Json).version
        $output = Join-Path $source ('release\local-' + $appVersion)
        Run-Native $pythonExe @('scripts/local_release.py', 'build', '--source-ref', $commit, '--output', $output)
        Run-Native $pythonExe @('scripts/local_release.py', 'upload', (Join-Path $output 'windows-x64'))
        Write-Host ''
        Write-Host 'DONE. Windows package and test report transferred privately. No Actions minutes used.'
        Write-Host 'Tell Codex: Windows local build finished. Signing and publication can continue on the Mac.'
        Write-Host "Local files: $output"
    } finally { Pop-Location }
} catch {
    Write-Host ''
    Write-Error $_
    exit 1
}

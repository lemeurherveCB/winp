[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Configuration = "Debug",

    [Parameter(Position = 2)]
    [string]$Version
)

$ErrorActionPreference = "Stop"
$global:BUILDROOT = Get-Location

# Find MSBuild
Write-Host "Locating MSBuild..."
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Error "vswhere.exe not found at $vswhere"
    exit 1
}

$global:MSBUILD = & $vswhere -latest -products * `
    -requires Microsoft.Component.MSBuild `
    -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1

if (-not $global:MSBUILD) {
    Write-Error "MSBuild not found"
    exit 1
}

$vsPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath | Select-Object -First 1

$global:VSINSTALLDIR = $vsPath
if (-not $global:VSINSTALLDIR) {
    Write-Error "Visual Studio with VC tools not found"
    exit 1
}

# vcvarsall.bat is the core VC toolset script that sets PATH, INCLUDE, LIB and
# WindowsSDKDir for a given target architecture.  Unlike VsDevCmd.bat or
# Enter-VsDevShell (which rely on VS developer-shell infrastructure that can be
# absent in Build-Tools-only installations), vcvarsall.bat is always present
# when the VC.Tools.x86.x64 component is installed and returns a real non-zero
# exit code on failure.
$global:VCVARSALL = Join-Path $global:VSINSTALLDIR 'VC\Auxiliary\Build\vcvarsall.bat'
if (-not (Test-Path $global:VCVARSALL)) {
    Write-Error "vcvarsall.bat not found: $global:VCVARSALL"
    exit 1
}

# Track which arch the VC environment is currently set up for so we only
# call vcvarsall.bat when the architecture actually changes.
$global:VSDEVENV_ARCH = $null

# Set by Ensure-WindowsSdk when the VS-installed SDK is missing.
$global:WINSDK_FALLBACK_DIR = $null
$global:WINSDK_FALLBACK_VER = $null

Write-Host "MSBUILD=${global:MSBUILD}"
Write-Host "VSINSTALLDIR=${global:VSINSTALLDIR}"
Write-Host "VCVARSALL=${global:VCVARSALL}"


# Determine version
if ([string]::IsNullOrEmpty($Version)) {
    Write-Host "No target version specified, will determine it from POM"
    try {
        $ErrorActionPreference = "SilentlyContinue"
        $versionOutput = & mvn -q -Dexec.executable="cmd.exe" -Dexec.args='/c echo ${project.version}' --non-recursive org.codehaus.mojo:exec-maven-plugin:3.5.0:exec 2>&1 > $null
        $Version = $versionOutput | Where-Object { $_ -notmatch '^\s*WARNING' -and $_ -notmatch '^\[' } | Where-Object { $_.Trim() } | Select-Object -Last 1
    } catch {
        Write-Error "Failed to extract version from POM: $_"
        exit 1
    } finally {
        $ErrorActionPreference = "Stop"
    }
} else {
    Write-Host "Setting MVN project version to the externally defined $Version"
}

Write-Host "Target version is $Version"

# Ensure the Windows SDK 10.0.22621.0 headers and libs are available for MSBuild.
# VS 2025 Build Tools ship with a Windows10SDK.22621 component that omits the
# Include/ directory entirely — the correct VS 2025 component is Windows11SDK.22621
# (tracked in packer-images).  Until that lands, we download the SDK via NuGet and
# build a junction-based layout at C:\winsdk\layout\ that MSBuild can use directly.
function Ensure-WindowsSdk {
    $sdkVer    = '10.0.22621.0'
    $kitsRoot  = "${env:ProgramFiles(x86)}\Windows Kits\10"
    $layoutDir = 'C:\winsdk\layout'
    $nugetDir  = 'C:\winsdk\nuget'

    # Prefer the VS-installed SDK if Include/ is present with headers
    $vsInclude = "$kitsRoot\Include\$sdkVer"
    if ((Test-Path "$vsInclude\um") -or (Test-Path "$vsInclude\ucrt")) {
        Write-Host "Windows SDK $sdkVer found in Windows Kits"
        $global:WINSDK_FALLBACK_DIR = "$kitsRoot\"
        $global:WINSDK_FALLBACK_VER = $sdkVer
        return
    }

    # Reuse cached NuGet layout from a previous run on the same agent
    if (Test-Path "$layoutDir\Include\$sdkVer\um\windows.h") {
        Write-Host "Windows SDK NuGet layout found at $layoutDir"
        $global:WINSDK_FALLBACK_DIR = "$layoutDir\"
        $global:WINSDK_FALLBACK_VER = $sdkVer
        return
    }

    Write-Host "Windows SDK $sdkVer headers not found — downloading via NuGet..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    New-Item -ItemType Directory -Path $nugetDir -Force | Out-Null
    $nugetExe = "$nugetDir\nuget.exe"
    if (-not (Test-Path $nugetExe)) {
        Invoke-WebRequest -UseBasicParsing `
            -Uri 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' `
            -OutFile $nugetExe
    }

    foreach ($pkg in @(
        "Microsoft.Windows.SDK.CPP.$sdkVer",
        "Microsoft.Windows.SDK.CPP.x86.$sdkVer",
        "Microsoft.Windows.SDK.CPP.x64.$sdkVer"
    )) {
        Write-Host "  Installing $pkg"
        & $nugetExe install $pkg -OutputDirectory $nugetDir -NonInteractive `
            -Source 'https://api.nuget.org/v3/index.json' | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Error "NuGet install failed: $pkg"; exit 1 }
    }

    $basePkg = Get-ChildItem $nugetDir -Directory |
        Where-Object { $_.Name -like "Microsoft.Windows.SDK.CPP.$sdkVer*" -and $_.Name -notmatch '\.x86\.|\.x64\.' } |
        Select-Object -First 1
    $x86Pkg  = Get-ChildItem $nugetDir -Directory |
        Where-Object { $_.Name -like "Microsoft.Windows.SDK.CPP.x86.$sdkVer*" } | Select-Object -First 1
    $x64Pkg  = Get-ChildItem $nugetDir -Directory |
        Where-Object { $_.Name -like "Microsoft.Windows.SDK.CPP.x64.$sdkVer*" } | Select-Object -First 1

    # Create layout with junctions so MSBuild sees a standard Windows Kits tree
    foreach ($d in @("$layoutDir\Include", "$layoutDir\Lib\$sdkVer\ucrt", "$layoutDir\Lib\$sdkVer\um")) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    $junctions = @(
        @{ L = "$layoutDir\Include\$sdkVer";              T = "$($basePkg.FullName)\c\Include\$sdkVer" },
        @{ L = "$layoutDir\Lib\$sdkVer\ucrt\x86"; T = "$($x86Pkg.FullName)\c\Lib\$sdkVer\ucrt\x86" },
        @{ L = "$layoutDir\Lib\$sdkVer\ucrt\x64"; T = "$($x64Pkg.FullName)\c\Lib\$sdkVer\ucrt\x64" },
        @{ L = "$layoutDir\Lib\$sdkVer\um\x86";   T = "$($x86Pkg.FullName)\c\Lib\$sdkVer\um\x86" },
        @{ L = "$layoutDir\Lib\$sdkVer\um\x64";   T = "$($x64Pkg.FullName)\c\Lib\$sdkVer\um\x64" }
    )
    foreach ($j in $junctions) {
        if (-not (Test-Path $j.L)) {
            cmd /c "mklink /J `"$($j.L)`" `"$($j.T)`"" | Out-Null
        }
    }

    Write-Host "Windows SDK layout ready at $layoutDir"
    $global:WINSDK_FALLBACK_DIR = "$layoutDir\"
    $global:WINSDK_FALLBACK_VER = $sdkVer
}

# Set up the VC build environment for the given target architecture by running
# vcvarsall.bat in a cmd subprocess, capturing the resulting environment via
# "set", then applying the variables to the current PowerShell process.
# This is more reliable than VsDevCmd.bat or Enter-VsDevShell on VS 2025 Build
# Tools, which silently fail to discover the Windows SDK on some configurations.
function Initialize-VsDevEnvironment {
    param([string]$Arch)

    if ($global:VSDEVENV_ARCH -eq $Arch) { return }

    Write-Host "Setting up VC build environment via vcvarsall.bat: arch=$Arch"

    $tmpBat = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.bat')
    try {
        # Dump env after calling vcvarsall.bat; propagate its exit code.
        $batContent = "@echo off`r`ncall `"$($global:VCVARSALL)`" $Arch > nul 2>&1`r`nif errorlevel 1 exit /b %errorlevel%`r`nset"
        [System.IO.File]::WriteAllText($tmpBat, $batContent)

        $output = & $env:ComSpec /d /c "`"$tmpBat`"" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "vcvarsall.bat ($Arch) failed with exit code $LASTEXITCODE"
            exit $LASTEXITCODE
        }

        foreach ($line in $output) {
            if ($line -match '^([^=]+)=(.*)$') {
                [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
            }
        }
        Write-Host "VC environment ready. WindowsSDKDir=$env:WindowsSDKDir"
    } finally {
        Remove-Item $tmpBat -Force -ErrorAction SilentlyContinue
    }

    # Diagnose Windows SDK state regardless of whether vcvarsall found it
    $kitsRoot = "${env:ProgramFiles(x86)}\Windows Kits\10"
    Write-Host "Windows Kits root: $kitsRoot (exists: $(Test-Path $kitsRoot))"
    if (Test-Path "$kitsRoot\Include") {
        Get-ChildItem "$kitsRoot\Include" -Directory |
            Sort-Object Name -Descending |
            ForEach-Object {
                $hasHeaders = Test-Path "$kitsRoot\Include\$($_.Name)\um\windows.h"
                Write-Host "  SDK $($_.Name): windows.h=$hasHeaders"
            }
    } else {
        Write-Host "  $kitsRoot\Include not found"
    }

    # If vcvarsall.bat left WindowsSDKDir empty (VS 2025 Windows10SDK.22621 installs
    # no headers), apply the fallback SDK path prepared by Ensure-WindowsSdk.
    if ([string]::IsNullOrEmpty($env:WindowsSDKDir)) {
        if (-not $global:WINSDK_FALLBACK_DIR) {
            Write-Error "WindowsSDKDir empty and no SDK fallback available — Ensure-WindowsSdk must run first"
            exit 1
        }
        Write-Host "  Applying SDK fallback: $global:WINSDK_FALLBACK_DIR v$global:WINSDK_FALLBACK_VER"
        [System.Environment]::SetEnvironmentVariable('WindowsSDKDir',     $global:WINSDK_FALLBACK_DIR,        'Process')
        [System.Environment]::SetEnvironmentVariable('WindowsSDKVersion', "$global:WINSDK_FALLBACK_VER\",     'Process')
    }

    $global:VSDEVENV_ARCH = $Arch
}

# Run MSBuild for a set of project files after setting up the dev environment.
function Invoke-MSBuild {
    param(
        [string[]]$ProjectPaths,
        [string]$Arch,
        [string]$Platform,
        [string]$Configuration,
        [string]$Target = $null,
        [string]$Verbosity = "minimal"
    )

    if (-not $Arch) {
        switch ($Platform) {
            "Win32" { $Arch = "x86" }
            "x64"   { $Arch = "x64" }
            default {
                Write-Error "Unable to infer dev shell architecture for platform '$Platform'"
                exit 1
            }
        }
    }

    Initialize-VsDevEnvironment -Arch $Arch

    foreach ($projectPath in $ProjectPaths) {
        $absPath = if ([System.IO.Path]::IsPathRooted($projectPath)) {
            $projectPath
        } else {
            Join-Path (Get-Location) $projectPath
        }

        $msbuildArgs = @(
            $absPath,
            '/m', '/nologo', "/verbosity:$Verbosity",
            "/p:Configuration=$Configuration",
            "/p:Platform=$Platform"
        )

        if ($Target) { $msbuildArgs += "/t:$Target" }

        Write-Host "Running MSBuild: $(Split-Path $absPath -Leaf) platform=$Platform target=$Target"
        & $global:MSBUILD @msbuildArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error "MSBuild failed with exit code $LASTEXITCODE"
            exit $LASTEXITCODE
        }
    }
}

# Clean function
function Invoke-Clean {
    Write-Host "### Cleaning the $Configuration build directory"
    Push-Location "$global:BUILDROOT\native"
    try {
        Invoke-MSBuild -ProjectPaths @("winp.vcxproj", "sendctrlc\sendctrlc.vcxproj", "..\native_test\testapp\testapp.vcxproj") -Platform "Win32" -Arch "x86" -Configuration $Configuration -Target "Clean"
        Invoke-MSBuild -ProjectPaths @("winp.vcxproj", "sendctrlc\sendctrlc.vcxproj", "..\native_test\testapp\testapp.vcxproj") -Platform "x64" -Arch "x64" -Configuration $Configuration -Target "Clean"
    } finally {
        Pop-Location
    }
}

# Build function
function Invoke-Build {
    Write-Host "### Building the $Configuration configuration"
    Push-Location "$global:BUILDROOT\native"
    try {
        Invoke-MSBuild -ProjectPaths @("winp.vcxproj", "sendctrlc\sendctrlc.vcxproj", "..\native_test\testapp\testapp.vcxproj") -Platform "Win32" -Arch "x86" -Configuration $Configuration
        Invoke-MSBuild -ProjectPaths @("winp.vcxproj", "sendctrlc\sendctrlc.vcxproj", "..\native_test\testapp\testapp.vcxproj") -Platform "x64" -Arch "x64" -Configuration $Configuration
    } finally {
        Pop-Location
    }

    Write-Host "### Updating WinP resource files for the $Configuration build"
    Set-Location $global:BUILDROOT

    $resourceDir = "src\main\resources"
    if (-not (Test-Path $resourceDir)) {
        New-Item -ItemType Directory -Path $resourceDir -Force | Out-Null
    }

    $filesToCopy = @(
        @{ Source = "native\$Configuration\winp.dll"; Dest = "$resourceDir\winp.dll" },
        @{ Source = "native\x64\$Configuration\winp.dll"; Dest = "$resourceDir\winp.x64.dll" },
        @{ Source = "native\sendctrlc\Win32\$Configuration\sendctrlc.exe"; Dest = "$resourceDir\sendctrlc.exe" },
        @{ Source = "native\sendctrlc\x64\$Configuration\sendctrlc.exe"; Dest = "$resourceDir\sendctrlc.x64.exe" }
    )

    foreach ($file in $filesToCopy) {
        if (-not (Test-Path $file.Source)) {
            Write-Error "Source file not found: $($file.Source)"
            exit 1
        }
        Copy-Item -Path $file.Source -Destination $file.Dest -Force
        Write-Host "Copied $($file.Source) to $($file.Dest)"
    }
}

# Ensure the Windows SDK is available before any build or clean operation.
Ensure-WindowsSdk

# Main dispatch
switch ($Command) {
    "clean" { Invoke-Clean }
    "build" { Invoke-Build }
    ""      { Invoke-Build }  # Default to build
    default {
        Write-Host "Unknown command: $Command"
        Write-Host "Valid commands: clean, build"
        exit 1
    }
}

Write-Host "Build completed successfully"

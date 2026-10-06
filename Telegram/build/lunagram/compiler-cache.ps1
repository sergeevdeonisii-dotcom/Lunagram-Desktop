param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Setup', 'Probe', 'Stats')]
    [string] $Stage,
    [switch] $Required
)

$ErrorActionPreference = 'Stop'
$cacheVersion = '0.33.0'
$archiveHash = '787A5062C95AFF41C0448EA80111EB98A591F778135E906856D7AF412954A372'

function Get-CacheChild([string] $Root, [string] $Name) {
    if ([IO.Path]::IsPathRooted($Name) -or $Name.Contains(':')) { throw 'Only relative cache paths are accepted.' }
    $parent = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $child = [IO.Path]::GetFullPath((Join-Path $parent $Name))
    if (-not $child.StartsWith($parent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Compiler cache path escaped its isolated build directory.'
    }
    return $child
}

function Set-BuildEnvironment([string] $Name, [string] $Value) {
    if ($Value -match '[\r\n]') { throw 'Multiline build environment values are not accepted.' }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    if ($env:GITHUB_ENV) { Add-Content -LiteralPath $env:GITHUB_ENV -Value "$Name=$Value" -Encoding utf8 }
}

function Get-CacheIdentity([string[]] $Parts) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Parts -join "`n"))))).Replace('-', '').ToLowerInvariant()
    } finally {
        $hash.Dispose()
    }
}

function Invoke-CacheCommand([string] $Command, [string[]] $Arguments) {
    $result = @(& $Command @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        if ($env:LUNAGRAM_DIAGNOSTICS) {
            $result | Add-Content -LiteralPath (Join-Path $env:LUNAGRAM_DIAGNOSTICS 'compiler-cache-error.txt') -Encoding utf8
        }
        throw 'Compiler cache compatibility check failed.'
    }
    return ($result -join "`n")
}

function Get-LocalCacheHits([string] $Statistics) {
    if ($Statistics -notmatch '(?m)^\s*Local hits:\s*(\d+)\s*$') { throw 'Compiler cache statistics are missing.' }
    return [long] $Matches[1]
}

function Remove-ProbeOutputs([string] $Root) {
    foreach ($name in @('probe.pch', 'pch.obj', 'main.obj', 'probe.exe')) {
        $path = Get-CacheChild $Root $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
}

function Invoke-CacheProbe([string] $Tool, [string] $Root, [string] $Expected) {
    Remove-ProbeOutputs $Root
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $common = @('/nologo', '/c', '/std:c++20', '/EHsc', '/MTd', '/Ob0', '/Od', '/RTC1', '/showIncludes')
    $compiler = (Get-Command cl.exe -ErrorAction Stop).Source
    $pch = Invoke-CacheCommand $Tool (@($compiler) + $common + @('/Ycpch.h', '/Fpprobe.pch', '/Fopch.obj', 'pch.cpp'))
    $object = Invoke-CacheCommand $Tool (@($compiler) + $common + @('/Yupch.h', '/Fpprobe.pch', '/Fomain.obj', 'main.cpp'))
    if ($object -notmatch 'including file:.*after.h') { throw 'Cached compilation did not preserve Ninja include dependencies.' }
    $link = Invoke-CacheCommand 'link.exe' @('/nologo', '/OUT:probe.exe', 'pch.obj', 'main.obj')
    $actual = Invoke-CacheCommand (Get-CacheChild $Root 'probe.exe') @()
    if ($actual.Trim() -ne $Expected) { throw 'Compiler cache returned stale executable behavior.' }
    $timer.Stop()
    return [math]::Round($timer.Elapsed.TotalMilliseconds)
}

if (-not $env:LUNAGRAM_BUILD_ROOT) { throw 'LUNAGRAM_BUILD_ROOT is required.' }
$toolRoot = Get-CacheChild $env:LUNAGRAM_BUILD_ROOT "compiler-cache-tool-$cacheVersion"
$cacheRoot = Get-CacheChild $env:LUNAGRAM_BUILD_ROOT 'compiler-cache-v1'
$probeRoot = Get-CacheChild $env:LUNAGRAM_BUILD_ROOT 'compiler-cache-probe'
$tool = Get-CacheChild $toolRoot 'buildcache/bin/buildcache.exe'

switch ($Stage) {
    'Setup' {
        Set-BuildEnvironment 'LUNAGRAM_COMPILER_LAUNCHER' ''
        Set-BuildEnvironment 'LUNAGRAM_COMPILER_CACHE_READY' 'false'
        New-Item -ItemType Directory -Force -Path $toolRoot, $cacheRoot | Out-Null
        $archive = Get-CacheChild $toolRoot 'buildcache-windows.zip'
        Invoke-WebRequest "https://gitlab.com/api/v4/projects/49153623/packages/generic/releases/v$cacheVersion/buildcache-windows.zip" -OutFile $archive
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $archiveHash) {
            throw 'Compiler cache download does not match the pinned release.'
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $toolRoot -Force
        $compiler = (Get-Command cl.exe -ErrorAction Stop).Source
        $identity = Get-CacheIdentity @(
            $cacheVersion, $env:ImageOS, $env:ImageVersion, $env:VCToolsVersion,
            $env:WindowsSDKVersion, $env:INCLUDE, $env:LIB, $env:LIBPATH,
            $env:CL, $env:_CL_, $env:LUNAGRAM_CACHE_KEY, $env:LUNAGRAM_SOURCE_ROOT,
            (Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash,
            (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
        )
        $identityPath = Get-CacheChild $toolRoot 'environment.sha256'
        [IO.File]::WriteAllText($identityPath, $identity, [Text.UTF8Encoding]::new($false))
        foreach ($item in @{
            BUILDCACHE_DIR = $cacheRoot
            BUILDCACHE_ACCURACY = 'STRICT'
            BUILDCACHE_DIRECT_MODE = 'true'
            BUILDCACHE_COMPRESS = 'true'
            BUILDCACHE_COMPRESS_FORMAT = 'ZSTD'
            BUILDCACHE_COMPRESS_LEVEL = '3'
            BUILDCACHE_HARD_LINKS = 'false'
            BUILDCACHE_MAX_CACHE_SIZE = '3221225472'
            BUILDCACHE_MAX_LOCAL_ENTRY_SIZE = '1073741824'
            BUILDCACHE_HASH_EXTRA_FILES = $identityPath
            LUNAGRAM_COMPILER_CACHE_KEY = "compiler-v1-$identity"
            LUNAGRAM_COMPILER_CACHE_TOOL = $tool
        }.GetEnumerator()) { Set-BuildEnvironment $item.Key $item.Value }
        Write-Output "BuildCache $cacheVersion installed; compressed cache limit: 3 GiB."
    }
    'Probe' {
        Set-BuildEnvironment 'LUNAGRAM_COMPILER_LAUNCHER' ''
        Set-BuildEnvironment 'LUNAGRAM_COMPILER_CACHE_READY' 'false'
        New-Item -ItemType Directory -Force -Path $probeRoot, $env:LUNAGRAM_DIAGNOSTICS | Out-Null
        $fixtureRoot = Join-Path $PSScriptRoot 'compiler_cache_probe'
        foreach ($name in @('pch.h', 'pch.cpp', 'main.cpp', 'value.h', 'after.h')) {
            Copy-Item -LiteralPath (Join-Path $fixtureRoot $name) -Destination (Get-CacheChild $probeRoot $name) -Force
        }
        Push-Location $probeRoot
        try {
            Invoke-CacheCommand $tool @('--zero-stats') | Out-Null
            $initial = Invoke-CacheProbe $tool $probeRoot '7'
            $initialHits = Get-LocalCacheHits (Invoke-CacheCommand $tool @('--show-stats'))
            Invoke-CacheCommand $tool @('--zero-stats') | Out-Null
            $env:BUILDCACHE_TERMINATE_ON_MISS = 'true'
            $warm = Invoke-CacheProbe $tool $probeRoot '7'
            $warmHits = Get-LocalCacheHits (Invoke-CacheCommand $tool @('--show-stats'))
            if ($warmHits -lt 2) { throw 'PCH and object compilation were not both served from cache.' }
            $env:BUILDCACHE_TERMINATE_ON_MISS = 'false'
            $mainPath = Get-CacheChild $probeRoot 'main.cpp'
            $main = [IO.File]::ReadAllText($mainPath).Replace('values.front()', 'values.front() + 1')
            [IO.File]::WriteAllText($mainPath, $main, [Text.UTF8Encoding]::new($false))
            $sourceChange = Invoke-CacheProbe $tool $probeRoot '8'
            $headerPath = Get-CacheChild $probeRoot 'value.h'
            $header = [IO.File]::ReadAllText($headerPath).Replace('PROBE_VALUE 7', 'PROBE_VALUE 11')
            [IO.File]::WriteAllText($headerPath, $header, [Text.UTF8Encoding]::new($false))
            $headerChange = Invoke-CacheProbe $tool $probeRoot '12'
            [ordered] @{
                version = $cacheVersion
                pchAndObjectCacheHit = $true
                sourceInvalidation = $true
                pchHeaderInvalidation = $true
                initialCacheHits = $initialHits
                warmCacheHits = $warmHits
                initialMilliseconds = $initial
                warmMilliseconds = $warm
                sourceChangeMilliseconds = $sourceChange
                headerChangeMilliseconds = $headerChange
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:LUNAGRAM_DIAGNOSTICS 'compiler-cache-probe.json') -Encoding utf8
            Set-BuildEnvironment 'LUNAGRAM_COMPILER_LAUNCHER' $tool
            Set-BuildEnvironment 'LUNAGRAM_COMPILER_CACHE_READY' 'true'
            Write-Output "Cache verified: initial hits $initialHits; warm hits $warmHits; source/header invalidation; native link/run. Initial: ${initial}ms; warm: ${warm}ms."
            & $tool --zero-stats
        } catch {
            Write-Warning 'Compiler cache was not enabled: compatibility probe failed. The normal PCH build remains available.'
            if ($Required) { throw }
        } finally {
            $env:BUILDCACHE_TERMINATE_ON_MISS = 'false'
            Pop-Location
        }
    }
    'Stats' {
        if (Test-Path -LiteralPath $tool -PathType Leaf) {
            $statistics = Invoke-CacheCommand $tool @('--show-stats')
            Write-Output $statistics
            New-Item -ItemType Directory -Force -Path $env:LUNAGRAM_DIAGNOSTICS | Out-Null
            $statistics | Set-Content -LiteralPath (Join-Path $env:LUNAGRAM_DIAGNOSTICS 'compiler-cache-stats.txt') -Encoding utf8
        }
    }
}

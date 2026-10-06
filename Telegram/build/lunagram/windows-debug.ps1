param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Prepare', 'Prune', 'Configure', 'Build', 'Smoke', 'Package', 'Diagnostics')]
    [string] $Stage
)

$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath($env:LUNAGRAM_SOURCE_ROOT)
$buildRoot = [IO.Path]::GetFullPath($env:LUNAGRAM_BUILD_ROOT)
$diagnosticsRoot = [IO.Path]::GetFullPath($env:LUNAGRAM_DIAGNOSTICS)
$packageRoot = [IO.Path]::GetFullPath($env:LUNAGRAM_PACKAGE_ROOT)
$librariesRoot = Join-Path $buildRoot 'Libraries\win64'
$thirdPartyRoot = Join-Path $buildRoot 'ThirdParty'
$outputRoot = Join-Path $sourceRoot 'out\Debug'

function Assert-BuildPath([string] $Path) {
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $prefix = $buildRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the isolated build directory: $resolved"
    }
}

function Test-KeepDependencyFile([string] $Path, [string] $LibraryRoot) {
    $libraryPath = [IO.Path]::GetFullPath($LibraryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $filePath = [IO.Path]::GetFullPath($Path)
    if (-not $filePath.StartsWith($libraryPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Dependency file is outside the native library directory.'
    }
    $relative = $filePath.Substring($libraryPath.Length).Replace([IO.Path]::DirectorySeparatorChar, [char] '/')
    $extension = [IO.Path]::GetExtension($filePath).ToLowerInvariant()
    $name = [IO.Path]::GetFileName($filePath)
    $keepExtensions = @('.lib', '.a', '.exe', '.dll', '.h', '.hpp', '.inc', '.cmake', '.pc', '.prl', '.pri', '.json', '.rcc', '.qm', '.ttf', '.otf', '.dat')
    return ($keepExtensions -contains $extension -or
        $relative -match '/(include|objects-[^/]+|cache_keys|patches|nv-codec-headers)/' -or
        $name -match '^(LICENSE|COPYING|NOTICE|LEGAL|COPYRIGHT)')
}

function Protect-Log([string] $Line) {
    foreach ($secretName in @('TDESKTOP_API_ID', 'TDESKTOP_API_HASH')) {
        $secret = [Environment]::GetEnvironmentVariable($secretName)
        if (-not [string]::IsNullOrEmpty($secret)) {
            $Line = $Line.Replace($secret, '[redacted]')
        }
    }
    return $Line
}

function Invoke-BuildCommand([string] $Command, [string[]] $Arguments) {
    $logPath = Join-Path $diagnosticsRoot ($Stage.ToLowerInvariant() + '.log')
    & $Command @Arguments 2>&1 | ForEach-Object {
        $line = Protect-Log $_.ToString()
        Write-Host $line
        Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$Stage failed with exit code $LASTEXITCODE. See the sanitized diagnostics artifact."
    }
}

function Assert-NativeExecutable([string] $Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw 'Package output is not a Windows executable.' }
        $stream.Position = 0x3C
        $headerOffset = $reader.ReadUInt32()
        $stream.Position = $headerOffset
        if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) {
            throw 'Package output must be a native x64 Windows PE executable.'
        }
    } finally {
        $stream.Dispose()
    }
}

foreach ($path in @($sourceRoot, $diagnosticsRoot, $packageRoot, $librariesRoot, $thirdPartyRoot)) {
    Assert-BuildPath $path
}
New-Item -ItemType Directory -Force -Path $diagnosticsRoot | Out-Null
Push-Location $sourceRoot
try {
    switch ($Stage) {
        'Prepare' {
            if ($env:Platform -ne 'x64') { throw 'Initialize the x64 Native Tools environment first.' }
            Invoke-BuildCommand 'python' @('Telegram\build\prepare\prepare.py', 'skip-release', 'silent', 'qt6')
        }
        'Prune' {
            Assert-BuildPath $librariesRoot
            $removedBytes = [long] 0
            $removedFiles = 0
            foreach ($file in Get-ChildItem -LiteralPath $librariesRoot -Recurse -File -Force) {
                if (Test-KeepDependencyFile $file.FullName $librariesRoot) {
                    continue
                }
                Assert-BuildPath $file.FullName
                $removedBytes += $file.Length
                Remove-Item -LiteralPath $file.FullName -Force
                $removedFiles++
            }
            "Removed $removedFiles dependency intermediate files ($removedBytes bytes)." | Add-Content -LiteralPath "$diagnosticsRoot\prune.log" -Encoding utf8
        }
        'Configure' {
            if ($env:TDESKTOP_API_ID -notmatch '^[1-9][0-9]*$' -or $env:TDESKTOP_API_ID -eq '17349' -or
                $env:TDESKTOP_API_HASH -notmatch '^[a-fA-F0-9]{32}$') {
                throw 'App-owned TDESKTOP_API_ID and TDESKTOP_API_HASH are required.'
            }
            Push-Location (Join-Path $sourceRoot 'Telegram')
            try {
                Invoke-BuildCommand 'python' @(
                    'configure.py', '-G', 'Ninja Multi-Config', 'qt6',
                    '-D', "TDESKTOP_API_ID=$env:TDESKTOP_API_ID",
                    '-D', "TDESKTOP_API_HASH=$env:TDESKTOP_API_HASH",
                    '-D', 'CMAKE_CONFIGURATION_TYPES=Debug',
                    '-D', 'CMAKE_BUILD_TYPE=Debug',
                    '-D', 'CMAKE_COMPILE_WARNING_AS_ERROR=OFF',
                    '-D', 'CMAKE_MSVC_DEBUG_INFORMATION_FORMAT=',
                    '-D', 'CMAKE_C_FLAGS_DEBUG=/Ob0 /Od /RTC1',
                    '-D', 'CMAKE_CXX_FLAGS_DEBUG=/Ob0 /Od /RTC1',
                    '-D', 'DESKTOP_APP_DISABLE_AUTOUPDATE=ON',
                    '-D', 'DESKTOP_APP_DISABLE_CRASH_REPORTS=ON'
                )
            } finally {
                Pop-Location
            }
        }
        'Build' {
            Invoke-BuildCommand 'cmake' @('--build', 'out', '--config', 'Debug', '--target', 'Telegram', '--parallel', '2')
        }
        'Smoke' {
            $executable = Join-Path $outputRoot 'Lunagram.exe'
            Assert-NativeExecutable $executable
            $smokeRoot = Join-Path $buildRoot 'smoke-profile'
            Assert-BuildPath $smokeRoot
            New-Item -ItemType Directory -Force -Path $smokeRoot | Out-Null
            $process = Start-Process -FilePath $executable -ArgumentList @('-many', '-workdir', "`"$smokeRoot`"") -WindowStyle Hidden -PassThru
            try {
                $exited = $process.WaitForExit(15000)
                if ($exited) {
                    throw "Lunagram exited during its isolated startup check (exit code $($process.ExitCode))."
                }
                'The native executable remained running through the isolated 15-second startup check.' | Set-Content -LiteralPath "$diagnosticsRoot\smoke.log" -Encoding utf8
            } finally {
                if (-not $process.HasExited) {
                    $currentProcess = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
                    if ($currentProcess -and $currentProcess.StartTime -eq $process.StartTime) {
                        Stop-Process -Id $process.Id -Force
                    }
                }
                foreach ($log in Get-ChildItem -LiteralPath $smokeRoot -File -Filter '*.txt') {
                    $content = Protect-Log ([IO.File]::ReadAllText($log.FullName))
                    Set-Content -LiteralPath (Join-Path $diagnosticsRoot ('smoke-' + $log.Name)) -Value $content -Encoding utf8
                }
            }
        }
        'Package' {
            $executable = Join-Path $outputRoot 'Lunagram.exe'
            if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
                throw 'The native Lunagram.exe build output was not found.'
            }
            Assert-NativeExecutable $executable
            $applicationRoot = Join-Path $packageRoot 'Lunagram'
            New-Item -ItemType Directory -Force -Path $applicationRoot | Out-Null
            Copy-Item -LiteralPath $executable -Destination $applicationRoot
            foreach ($dll in Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.dll') {
                Copy-Item -LiteralPath $dll.FullName -Destination $applicationRoot
            }
            foreach ($directoryName in @('modules', 'plugins')) {
                $directory = Join-Path $outputRoot $directoryName
                if (Test-Path -LiteralPath $directory -PathType Container) {
                    Copy-Item -LiteralPath $directory -Destination $applicationRoot -Recurse
                }
            }
            foreach ($notice in @('LICENSE', 'LEGAL')) {
                Copy-Item -LiteralPath (Join-Path $sourceRoot $notice) -Destination $applicationRoot
            }
            $licenseRoot = Join-Path $applicationRoot 'licenses'
            foreach ($origin in @{ source = $sourceRoot; libraries = $librariesRoot; tools = $thirdPartyRoot }.GetEnumerator()) {
                foreach ($notice in Get-ChildItem -LiteralPath $origin.Value -Recurse -File -Force) {
                    if ($notice.Name -notmatch '^(LICENSE|COPYING|NOTICE|LEGAL|COPYRIGHT)' -or $notice.FullName -match '[\\/]\.git[\\/]') { continue }
                    $relative = $notice.FullName.Substring($origin.Value.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
                    $destination = Join-Path $licenseRoot (Join-Path $origin.Key $relative)
                    New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
                    Copy-Item -LiteralPath $notice.FullName -Destination $destination
                }
            }
            $buildInfo = [ordered] @{
                application = 'Lunagram'
                upstreamVersion = '7.2.9'
                configuration = 'Debug'
                architecture = 'x64'
                repository = $env:GITHUB_REPOSITORY
                commit = $env:GITHUB_SHA
                run = $env:GITHUB_RUN_NUMBER
                source = "https://github.com/$env:GITHUB_REPOSITORY/tree/$env:GITHUB_SHA"
                sdk = '10.0.26100.0'
                toolset = '14.44'
                executableSha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
                submodules = @(git submodule status --recursive)
            }
            $buildInfo | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$applicationRoot\BUILD-INFO.json" -Encoding utf8
            @(
                'Lunagram is an independent Telegram API client based on Telegram Desktop.'
                'This package is a native Windows x64 Debug build for testing.'
                'Sign in normally; Lunagram keeps its own profile in %APPDATA%\Lunagram.'
                'Telegram profiles are not imported. Automatic stock updates are disabled.'
                'Source and pinned submodule revisions are listed in BUILD-INFO.json.'
                'Preserved upstream license terms are in LICENSE, LEGAL, and licenses.'
            ) | Set-Content -LiteralPath "$applicationRoot\README.txt" -Encoding utf8
        }
        'Diagnostics' {
            $snapshot = [ordered] @{
                capturedAt = [DateTime]::UtcNow.ToString('o')
                runner = $env:RUNNER_NAME
                source = $sourceRoot
                configuration = 'Debug'
                platform = $env:Platform
                compilerVersion = $env:VCToolsVersion
                windowsSdkVersion = $env:WindowsSDKVersion
                drives = @(Get-PSDrive -PSProvider FileSystem | Select-Object Name, Used, Free)
                submodules = @(git submodule status --recursive)
            }
            $snapshot | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$diagnosticsRoot\environment.json" -Encoding utf8
            foreach ($file in Get-ChildItem -LiteralPath $diagnosticsRoot -File) {
                $content = Protect-Log ([IO.File]::ReadAllText($file.FullName))
                [IO.File]::WriteAllText($file.FullName, $content, [Text.UTF8Encoding]::new($false))
            }
        }
    }
} finally {
    Pop-Location
}

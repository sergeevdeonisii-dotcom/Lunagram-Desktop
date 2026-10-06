param(
    [string] $QtPrefix,
    [string] $BuildDirectory
)

$ErrorActionPreference = 'Stop'
if ($env:Platform -ne 'x64') { throw 'Initialize the x64 Native Tools environment first.' }
if ([string]::IsNullOrEmpty($QtPrefix)) {
    if ([string]::IsNullOrEmpty($env:LUNAGRAM_BUILD_ROOT)) { throw 'Provide QtPrefix or LUNAGRAM_BUILD_ROOT.' }
    $QtPrefix = Join-Path $env:LUNAGRAM_BUILD_ROOT 'Libraries\win64\Qt-6.11.2'
}
$QtPrefix = [IO.Path]::GetFullPath($QtPrefix)
if (-not (Test-Path -LiteralPath (Join-Path $QtPrefix 'lib\cmake\Qt6\Qt6Config.cmake') -PathType Leaf)) {
    throw 'The prepared Qt 6 installation was not found.'
}
if ([string]::IsNullOrEmpty($BuildDirectory)) {
    if ([string]::IsNullOrEmpty($env:LUNAGRAM_BUILD_ROOT)) { throw 'Provide BuildDirectory or LUNAGRAM_BUILD_ROOT.' }
    $BuildDirectory = Join-Path $env:LUNAGRAM_BUILD_ROOT 'private-codec-tests'
}
$BuildDirectory = [IO.Path]::GetFullPath($BuildDirectory)
$librariesDirectory = Split-Path $QtPrefix -Parent
$zlibDirectory = Join-Path $librariesDirectory 'zlib'
$zlibDebug = @('Debug\libzsd.lib', 'Debug\zlibstaticd.lib') | ForEach-Object {
    Join-Path $zlibDirectory $_
} | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ([string]::IsNullOrEmpty($zlibDebug)) { throw 'The prepared Debug zlib library was not found.' }
$sourceDirectory = Join-Path $PSScriptRoot 'private_codec'
$arguments = @(
    '-S', $sourceDirectory,
    '-B', $BuildDirectory,
    '-G', 'Ninja Multi-Config',
    "-DCMAKE_PREFIX_PATH=$QtPrefix",
    "-DZLIB_INCLUDE_DIR=$zlibDirectory",
    "-DZLIB_LIBRARY_DEBUG=$zlibDebug",
    "-DZLIB_LIBRARY_RELEASE=$zlibDebug",
    '-DCMAKE_CONFIGURATION_TYPES=Debug',
    '-DCMAKE_BUILD_TYPE=Debug'
)
& cmake @arguments
if ($LASTEXITCODE -ne 0) { throw "Private codec configure failed: $LASTEXITCODE" }
& cmake --build $BuildDirectory --config Debug --target lunagram_private_codec_tests --parallel 2
if ($LASTEXITCODE -ne 0) { throw "Private codec build failed: $LASTEXITCODE" }
$originalPath = $env:PATH
try {
    $env:PATH = (Join-Path $QtPrefix 'bin') + [IO.Path]::PathSeparator + $originalPath
    & ctest --test-dir $BuildDirectory -C Debug --output-on-failure
    if ($LASTEXITCODE -ne 0) { throw "Private codec tests failed: $LASTEXITCODE" }
} finally {
    $env:PATH = $originalPath
}

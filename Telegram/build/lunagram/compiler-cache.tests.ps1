$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$helper = Join-Path $PSScriptRoot 'compiler-cache.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($helper, [ref] $tokens, [ref] $errors)
if ($errors.Count) { throw 'Compiler cache helper has syntax errors.' }
foreach ($name in @('Get-CacheChild', 'Get-CacheIdentity', 'Set-BuildEnvironment', 'Get-LocalCacheHits')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing cache helper: $name" }
    . ([ScriptBlock]::Create($definition.Extent.Text))
}
$root = 'D:\CacheFixture'
if ((Get-CacheChild $root 'compiler-cache-v1') -ne 'D:\CacheFixture\compiler-cache-v1') { throw 'Unexpected cache directory.' }
foreach ($name in @('..', '..\foreign', 'D:\foreign', '.')) {
    $rejected = $false
    try { Get-CacheChild $root $name | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "Cache boundary accepted $name" }
}
$original = Get-CacheIdentity @('msvc', 'sdk', 'headers')
if ($original -notmatch '^[a-f0-9]{64}$') { throw 'Invalid cache fingerprint.' }
if ($original -ne (Get-CacheIdentity @('msvc', 'sdk', 'headers'))) { throw 'Cache fingerprint is unstable.' }
foreach ($parts in @(@('msvc-new', 'sdk', 'headers'), @('msvc', 'sdk-new', 'headers'), @('msvc', 'sdk', 'headers-new'))) {
    if ($original -eq (Get-CacheIdentity $parts)) { throw 'Toolchain changes did not invalidate the cache.' }
}
$rejected = $false
try { Set-BuildEnvironment 'LUNAGRAM_TEST_UNUSED' "bad`nvalue" } catch { $rejected = $true }
if (-not $rejected) { throw 'Multiline environment injection was accepted.' }
$source = [IO.File]::ReadAllText($helper)
if ((Get-LocalCacheHits "Cache status:`n  Local hits:        2`n  Local misses:      0") -ne 2) { throw 'Cache hit counter parsing failed.' }
$rejected = $false
try { Get-LocalCacheHits 'unknown statistics' | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw 'Unknown statistics were treated as successful caching.' }
foreach ($required in @('BUILDCACHE_TERMINATE_ON_MISS', 'BUILDCACHE_ACCURACY', "'STRICT'", '1073741824', '3221225472')) {
    if (-not $source.Contains($required)) { throw "Missing cache safety setting: $required" }
}
$build = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'windows-debug.ps1'))
if ($build.Contains('CMAKE_DISABLE_PRECOMPILE_HEADERS')) { throw 'Compiler cache must not disable PCH.' }
foreach ($language in @('C', 'CXX')) {
    if (-not $build.Contains("CMAKE_${language}_COMPILER_LAUNCHER=")) { throw 'Missing compiler launcher configuration.' }
}
Write-Output 'Compiler cache tests passed: syntax, path boundaries, invalidation, memory limits and PCH preservation.'

$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$helperPath = Join-Path $PSScriptRoot 'windows-debug.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($helperPath, [ref] $tokens, [ref] $errors)
if ($errors.Count -ne 0) { throw 'The Windows build helper has PowerShell syntax errors.' }
foreach ($name in @('Assert-BuildPath', 'Test-KeepDependencyFile')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Missing build-helper function: $name" }
    . ([ScriptBlock]::Create($definition.Extent.Text))
}

$buildRoot = 'D:\LunagramBuildFixture'
$libraryRoot = Join-Path $buildRoot 'Libraries\win64'
$cases = [ordered] @{
    'cache_keys\qt_6_11_2' = $true
    'cache_keys\openssl3' = $true
    'qt_6_11_2\include\QtCore\qglobal' = $true
    'qt_6_11_2\include\QtCore\qconfig.h' = $true
    'qt_6_11_2\objects-Debug\Core.obj' = $true
    'patches\qt.patch' = $true
    'nv-codec-headers\include\ffnvcodec\dynlink_cuda.h' = $true
    'openssl3\out.dbg\libcrypto.lib' = $true
    'qt_6_11_2\bin\Qt6Cored.dll' = $true
    'qt_6_11_2\LICENSE.LGPL3' = $true
    'ffmpeg\COPYING.GPLv3' = $true
    'ffmpeg\src\intermediate.obj' = $false
    'qt_6_11_2\src\corelib\temporary.cpp' = $false
}
foreach ($case in $cases.GetEnumerator()) {
    $actual = Test-KeepDependencyFile (Join-Path $libraryRoot $case.Key) $libraryRoot
    if ($actual -ne $case.Value) { throw "Incorrect dependency preservation for $($case.Key)" }
}
Assert-BuildPath (Join-Path $libraryRoot 'openssl3\out.dbg\libcrypto.lib')
foreach ($foreignPath in @('D:\LunagramBuildFixture-other\file.obj', 'D:\outside\file.obj')) {
    $rejected = $false
    try { Assert-BuildPath $foreignPath } catch { $rejected = $true }
    if (-not $rejected) { throw "Build boundary did not reject $foreignPath" }
}
$rejected = $false
try { Test-KeepDependencyFile 'D:\outside\cache_keys\qt' $libraryRoot } catch { $rejected = $true }
if (-not $rejected) { throw 'Dependency preservation accepted a path outside the library directory.' }
Write-Output 'Windows helper checks passed: 13 path-preservation cases and build-directory boundaries.'

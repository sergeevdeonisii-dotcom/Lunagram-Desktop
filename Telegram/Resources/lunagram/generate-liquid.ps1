$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Drawing
$backgroundSource = Join-Path $PSScriptRoot 'liquid-background.cs'
if ($PSVersionTable.PSEdition -eq 'Core') {
    $backgroundReferences = @(
        [Drawing.Bitmap].Assembly.Location,
        'System.Drawing.Primitives',
        'System.Xml.ReaderWriter',
        'System.IO.Compression',
        'System.Collections',
        'System.Text.RegularExpressions',
        'System.Runtime'
    )
    foreach ($reference in [Drawing.Bitmap].Assembly.GetReferencedAssemblies()) {
        if ($reference.Name.StartsWith('System.Private.Windows.')) {
            $backgroundReferences += $reference.Name
        }
    }
    Add-Type -Path $backgroundSource -ReferencedAssemblies $backgroundReferences
} else {
    Add-Type -Path $backgroundSource -ReferencedAssemblies @(
        'System.dll',
        'System.Core.dll',
        'System.Drawing.dll',
        'System.IO.Compression.dll',
        'System.Xml.dll'
    )
}

$resourcesPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$defaultsPath = [IO.Path]::GetFullPath((Join-Path $resourcesPath '../lib_ui/ui/colors.palette'))
$overridePath = Join-Path $PSScriptRoot 'liquid.tdesktop-palette'
$outputPath = Join-Path $PSScriptRoot 'liquid.tdesktop-theme'
$encoding = [Text.UTF8Encoding]::new($false)
$values = [ordered]@{}

foreach ($line in [IO.File]::ReadAllLines($defaultsPath)) {
    if ($line -match '^([A-Za-z0-9_]+):\s*([^;]+);') {
        $values[$Matches[1]] = ($Matches[2] -split '\|')[0].Trim()
    }
}

$baseArchive = [IO.Compression.ZipFile]::OpenRead((Join-Path $resourcesPath 'day-blue.tdesktop-theme'))
try {
    $baseReader = [IO.StreamReader]::new($baseArchive.GetEntry('colors.tdesktop-theme').Open())
    try {
        foreach ($line in ($baseReader.ReadToEnd() -split '\r?\n')) {
            if ($line -match '^([A-Za-z0-9_]+):\s*([^;]+);') {
                if ($values.Contains($Matches[1])) {
                    $values[$Matches[1]] = $Matches[2].Trim()
                }
            }
        }
    } finally {
        $baseReader.Dispose()
    }
} finally {
    $baseArchive.Dispose()
}

$overrides = @{}
foreach ($line in [IO.File]::ReadAllLines($overridePath)) {
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }
    if ($line -notmatch '^([A-Za-z0-9_]+):\s*(#[A-Fa-f0-9]{6}(?:[A-Fa-f0-9]{2})?);$') {
        throw "Invalid Liquid palette line: $line"
    }
    $key = $Matches[1]
    $value = $Matches[2]
    if (-not $values.Contains($key)) {
        throw "Unknown Liquid palette key: $key"
    }
    if ($overrides.ContainsKey($key)) {
        throw "Duplicate Liquid palette key: $key"
    }
    $overrides[$key] = $value
    $values[$key] = $value
}

foreach ($entry in $values.GetEnumerator()) {
    if ($entry.Value -match '^#[A-Fa-f0-9]{6}(?:[A-Fa-f0-9]{2})?$') {
        continue
    }
    if (-not $values.Contains($entry.Value)) {
        throw "Unknown palette reference: $($entry.Key) -> $($entry.Value)"
    }
}

$paletteText = (($values.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value);" }) -join "`r`n") + "`r`n"
$paletteBytes = $encoding.GetBytes($paletteText)
$patternPath = Join-Path $resourcesPath 'art/background.tgv'
$backgroundBytes = [LiquidBackground]::Render($patternPath)
$outputStream = [IO.File]::Open($outputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
$outputArchive = [IO.Compression.ZipArchive]::new($outputStream, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($entryData in @(
        @{ Name = 'colors.tdesktop-theme'; Bytes = $paletteBytes },
        @{ Name = 'background.png'; Bytes = $backgroundBytes }
    )) {
        $entry = $outputArchive.CreateEntry($entryData.Name, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $entryStream = $entry.Open()
        try {
            $entryStream.Write($entryData.Bytes, 0, $entryData.Bytes.Length)
        } finally {
            $entryStream.Dispose()
        }
    }
} finally {
    $outputArchive.Dispose()
    $outputStream.Dispose()
}

Write-Output "Generated Liquid with $($values.Count) palette keys and $($overrides.Count) reference overrides."

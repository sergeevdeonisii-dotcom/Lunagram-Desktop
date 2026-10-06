$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$resources = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Resources'))
$destination = Join-Path $resources 'lunagram'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$presets = @(
    @{ Name = 'glass'; Base = 'night.tdesktop-theme'; Colors = @{
        windowBg='#111522'; windowBgOver='#1b2135'; windowBgRipple='#283047';
        windowFg='#f1f2ff'; windowBgActive='#687cf0'; windowActiveTextFg='#a7b5ff';
        activeButtonBg='#687cf0'; activeButtonBgOver='#7b8dfa'; activeButtonBgRipple='#8f9dff';
        boxBg='#161b2b'; boxTitleFg='#f1f2ff'; menuBg='#161b2b'; menuBgOver='#242c43';
        dialogsBg='#111522'; dialogsBgOver='#1b2135'; dialogsBgActive='#5368d3';
        topBarBg='#161b2b'; historyComposeAreaBg='#161b2b';
        msgInBg='#20283a'; msgOutBg='#354570'; msgInBgSelected='#334263'; msgOutBgSelected='#465b91';
    }}
    @{ Name = 'black'; Base = 'night.tdesktop-theme'; Colors = @{
        windowBg='#000000'; windowBgOver='#161616'; windowBgRipple='#252525';
        windowFg='#f6f6fa'; windowBgActive='#7488fa'; windowActiveTextFg='#a5b3ff';
        activeButtonBg='#667df2'; activeButtonBgOver='#7b8dfa'; activeButtonBgRipple='#8f9dff';
        boxBg='#080808'; boxTitleFg='#f6f6fa'; menuBg='#080808'; menuBgOver='#202020';
        dialogsBg='#000000'; dialogsBgOver='#161616'; dialogsBgActive='#35436f';
        topBarBg='#080808'; historyComposeAreaBg='#080808';
        msgInBg='#1b1b20'; msgOutBg='#303c65'; msgInBgSelected='#303038'; msgOutBgSelected='#465789';
    }}
    @{ Name = 'pearl'; Base = 'day-blue.tdesktop-theme'; Colors = @{
        windowBg='#f8f7fd'; windowBgOver='#eeecf7'; windowBgRipple='#e2dfed';
        windowFg='#222238'; windowBgActive='#6574dd'; windowActiveTextFg='#5665c9';
        activeButtonBg='#6574dd'; activeButtonBgOver='#747fe7'; activeButtonBgRipple='#8290ef';
        boxBg='#fbfaff'; boxTitleFg='#222238'; menuBg='#fbfaff'; menuBgOver='#eeecf7';
        dialogsBg='#f8f7fd'; dialogsBgOver='#eeecf7'; dialogsBgActive='#6574dd';
        topBarBg='#fbfaff'; historyComposeAreaBg='#fbfaff';
        msgInBg='#ffffff'; msgOutBg='#e4e6fc'; msgInBgSelected='#ecebf7'; msgOutBgSelected='#d0d5fa';
    }}
)
foreach ($preset in $presets) {
    $source = [IO.Compression.ZipFile]::OpenRead((Join-Path $resources $preset.Base))
    $outputPath = Join-Path $destination ($preset.Name + '.tdesktop-theme')
    $stream = [IO.File]::Open($outputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    $output = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entry in $source.Entries) {
            $target = $output.CreateEntry($entry.FullName, [IO.Compression.CompressionLevel]::Optimal)
            $target.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $inputStream = $entry.Open()
            $targetStream = $target.Open()
            try {
                if ($entry.FullName -eq 'colors.tdesktop-theme') {
                    $reader = [IO.StreamReader]::new($inputStream)
                    $text = $reader.ReadToEnd()
                    foreach ($color in $preset.Colors.GetEnumerator()) {
                        $pattern = '(?m)^' + [regex]::Escape($color.Key) + ':\s*[^;]+;'
                        if (-not [regex]::IsMatch($text, $pattern)) { throw "Unknown palette key: $($color.Key)" }
                        $text = [regex]::Replace($text, $pattern, ($color.Key + ': ' + $color.Value + ';'))
                    }
                    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($text -replace '\r?\n', "`r`n"))
                    $targetStream.Write($bytes, 0, $bytes.Length)
                } else {
                    $inputStream.CopyTo($targetStream)
                }
            } finally {
                $inputStream.Dispose()
                $targetStream.Dispose()
            }
        }
    } finally {
        $output.Dispose()
        $stream.Dispose()
        $source.Dispose()
    }
    Write-Output "Generated $($preset.Name) from $($preset.Base); upstream background and palette coverage preserved."
}

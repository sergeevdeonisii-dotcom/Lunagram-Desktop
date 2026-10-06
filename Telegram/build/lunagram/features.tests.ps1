#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Join-Path $PSScriptRoot '..\..\..'),
    [string] $BaseRef = 'fb2e33209517e1a34637d837bfadb3783f2fd59c'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$script:CheckCount = 0
$script:Failures = [Collections.Generic.List[string]]::new()
$utf8 = [Text.UTF8Encoding]::new($false, $true)

function Check([bool] $condition, [string] $label) {
    $script:CheckCount += 1
    if (-not $condition) { $script:Failures.Add($label) }
}

function Read-Source([string] $relative) {
    $path = Join-Path $RepositoryRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Check $false "Missing source: $relative"
        return ''
    }
    return [IO.File]::ReadAllText($path, $utf8)
}

function Git-Lines([string[]] $arguments) {
    $result = @(& git -c core.quotepath=false -c core.safecrlf=false -C $RepositoryRoot @arguments)
    if ($LASTEXITCODE -ne 0) { throw "Read-only Git check failed: $($arguments[0])" }
    return $result
}

function Tags([string] $value) {
    return @([regex]::Matches($value, '(?<!\\)\{([A-Za-z_][A-Za-z0-9_]*)\}') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ','
}

function Read-Translations([string] $relative) {
    $source = Read-Source $relative
    $entries = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $families = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $variants = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $pattern = '(?m)^\s*"(?<key>lng_lunagram_[^"\r\n]+)"\s*=\s*"(?<value>(?:\\.|[^"\\\r\n])*)"\s*;\s*(?://[^\r\n]*)?$'
    $matches = [regex]::Matches($source, $pattern)
    $declared = [regex]::Matches($source, '(?m)^\s*"lng_lunagram_').Count
    Check ($matches.Count -eq $declared -and $declared -gt 0) "Translation syntax: $relative"
    foreach ($match in $matches) {
        $key = $match.Groups['key'].Value
        $value = $match.Groups['value'].Value
        if ($entries.ContainsKey($key)) {
            Check $false "Duplicate translation: $relative/$key"
            continue
        }
        $entries.Add($key, $value)
        $parts = $key.Split('#')
        $family = $parts[0]
        $tags = Tags $value
        if ($families.ContainsKey($family)) {
            Check ($families[$family] -ceq $tags) "Plural tag consistency: $relative/$family"
        } else {
            $families.Add($family, $tags)
            $variants.Add($family, [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal))
        }
        if ($parts.Count -gt 1) {
            Check ($parts.Count -eq 2 -and $parts[1] -in @('zero', 'one', 'two', 'few', 'many', 'other')) "Plural suffix: $relative/$key"
            $variants[$family].Add($parts[1]) | Out-Null
            Check ($tags.Split(',') -contains 'count') "Plural count tag: $relative/$key"
        } else {
            $variants[$family].Add('plain') | Out-Null
        }
    }
    foreach ($family in $variants.Keys) {
        $set = $variants[$family]
        Check (-not ($set.Contains('plain') -and $set.Count -gt 1)) "Mixed plain/plural family: $relative/$family"
        if (-not $set.Contains('plain')) {
            Check ($set.Contains('one') -and $set.Contains('other')) "Required plural forms: $relative/$family"
            if ($relative.EndsWith('lunagram_ru.strings')) {
                Check ($set.Contains('few') -and $set.Contains('many')) "Russian plural forms: $family"
            }
        }
    }
    return $families
}

function Call-Arguments([string] $source, [int] $offset) {
    while ($offset -lt $source.Length -and [char]::IsWhiteSpace($source[$offset])) { $offset += 1 }
    if ($offset -ge $source.Length -or $source[$offset] -ne '(') { return $null }
    $start = $offset + 1
    $depth = 1
    $quote = [char]0
    for ($index = $start; $index -lt $source.Length; $index += 1) {
        $ch = $source[$index]
        if ($quote -ne [char]0) {
            if ($ch -eq '\') { $index += 1 }
            elseif ($ch -eq $quote) { $quote = [char]0 }
        } elseif ($ch -eq '"' -or $ch -eq "'") {
            $quote = $ch
        } elseif ($ch -eq '(') {
            $depth += 1
        } elseif ($ch -eq ')') {
            $depth -= 1
            if ($depth -eq 0) { return $source.Substring($start, $index - $start) }
        }
    }
    return $null
}

function Method-Source([string] $source, [string] $name) {
    $start = $source.IndexOf("void $name(", [StringComparison]::Ordinal)
    if ($start -lt 0) { $start = $source.IndexOf("$name(", [StringComparison]::Ordinal) }
    if ($start -lt 0) {
        Check $false "Missing composer method: $name"
        return ''
    }
    $end = $source.IndexOf("`nvoid ", $start + 1, [StringComparison]::Ordinal)
    return $(if ($end -lt 0) { $source.Substring($start) } else { $source.Substring($start, $end - $start) })
}

Write-Output 'Lunagram source/model validation only: no C++ compilation, protocol simulation or UI/runtime test.'
$hasBaseline = -not [string]::IsNullOrWhiteSpace($BaseRef)
if ($hasBaseline) {
    $baseline = @(& git -C $RepositoryRoot cat-file -t $BaseRef 2>$null)
    if ($LASTEXITCODE -ne 0 -or $baseline -notcontains 'commit') {
        throw "Pinned baseline is unavailable. Fetch the exact stable ancestor $BaseRef before this read-only check, or pass -BaseRef '' for explicitly limited checks."
    }
}
$untracked = @(Git-Lines @('ls-files', '--others', '--exclude-standard'))
$added = $(if ($hasBaseline) { @(Git-Lines @('diff', '--name-only', '--diff-filter=A', $BaseRef, '--')) } else { @() })
$newPaths = @($added + $untracked | Where-Object { $_ } | Sort-Object -Unique)
$modulePaths = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'Telegram/SourceFiles/lunagram') -File |
    Where-Object { $_.Extension -in @('.cpp', '.h') } |
    ForEach-Object { [IO.Path]::GetRelativePath($RepositoryRoot, $_.FullName).Replace('\', '/') })
$cppPaths = @($modulePaths + @('Telegram/SourceFiles/settings/sections/settings_lunagram.cpp', 'Telegram/SourceFiles/settings/sections/settings_lunagram.h') +
    @($newPaths | Where-Object { $_ -match '^Telegram/SourceFiles/.+\.(cpp|h)$' }) | Sort-Object -Unique)
$cmake = Read-Source 'Telegram/CMakeLists.txt'
foreach ($path in $cppPaths) {
    $relative = $path.Substring('Telegram/SourceFiles/'.Length)
    Check ($cmake -match ('(?m)^\s*' + [regex]::Escape($relative) + '\s*$')) "Missing CMake source registration: $relative"
}
$testCodePaths = @($newPaths | Where-Object { $_ -match '\.(cpp|h)$' -and $_ -notmatch '^Telegram/SourceFiles/' })
$testCmakeFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'Telegram/build') -Recurse -File -Filter 'CMakeLists.txt')
foreach ($path in $testCodePaths) {
    $absolute = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $path))
    $registered = $false
    foreach ($file in $testCmakeFiles) {
        $content = [IO.File]::ReadAllText($file.FullName, $utf8)
        foreach ($match in [regex]::Matches($content, '(?m)^\s*"?(?<path>[^"\s;$]+\.(?:cpp|h))"?\s*$')) {
            $target = [IO.Path]::GetFullPath((Join-Path $file.DirectoryName $match.Groups['path'].Value))
            if ($target -eq $absolute) { $registered = $true }
        }
    }
    Check $registered "Missing standalone-test CMake source registration: $path"
}

$english = Read-Translations 'Telegram/Resources/langs/lang.strings'
$russian = Read-Translations 'Telegram/Resources/langs/lunagram_ru.strings'
foreach ($family in $english.Keys) {
    Check ($russian.ContainsKey($family)) "Missing Russian family: $family"
    if ($russian.ContainsKey($family)) {
        Check ($english[$family] -ceq $russian[$family]) "EN/RU placeholder mismatch: $family"
    }
}
foreach ($family in $russian.Keys) { Check ($english.ContainsKey($family)) "Russian key has no English family: $family" }
$referenced = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$resources = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'Telegram/SourceFiles') -Recurse -File) {
    if ($file.Extension -notin @('.cpp', '.h')) { continue }
    $source = [IO.File]::ReadAllText($file.FullName, $utf8)
    foreach ($match in [regex]::Matches($source, '\btr::(?<key>lng_lunagram_[A-Za-z0-9_]+)\b')) {
        $key = $match.Groups['key'].Value
        $referenced.Add($key) | Out-Null
        $arguments = Call-Arguments $source ($match.Index + $match.Length)
        if ($null -ne $arguments -and $english.ContainsKey($key)) {
            $tags = @([regex]::Matches($arguments, '\blt_([A-Za-z0-9_]+)\b') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ','
            Check ($tags -ceq $english[$key]) "C++ placeholder mismatch: $($file.Name)/$key"
        }
    }
    foreach ($match in [regex]::Matches($source, ':/lunagram/[^"\s]+')) { $resources.Add($match.Value) | Out-Null }
}
foreach ($key in $referenced) {
    Check ($english.ContainsKey($key) -and $russian.ContainsKey($key)) "Referenced localization family missing: $key"
}

$qrcPath = 'Telegram/Resources/qrc/telegram/telegram.qrc'
$qrcDirectory = Split-Path (Join-Path $RepositoryRoot $qrcPath) -Parent
$qrc = [xml](Read-Source $qrcPath)
$aliases = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
foreach ($group in $qrc.RCC.qresource) {
    if ([string]$group.prefix -ne '/lunagram') { continue }
    foreach ($file in $group.file) {
        $uri = ':/lunagram/' + [string]$file.alias
        $path = [IO.Path]::GetFullPath((Join-Path $qrcDirectory $file.InnerText))
        Check (-not $aliases.ContainsKey($uri)) "Duplicate Lunagram resource alias: $uri"
        $aliases[$uri] = $path
        Check (Test-Path -LiteralPath $path -PathType Leaf) "Missing Lunagram resource: $uri"
    }
}
foreach ($uri in $resources) { Check ($aliases.ContainsKey($uri)) "Unregistered source resource URI: $uri" }
foreach ($name in @('glass', 'black', 'pearl')) {
    $uri = ":/lunagram/themes/$name.tdesktop-theme"
    Check ($aliases.ContainsKey($uri)) "Missing theme alias: $uri"
    if (-not $aliases.ContainsKey($uri) -or -not (Test-Path -LiteralPath $aliases[$uri] -PathType Leaf)) { continue }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($aliases[$uri])
        try {
            Check (@($archive.Entries | Where-Object { $_.FullName -eq 'colors.tdesktop-theme' }).Count -eq 1) "Theme palette missing or duplicated: $name"
            foreach ($entry in $archive.Entries) {
                Check ($entry.FullName -notmatch '(^[/\\]|(^|[/\\])\.\.([/\\]|$)|:)') "Unsafe theme entry: $name/$($entry.FullName)"
            }
        } finally { $archive.Dispose() }
    } catch { Check $false "Unreadable theme archive: $name" }
}

$textExtensions = @('.cpp', '.h', '.ps1', '.py', '.yml', '.yaml', '.toml', '.strings', '.qrc', '.style', '.cmake', '.json', '.palette', '.md', '.txt')
$textPaths = @($newPaths + $cppPaths + @('Telegram/Resources/langs/lunagram_ru.strings', 'Telegram/build/lunagram/features.tests.ps1') | Sort-Object -Unique)
$textCount = 0
foreach ($path in $textPaths) {
    if ([IO.Path]::GetExtension($path) -notin $textExtensions) { continue }
    $absolute = Join-Path $RepositoryRoot $path
    Check (Test-Path -LiteralPath $absolute -PathType Leaf) "Missing new text file: $path"
    if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) { continue }
    $bytes = [IO.File]::ReadAllBytes($absolute)
    Check (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf)) "UTF-8 BOM: $path"
    try {
        $text = $utf8.GetString($bytes)
        Check ($text -notmatch '(?<!\r)\n|\r(?!\n)') "Not exclusively CRLF: $path"
    } catch { Check $false "Invalid UTF-8 text: $path" }
    $textCount += 1
}

$featureSource = ($modulePaths | ForEach-Object { Read-Source $_ }) -join "`n"
Check ($featureSource -notmatch '(?i)\b(ghost|stealth|suppress_online|suppress_typing|suppress_read)\b') 'No ghost/suppression identifiers in native feature module'
Check ($featureSource -notmatch '\b(MTPaccount_UpdateStatus|MTPmessages_ReadHistory|MTPchannels_ReadHistory|MTPmessages_SetTyping|sendProgressManager)\b') 'Native feature module does not intercept presence/read/typing protocol paths'
if ($hasBaseline) {
    foreach ($path in @('Telegram/SourceFiles/api/api_send_progress.cpp', 'Telegram/SourceFiles/api/api_send_progress.h', 'Telegram/SourceFiles/api/api_read_metrics.cpp', 'Telegram/SourceFiles/api/api_user_privacy.cpp')) {
        $changed = @(Git-Lines @('diff', '--name-only', $BaseRef, '--', $path))
        Check ($changed.Count -eq 0) "Stock protocol/privacy source unchanged: $path"
    }
} else {
    Write-Warning 'No baseline requested: added-file coverage and stock protocol/privacy file comparison are limited.'
}

$composer = Read-Source 'Telegram/SourceFiles/lunagram/composer.cpp'
Check ($composer -match 'std::clamp\(requested, 400, 5000\)' -and $composer -match 'requested <= 0') 'Undo is opt-in and bounded400..5000ms'
Check ($composer -match 'callOnce\(_delay, Qt::PreciseTimer\)' -and $composer -match '\.infinite = true') 'Precise undo timer and durable cancel UI'
Check ($composer -match '_timer.cancel\(\);\s+_send = nullptr;' -and $composer -match 'strong->cancel\(\)') 'Cancel removes queued callback and timer'
Check ($composer -match '_sessionId\(controller->session\(\).uniqueId\(\)\)' -and $composer -match '&controller->session\(\) != session') 'Deferred send account/controller binding'
foreach ($definition in @(
    @{ Path = 'Telegram/SourceFiles/history/history_widget.cpp'; Method = 'HistoryWidget::sendTextWithTags' },
    @{ Path = 'Telegram/SourceFiles/history/view/history_view_chat_section.cpp'; Method = 'ChatWidget::sendTextWithTags' }
)) {
    $source = Read-Source $definition.Path
    $method = Method-Source $source $definition.Method
    $queue = $method.IndexOf('QueueUndoSend', [StringComparison]::Ordinal)
    $send = $method.IndexOf('session().api().sendMessage(', [StringComparison]::Ordinal)
    Check ($queue -ge 0 -and $send -gt $queue) "Undo queue precedes actual send: $($definition.Method)"
    Check ($method -match 'pending\(\)' -and $method -match 'undoApproved') "Repeated send and replay guards: $($definition.Method)"
    Check ($method -match 'getTextWithTags\(\) != draft' -and $method -match 'replyTo\(\) != reply' -and $method -match 'prepareSendAction\(options\) != action') "Draft/context snapshot guards: $($definition.Method)"
    Check ($method -match 'IsChatLocked\(&session\(\), action.history->peer->id\)') "Vault-locked deferred send denied: $($definition.Method)"
    Check ($source -match 'VaultChanges\(&session\(\)\)[\s\S]{0,500}_lunagramPendingSend->cancel\(\)') "Vault change cancels pending send: $($definition.Method)"
    Check ($method -match '!sendOptions.scheduled' -and $method -match '!sendOptions.price' -and $method -match '!ephemeral') "Special sends bypass undo: $($definition.Method)"
}
$formatting = Read-Source 'Telegram/SourceFiles/lunagram/formatting.cpp'
Check ($formatting -match 'existing == EntityType::Code' -and $formatting -match 'existing == EntityType::Pre' -and $formatting -match 'existing == EntityType::Blockquote') 'Explicit code/pre/quote formatting protected'
$vault = Read-Source 'Telegram/SourceFiles/lunagram/chat_vault.cpp'
Check ($vault -notmatch 'decoded\.array\(\)\.front\(') 'Vault JSON lookup uses supported QJsonArray API'
Check ($vault -match 'Ui::PasswordInput \*AddPinField' -and $vault -match 'addRow\(object_ptr<Ui::RpWidget>\(box\)\)' -and $vault -notmatch 'addRow\(object_ptr<Ui::PasswordInput>') 'Masked PIN fields are hosted in RpWidget layout rows'
Check ($composer -match "tr::marked\(QString::number\(_delay / 1000\., 'f', 1\)\)") 'Undo seconds placeholder uses the rich-text projection type'
Check ($vault -match 'kIterations = 600000' -and $vault -match 'PKCS5_PBKDF2_HMAC' -and $vault -match 'RAND_bytes' -and $vault -match 'CRYPTO_memcmp') 'Vault PIN verifier source primitives'
Check ($vault -match 'state.epoch != epoch' -and $vault -match 'crl::on_main\(weakSession' -and $vault -match 'state.unlocked = false') 'Vault asynchronous lifetime/lock source guards'
Check ($vault -match '!state.valid \|\| \(!state.unlocked && state.peers.contains\(peer\)\)') 'Invalid vault metadata fails closed'
$notifications = Read-Source 'Telegram/SourceFiles/window/notifications_manager.cpp'
foreach ($definition in @(
    @{ Method = 'Manager::notificationActivated'; Barrier = 'onBeforeNotificationActivated(' },
    @{ Method = 'Manager::notificationReplied'; Barrier = 'session->data().history(' },
    @{ Method = 'Manager::notificationActionActivated'; Barrier = 'session->data().history(' },
    @{ Method = 'Manager::openNotificationMessage'; Barrier = 'Core::App().passcodeLocked()' }
)) {
    $method = Method-Source $notifications $definition.Method
    $guard = $method.IndexOf('Lunagram::IsChatLocked(', [StringComparison]::Ordinal)
    $barrier = $method.IndexOf($definition.Barrier, [StringComparison]::Ordinal)
    Check ($guard -ge 0 -and $barrier -gt $guard -and $method -match 'IsChatLocked[^\r\n]*\)\s*\{\s*return(?: nullptr)?;') "Late notification vault guard precedes action: $($definition.Method)"
}
$notificationAction = Method-Source $notifications 'Manager::notificationActionActivated'
Check ($notificationAction -match 'actionId == u"markAsRead"_q\)\s*\{\s*notificationReplied\(id, \{\}\);') 'Late mark-read notification action uses the vault-guarded reply path'
$privateStore = Read-Source 'Telegram/SourceFiles/lunagram/secure_storage.cpp'
$codecPath = 'Telegram/SourceFiles/lunagram/private_codec.cpp'
$hasCodec = Test-Path -LiteralPath (Join-Path $RepositoryRoot $codecPath)
$codec = $(if ($hasCodec) { Read-Source $codecPath } else { $privateStore })
Check ($codec -match 'CryptProtectData' -and $codec -match 'CryptUnprotectData' -and $codec -match 'CRYPTPROTECT_UI_FORBIDDEN' -and $cmake -match 'Crypt32') 'Native DPAPI source and linkage declarations'
if ($hasCodec) {
    Check ($privateStore -match 'PrivateCodec::Protect\(payload, entropy\)' -and $privateStore -match 'PrivateCodec::Unprotect\(file.readAll\(\), entropy\)') 'Production storage routes through the tested codec'
}
Check ($privateStore -match 'QSaveFile\(path\)' -and $privateStore -match '!Read\(path, entropy\).has_value\(\)' -and $privateStore -match 'Lunagram/1/%1/%2') 'Private storage atomic-save/account entropy source invariants'
$automaticMedia = Read-Source 'Telegram/SourceFiles/data/data_auto_download.cpp'
$lowMediaGuard = 'if\s*\(Lunagram::Enabled\(&(?:document|photo)->session\(\), Lunagram::Flag::Emergency\)\)\s*\{\s*return false;\s*\}'
Check ([regex]::Matches($automaticMedia, $lowMediaGuard).Count -eq 6) 'Reduced-media source guards cover six automatic download/play decisions'

Write-Output "Coverage: $($cppPaths.Count) feature sources, $($referenced.Count) referenced localization families, $($aliases.Count) Lunagram resources, $textCount new/feature text files."
if ($script:Failures.Count) {
    foreach ($failure in $script:Failures) { Write-Output "FAIL: $failure" }
    throw "$($script:Failures.Count) of $($script:CheckCount) source/model checks failed. No compile/runtime validation was performed."
}
Write-Output "PASS: $($script:CheckCount) source/model checks; $($cppPaths.Count) registered feature sources, $($referenced.Count) localization families, $($aliases.Count) resources, $textCount new/feature text files."
Write-Output 'Native C++ compilation, DPAPI execution, protocol behavior and interactive UI/vault tests remain required.'

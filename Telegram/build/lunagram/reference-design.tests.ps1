#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Join-Path $PSScriptRoot '..\..\..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$script:Checks = 0
$script:Failures = [Collections.Generic.List[string]]::new()
$script:Sources = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
$utf8 = [Text.UTF8Encoding]::new($false, $true)

function Check([bool] $condition, [string] $label) {
    $script:Checks += 1
    if (-not $condition) { $script:Failures.Add($label) }
}

function Read-Source([string] $relative) {
    if ($script:Sources.ContainsKey($relative)) { return $script:Sources[$relative] }
    $path = Join-Path $RepositoryRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Check $false "Missing source: $relative"
        $script:Sources[$relative] = ''
        return ''
    }
    $script:Sources[$relative] = [IO.File]::ReadAllText($path, $utf8)
    return $script:Sources[$relative]
}

function Block-Source([string] $source, [string] $pattern, [string] $label) {
    $match = [regex]::Match($source, $pattern)
    Check $match.Success "Source declaration: $label"
    if (-not $match.Success) { return '' }
    $start = $source.IndexOf('{', $match.Index + $match.Length - 1)
    if ($start -lt 0) { Check $false "Opening brace: $label"; return '' }
    $depth = 1
    $quote = [char]0
    for ($index = $start + 1; $index -lt $source.Length; $index += 1) {
        $ch = $source[$index]
        if ($quote -ne [char]0) {
            if ($ch -eq '\') { $index += 1 }
            elseif ($ch -eq $quote) { $quote = [char]0 }
        } elseif ($ch -eq '/' -and $index + 1 -lt $source.Length -and $source[$index + 1] -eq '/') {
            $lineEnd = $source.IndexOf("`n", $index + 2)
            if ($lineEnd -lt 0) { break }
            $index = $lineEnd
        } elseif ($ch -eq '/' -and $index + 1 -lt $source.Length -and $source[$index + 1] -eq '*') {
            $commentEnd = $source.IndexOf('*/', $index + 2)
            if ($commentEnd -lt 0) { break }
            $index = $commentEnd + 1
        } elseif ($ch -eq '"' -or $ch -eq "'") {
            $quote = $ch
        } elseif ($ch -eq '{') {
            $depth += 1
        } elseif ($ch -eq '}') {
            $depth -= 1
            if ($depth -eq 0) { return $source.Substring($start + 1, $index - $start - 1) }
        }
    }
    Check $false "Closing brace: $label"
    return ''
}

function Style-Block([string] $source, [string] $name) {
    return Block-Source $source ('(?m)^' + [regex]::Escape($name) + ':\s*[A-Za-z][A-Za-z0-9_]*(?:\([^\r\n]*\))?\s*\{') $name
}

function Pixel-Value([string] $source, [string] $name) {
    $match = [regex]::Match($source, ('(?m)^\s*' + [regex]::Escape($name) + ':\s*(\d+)px;'))
    Check $match.Success "Scaled pixel style value: $name"
    if (-not $match.Success) { return 0 }
    return [int]$match.Groups[1].Value
}

function Scale-Pixels([int] $value, [int] $percent) {
    return [int][Math]::Round($value * $percent / 100.0 - 0.01, [MidpointRounding]::AwayFromZero)
}

function Mirror-Rect([object] $rect, [int] $width) {
    return [pscustomobject]@{ X = $width - $rect.X - $rect.W; W = $rect.W }
}

function Read-Palette([string] $source, [string] $label) {
    $values = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($match in [regex]::Matches($source, '(?m)^([A-Za-z0-9_]+):\s*([^;\r\n]+);')) {
        $key = $match.Groups[1].Value
        Check (-not $values.ContainsKey($key)) "Duplicate palette key: $label/$key"
        $values[$key] = ($match.Groups[2].Value -split '\|')[0].Trim()
    }
    return ,$values
}

function Color-Alpha([string] $color) {
    if ($color -match '^#[A-Fa-f0-9]{6}$') { return 255 }
    if ($color -match '^#[A-Fa-f0-9]{8}$') { return [Convert]::ToInt32($color.Substring(7, 2), 16) }
    Check $false "Literal RGB/RGBA color expected: $color"
    return 0
}

Write-Output 'Reference design source/contracts and geometry model only; no C++ compiler, style generator, Qt rendering, UI or account actions.'
$newCppPaths = @('lunagram/design.cpp', 'lunagram/design.h', 'lunagram/navigation.cpp', 'lunagram/navigation.h', 'lunagram/window_chrome.cpp', 'lunagram/window_chrome.h')
$cmake = Read-Source 'Telegram/CMakeLists.txt'
$uiCmake = Read-Source 'Telegram/cmake/td_ui.cmake'
$stylePath = 'Telegram/SourceFiles/lunagram/lunagram_design.style'
$designStyle = Read-Source $stylePath
$chatStyle = Read-Source 'Telegram/SourceFiles/ui/chat/chat.style'
$helpersStyle = Read-Source 'Telegram/SourceFiles/chat_helpers/chat_helpers.style'
$dialogStyle = Read-Source 'Telegram/SourceFiles/dialogs/dialogs.style'
$allStyles = "$designStyle`n$chatStyle`n$helpersStyle`n$dialogStyle"
$newSources = @()
foreach ($relative in $newCppPaths) {
    Check ($cmake -match ('(?m)^\s*' + [regex]::Escape($relative) + '\s*$')) "CMake registration: $relative"
    $source = Read-Source "Telegram/SourceFiles/$relative"
    $newSources += $source
    $fixedDimensions = '\b(?:QRectF?|QSizeF?|QPointF?)\(\s*[1-9]\d*\s*[,)]|\bset(?:Fixed)?(?:Width|Height)\(\s*[1-9]\d*|\bQPen\([^,\r\n]+,\s*[1-9]\d*'
    Check ($source -notmatch $fixedDimensions) "No literal geometry dimensions in new C++: $relative"
    foreach ($match in [regex]::Matches($source, '\bst::(lunagram[A-Za-z0-9_]+)\b')) {
        Check ($allStyles -match ('(?m)^' + [regex]::Escape($match.Groups[1].Value) + ':')) "Declared generated style symbol: $relative/$($match.Groups[1].Value)"
    }
}
Check ($uiCmake -match '(?m)^\s*lunagram/lunagram_design\.style\s*$') 'Reference styles participate in native style generation'
Check ($uiCmake -match 'generate_styles\(td_ui[^\r\n]*style_files') 'Style source list reaches the generator'
foreach ($match in [regex]::Matches($designStyle, '(?m)^using "([^"\r\n]+)";')) {
    $import = $match.Groups[1].Value
    $available = @('Telegram/SourceFiles', 'Telegram/lib_ui', 'Telegram/Resources') |
        Where-Object { Test-Path -LiteralPath (Join-Path (Join-Path $RepositoryRoot $_) $import) -PathType Leaf }
    Check (@($available).Count -gt 0) "Resolvable style import: $import"
}
$english = Read-Source 'Telegram/Resources/langs/lang.strings'
foreach ($match in [regex]::Matches(($newSources -join "`n"), '\btr::(lng_[A-Za-z0-9_]+)\b')) {
    Check ($english -match ('(?m)^"' + [regex]::Escape($match.Groups[1].Value) + '(?:#[a-z]+)?"\s*=')) "Existing native localization key: $($match.Groups[1].Value)"
}
$navigation = Read-Source 'Telegram/SourceFiles/lunagram/navigation.cpp'
Check ($navigation -match 'Calls::ShowCallsBox\(controller\)' -and $navigation -match 'controller->showPeerInfo\(controller->session\(\).user\(\)\)' -and $navigation -match 'controller->showSettings\(\)') 'Navigation uses existing session-bound native routes'
Check ($navigation -match 'moveToLeft\(') 'Navigation uses native RTL-aware placement'
$sessionNavigation = Read-Source 'Telegram/SourceFiles/window/window_session_controller.cpp'
$profileRoute = Block-Source $sessionNavigation 'void SessionNavigation::showPeerInfo\(\s*not_null<PeerData\*> peer,[\s\S]*?\{' 'SessionNavigation::showPeerInfo(peer)'
Check ($profileRoute -match 'Lunagram::IsChatLocked\(_session, peer->id\)') 'Existing profile route retains its vault guard'

$settings = Read-Source 'Telegram/SourceFiles/lunagram/lunagram_settings.cpp'
$referenceHelper = Block-Source $settings 'bool ReferenceDesignEnabled\(\)\s*\{' 'ReferenceDesignEnabled'
Check ($referenceHelper -match 'static const auto result' -and $referenceHelper -match 'readPref<bool>\(\s*"lunagram/reference_design",\s*true\)') 'Reference preference is opt-out and fixed for the process lifetime'
$application = Read-Source 'Telegram/SourceFiles/core/application.cpp'
$run = Block-Source $application 'void Application::run\(\)\s*\{' 'Application::run'
Check ($run.IndexOf('startLocalStorage();') -ge 0 -and $run.IndexOf('style::StartManager(') -gt $run.IndexOf('startLocalStorage();')) 'Startup loads global settings before style initialization'
$radiusSource = Read-Source 'Telegram/SourceFiles/ui/chat/chat_style_radius.cpp'
$largeRadius = Block-Source $radiusSource 'int BubbleRadiusLarge\(\)\s*\{' 'BubbleRadiusLarge'
Check ($largeRadius -match 'static const auto result' -and $largeRadius -match 'ReferenceDesignEnabled\(\)' -and $largeRadius -match 'st::lunagramReferenceBubbleRadius') 'Cached large bubble radius uses the scaled reference style'
$messageStyle = Read-Source 'Telegram/SourceFiles/ui/chat/chat_style.cpp'
Check ($messageStyle -match 'result\.msgBgCornersLarge,\s*BubbleRadiusLarge\(\),\s*result\.msgBg') 'Cached bubble corners preserve palette RGB and alpha'
$design = Read-Source 'Telegram/SourceFiles/lunagram/design.cpp'
Check ($design -match 'background\.setAlpha\(std::min\(background\.alpha\(\),\s*\d+\)\)' -and $design -notmatch 'static[^;\r\n]*(?:QColor|background|border)') 'Glass tint respects existing alpha and reads palette color on each paint'
$topBar = Read-Source 'Telegram/SourceFiles/history/view/history_view_top_bar_widget.cpp'
$topBarPaint = Block-Source $topBar 'void TopBarWidget::paintEvent\([^)]*\)\s*\{' 'TopBarWidget::paintEvent'
Check ($topBarPaint -match 'style::RightToLeft\(\)' -and $topBarPaint -match 'myrtlrect\(left, inset,' -and $topBarPaint -notmatch '_back->geometry\(\)\.right\(\)') 'Title capsule converts physical back-button geometry to mirrored logical placement'
Check ($topBarPaint -match 'QSize\(diameter, diameter\)' -and $topBarPaint -match 'QPoint\(button->width\(\) / 2, button->height\(\) / 2\)') 'Floating header controls have square, icon-centered circular surfaces'
$infoStyle = Read-Source 'Telegram/SourceFiles/info/info.style'
$referenceAvatar = Style-Block $infoStyle 'lunagramReferenceTopBarInfoButton'
Check ($referenceAvatar -match 'photoSize:\s*30px;' -and $referenceAvatar -match 'photoPosition:\s*point\(6px,\s*-1px\);') 'Reference header uses the compact vertically centered native avatar'
$avatarVisibility = Block-Source $topBar 'void TopBarWidget::updateInfoButtonVisibility\(\)\s*\{' 'TopBarWidget::updateInfoButtonVisibility'
Check ($avatarVisibility -match 'Lunagram::ReferenceDesignEnabled\(\)') 'Reference avatar is available in normal multicolumn chats'
$chrome = Read-Source 'Telegram/SourceFiles/lunagram/window_chrome.cpp'
$chromeHeader = Read-Source 'Telegram/SourceFiles/lunagram/window_chrome.h'
$window = Read-Source 'Telegram/SourceFiles/window/main_window.cpp'
$captionUtility = Block-Source $chrome 'void UpdateWindowChromeCaption\([\s\S]*?\)\s*\{' 'UpdateWindowChromeCaption'
Check ($captionUtility -match 'sessionController\(\) != controller\.get\(\)') 'Old session controller cannot update the current caption'
$captionSetter = Block-Source $window 'void MainWindow::setReferenceCaptionArea\([\s\S]*?\)\s*\{' 'MainWindow::setReferenceCaptionArea'
Check ($captionSetter -match 'sessionController\(\) != controller\.get\(\)' -and $captionSetter -notmatch 'refreshTitleWidget\(\)|recountGeometryConstraints\(\)') 'Main window rejects stale controllers and avoids synchronous frame re-entry'
Check ($window -match 'sessionControllerChanges\([\s\S]*?_windowChrome->clearCaptionSource\(\)' -and $chromeHeader -match 'QPointer<QWidget> _captionSource;') 'Every session switch clears the weakly held caption source'
$sourceShown = Block-Source $chrome 'bool WindowChrome::captionSourceShown\(\) const\s*\{' 'WindowChrome::captionSourceShown'
Check ($sourceShown -match '!_sourceValid\(\)' -and $sourceShown -match 'widget->isHidden\(\)' -and $sourceShown -match 'widget == parentWidget\(\)') 'Caption visibility follows its current controller and ancestor chain'
$observeSource = Block-Source $chrome 'void WindowChrome::observeCaptionSource\(\)\s*\{' 'WindowChrome::observeCaptionSource'
foreach ($event in @('Show', 'Hide', 'ShowToParent', 'HideToParent', 'ParentChange', 'Move', 'Resize')) {
    Check ($observeSource -match ('QEvent::' + $event + ':')) "Caption source observes $event transitions"
}
Check ($observeSource -match 'QObject::destroyed' -and $observeSource -match 'removeEventFilter\(filter\)' -and $observeSource -match 'filter->deleteLater\(\)' -and $observeSource -match 'QObject::disconnect\(destroyed\)') 'Caption observer cleanup detaches filters and destruction callbacks'
$queueChrome = Block-Source $window 'void MainWindow::queueReferenceChromeUpdate\(\)\s*\{' 'MainWindow::queueReferenceChromeUpdate'
Check ($queueChrome -match '_referenceChromeUpdateScheduled' -and $queueChrome -match 'InvokeQueued\(this,' -and $queueChrome -match 'refreshTitleWidget\(\)' -and $queueChrome -match 'recountGeometryConstraints\(\)') 'Caption frame changes are coalesced until the current layout event completes'

$field = Style-Block $helpersStyle 'lunagramReferenceComposeField'
$action = Style-Block $helpersStyle 'lunagramReferenceComposeButton'
$emoji = Style-Block $helpersStyle 'lunagramReferenceAttachEmoji'
$compose = Style-Block $helpersStyle 'lunagramReferenceComposeControls'
$fieldMin = Pixel-Value $field 'heightMin'
$fieldRadius = Pixel-Value $field 'borderRadius'
$actionHeight = Pixel-Value $action 'height'
$padding = Pixel-Value $helpersStyle 'historySendPadding'
$edge = Pixel-Value $helpersStyle 'historySendRight'
$bubbleRadius = Pixel-Value $chatStyle 'lunagramReferenceBubbleRadius'
$panelRadius = Pixel-Value $designStyle 'lunagramReferencePanelRadius'
$navigationHeight = Pixel-Value $designStyle 'lunagramNavigationHeight'
$replyHeight = Pixel-Value $helpersStyle 'historyReplyHeight'
$attach = Style-Block $helpersStyle 'historyAttach'
$attachWidth = Pixel-Value $attach 'width'
$attachHeight = Pixel-Value $attach 'height'
$marginMatch = [regex]::Match($field, 'textMargins:\s*margins\((\d+)px,\s*(\d+)px,\s*(\d+)px,\s*(\d+)px\);')
Check $marginMatch.Success 'Reference field defines four scaled text margins'
$textLeft = $(if ($marginMatch.Success) { [int]$marginMatch.Groups[1].Value } else { 0 })
$textRight = $(if ($marginMatch.Success) { [int]$marginMatch.Groups[3].Value } else { 0 })
Check ($field -match 'textBg:\s*transparent;' -and $field -match 'textBgActive:\s*transparent;' -and $emoji -match 'bg:\s*transparent;' -and $compose -match 'bg:\s*transparent;') 'Field, emoji and default composer expose the native glass background'
Check ($action -match 'bgColor:\s*transparent;' -and $action -match 'overBgColor:\s*transparent;') 'Channel action avoids an opaque full-width hover rectangle'
Check ($actionHeight -eq $fieldMin + 2 * $padding -and $fieldMin -ge 2 * $fieldRadius) 'Action row and minimum field share a non-overlapping capsule diameter'
Check ($bubbleRadius -ge 18 -and $bubbleRadius -le 20 -and $panelRadius -ge $bubbleRadius) 'Reference bubble and panel radii fit the intended geometry range'
$dialogRow = Style-Block $dialogStyle 'referenceDialogRow'
$dialogHeight = Pixel-Value $dialogStyle 'dialogsReferenceRowHeight'
$dialogPhoto = Pixel-Value $dialogRow 'photoSize'
$dialogNameTop = Pixel-Value $dialogRow 'nameTop'
$dialogTextTop = Pixel-Value $dialogRow 'textTop'
Check ($dialogHeight -gt $dialogPhoto -and $dialogTextTop -gt $dialogNameTop -and $dialogTextTop -lt $dialogHeight) 'Reference dialog row leaves space for its avatar and separate text baselines'

$history = Read-Source 'Telegram/SourceFiles/history/history_widget.cpp'
$fieldPaint = Block-Source $history 'void HistoryWidget::drawField\([^)]*\)\s*\{' 'HistoryWidget::drawField'
Check ($fieldPaint -match '!Lunagram::ReferenceDesignEnabled\(\)') 'Reference composer keeps its native wallpaper under the glass panel'
$message = Read-Source 'Telegram/SourceFiles/history/view/history_view_message.cpp'
$rounding = Block-Source $message 'Ui::BubbleRounding Message::countMessageRounding\(\) const\s*\{' 'Message::countMessageRounding'
Check ($rounding -match 'smallTop = !reference &&' -and $rounding -match 'smallBottom = !reference &&' -and $rounding -match 'skipTail = reference') 'Reference grouping retains large corners and removes message tails'
$bubbleRounding = Block-Source $message 'Ui::BubbleRounding Message::countBubbleRounding\(\s*Ui::BubbleRounding messageRounding\) const\s*\{' 'Message::countBubbleRounding'
Check ($bubbleRounding -match 'inlineReplyKeyboard\(\)' -and $bubbleRounding -match 'Ui::BubbleCornerRounding::Small') 'Keyboard seam keeps its separate rounding contract'
$resize = Block-Source $message 'int Message::resizeContentGetHeight\(int newWidth\)\s*\{' 'Message::resizeContentGetHeight'
$minimum = $resize.IndexOf('accumulate_max(newHeight, 2 * st::lunagramReferenceBubbleRadius)')
$keyboard = $resize.LastIndexOf('if (const auto keyboard = item->inlineReplyKeyboard())')
Check ($minimum -ge 0 -and $keyboard -gt $minimum) 'Minimum bubble body height precedes external keyboard height'
$composer = Read-Source 'Telegram/SourceFiles/lunagram/composer.cpp'
$composerPaint = Block-Source $composer 'void PaintComposerBackground\([\s\S]*?\)\s*\{' 'PaintComposerBackground'
$reference = $composerPaint.IndexOf('ReferenceDesignEnabled()')
$glassPreference = $composerPaint.IndexOf('Enabled(session, Flag::Glass)')
Check ($reference -ge 0 -and $glassPreference -gt $reference) 'Reference glass is handled before the optional legacy glass preference'
Check ($composerPaint -match 'PaintGlassPanel\(') 'Composer uses the shared palette-aware glass painter'

$defaults = Read-Palette (Read-Source 'Telegram/lib_ui/ui/colors.palette') 'native'
$overrides = Read-Palette (Read-Source 'Telegram/Resources/lunagram/liquid.tdesktop-palette') 'liquid'
foreach ($entry in $overrides.GetEnumerator()) {
    Check ($defaults.ContainsKey($entry.Key)) "Known Liquid palette key: $($entry.Key)"
    Check ($entry.Value -match '^#[A-Fa-f0-9]{6}(?:[A-Fa-f0-9]{2})?$') "Liquid RGB/RGBA syntax: $($entry.Key)"
}
foreach ($key in @('msgInBg', 'msgOutBg', 'topBarBg', 'historyComposeAreaBg', 'historyPinnedBg')) {
    Check $overrides.ContainsKey($key) "Required Liquid tint: $key"
    if ($overrides.ContainsKey($key)) {
        $alpha = Color-Alpha $overrides[$key]
        Check ($alpha -gt 0 -and $alpha -lt 255) "Translucent reference tint: $key"
    }
}
$qrcRelative = 'Telegram/Resources/qrc/telegram/telegram.qrc'
$qrc = [xml](Read-Source $qrcRelative)
$themeFiles = @($qrc.RCC.qresource | Where-Object { [string]$_.prefix -eq '/lunagram' } |
    ForEach-Object { $_.file } | Where-Object { [string]$_.alias -eq 'themes/liquid.tdesktop-theme' })
Check ($themeFiles.Count -eq 1) 'Liquid theme has one native resource alias'
if ($themeFiles.Count -eq 1) {
    $themePath = Join-Path (Split-Path (Join-Path $RepositoryRoot $qrcRelative) -Parent) $themeFiles[0].InnerText
    Check (Test-Path -LiteralPath $themePath -PathType Leaf) 'Registered Liquid theme exists'
    if (Test-Path -LiteralPath $themePath -PathType Leaf) {
        $archive = [IO.Compression.ZipFile]::OpenRead($themePath)
        try {
            foreach ($entry in $archive.Entries) {
                Check ($entry.FullName -notmatch '(^[/\\]|(^|[/\\])\.\.([/\\]|$)|:)') "Safe theme archive path: $($entry.FullName)"
            }
            Check (@($archive.Entries | Where-Object { $_.FullName -eq 'background.png' }).Count -eq 1) 'Theme includes one native background PNG'
            $paletteEntries = @($archive.Entries | Where-Object { $_.FullName -eq 'colors.tdesktop-theme' })
            Check ($paletteEntries.Count -eq 1) 'Theme includes one palette'
            if ($paletteEntries.Count -eq 1) {
                $reader = [IO.StreamReader]::new($paletteEntries[0].Open(), $utf8)
                try { $packed = Read-Palette $reader.ReadToEnd() 'packed-liquid' } finally { $reader.Dispose() }
                foreach ($entry in $overrides.GetEnumerator()) {
                    Check ($packed.ContainsKey($entry.Key) -and $packed[$entry.Key] -ceq $entry.Value) "Packed theme retains source override: $($entry.Key)"
                }
            }
        } finally { $archive.Dispose() }
    }
}

$modelCases = 0
foreach ($scale in @(100, 125, 150, 175, 200)) {
    $minimumField = Scale-Pixels $fieldMin $scale
    $pad = Scale-Pixels $padding $scale
    $buttonHeight = Scale-Pixels $actionHeight $scale
    $iconHeight = Scale-Pixels $attachHeight $scale
    $iconWidth = Scale-Pixels $attachWidth $scale
    $right = Scale-Pixels $edge $scale
    $leftTextMargin = Scale-Pixels $textLeft $scale
    $rightTextMargin = Scale-Pixels $textRight $scale
    $radius = Scale-Pixels $bubbleRadius $scale
    Check ((Scale-Pixels $dialogHeight $scale) -gt (Scale-Pixels $dialogPhoto $scale)) "Scaled avatar fits reference dialog row: $scale%"
    Check ([Math]::Abs($buttonHeight - $minimumField - 2 * $pad) -le 1) "Scaled action/field diameter rounding: $scale%"
    foreach ($widthBase in @(320, 480, 960)) {
        $width = Scale-Pixels $widthBase $scale
        foreach ($extraButtons in @(0, 1, 2)) {
            $fieldX = $right + $iconWidth
            $fieldWidth = $width - $iconWidth - $right - (2 + $extraButtons) * $iconWidth
            $rects = @(
                [pscustomobject]@{ X = $right; W = $iconWidth },
                [pscustomobject]@{ X = $fieldX + $leftTextMargin; W = $fieldWidth - $leftTextMargin - $rightTextMargin },
                [pscustomobject]@{ X = $width - $right - (2 + $extraButtons) * $iconWidth; W = $iconWidth },
                [pscustomobject]@{ X = $width - $right - $iconWidth; W = $iconWidth }
            )
            foreach ($rtl in @($false, $true)) {
                foreach ($rect in $rects) {
                    $placed = $(if ($rtl) { Mirror-Rect $rect $width } else { $rect })
                    Check ($placed.W -gt 0 -and $placed.X -ge 0 -and $placed.X + $placed.W -le $width) "Input/control content fits width: $scale%/$widthBase/$extraButtons/RTL=$rtl"
                    $restored = Mirror-Rect (Mirror-Rect $rect $width) $width
                    Check ($restored.X -eq $rect.X -and $restored.W -eq $rect.W) "RTL reflection preserves geometry: $scale%/$widthBase/$extraButtons"
                }
                Check ($rects[1].X -ge $rects[0].X + $rects[0].W -and $rects[1].X + $rects[1].W -le $rects[2].X) "Text avoids adjacent icons: $scale%/$widthBase/$extraButtons"
                foreach ($heightBase in @($fieldMin, 72, 224)) {
                    foreach ($keyboardBase in @(0, 80, 240)) {
                        foreach ($reply in @($false, $true)) {
                            $bottom = Scale-Pixels (640 - $keyboardBase) $scale
                            $height = Scale-Pixels $heightBase $scale
                            $header = $(if ($reply) { Scale-Pixels $replyHeight $scale } else { 0 })
                            $fieldTop = $bottom - $height - $pad
                            $panelTop = $fieldTop - $header
                            $panelHeight = $height + $header
                            $iconsTop = $bottom - $pad - [int][Math]::Floor(($minimumField + $iconHeight) / 2.0)
                            Check ($panelTop -ge 0 -and $panelTop + $panelHeight -eq $bottom - $pad) "Growing field/reply stays above keyboard: $scale%/$heightBase/$keyboardBase/$reply"
                            Check ([Math]::Abs(($iconsTop + $iconHeight / 2.0) - ($bottom - $pad - $minimumField / 2.0)) -le 0.5) "Icons stay centered in bottom input row: $scale%/$heightBase/$keyboardBase"
                            $modelCases += 1
                        }
                    }
                }
            }
        }
        $navWidth = Scale-Pixels 40 $scale
        $navHeight = Scale-Pixels $navigationHeight $scale
        for ($index = 0; $index -lt 4; $index += 1) {
            $x = [int][Math]::Floor((2 * $index + 1) * $width / 8.0) - [int][Math]::Floor($navWidth / 2.0)
            Check ($x -ge 0 -and $x + $navWidth -le $width -and $navHeight -ge $navWidth) "Navigation fits scaled row: $scale%/$widthBase/$index"
        }
    }
    foreach ($bodyBase in @(0, 17, 33, 36, 80, 500)) {
        $body = [Math]::Max((Scale-Pixels $bodyBase $scale), 2 * $radius)
        foreach ($externalBase in @(0, 24, 76, 100)) {
            $external = Scale-Pixels $externalBase $scale
            $total = $body + $external
            Check ($total - $external -ge 2 * $radius) "Cached bubble corners fit before keyboard/reactions: $scale%/$bodyBase/$externalBase"
        }
    }
}

Write-Output "Coverage: $modelCases scaled input/reply/keyboard/RTL model cases, source/style/resource contracts, localization and theme RGBA consistency."
if ($script:Failures.Count) {
    foreach ($failure in $script:Failures) { Write-Output "FAIL: $failure" }
    throw "$($script:Failures.Count) of $($script:Checks) source/model checks failed. No compile or Qt runtime validation was performed."
}
Write-Output "PASS: $($script:Checks) reference-design source/model checks."
Write-Output 'Independent integer scaling models layout arithmetic; actual Qt font metrics, style generation, pixel appearance, input focus, media, privacy and account behavior still require native validation.'

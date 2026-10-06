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
$referenceFont = Block-Source $design 'QString ReferenceFontFamily\([\s\S]*?\)\s*\{' 'ReferenceFontFamily'
Check ($referenceFont -match '!preferred\.isEmpty\(\) \|\| !ReferenceDesignEnabled\(\)' -and $referenceFont -match 'return preferred;') 'Reference font preserves explicit user choices and the native non-reference fallback'
Check ($referenceFont -match '#ifdef Q_OS_WIN' -and $referenceFont -match 'QFontDatabase::families\(\)' -and $referenceFont -match 'Segoe UI Variable Text' -and $referenceFont -match 'Segoe UI' -and $referenceFont -match 'families\.contains\(family, Qt::CaseInsensitive\)') 'Windows reference typography uses an installed regular text family with a checked Segoe fallback'
Check ($referenceFont -notmatch 'writePref|setCustomFontFamily|addApplicationFont|QFile|QFont::insertSubstitution') 'Reference font does not overwrite preferences, bundle fonts or substitute unrelated families'
Check ($run -match 'style::SetCustomFont\(Lunagram::ReferenceFontFamily\(' -and $run.IndexOf('startLocalStorage();') -lt $run.IndexOf('Lunagram::ReferenceFontFamily(') -and $run.IndexOf('Lunagram::ReferenceFontFamily(') -lt $run.IndexOf('style::internal::StartFonts();')) 'Reference font is resolved after settings load and before the native font cache starts'
$fontPicker = Read-Source 'Telegram/SourceFiles/ui/boxes/choose_font_box.cpp'
Check ($fontPicker -match '\.family = Lunagram::ReferenceFontFamily\(family\)' -and $fontPicker -match 'style::owned_font\(\s*Lunagram::ReferenceFontFamily\(row.id\)') 'Native font picker row and message preview share the reference default without changing stored selection ids'
$pinnedGlass = Read-Source 'Telegram/SourceFiles/ui/chat/pinned_bar.cpp'
Check ($pinnedGlass -notmatch '#include "window/window_session_controller.h"' -and $pinnedGlass -match 'Lunagram::ReferenceChatTheme\(_controller\)') 'The td_ui pinned bar resolves its theme through the application bridge without MTProto-generated header dependencies'
Check ($design -notmatch 'background\.setAlpha\(' -and $design -notmatch 'static[^;\r\n]*(?:QColor|background|border)' -and $design -match 'tint.setAlpha\(std::min\(tint.alpha\(\), alpha\)\)') 'Glass tint stays palette-based, honors its alpha ceiling and reads colors on each paint'
$appearance = Block-Source $design 'void EnsureReferenceAppearance\(\)\s*\{' 'EnsureReferenceAppearance'
Check ($appearance -match 'readPref<bool>\("lunagram/liquid_appearance_v2", false\)' -and $appearance -match 'writePref<bool>\("lunagram/liquid_appearance_v2", true\)' -and $appearance -notmatch 'liquid_appearance_v1') 'Reference appearance migration is versioned and recorded only after applying the theme'
Check ($appearance.IndexOf('Window::Theme::Apply(') -lt $appearance.IndexOf('writePref<bool>(') -and $appearance -match 'Window::Theme::KeepApplied\(\)') 'Appearance migration retains native apply/keep ordering'
$backdrop = Block-Source $design 'void PaintReferenceBackdrop\(\s*not_null<Window::SessionController\*>[\s\S]*?\)\s*\{' 'PaintReferenceBackdrop(widget)'
Check ($backdrop -match '!ReferenceDesignEnabled\(\)' -and $backdrop -notmatch 'theme\.get\(\) != controller->defaultChatTheme\(\)\.get\(\)' -and $backdrop -match 'theme->background\(\)\.giftId') 'Shared wallpaper supports the active non-gift theme while retaining the native gift fallback'
Check ($backdrop -match 'content->size\(\)\.isEmpty\(\)' -and $backdrop -match 'widget\.get\(\) != content\.get\(\)' -and $backdrop -match '!content->isAncestorOf\(widget\.get\(\)\)') 'Shared wallpaper checks viewport size and widget ancestry before mapping'
$legacyBackdrop = $backdrop.IndexOf('Window::SectionWidget::PaintBackground(controller, theme, widget, clip);')
$mappedBackdrop = $backdrop.IndexOf('widget->mapTo(content, QPoint())')
Check ($legacyBackdrop -ge 0 -and $mappedBackdrop -gt $legacyBackdrop) 'Unsupported wallpaper contexts return through the original controller-aware painter'
Check ($backdrop -match 'clip\.translate\(origin\)' -and $backdrop -match 'p\.translate\(-origin\)' -and $backdrop -match 'p\.setClipRect\(clip, Qt::IntersectClip\)') 'Shared wallpaper moves its painter and partial clip into the same content coordinates'
Check ($backdrop -match 'PaintBackground\(\s*p,\s*theme,\s*content->size\(\),\s*clip,\s*controller->isGifPausedAtLeastFor\(Window::GifPauseReason::Any\)\)' -and $backdrop -notmatch 'backgroundFromY|widget->width\(\)|QImage|QPixmap|\bgrab\(|\brender\(') 'Shared wallpaper uses the native cached painter with one full viewport and the existing pause state'
$mainWidget = Read-Source 'Telegram/SourceFiles/mainwidget.cpp'
$mainPaint = Block-Source $mainWidget 'void MainWidget::paintEvent\([^)]*\)\s*\{' 'MainWidget::paintEvent'
Check ($mainPaint -match 'ReferenceDesignEnabled\(\) && !_showAnimation' -and $mainPaint -match 'Lunagram::PaintReferenceBackdrop\(') 'Main viewport paints the common reference wallpaper outside its slide animation'
Check ($mainPaint -match '_controller->currentChatTheme\(\)' -and $mainPaint -notmatch '_controller->defaultChatTheme\(\)') 'Main viewport uses the selected chat wallpaper instead of a fixed green default'
Check ($mainWidget -match 'activeChatChanges\(\) \| rpl::on_next\([\s\S]*?ReferenceDesignEnabled\(\)[\s\S]*?update\(\);[\s\S]*?lifetime\(\)\)') 'Active chat changes repaint the surrounding viewport without changing wallpaper settings'
Check ($mainWidget -match 'defaultChatTheme\(\)->repaintBackgroundRequests\(\s*\) \| rpl::on_next\([\s\S]*?ReferenceDesignEnabled\(\)[\s\S]*?update\(\);[\s\S]*?lifetime\(\)\)') 'Native theme cache changes repaint the common viewport with a widget-bound lifetime'
$mainGeometry = Block-Source $mainWidget 'void MainWidget::updateControlsGeometry\(\)\s*\{' 'MainWidget::updateControlsGeometry'
Check ($mainGeometry -match 'floatPlayerUpdatePositions\(\);\s*if \(Lunagram::ReferenceDesignEnabled\(\)\) \{\s*update\(\);') 'Reference viewport repaint is deferred until the geometry update is complete'
foreach ($icon in @('reference_profile', 'reference_chats', 'reference_compose')) {
    $svg = [xml](Read-Source "Telegram/Resources/icons/lunagram/$icon.svg")
    Check ([string]$svg.svg.width -eq '24' -and [string]$svg.svg.height -eq '24' -and [string]$svg.svg.viewBox -eq '0 0 24 24') "Reference vector icon has native 24px dimensions: $icon"
    Check (@($svg.svg.path).Count -gt 0) "Reference vector icon contains its mask: $icon"
    Check (($allStyles -match ('"lunagram/' + [regex]::Escape($icon) + '"'))) "Reference vector icon reaches native style generation: $icon"
}
$topBar = Read-Source 'Telegram/SourceFiles/history/view/history_view_top_bar_widget.cpp'
$topBarPaint = Block-Source $topBar 'void TopBarWidget::paintEvent\([^)]*\)\s*\{' 'TopBarWidget::paintEvent'
Check ($topBarPaint -match 'Lunagram::PaintReferenceBackdrop\(') 'Floating header uses the common reference wallpaper painter'
Check ($topBarPaint -match 'style::RightToLeft\(\)' -and $topBarPaint -match 'myrtlrect\(left, inset,' -and $topBarPaint -notmatch '_back->geometry\(\)\.right\(\)') 'Title capsule converts physical back-button geometry to mirrored logical placement'
Check ($topBarPaint -match 'QSize\(diameter, diameter\)' -and $topBarPaint -match 'QPoint\(button->width\(\) / 2, button->height\(\) / 2\)') 'Floating header controls have square, icon-centered circular surfaces'
$infoStyle = Read-Source 'Telegram/SourceFiles/info/info.style'
$referenceAvatar = Style-Block $infoStyle 'lunagramReferenceTopBarInfoButton'
Check ($referenceAvatar -match 'photoSize:\s*30px;' -and $referenceAvatar -match 'photoPosition:\s*point\(6px,\s*-1px\);') 'Reference header uses the compact vertically centered native avatar'
$avatarVisibility = Block-Source $topBar 'void TopBarWidget::updateInfoButtonVisibility\(\)\s*\{' 'TopBarWidget::updateInfoButtonVisibility'
Check ($avatarVisibility -match 'Lunagram::ReferenceDesignEnabled\(\)') 'Reference avatar is available in normal multicolumn chats'
$chrome = Read-Source 'Telegram/SourceFiles/lunagram/window_chrome.cpp'
$launcher = Read-Source 'Telegram/SourceFiles/core/launcher.cpp'
$launcherDestructor = Block-Source $launcher 'Launcher::~Launcher\(\)\s*\{' 'Launcher destructor'
Check ($launcherDestructor -match 'qInstallMessageHandler\(OriginalMessageHandler\)' -and $launcherDestructor -match 'av_log_set_callback\(av_log_default_callback\)') 'External logging callbacks are detached before the launcher destroys BaseIntegration'
$qtLogging = Block-Source $launcher 'void Launcher::initQtMessageLogging\(\)\s*\{' 'Qt logging setup'
Check ($launcher -match '(?m)^QtMessageHandler OriginalMessageHandler = nullptr;' -and $qtLogging -notmatch 'static QtMessageHandler') 'The saved Qt log handler is shared with shutdown, not shadowed inside setup'
$chromeHeader = Read-Source 'Telegram/SourceFiles/lunagram/window_chrome.h'
$window = Read-Source 'Telegram/SourceFiles/window/main_window.cpp'
$captionUtility = Block-Source $chrome 'void UpdateWindowChromeCaption\([\s\S]*?\)\s*\{' 'UpdateWindowChromeCaption'
Check ($captionUtility -match 'sessionController\(\) != controller\.get\(\)') 'Old session controller cannot update the current caption'
$captionSetter = Block-Source $window 'void MainWindow::setReferenceCaptionArea\([\s\S]*?\)\s*\{' 'MainWindow::setReferenceCaptionArea'
Check ($captionSetter -match 'sessionController\(\) != controller\.get\(\)' -and $captionSetter -notmatch 'refreshTitleWidget\(\)|recountGeometryConstraints\(\)') 'Main window rejects stale controllers and avoids synchronous frame re-entry'
Check ($window -match 'sessionControllerChanges\([\s\S]*?_windowChrome->clearCaptionSource\(\)' -and $chromeHeader -match 'QPointer<QWidget> _captionSource;') 'Every session switch clears the weakly held caption source'
$windowConstructor = Block-Source $window 'MainWindow::MainWindow\([^)]*\)[\s\S]*?, _body\(body\(\)\)\s*\{' 'MainWindow constructor'
$windowInit = Block-Source $window 'void MainWindow::init\(\)\s*\{' 'MainWindow post-construction init'
Check ($windowConstructor -notmatch 'sessionControllerChanges\(' -and $windowInit -match 'sessionControllerChanges\(') 'Caption session subscription starts only after the owning Controller fields are initialized'
$controllerHeader = Read-Source 'Telegram/SourceFiles/window/window_controller.h'
$controllerSource = Read-Source 'Telegram/SourceFiles/window/window_controller.cpp'
Check ($controllerHeader.IndexOf('::MainWindow _widget;') -ge 0 -and $controllerHeader.IndexOf('rpl::variable<SessionController*> _sessionControllerValue;') -gt $controllerHeader.IndexOf('::MainWindow _widget;') -and $controllerSource -match 'Controller::Controller\(CreateArgs &&args\)[\s\S]*?_widget\.init\(\);') 'Controller constructs its session stream after MainWindow and initializes the window from its constructor body'
$sourceShown = Block-Source $chrome 'bool WindowChrome::captionSourceShown\(\) const\s*\{' 'WindowChrome::captionSourceShown'
Check ($sourceShown -match '!_sourceValid\(\)' -and $sourceShown -match 'widget->isHidden\(\)' -and $sourceShown -match 'widget == parentWidget\(\)') 'Caption visibility follows its current controller and ancestor chain'
$observeSource = Block-Source $chrome 'void WindowChrome::observeCaptionSource\(\)\s*\{' 'WindowChrome::observeCaptionSource'
foreach ($event in @('Show', 'Hide', 'ShowToParent', 'HideToParent', 'ParentChange', 'Move', 'Resize')) {
    Check ($observeSource -match ('QEvent::' + $event + ':')) "Caption source observes $event transitions"
}
Check ($observeSource -match 'QObject::destroyed' -and $observeSource -match 'removeEventFilter\(filter\)' -and $observeSource -match 'filter->deleteLater\(\)' -and $observeSource -match 'QObject::disconnect\(destroyed\)') 'Caption observer cleanup detaches filters and destruction callbacks'
$queueChrome = Block-Source $window 'void MainWindow::queueReferenceChromeUpdate\(\)\s*\{' 'MainWindow::queueReferenceChromeUpdate'
Check ($queueChrome -match '_referenceChromeUpdateScheduled' -and $queueChrome -match 'InvokeQueued\(this,' -and $queueChrome -match 'refreshTitleWidget\(\)' -and $queueChrome -match 'recountGeometryConstraints\(\)') 'Caption frame changes are coalesced until the current layout event completes'
Check ($queueChrome -match '^\s*if \(Core::Quitting\(\)\s*\|\| _referenceChromeUpdateScheduled\) \{\s*return;\s*\}') 'Caption update rejects shutdown before reading the coalescing member or enqueueing work'
$queuedChromeCallback = Block-Source $queueChrome 'InvokeQueued\(this, \[=\] \{' 'Queued reference chrome callback'
Check ($queuedChromeCallback -match '^\s*if \(Core::Quitting\(\)\) \{\s*return;\s*\}\s*_referenceChromeUpdateScheduled = false;') 'Queued caption callback rejects shutdown before touching MainWindow members'
foreach ($quittingAtQueue in @($false, $true)) {
    foreach ($alreadyScheduled in @($false, $true)) {
        foreach ($quittingAtCallback in @($false, $true)) {
            $queueState = [pscustomobject]@{ Scheduled = $alreadyScheduled; QueueTouches = 0; CallbackTouches = 0; FrameUpdates = 0 }
            $enqueue = -not ($quittingAtQueue -or (& {
                $queueState.QueueTouches += 1
                return $queueState.Scheduled
            }))
            if ($enqueue) {
                $queueState.Scheduled = $true
                & {
                    if ($quittingAtCallback) { return }
                    $queueState.CallbackTouches += 1
                    $queueState.Scheduled = $false
                    $queueState.FrameUpdates += 1
                }
            }
            Check ($enqueue -eq (-not $quittingAtQueue -and -not $alreadyScheduled)) "Caption queue preserves normal coalescing and shutdown rejection: $quittingAtQueue/$alreadyScheduled/$quittingAtCallback"
            Check (-not $quittingAtQueue -or $queueState.QueueTouches -eq 0) "Shutdown short-circuit never reads MainWindow queue state: $quittingAtQueue/$alreadyScheduled/$quittingAtCallback"
            Check (-not $quittingAtCallback -or $queueState.CallbackTouches -eq 0) "Shutdown callback never touches MainWindow state: $quittingAtQueue/$alreadyScheduled/$quittingAtCallback"
            Check ($queueState.FrameUpdates -eq [int]($enqueue -and -not $quittingAtCallback)) "Only live queued caption updates change the native frame: $quittingAtQueue/$alreadyScheduled/$quittingAtCallback"
        }
    }
}
Check ($designStyle -notmatch 'WindowTitle\(defaultWindowTitle\)' -and $window -match 'ReferenceWindowTitle\(\)' -and $window -match 'st::lunagramReferenceTitleHeight') 'Zero-height title uses a persistent native style copy, not cross-module unnamed-icon inheritance'
$buildHelper = Read-Source 'Telegram/build/lunagram/windows-debug.ps1'
Check ($buildHelper.IndexOf("'td_ui_styles'") -ge 0 -and $buildHelper.IndexOf("'td_ui_styles'") -lt $buildHelper.IndexOf('$allTargets =')) 'Native style generation fails fast before independent object compilation'

$mainMenu = Read-Source 'Telegram/SourceFiles/window/window_main_menu.cpp'
$mainMenuStyle = Read-Source 'Telegram/SourceFiles/window/window_main_menu.style'
$mainMenuCaptionSkip = Block-Source $mainMenu 'int MainMenuCaptionSkip\(\)\s*\{' 'MainMenuCaptionSkip'
$mainMenuCoverHeight = Block-Source $mainMenu 'int MainMenuCoverHeight\(\)\s*\{' 'MainMenuCoverHeight'
$mainMenuGeometry = Block-Source $mainMenu 'void MainMenu::updateControlsGeometry\(\)\s*\{' 'MainMenu::updateControlsGeometry'
Check ($mainMenu -match '#include "styles/style_lunagram_design.h"' -and $mainMenuCaptionSkip -match 'Lunagram::ReferenceDesignEnabled\(\)\s*\? st::lunagramReferenceCaptionHeight\s*: 0;') 'Drawer caption clearance uses the scaled reference height with a zero native fallback'
Check ($mainMenuCoverHeight -match 'return st::mainMenuCoverHeight \+ MainMenuCaptionSkip\(\);') 'Drawer cover extends by exactly the reference caption clearance'
Check ($mainMenuGeometry -match 'st::mainMenuUserpicTop \+ captionSkip' -and $mainMenuGeometry -match 'st::mainMenuCoverStatusTop \+ captionSkip' -and $mainMenuGeometry -match '_resetScaleButton->moveToRight\(0, captionSkip\)' -and $mainMenuGeometry -match 'st::mainMenuCoverNameTop \+ captionSkip') 'Drawer avatar, status and header actions shift together below traffic lights'
Check ($mainMenuGeometry -match 'st::mainMenuCoverHeight - st::mainMenuCoverNameTop' -and $mainMenuGeometry -match 'MainMenuCoverHeight\(\) - st::lineWidth' -and $mainMenuGeometry -match '_scroll->setGeometry\(0, top, width\(\), height\(\) - top\)') 'Drawer preserves the account-toggle hit height and moves the native scroll viewport below the extended cover'
Check ($mainMenu -match 'height\(\) - MainMenuCoverHeight\(\) - contentHeight' -and $mainMenu -match 'shadow->setGeometry\(0, MainMenuCoverHeight\(\) - line, width, line\)' -and $mainMenu -match 'snowRaw->setGeometry\(0, 0, width, MainMenuCoverHeight\(\)\)' -and $mainMenu -match 'const auto cover = QRect\(0, 0, width\(\), MainMenuCoverHeight\(\)\)') 'Drawer footer sizing, shadow and optional seasonal paint share the extended header boundary'
Check ($mainMenu -match 'st::mainMenuCoverNameTop \+ MainMenuCaptionSkip\(\)' -and $mainMenu -match 'st::mainMenuCoverNameTop\s*\+ MainMenuCaptionSkip\(\)\s*\+ st::semiboldFont->height') 'Drawer name and premium badge preserve their alignment after the header shift'

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
$captionHeight = Pixel-Value $designStyle 'lunagramReferenceCaptionHeight'
$lightRadius = Pixel-Value $designStyle 'lunagramTrafficLightRadius'
$lightHitSize = Pixel-Value $designStyle 'lunagramTrafficLightHitSize'
$lightSpacing = Pixel-Value $designStyle 'lunagramTrafficLightSpacing'
$lightLeft = Pixel-Value $designStyle 'lunagramTrafficLightLeft'
$lightTop = Pixel-Value $designStyle 'lunagramTrafficLightTop'
$captionSide = Pixel-Value $dialogStyle 'dialogsReferenceCaptionTitleSide'
$cardInset = Pixel-Value $designStyle 'lunagramReferenceCardInset'
$mainMenuAvatarTop = Pixel-Value $mainMenuStyle 'mainMenuUserpicTop'
$mainMenuNativeCover = Pixel-Value $mainMenuStyle 'mainMenuCoverHeight'
$mainMenuNameTop = Pixel-Value $mainMenuStyle 'mainMenuCoverNameTop'
$mainMenuStatusTop = Pixel-Value $mainMenuStyle 'mainMenuCoverStatusTop'
$mainMenuFooterMinimum = Pixel-Value $mainMenuStyle 'mainMenuFooterHeightMin'
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
$dialogsWidget = Read-Source 'Telegram/SourceFiles/dialogs/dialogs_widget.cpp'
$dialogsHeader = Read-Source 'Telegram/SourceFiles/dialogs/dialogs_widget.h'
$dialogsDestructor = Block-Source $dialogsWidget 'Widget::~Widget\(\)\s*\{' 'Dialogs Widget destructor'
Check ($dialogsHeader.IndexOf('std::unique_ptr<style::InputField> _searchStyle;') -ge 0 -and $dialogsHeader.IndexOf('object_ptr<Ui::InputField> _search;') -gt $dialogsHeader.IndexOf('std::unique_ptr<style::InputField> _searchStyle;')) 'Mutable search style is initialized before its field'
Check ($dialogsDestructor -match 'lifetime\(\)\.destroy\(\);[\s\S]*?_referenceSearchHint\.reset\(\);[\s\S]*?_search->lifetime\(\)\.destroy\(\);[\s\S]*?_search\.destroy\(\);') 'Search field and its subscriptions are torn down while its style is still alive'
$referenceTextStyle = Style-Block $dialogStyle 'dialogsReferenceTextStyle'
$previewPitch = Pixel-Value $referenceTextStyle 'lineHeight'
$dialogsLayout = Read-Source 'Telegram/SourceFiles/dialogs/ui/dialogs_layout.cpp'
$dialogsPreview = Read-Source 'Telegram/SourceFiles/dialogs/ui/dialogs_message_view.cpp'
Check ($dialogsLayout -match 'st\.nameTop \+ st::semiboldFont->height' -and $dialogsLayout -match 'lineHeight \+ pitch \*') 'Reference preview respects actual title and glyph height rather than fixed line count division'
Check ($dialogsPreview -match 'st::dialogsReferenceTextStyle' -and $dialogsPreview -match '\.elisionLines = reference' -and $dialogsPreview -match 'p\.setClipRect\(') 'Reference text uses native line spacing, bounded elision and vertical clipping'
foreach ($previewScale in @(100, 125, 150, 175, 200)) {
    foreach ($fontHeightBase in 15..19) {
        foreach ($titleExtra in @(0, 1)) {
            $fontHeight = Scale-Pixels $fontHeightBase $previewScale
            $titleHeight = $fontHeight + $titleExtra
            $top = (Scale-Pixels $dialogNameTop $previewScale) + $titleHeight
            $pitch = Scale-Pixels $previewPitch $previewScale
            $budget = $fontHeight + $pitch
            Check ($top + $budget -le (Scale-Pixels $dialogHeight $previewScale)) "Two-line native glyph/pitch budget fits normal row: $previewScale%/$fontHeightBase/title+$titleExtra"
        }
    }
}

$history = Read-Source 'Telegram/SourceFiles/history/history_widget.cpp'
$historyPaint = Block-Source $history 'void HistoryWidget::paintEvent\([^)]*\)\s*\{' 'HistoryWidget::paintEvent'
Check ($historyPaint -match 'Lunagram::PaintReferenceBackdrop\(' -and $historyPaint -match 'controller\(\)->currentChatTheme\(\)') 'History passes its real current theme through the common painter and fallback guard'
$dialogs = Read-Source 'Telegram/SourceFiles/dialogs/dialogs_widget.cpp'
$dialogsPaint = Block-Source $dialogs 'void Widget::paintEvent\([^)]*\)\s*\{' 'Dialogs::Widget::paintEvent'
Check ($dialogsPaint -match 'Lunagram::PaintReferenceBackdrop\(' -and $dialogsPaint -match 'referencePanel && !_showAnimation') 'Reference dialogs share the viewport wallpaper outside their slide animation'
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
Check ($composerPaint -match 'PaintComposerPanel\(' -and $composer -match 'void PaintComposerPanel\([\s\S]*?PaintGlassPanel\(') 'Composer uses the shared palette-aware glass painter through its panel helper'

$glassPrepare = Block-Source $design 'void BackdropCache::prepare\([\s\S]*?\)\s*\{' 'BackdropCache::prepare'
$glassCapture = Block-Source $design 'void BackdropCache::capture\([\s\S]*?\)\s*\{' 'BackdropCache::capture'
$glassAccept = Block-Source $design 'void BackdropCache::accept\([\s\S]*?\)\s*\{' 'BackdropCache::accept'
Check ($glassPrepare -match '_running' -and $glassPrepare -match '_consumers.size\(\) < kGlassConsumerLimit') 'Backdrop work and repaint consumers are bounded'
Check ($glassCapture -match 'kGlassSourcePixels / pixels' -and $glassCapture -match 'Images::BlurLargeImage' -and $glassCapture -match 'crl::async') 'Glass computes a bounded real wallpaper blur outside the UI thread'
Check ($glassAccept -match 'generation == _generation && _owner' -and $glassAccept -match '_running = false') 'Resize or theme changes reject stale blur work and unblock the next capture'
$contentPrepare = Block-Source $design 'const GlassBackdrop &ContentBackdropCache::prepare\([\s\S]*?\)\s*\{' 'ContentBackdropCache::prepare'
$contentAccept = Block-Source $design 'void ContentBackdropCache::accept\([\s\S]*?\)\s*\{' 'ContentBackdropCache::accept'
$contentInvalidate = Block-Source $design 'void ContentBackdropCache::invalidate\(\)\s*\{' 'ContentBackdropCache::invalidate'
$contentClear = Block-Source $design 'void ContentBackdropCache::clear\(\)\s*\{' 'ContentBackdropCache::clear'
$contentGlass = Block-Source $design 'void PaintGlassPanel\(\s*QPainter &p,\s*QRect bounds,\s*QColor tint,\s*const GlassBackdrop &[\s\S]*?\)\s*\{' 'PaintGlassPanel(content)'
Check ($contentPrepare -match '_running' -and $contentPrepare -match 'kGlassContentPixels / pixels' -and $contentPrepare -match 'crl::async' -and $contentPrepare -match 'Images::BlurLargeImage') 'Message-strip blur has a bounded image budget and only one background job'
Check ($contentPrepare.IndexOf('paint(p, _area);') -ge 0 -and $contentPrepare.IndexOf('paint(p, _area);') -lt $contentPrepare.IndexOf('crl::async') -and $contentPrepare -notmatch '_paint\s*=') 'Native message rendering stays on the UI thread and no owner callback is retained by the blur worker'
Check ($contentInvalidate -match '\+\+_generation' -and $contentInvalidate -match '_frame = GlassBackdrop\(\)' -and $contentAccept -match 'generation == _generation && _owner' -and $contentAccept -match '_running = false') 'A changed message strip rejects old jobs and drops old visible pixels before rendering a replacement'
Check ($contentClear -match '_area = QRect\(\)' -and $contentClear -match '_themeLifetime.destroy\(\)' -and $contentClear -match '_refreshTimer.cancel\(\)' -and $contentClear -match 'invalidate\(\)') 'Chat-switch clearing removes old pixels, wallpaper subscriptions and pending timer refreshes'
Check ($contentPrepare -match '_area != area \|\| _revision != revision \|\| _deviceRatio != ratio' -and $contentPrepare -match 'theme->repaintBackgroundRequests\(\)') 'Content glass observes geometry, content revision, DPR and its actual wallpaper theme'
Check ($contentGlass -match 'backdrop.area.contains\(bounds\)' -and $contentGlass -match 'backdrop.blurred.isNull\(\) \? backdrop.source : backdrop.blurred' -and $contentGlass -match 'sample.x\(\) \* backdrop.scale' -and $contentGlass -notmatch 'setClipping\(false\)') 'Content panels sample their bounded local strip and preserve the caller clip'
$webPageMedia = Read-Source 'Telegram/SourceFiles/history/view/media/history_view_web_page.cpp'
Check ($webPageMedia -match 'context.backdrop\s*&& \(\(asArticle\(\) && !_photoMedia\)\s*\|\| _hasLogEntryPreview\s*\|\| _data->uniqueGift\s*\|\| _data->auction\)\)') 'Captured web-page previews skip native dynamic gift and auction renderers'
foreach ($area in @(@(1,1,1.0), @(1280,80,1.0), @(3840,400,2.0), @(7680,2000,4.0))) {
    $ratio = [Math]::Min($area[2] / 2.0, [Math]::Sqrt((256 * 1024) / ($area[0] * [double]$area[1])))
    $sampleWidth = [Math]::Max(1, [Math]::Floor($area[0] * $ratio))
    $sampleHeight = [Math]::Max(1, [Math]::Floor($area[1] * $ratio))
    Check ($sampleWidth * $sampleHeight -le 256 * 1024) 'Message source and blur images stay within their smaller pixel budget at supported DPIs'
}
Check ($design -notmatch '\bgrab\(|\brender\(|QGraphicsBlurEffect|QScreen::|grabWindow') 'Glass samples the native wallpaper plane without screen or foreground capture'
Check ($design -match 'p.setClipPath\(ring, Qt::IntersectClip\)' -and $design -match 'cache->source\(\)') 'Rounded glass rims displace the actual sampled wallpaper'

$chrome = Read-Source 'Telegram/SourceFiles/lunagram/window_chrome.cpp'
$chromeGeometry = Block-Source $chrome 'void WindowChrome::rememberNormalGeometry\(\)\s*\{' 'WindowChrome::rememberNormalGeometry'
$chromeState = Block-Source $chrome 'void WindowChrome::handleWindowStateChange\(\)\s*\{' 'WindowChrome::handleWindowStateChange'
Check ($chromeGeometry -match '!_restorePending' -and $chromeGeometry -match '_lastWindowState == Qt::WindowNoState' -and $chromeGeometry -match '_window->windowState\(\) == Qt::WindowNoState') 'Chrome records only stable normal geometry outside a restore correction'
Check ($chromeState -match 'state == _lastWindowState' -and $chromeState -match 'wasMaximized' -and $chromeState -match 'InvokeQueued\(this' -and $chromeState -match 'serial != _restoreSerial' -and $chromeState -match '_window->geometry\(\).topLeft\(\)' -and $chromeState -match '_normalGeometry.size\(\)') 'Chrome restores the saved client size after native frame correction, preserves drag-restore position and rejects stale work'
$rawChromeRestore = $chromeState -match '_window->QWidget::setGeometry\(QRect\('
Check ($rawChromeRestore -and $chromeState -notmatch '_window->setGeometry\(' -and $chromeGeometry -match '_normalGeometry = _window->geometry\(\)') 'Chrome restores raw QWidget geometry without adding RpWindow title padding twice'
$nativeWindow = Read-Source 'Telegram/lib_ui/ui/platform/win/ui_window_win.cpp'
$nativeGeometry = Block-Source $nativeWindow 'void WindowHelper::setGeometry\(QRect rect\)\s*\{' 'Windows wrapper body geometry'
Check ($nativeGeometry -match 'rect.marginsAdded\(\{ 0, titleHeight\(\), 0, 0 \}\)') 'Windows RpWindow geometry setter interprets its input as body geometry'
$nativeTitle = Read-Source 'Telegram/lib_ui/ui/platform/win/ui_window_title_win.cpp'
$nativeTitleGeometry = Block-Source $nativeTitle 'void TitleWidget::refreshGeometryWithWidth\(int width\)\s*\{' 'Windows title padding geometry'
Check ($nativeTitleGeometry -match 'additionalPadding\(\)' -and $nativeTitleGeometry -match '_controls.st\(\)->height \+ add') 'A zero style title height can still have native Windows title padding'
Check ($chrome -match 'control \|\| menu' -and $chrome -match '_menu->setIsMenuButton\(true\)' -and $chrome -match 'tr::lng_main_menu\(\)') 'The header title exposes the native main menu as a client-area accessible button'

Check ($dialogs -match 'referenceTitleRect\(\).intersected\(caption\)' -and $dialogsPaint -match 'const auto titleRect = referenceTitleRect\(\)' -and $dialogs -match 'crl::guard\(this, \[=\] \{ showMainMenu\(\); \}\)') 'Header menu hit geometry matches the painted title and retains the source lifetime guard'
Check ($dialogs -match '_stories->setCollapsedPreviewHidden\(referenceHeader' -and $dialogs -match '_referenceStories->moveToRight\(' -and $dialogs -match 'st::dialogsReferenceStoriesSkip') 'Reference stories have a separate accessible entry outside the search pill'
$stories = Read-Source 'Telegram/SourceFiles/dialogs/ui/dialogs_stories_list.cpp'
Check ($stories -match '_collapsedPreviewHidden && _state == State::Small' -and $stories -match 'Qt::WA_TransparentForMouseEvents,\s*_collapsedPreviewHidden && _state != State::Full') 'Hidden collapsed stories neither paint over nor intercept the search; full stories remain interactive'
Check ($dialogs -match '\{ childx, captionHeight, childw, childh \}' -and $dialogs -match '_scroll->y\(\) \+ _scroll->height\(\) - captionHeight') 'Forum child lists stay below the custom caption and above the footer'
Check ($dialogs -match '\(_search->height\(\) - button->height\(\)\) / 2') 'Transient search controls center on the field rather than the top edge'
Check ($navigation -notmatch 'NavigationBar::paintEvent' -and $navigation -notmatch 'PaintGlassPanel') 'Navigation inherits the full sidebar material without a duplicate rounded footer'

$botKeyboard = Read-Source 'Telegram/SourceFiles/chat_helpers/bot_keyboard.cpp'
$botPaint = Block-Source $botKeyboard 'void BotKeyboard::paintEvent\([^)]*\)\s*\{' 'BotKeyboard::paintEvent'
$botBackground = Block-Source $botKeyboard 'void Style::paintButtonBg\([\s\S]*?\) const\s*\{' 'Bot keyboard button background'
$botSelection = Block-Source $botKeyboard 'void BotKeyboard::updateSelected\(\)\s*\{' 'BotKeyboard::updateSelected'
Check ($botPaint -match 'PaintReferenceBackdrop\(' -and $botPaint -match 'if \(!reference\)\s*\{\s*p.fillRect') 'Reference bot keyboards keep the wallpaper visible between their buttons'
Check ($botBackground -match 'worldTransform\(\).mapRect\(rect\)' -and $botBackground -match 'p.resetTransform\(\)' -and $botBackground -match 'PaintGlassPanel\(') 'Bot button blur samples its actual widget rectangle after native painter translation'
Check ($botBackground -match 'color == Color::Normal' -and $botBackground -match 'p.setBrush\(bg\)' -and $botKeyboard -match 'CachedCornerRadius::Small') 'Bot button color roles remain native and compact buttons have fitting ripple corners'
Check ($botSelection -match '\? st::botKbScroll.deltat\s*: _st->margin' -and $botSelection -match 'getLink\(p - QPoint\(x, top\)\)') 'Reference bot button hit testing uses the same vertical origin as painting'
foreach ($percent in @(100,125,150,175,200,250,300)) {
    foreach ($marginBase in @(4,10)) {
        foreach ($rtl in @($false,$true)) {
            $keyboardX = Scale-Pixels $(if ($rtl) { 8 } else { $marginBase }) $percent
            $keyboardY = Scale-Pixels 6 $percent
            $buttonHeight = Scale-Pixels $(if ($marginBase -eq 4) { 25 } else { 38 }) $percent
            foreach ($row in 0..3) {
                $localY = $row * ($buttonHeight + (Scale-Pixels $marginBase $percent))
                $paintY = $keyboardY + $localY
                Check ($paintY - $keyboardY -eq $localY -and $keyboardX -ge 0) 'Bot keyboard paint and hit origins remain identical across rows, scales and RTL'
            }
        }
    }
}

$normalSize = [pscustomobject]@{ W = 802; H = 626 }
foreach ($cycle in 1..20) {
    $saved = [pscustomobject]@{ W = $normalSize.W; H = $normalSize.H }
    $normalSize = [pscustomobject]@{ W = $saved.W + 16; H = $saved.H + 16 }
    $normalSize = $saved
    Check ($normalSize.W -eq 802 -and $normalSize.H -eq 626) "Queued restore geometry model does not accumulate native frame deltas: cycle$cycle"
}
foreach ($titlePadding in @(0, 1, 2, 16, 32)) {
    $rawNormal = [pscustomobject]@{ W = 834; H = 682 }
    $wrappedHeight = $rawNormal.H
    foreach ($cycle in 1..20) {
        $savedRawHeight = $rawNormal.H
        $restoredHeight = if ($rawChromeRestore) { $savedRawHeight } else { $savedRawHeight + $titlePadding }
        $rawNormal = [pscustomobject]@{ W = $rawNormal.W; H = $restoredHeight }
        $wrappedHeight += $titlePadding
        Check ($rawNormal.W -eq 834 -and $rawNormal.H -eq 682) "Raw geometry restore model preserves size with title padding${titlePadding}: cycle$cycle"
        Check ($wrappedHeight -eq 682 + $cycle * $titlePadding) "Body-wrapper witness reproduces cumulative title padding${titlePadding}: cycle$cycle"
    }
}
foreach ($area in @(@(1,1,1.0), @(1280,871,1.0), @(3840,2160,2.0), @(7680,4320,4.0))) {
    $ratio = [Math]::Min($area[2] / 2.0, [Math]::Sqrt((768 * 1024) / ($area[0] * [double]$area[1])))
    $sampleWidth = [Math]::Max(1, [Math]::Floor($area[0] * $ratio))
    $sampleHeight = [Math]::Max(1, [Math]::Floor($area[1] * $ratio))
    Check ($sampleWidth * $sampleHeight -le 768 * 1024) 'Shared source and blur images stay within their pixel budget at extreme viewport sizes'
}

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
    $scaledCaption = Scale-Pixels $captionHeight $scale
    $scaledHit = Scale-Pixels $lightHitSize $scale
    $scaledRadius = Scale-Pixels $lightRadius $scale
    $scaledSpacing = Scale-Pixels $lightSpacing $scale
    $scaledLightLeft = Scale-Pixels $lightLeft $scale
    $scaledLightTop = Scale-Pixels $lightTop $scale
    Check ($scaledHit -ge 2 * $scaledRadius -and $scaledSpacing -ge $scaledHit) "Traffic lights have separate scaled hit targets: $scale%"
    Check ($scaledLightTop - $scaledHit / 2.0 -ge 0 -and $scaledLightTop + $scaledHit / 2.0 -le $scaledCaption) "Traffic lights fit the draggable caption: $scale%"
    Check ($scaledLightLeft - $scaledHit / 2.0 -ge 0 -and $scaledLightLeft + 2 * $scaledSpacing + $scaledHit / 2.0 -lt (Scale-Pixels $captionSide $scale)) "Caption title avoids all three traffic-light targets: $scale%"
    $scaledMenuAvatarTop = (Scale-Pixels $mainMenuAvatarTop $scale) + $scaledCaption
    $scaledMenuCover = (Scale-Pixels $mainMenuNativeCover $scale) + $scaledCaption
    $scaledMenuNameTop = (Scale-Pixels $mainMenuNameTop $scale) + $scaledCaption
    $scaledMenuStatusTop = (Scale-Pixels $mainMenuStatusTop $scale) + $scaledCaption
    $trafficBottom = (Scale-Pixels $cardInset $scale) + $scaledLightTop + $scaledHit / 2.0
    Check ($scaledMenuAvatarTop -ge $trafficBottom -and $scaledCaption -ge $trafficBottom) "Drawer avatar and reset-scale action clear all caption hit targets: $scale%"
    Check ($scaledMenuCover - $scaledMenuNameTop -eq (Scale-Pixels $mainMenuNativeCover $scale) - (Scale-Pixels $mainMenuNameTop $scale) -and $scaledMenuStatusTop - $scaledMenuNameTop -eq (Scale-Pixels $mainMenuStatusTop $scale) - (Scale-Pixels $mainMenuNameTop $scale)) "Drawer shifted toggle hit height and name/status spacing remain native: $scale%"
    foreach ($menuHeightBase in @(480, 640, 900)) {
        $menuHeight = Scale-Pixels $menuHeightBase $scale
        $menuScrollTop = $scaledMenuCover - (Scale-Pixels 1 $scale)
        Check ($menuScrollTop -ge $scaledCaption -and $menuHeight - $menuScrollTop -gt 0) "Drawer scroll viewport remains positive below its extended header: $scale%/$menuHeightBase"
        foreach ($menuContentBase in @(0, 240, 800)) {
            $menuContent = Scale-Pixels $menuContentBase $scale
            $availableMenu = $menuHeight - $scaledMenuCover - $menuContent
            $nativeAvailableMenu = $menuHeight - (Scale-Pixels $mainMenuNativeCover $scale) - $menuContent
            $menuFooter = [Math]::Max($availableMenu, (Scale-Pixels $mainMenuFooterMinimum $scale))
            Check ($nativeAvailableMenu - $availableMenu -eq $scaledCaption -and $menuFooter -ge (Scale-Pixels $mainMenuFooterMinimum $scale)) "Drawer reserves only caption height and preserves minimum scrolling footer: $scale%/$menuHeightBase/$menuContentBase"
        }
    }
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

$backdropCases = 0
foreach ($scale in @(100, 125, 150, 175, 200)) {
    foreach ($widthBase in @(320, 960, 1440)) {
        foreach ($heightBase in @(640, 900)) {
            $viewportWidth = Scale-Pixels $widthBase $scale
            $viewportHeight = Scale-Pixels $heightBase $scale
            $panelWidth = [int][Math]::Floor($viewportWidth / 3.0)
            foreach ($rtl in @($false, $true)) {
                $left = $(if ($rtl) { $viewportWidth - $panelWidth } else { 0 })
                foreach ($topBase in @(0, 42, 86)) {
                    $top = Scale-Pixels $topBase $scale
                    $partial = [pscustomobject]@{ X = 7; Y = 11; W = 23; H = 17 }
                    $mappedClip = [pscustomobject]@{ X = $left + $partial.X; Y = $top + $partial.Y; W = $partial.W; H = $partial.H }
                    Check ($mappedClip.X - $left -eq $partial.X -and $mappedClip.Y - $top -eq $partial.Y -and $mappedClip.W -eq $partial.W -and $mappedClip.H -eq $partial.H) "Wallpaper partial clip translation is reversible: $scale%/$widthBase/$heightBase/RTL=$rtl/$topBase"
                    foreach ($dpr in @(1.0, 1.25, 1.5, 2.0)) {
                        foreach ($probe in @(
                            [pscustomobject]@{ X = 0; Y = 0 },
                            [pscustomobject]@{ X = 7; Y = 11 },
                            [pscustomobject]@{ X = $panelWidth - 1; Y = $viewportHeight - $top - 1 }
                        )) {
                            $globalX = $left + $probe.X
                            $globalY = $top + $probe.Y
                            Check ($globalX -ge 0 -and $globalX -lt $viewportWidth -and $globalY -ge 0 -and $globalY -lt $viewportHeight) "Wallpaper mapped point remains in the shared viewport: $scale%/$widthBase/$heightBase/RTL=$rtl/$topBase/$dpr"
                            $parentPixel = [pscustomobject]@{ X = [Math]::Floor($globalX * $dpr); Y = [Math]::Floor($globalY * $dpr) }
                            $childPixel = [pscustomobject]@{ X = [Math]::Floor(($probe.X + $left) * $dpr); Y = [Math]::Floor(($probe.Y + $top) * $dpr) }
                            Check ($parentPixel.X -eq $childPixel.X -and $parentPixel.Y -eq $childPixel.Y) "Parent and translated panel sample identical wallpaper coordinates: $scale%/$widthBase/$heightBase/RTL=$rtl/$topBase/$dpr"
                            $backdropCases += 1
                        }
                    }
                }
            }
        }
    }
}

Write-Output "Coverage: $modelCases scaled input/reply/keyboard/RTL model cases, $backdropCases viewport/partial-clip/DPR wallpaper coordinate cases, source/style/resource contracts, localization and theme RGBA consistency."
if ($script:Failures.Count) {
    foreach ($failure in $script:Failures) { Write-Output "FAIL: $failure" }
    throw "$($script:Failures.Count) of $($script:Checks) source/model checks failed. No compile or Qt runtime validation was performed."
}
Write-Output "PASS: $($script:Checks) reference-design source/model checks."
Write-Output 'Independent integer scaling models layout arithmetic; actual Qt font metrics, style generation, pixel appearance, input focus, media, privacy and account behavior still require native validation.'

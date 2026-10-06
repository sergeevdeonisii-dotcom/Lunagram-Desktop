param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot '../../..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$script:Checks = 0

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (!$Condition) {
        throw $Message
    }
    $script:Checks++
}

function Read-Source([string]$RelativePath) {
    return [IO.File]::ReadAllText((Join-Path $RepoRoot $RelativePath))
}

function Function-Body([string]$Source, [string]$Name) {
    $pattern = [regex]::Escape($Name) + '\s*\([^;]*?\)\s*(?:const\s*)?\{'
    $match = [regex]::Match($Source, $pattern)
    Assert-Contract $match.Success ('Missing function: ' + $Name)
    $start = $match.Index + $match.Length - 1
    $depth = 0
    for ($index = $start; $index -lt $Source.Length; $index++) {
        if ($Source[$index] -eq '{') { $depth++ }
        if ($Source[$index] -eq '}') { $depth-- }
        if ($depth -eq 0) {
            return $Source.Substring($start, $index - $start + 1)
        }
    }
    throw ('Unclosed function: ' + $Name)
}

function Native-Scale([int]$Value, [int]$Scale) {
    return [int][math]::Floor($Value * $Scale / 100.0 - 0.01 + 0.5)
}

function Button-Panel([int]$X, [int]$Y, [int]$Width, [int]$Height, [int]$Diameter) {
    $diameter = [math]::Min($Diameter, $Height)
    $panelWidth = [math]::Max($diameter, $Width - $Height + $diameter)
    return @(
        ($X + [math]::Truncate(($Width - $panelWidth) / 2)),
        ($Y + [math]::Truncate(($Height - $diameter) / 2)),
        $panelWidth,
        $diameter
    )
}

function Downscaled-Size([double]$Width, [double]$Height, [int]$Limit) {
    $factor = [math]::Min(1.0, [math]::Min($Limit / $Width, $Limit / $Height))
    return @(
        [math]::Max(1, [math]::Floor($Width * $factor + 0.5)),
        [math]::Max(1, [math]::Floor($Height * $factor + 0.5))
    )
}

$prefix = 'Telegram/SourceFiles/'
$composer = Read-Source ($prefix + 'lunagram/composer.cpp')
$history = Read-Source ($prefix + 'history/history_widget.cpp')
$controls = Read-Source ($prefix + 'history/view/controls/history_view_compose_controls.cpp')
$photo = Read-Source ($prefix + 'history/view/media/history_view_photo.cpp')
$chatStyle = Read-Source ($prefix + 'ui/chat/chat.style')
$helpersStyle = Read-Source ($prefix + 'chat_helpers/chat_helpers.style')
$designStyle = Read-Source ($prefix + 'lunagram/lunagram_design.style')
$nativeSize = Read-Source ($prefix + 'history/view/media/history_view_media_common.cpp')
$inner = Read-Source ($prefix + 'history/history_inner_widget.cpp')
$message = Read-Source ($prefix + 'history/view/history_view_message.cpp')
$reply = Read-Source ($prefix + 'history/view/history_view_reply.cpp')
$paintContext = Read-Source ($prefix + 'ui/chat/chat_style.h')
$documentMedia = Read-Source ($prefix + 'data/data_document_media.cpp')
$documentMediaHeader = Read-Source ($prefix + 'data/data_document_media.h')
$gif = Read-Source ($prefix + 'history/view/media/history_view_gif.cpp')
$document = Read-Source ($prefix + 'history/view/media/history_view_document.cpp')
$sticker = Read-Source ($prefix + 'history/view/media/history_view_sticker.cpp')
$themeDocument = Read-Source ($prefix + 'history/view/media/history_view_theme_document.cpp')

Assert-Contract ($chatStyle -match 'msgMaxWidth:\s*430px;') 'Plain text max width changed.'
Assert-Contract ($chatStyle -match 'maxMediaSize:\s*430px;') 'Global media max width changed.'
Assert-Contract ($chatStyle -match 'lunagramReferencePhotoMaxWidth:\s*320px;') 'Reference photo style cap missing.'
Assert-Contract ($chatStyle -match 'historyGroupWidthMax:\s*maxMediaSize;') 'Album width changed.'
Assert-Contract ($helpersStyle -match '(?s)lunagramReferenceComposeField:.*?heightMin:\s*40px;') 'Reference field height missing.'
Assert-Contract ($designStyle -match 'lunagramReferenceHeaderButtonDiameter:\s*38px;') 'Reference circle style missing.'
Assert-Contract ($designStyle -match 'lunagramReferencePanelInset:\s*5px;') 'Panel inset style changed; update the model.'
Assert-Contract ($chatStyle -match '(?s)lunagramReferenceBotMenuButton: RoundButton\(historyBotMenuButton\).*?textBg:\s*transparent;.*?textBgOver:\s*transparent;.*?height:\s*38px;.*?textTop:\s*10px;') 'Bot Menu must be a separate transparent 38px native button.'

$panel = Function-Body $composer 'PaintComposerPanel'
Assert-Contract ($panel -match '&controller->session\(\) == session.get\(\)') 'Composer controller/session guard missing.'
Assert-Contract ($panel -match 'controller->currentChatTheme\(\)') 'Composer uses a stale/default theme.'
Assert-Contract ($panel -match 'bounds.isEmpty\(\)') 'Empty-panel guard missing.'
Assert-Contract ($panel -match 'bounds.height\(\) / 2') 'Small surface radius is not bounded.'
$circle = Function-Body $composer 'ComposerButtonPanel'
Assert-Contract ($circle -match 'geometry.width\(\) - geometry.height\(\) \+ diameter') 'Paid Send surface must preserve native extra width.'
$field = Function-Body $composer 'ComposerFieldPanel'
Assert-Contract ($field -match 'field.setRight\(send.left\(\) - st::lunagramReferencePanelInset\)') 'LTR Send separation missing.'
Assert-Contract ($field -match 'field.setLeft\(send.right\(\) \+ st::lunagramReferencePanelInset\)') 'RTL Send separation missing.'

foreach ($source in @($history, $controls)) {
    Assert-Contract ($source -match 'buttonsCenterTwice - button->height\(\)') 'Controls must use their actual heights on one axis.'
    Assert-Contract ($source -match 'buttonsCenterTwice - st::historyMessagesTTL.iconButton.height') 'TTL must use its native internal button height.'
    Assert-Contract ($source -match 'Lunagram::ComposerFieldPanel\(field, _send->geometry\(\)\)') 'Missing split middle composer panel.'
    Assert-Contract ($source -match 'Lunagram::ComposerButtonPanel\(button->geometry\(\)\)') 'Buttons must use actual native geometry.'
    Assert-Contract ($source -match 'fieldWidth\s*:\s*(?:width\(\)|size.width\(\))') 'Disabled field must honor reserved width in reference mode.'
    Assert-Contract ($source -match 'updateExpandButtonGeometry\(\)') 'Native multiline editor handling missing.'
    Assert-Contract ($source -match '(?s)std::array<QWidget\*, [57]>\{\s*_botMenu.button.get\(\)') 'Bot Menu must have its own glass surface.'
}
$channelGeometry = Function-Body $history 'HistoryWidget::updateChannelButtonsGeometry'
Assert-Contract ($channelGeometry -match '!Lunagram::ReferenceDesignEnabled\(\)') 'Channel geometry must not change non-reference mode.'
Assert-Contract ($channelGeometry -match 'myrtlrect\(') 'Channel middle button must mirror in RTL.'
Assert-Contract ($channelGeometry -match '_joinChannel->setGeometry\(geometry\)') 'Join hit rectangle missing.'
Assert-Contract ($channelGeometry -match '_muteUnmute->setGeometry\(geometry\)') 'Mute hit rectangle missing.'
foreach ($name in @('setupGiftToChannelButton', 'setupDirectMessageButton')) {
    $body = Function-Body $history ('HistoryWidget::' + $name)
    Assert-Contract ($body -match 'static_cast<QWidget\*>\(this\)') 'Reference channel action must be a sibling.'
    Assert-Contract ($body -match 'setParent\(newParent\)') 'Original non-reference child ownership missing.'
    Assert-Contract ($body -match 'setClickedCallback') 'Native channel action callback missing.'
}
foreach ($name in @('refreshGiftToChannelShown', 'refreshDirectMessageShown')) {
    $body = Function-Body $history ('HistoryWidget::' + $name)
    Assert-Contract ($body -match '!_muteUnmute->isHidden\(\)') 'Sibling action may leak out of channel row.'
    Assert-Contract ($body -match '!_joinChannel->isHidden\(\)') 'Join row presence guard missing.'
}
$paint = Function-Body $controls 'ComposeControls::paintBackground'
Assert-Contract ($paint -match '(?s)if \(_regularWindow\s*&& &_st == &st::lunagramReferenceComposeControls\s*&& widget == _wrap.get\(\)\)') 'Non-window/overridden composer must retain its original paint path.'
Assert-Contract ($paint -match '_header->geometry\(\).adjusted') 'Reply preview must have a separate surface.'

$photoGate = Function-Body $photo 'Photo::maximumMediaSize'
foreach ($guard in @(
    'Lunagram::ReferenceDesignEnabled()',
    '_parent->media() == this',
    'media->photo() == _data.get()',
    '!_storyId',
    '!_serviceWidth',
    '!_data->extendedMediaVideoDuration()',
    '!IsHostedInstantViewMedia(_parent)',
    '!_parent->data()->isFakeAboutView()',
    '!_parent->data()->isSponsored()',
    '_parent->delegate()->elementChatMode() != ElementChatMode::Narrow'
)) {
    Assert-Contract ($photoGate.Contains($guard)) ('Missing single-photo exclusion: ' + $guard)
}
Assert-Contract ($photoGate -match 'reference \? st::lunagramReferencePhotoMaxWidth : st::maxMediaSize') 'Reference-only photo cap missing.'
foreach ($name in @('countOptimalSize', 'countCurrentSize')) {
    $body = Function-Body $photo ('Photo::' + $name)
    Assert-Contract ($body -match 'maximumMediaSize\(\)') 'Both photo layout passes must use the same cap.'
    Assert-Contract ($body -match 'std::min\(st::msgMaxWidth, maximumSize\)') 'Caption can re-expand the photo beyond its cap.'
    Assert-Contract ($body -match 'adjustHeightForLessCrop\(') 'Native photo crop/aspect adjustment missing.'
    Assert-Contract ($body -match 'HostedInstantViewForcedSize\(') 'Hosted forced size path missing.'
}
foreach ($name in @('sizeForGroupingOptimal', 'sizeForGrouping')) {
    $body = Function-Body $photo ('Photo::' + $name)
    Assert-Contract ($body -notmatch 'maximumMediaSize|lunagramReference') 'Grouped photo sizing must remain native.'
}
Assert-Contract ($nativeSize -match '(?s)CountDesiredMediaSize\(QSize original\).*?DownscaledSize\(\s*style::ConvertScale\(original\),\s*\{ st::maxMediaSize, st::maxMediaSize \}') 'Native unmodified downscale contract changed.'

Assert-Contract ($paintContext -match 'bool backdrop = false;') 'Backdrop paint must be opt-in for every existing context.'
$cachedThumbnail = Function-Body $documentMedia 'DocumentMedia::goodThumbnailCached'
Assert-Contract ($documentMediaHeader -match '\[\[nodiscard\]\] Image \*goodThumbnailCached\(\) const;') 'Cached thumbnail accessor declaration missing.'
Assert-Contract ($cachedThumbnail -match '^\{\s*return _goodThumbnail.get\(\);\s*\}$') 'Capture thumbnail accessor must only return the existing image pointer.'
Assert-Contract ($cachedThumbnail -notmatch 'Expects|_flags|Wanted|ReadOrGenerate|load|new ') 'Cached thumbnail lookup cannot assert wanted state, request or generate an asset.'
$normalThumbnail = Function-Body $documentMedia 'DocumentMedia::goodThumbnail'
Assert-Contract ($normalThumbnail.Contains('Expects((_flags & Flag::GoodThumbnailWanted) != 0);')) 'Native requested-thumbnail assertion must remain enabled.'
Assert-Contract ($normalThumbnail.Contains('ReadOrGenerateThumbnail(_owner);')) 'Native requested-thumbnail generation behavior changed.'
foreach ($source in @($gif, $document, $sticker, $themeDocument)) {
    $normalCalls = [regex]::Matches($source, '_dataMedia->goodThumbnail\(\)').Count
    $guardedCalls = [regex]::Matches($source, '(?:context\.)?backdrop\s*\?\s*_dataMedia->goodThumbnailCached\(\)\s*:\s*_dataMedia->goodThumbnail\(\)').Count
    Assert-Contract ($normalCalls -gt 0 -and $guardedCalls -eq $normalCalls) 'Every capture-reachable goodThumbnail call must select the pure cached accessor before the native getter.'
}
foreach ($entry in @(
    @($gif, 'Gif::validateThumbCache'),
    @($gif, 'Gif::prepareThumbCache'),
    @($gif, 'Gif::validateGroupedCache'),
    @($document, 'Document::validateThumbnail'),
    @($sticker, 'Sticker::paintedPixmap'),
    @($themeDocument, 'ThemeDocument::validateThumbnail')
)) {
    $body = Function-Body $entry[0] $entry[1]
    Assert-Contract ($body -match '(?:context\.)?backdrop\s*\?\s*_dataMedia->goodThumbnailCached\(\)') ('Nested thumbnail helper loses capture mode: ' + $entry[1])
}
Assert-Contract ($gif -match '(?s)validateThumbCache\(\s*\{ usew, painth \},\s*isRound,\s*rounding,\s*context.backdrop\)') 'Single Gif thumbnail caller must propagate capture mode.'
Assert-Contract ($gif -match '(?s)validateGroupedCache\(\s*geometry,\s*rounding,\s*cacheKey,\s*cache,\s*context.backdrop\)') 'Grouped Gif thumbnail caller must propagate capture mode.'
Assert-Contract ($gif -match 'prepareThumbCache\(scaled, backdrop\)') 'Gif cache preparation must inherit capture mode rather than defaulting to native loading.'
Assert-Contract ($gif -match 'if \(!backdrop && !normal\)') 'Capture Gif fallback must not load or validate a video thumbnail.'
Assert-Contract ($document -match '(?s)validateThumbnail\(\s*thumbed,\s*st.thumbSize,\s*rounding,\s*context.backdrop\)') 'Document thumbnail caller must propagate capture mode.'
Assert-Contract ($document -match 'if \(!backdrop && _data->isSvgImage\(\)\)') 'Capture SVG fallback must not set wanted flags or request thumbnail generation.'
Assert-Contract ($themeDocument -match 'validateThumbnail\(context.backdrop\)') 'Theme thumbnail caller must propagate capture mode.'
foreach ($wanted in @($false, $true)) {
    foreach ($cached in @($false, $true)) {
        foreach ($backdrop in @($false, $true)) {
            $lookup = if ($backdrop) { 'cached' } else { 'native' }
            $asserts = $lookup -eq 'native' -and !$wanted
            $generates = $lookup -eq 'native' -and $wanted -and !$cached
            Assert-Contract (!$backdrop -or (!$asserts -and !$generates)) 'Cold capture media must be safe before wanted state is set.'
            Assert-Contract ($backdrop -or ($asserts -eq (!$wanted) -and $generates -eq ($wanted -and !$cached))) 'Non-capture getter must retain native wanted assertion and lazy generation.'
        }
    }
}
$diceCaptureSource = Read-Source 'Telegram/SourceFiles/history/view/media/history_view_dice.cpp'
Assert-Contract ($diceCaptureSource -match '#include "ui/chat/chat_style.h"') 'Dice capture must include the complete ChatPaintContext definition before accessing its fields.'
$capture = Function-Body $inner 'HistoryInner::paintBackdrop'
foreach ($contract in @(
    'context.backdrop = true;',
    'context.paused = true;',
    'context.skipSelectionCheck = true;',
    'context.reactionInfo = nullptr;',
    'context.highlightPathCache = nullptr;',
    'context.gestureHorizontal = {};',
    '_widget->history() != _history',
    'view->data()->isService()',
    'view->data()->isSponsored()',
    'view->data()->hasUnpaidContent()',
    'view->data()->media()->gift()',
    'view->data()->media()->ttlSeconds()',
    'view->data()->media()->sharedContact()',
    'view->data()->media()->todolist()',
    'view->data()->media()->paper()',
    'view->data()->media()->giveawayStart()',
    'view->data()->media()->giveawayResults()',
    'enumerateItemsInHistory<true>',
    'view->draw(p, copy)'
)) {
    Assert-Contract ($capture.Contains($contract)) ('Capture source contract missing: ' + $contract)
}
Assert-Contract ($capture -notmatch 'processPainted|startBunch|readInboxTill|markContentsRead|scheduleIncrement|pollExtendedMedia|recordCurrentReactionEffect|visibleAreaUpdated|adjustCurrent') 'Backdrop must not run native observation, polling or scrolling bookkeeping.'
$iterator = Function-Body $inner 'HistoryInner::enumerateItemsInHistory'
Assert-Contract ($iterator -match 'clip.isNull\(\) \? _visibleAreaTop : clip.top\(\)') 'Normal iterator visibility must be preserved.'
Assert-Contract ($iterator -match 'clip.isNull\(\) \? 0 : collapseGapsTotal') 'Capture must include collapsed-gap shifted history extent.'
$prepare = Function-Body $history 'HistoryWidget::prepareComposeBackdrop'
Assert-Contract ($prepare -match '_list->theme\(\)->background\(\).giftId') 'Gift wallpaper must retain the native path.'
Assert-Contract ($prepare -match '_kbScroll->isHidden\(\) \? _kbScroll->y\(\) : height\(\)') 'Continuation must stop above a visible native bot keyboard.'
Assert-Contract ($prepare -match '_list->theme\(\)') 'Backdrop fingerprint must use this history actual theme.'
Assert-Contract ($prepare -notmatch 'resize\(|setGeometry\(|scrollToY\(|historyMargin|visibleAreaUpdated') 'Backdrop must not change native scroll geometry or range.'
$sourcePaint = Function-Body $history 'HistoryWidget::paintComposeBackdrop'
Assert-Contract ($sourcePaint -match 'list->mapTo\(this, QPoint\(\)\)') 'Source origin must include the actual native scroll offset.'
Assert-Contract ($sourcePaint -match 'clip.translated\(-origin\)') 'Message clip must map to HistoryInner local coordinates.'
Assert-Contract ($sourcePaint -notmatch 'grab\(|render\(|QPaintEvent|paintEvent\(') 'Capture cannot recurse into QWidget paint or screen sampling.'
$historyPaint = Function-Body $history 'HistoryWidget::paintEvent'
Assert-Contract ($historyPaint.IndexOf('prepareComposeBackdrop()') -lt $historyPaint.IndexOf('Painter p(this)')) 'Prepare source before the native widget painter.'
Assert-Contract ($historyPaint.IndexOf('paintComposeBackdrop(p,') -lt $historyPaint.IndexOf('drawField(p,')) 'Raw continuation must paint before composer surfaces.'
Assert-Contract ($historyPaint -match '(?s)if \(backdrop\) \{.*?paintComposeBackdrop\(p,') 'Continuation must remain native-DPR while blur is pending.'
$switch = Function-Body $history 'HistoryWidget::setHistory'
Assert-Contract ($switch -match 'Lunagram::ClearGlassBackdrop\(this\)') 'Chat switch must discard private pixels immediately.'
$nativePaint = Function-Body $inner 'HistoryInner::paintEvent'
Assert-Contract ($nativePaint -notmatch 'invalidateComposeBackdrop') 'Worker completion cannot induce an Inner paint/revision feedback loop.'
$messagePaint = Function-Body $message 'Message::draw'
Assert-Contract ($messagePaint -match '!context.backdrop && item->hasUnrequestedFactcheck\(\)') 'Capture must not request fact checks.'
Assert-Contract ($messagePaint -match 'context.backdrop \? nullptr : Get<Reply>\(\)') 'Capture must not trigger a reply layout resize.'
Assert-Contract ($messagePaint -match 'media && !context.backdrop') 'Capture must not start bubble fireworks.'
$replyPaint = Function-Body $reply 'Reply::paint'
Assert-Contract ($replyPaint -match '(?s)const auto image = \[&\].*?if \(context.backdrop\) \{\s*return nullptr;') 'Capture must not retrieve lazy reply preview assets.'

foreach ($scale in @(100, 125, 150, 175, 200, 300)) {
    $halo = Native-Scale 20 $scale
    foreach ($scrollHeight in @(1, 80, 500)) {
        foreach ($fieldHeight in @(40, 89, 224)) {
            foreach ($keyboardHeight in @(0, 90, 280)) {
                $viewportTop = Native-Scale 66 $scale
                $viewportHeight = Native-Scale $scrollHeight $scale
                $composeHeight = Native-Scale $fieldHeight $scale
                $keyboard = Native-Scale $keyboardHeight $scale
                $viewportBottom = $viewportTop + $viewportHeight
                $keyboardTop = $viewportBottom + $composeHeight
                $windowBottom = $keyboardTop + $keyboard
                $roiTop = [math]::Max($viewportTop, $viewportBottom - $halo)
                $roiBottom = if ($keyboard -gt 0) { $keyboardTop } else { $windowBottom }
                Assert-Contract ($roiTop -le $viewportBottom -and $roiBottom -eq $keyboardTop) 'ROI does not cover composer plus bounded halo or crosses keyboard.'
                foreach ($scrollTop in @(0, 39, 1200, 120000)) {
                    $listOrigin = $viewportTop - $scrollTop
                    $innerEdge = $viewportBottom - $listOrigin
                    Assert-Contract ($innerEdge -eq $scrollTop + $viewportHeight) 'Underlap must use exactly the native next content pixel.'
                    $innerBottom = $roiBottom - $listOrigin
                    Assert-Contract ($innerBottom + $listOrigin -eq $roiBottom) 'Caller/list coordinate round-trip changed with scrolling/DPI.'
                }
            }
        }
    }
}
foreach ($gap in @(1, 19, 100, 400)) {
    $logicalEnd = 1000
    $shiftedEnd = $logicalEnd + $gap
    $captureTop = $shiftedEnd - 1
    Assert-Contract ($logicalEnd -le $captureTop -and $shiftedEnd -gt $captureTop) 'Collapsed-gap capture extent regression model failed.'
}

foreach ($scale in @(100, 125, 133, 150, 175, 200, 250, 300)) {
    $padding = Native-Scale 9 $scale
    $minimum = Native-Scale 40 $scale
    $diameter = Native-Scale 38 $scale
    $inset = Native-Scale 5 $scale
    $disabledContentHeight = (Native-Scale 46 $scale) - 2 * $padding
    $disabledTop = [math]::Truncate(($minimum - $disabledContentHeight) / 2)
    Assert-Contract ([math]::Abs($disabledTop + $disabledContentHeight / 2.0 - $minimum / 2.0) -le 0.5) 'Disabled native content is not centered in the reference field.'
    Assert-Contract ($disabledTop -ge 0 -and $disabledTop + $disabledContentHeight -le $minimum) 'Disabled native content is clipped.'
    foreach ($fieldPixels in @(40, 80, 140, 224)) {
        $fieldHeight = Native-Scale $fieldPixels $scale
        $rowHeight = $fieldHeight + 2 * $padding
        $axisTwice = 2 * ($rowHeight - $padding) - $minimum
        foreach ($heightPixels in @(28, 32, 40, 44, 46)) {
            $height = Native-Scale $heightPixels $scale
            $top = [math]::Truncate(($axisTwice - $height) / 2)
            Assert-Contract ([math]::Abs($top + $height / 2.0 - $axisTwice / 2.0) -le 0.5) 'DPI button centers drift more than native integer rounding.'
            Assert-Contract ($top -ge 0 -and $top + $height -le $rowHeight) 'Composer control clipped outside its allocated row.'
        }
        foreach ($sendPixels in @(44, 90, 160)) {
            $sendWidth = Native-Scale $sendPixels $scale
            $sendHeight = Native-Scale 46 $scale
            $top = [math]::Truncate(($axisTwice - $sendHeight) / 2)
            $surface = Button-Panel 0 $top $sendWidth $sendHeight $diameter
            Assert-Contract ($surface[0] -ge 0 -and $surface[0] + $surface[2] -le $sendWidth) 'Send surface overflows its real widget.'
            Assert-Contract ([math]::Abs($surface[1] + $surface[3] / 2.0 - ($top + $sendHeight / 2.0)) -le 0.5) 'Send circle is not centered.'
            Assert-Contract ($sendPixels -ne 44 -or $surface[2] -eq $diameter) 'Ordinary Send must be circular.'
            Assert-Contract ($sendPixels -eq 44 -or $surface[2] -gt $diameter) 'Paid Send width was cropped to a circle.'
        }
    }
    foreach ($widthPixels in @(380, 512, 720, 1080)) {
        $width = Native-Scale $widthPixels $scale
        $side = Native-Scale 46 $scale
        foreach ($direct in @($false, $true)) {
            foreach ($gift in @($false, $true)) {
                $left = if ($direct) { $side + $inset } else { 0 }
                $right = if ($gift) { $side + $inset } else { 0 }
                $middleWidth = $width - $left - $right
                Assert-Contract ($middleWidth -gt 0) 'Channel middle action has no usable width.'
                foreach ($rtl in @($false, $true)) {
                    $middleX = if ($rtl) { $right } else { $left }
                    $directX = if ($rtl) { $width - $side } else { 0 }
                    $giftX = if ($rtl) { 0 } else { $width - $side }
                    $middleEnd = $middleX + $middleWidth
                    Assert-Contract (!$direct -or ($middleEnd -le $directX -or $middleX -ge $directX + $side)) 'Channel Direct overlaps the central hit rectangle.'
                    Assert-Contract (!$gift -or ($middleEnd -le $giftX -or $middleX -ge $giftX + $side)) 'Channel Gift overlaps the central hit rectangle.'
                }
            }
        }
    }
    $limit = Native-Scale 320 $scale
    $bubbleMinimum = Native-Scale 200 $scale
    foreach ($widthPixels in @(128, 360, 1280)) {
        foreach ($ratio in @(0.25, 0.5, 1.0, 1.5, 4.0)) {
            $sourceWidth = Native-Scale $widthPixels $scale
            $sourceHeight = [math]::Max(1, [math]::Floor($sourceWidth * $ratio + 0.5))
            $desired = Downscaled-Size $sourceWidth $sourceHeight $limit
            Assert-Contract ($desired[0] -le $limit -and $desired[1] -le $limit) 'Desired single-photo size exceeds the cap.'
            Assert-Contract ($desired[0] -le $sourceWidth -and $desired[1] -le $sourceHeight) 'Desired thumbnail was upscaled.'
            foreach ($captionPixels in @(0, 100, 320, 430, 800)) {
                $caption = [math]::Min((Native-Scale $captionPixels $scale), $limit)
                $optimalWidth = [math]::Max([math]::Max($desired[0], $desired[1]), $bubbleMinimum)
                $optimalWidth = [math]::Min([math]::Max($optimalWidth, $caption), $limit)
                Assert-Contract ($optimalWidth -le $limit) 'Caption re-expanded optimal photo width.'
                foreach ($requestPixels in @(60, 160, 240, 320, 512)) {
                    $request = Native-Scale $requestPixels $scale
                    $thumbMaximum = [math]::Min($request, $limit)
                    $currentImage = Downscaled-Size $desired[0] $desired[1] ([math]::Min($request, $optimalWidth))
                    $minimumWidth = [math]::Min($thumbMaximum, $bubbleMinimum)
                    $currentWidth = [math]::Min([math]::Max([math]::Max($currentImage[0], $minimumWidth), $caption), $thumbMaximum)
                    Assert-Contract ($currentWidth -le $request -and $currentWidth -le $limit) 'Current photo/caption width exceeds the viewport or reference cap.'
                }
            }
        }
    }
}

Write-Output ('PASS ' + $script:Checks + ' chat layout source/model contracts. No Qt compilation, native visual test, UI, account access or build was performed.')

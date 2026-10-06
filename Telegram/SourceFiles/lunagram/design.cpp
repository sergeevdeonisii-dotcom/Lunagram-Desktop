#include "lunagram/design.h"

#include "core/application.h"
#include "core/core_settings.h"
#include "lunagram/lunagram_settings.h"
#include "ui/chat/chat_theme.h"
#include "ui/painter.h"
#include "window/themes/window_theme.h"
#include "window/section_widget.h"
#include "window/window_session_controller.h"
#include "mainwidget.h"

#include "styles/style_lunagram_design.h"
#include "styles/style_widgets.h"

namespace Lunagram {

void EnsureReferenceAppearance() {
	if (!ReferenceDesignEnabled()) {
		return;
	}
	auto &settings = Core::App().settings();
	if (settings.readPref<bool>("lunagram/liquid_appearance_v2", false)) {
		return;
	}
	if (Window::Theme::Apply(u":/lunagram/themes/liquid.tdesktop-theme"_q)) {
		Window::Theme::KeepApplied();
		settings.setChatFiltersHorizontal(true);
		settings.writePref<bool>("lunagram/liquid_appearance_v2", true);
		Core::App().saveSettingsDelayed();
	}
}

void PaintReferenceBackdrop(
		not_null<Window::SessionController*> controller,
		not_null<Ui::ChatTheme*> theme,
		not_null<QWidget*> widget,
		QRect clip) {
	const auto content = controller->content();
	if (!ReferenceDesignEnabled()
		|| theme.get() != controller->defaultChatTheme().get()
		|| theme->background().giftId
		|| content->size().isEmpty()
		|| (widget.get() != content.get()
			&& !content->isAncestorOf(widget.get()))) {
		Window::SectionWidget::PaintBackground(controller, theme, widget, clip);
		return;
	}
	const auto origin = widget->mapTo(content, QPoint());
	clip.translate(origin);
	auto p = QPainter(widget);
	p.translate(-origin);
	p.setClipRect(clip, Qt::IntersectClip);
	Window::SectionWidget::PaintBackground(
		p,
		theme,
		content->size(),
		clip,
		controller->isGifPausedAtLeastFor(Window::GifPauseReason::Any));
}

void PaintGlassPanel(
		QPainter &p,
		QRect bounds,
		QColor background,
		int radius) {
	if (bounds.isEmpty()) {
		return;
	}
	auto border = st::windowFg->c;
	border.setAlpha(24);
	const auto rounding = radius ? radius : st::lunagramReferencePanelRadius;
	p.save();
	p.setRenderHint(QPainter::Antialiasing);
	p.setBrush(background);
	p.setPen(QPen(border, st::lineWidth));
	p.drawRoundedRect(bounds, rounding, rounding);
	p.restore();
}

} // namespace Lunagram

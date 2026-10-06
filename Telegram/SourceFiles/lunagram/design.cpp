#include "lunagram/design.h"

#include "core/application.h"
#include "core/core_settings.h"
#include "lunagram/lunagram_settings.h"
#include "ui/painter.h"
#include "window/themes/window_theme.h"

#include <algorithm>

#include "styles/style_lunagram_design.h"
#include "styles/style_widgets.h"

namespace Lunagram {

void EnsureReferenceAppearance() {
	if (!ReferenceDesignEnabled()) {
		return;
	}
	auto &settings = Core::App().settings();
	if (settings.readPref<bool>("lunagram/liquid_appearance_v1", false)) {
		return;
	}
	if (Window::Theme::Apply(u":/lunagram/themes/liquid.tdesktop-theme"_q)) {
		Window::Theme::KeepApplied();
		settings.setChatFiltersHorizontal(true);
		settings.writePref<bool>("lunagram/liquid_appearance_v1", true);
		Core::App().saveSettingsDelayed();
	}
}

void PaintGlassPanel(
		QPainter &p,
		QRect bounds,
		QColor background,
		int radius) {
	if (bounds.isEmpty()) {
		return;
	}
	background.setAlpha(std::min(background.alpha(), 218));
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

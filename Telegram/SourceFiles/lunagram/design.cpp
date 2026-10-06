#include "lunagram/design.h"

#include "base/timer.h"
#include "base/weak_ptr.h"
#include "core/application.h"
#include "core/core_settings.h"
#include "lunagram/lunagram_settings.h"
#include "ui/chat/chat_theme.h"
#include "ui/image/image_prepare.h"
#include "ui/style/style_core.h"
#include "ui/painter.h"
#include "ui/power_saving.h"
#include "window/themes/window_theme.h"
#include "window/section_widget.h"
#include "window/window_session_controller.h"
#include "mainwidget.h"

#include <crl/crl_async.h>
#include <QtCore/QPointer>
#include <QtGui/QLinearGradient>
#include <QtGui/QPainterPath>
#include <algorithm>
#include <cmath>
#include <map>

#include "styles/style_lunagram_design.h"
#include "styles/style_widgets.h"

namespace Lunagram {
namespace {

constexpr auto kGlassSourcePixels = 768 * 1024;
constexpr auto kGlassConsumerLimit = 32;
constexpr auto kGlassFrameInterval = crl::time(33);
constexpr auto kGlassSlowFrameInterval = crl::time(100);

struct BackdropFingerprint {
	QString key;
	qint64 prepared = 0;
	qint64 tiled = 0;
	qint64 gradient = 0;
	std::optional<QColor> fill;
	float64 patternOpacity = 0.;
	int rotation = 0;
	bool tile = false;
	bool pattern = false;

	friend bool operator==(
		const BackdropFingerprint &,
		const BackdropFingerprint &) = default;
};

class BackdropCache final : public QObject, public base::has_weak_ptr {
public:
	BackdropCache(not_null<MainWidget*> owner);
	~BackdropCache();

	void prepare(
		not_null<Window::SessionController*> controller,
		not_null<Ui::ChatTheme*> theme,
		not_null<QWidget*> consumer);
	[[nodiscard]] const QImage &source() const;
	[[nodiscard]] const QImage &blurred() const;
	[[nodiscard]] float64 sampleScale() const;
	[[nodiscard]] bool dark() const;

private:
	void checkBackground();
	void invalidate(bool reset);
	void repaintConsumers();
	void capture(not_null<Window::SessionController*> controller);
	void accept(
		uint64 generation,
		QImage source,
		QImage blurred,
		float64 scale,
		bool dark);

	QPointer<MainWidget> _owner;
	base::weak_ptr<Ui::ChatTheme> _theme;
	BackdropFingerprint _fingerprint;
	std::vector<QPointer<QWidget>> _consumers;
	QSize _area;
	QImage _source;
	QImage _blurred;
	float64 _deviceRatio = 0.;
	float64 _sampleScale = 1.;
	crl::time _lastCapture = 0;
	uint64 _generation = 0;
	bool _dark = false;
	bool _dirty = true;
	bool _running = false;
	base::Timer _refreshTimer;
	rpl::lifetime _themeLifetime;
	rpl::lifetime _lifetime;

};

[[nodiscard]] std::map<MainWidget*, QPointer<BackdropCache>> &BackdropCaches() {
	static auto result = std::map<MainWidget*, QPointer<BackdropCache>>();
	return result;
}

[[nodiscard]] BackdropFingerprint Fingerprint(
		const Ui::ChatThemeBackground &background) {
	return {
		.key = background.key,
		.prepared = background.prepared.cacheKey(),
		.tiled = background.preparedForTiled.cacheKey(),
		.gradient = background.gradientForFill.cacheKey(),
		.fill = background.colorForFill,
		.patternOpacity = background.patternOpacity,
		.rotation = background.gradientRotation,
		.tile = background.tile,
		.pattern = background.isPattern,
	};
}

BackdropCache::BackdropCache(not_null<MainWidget*> owner)
: QObject(owner)
, _owner(owner)
, _refreshTimer([=] { repaintConsumers(); }) {
	owner->sizeValue() | rpl::on_next([=] {
		invalidate(true);
	}, _lifetime);
	style::PaletteChanged() | rpl::on_next([=] {
		invalidate(true);
	}, _lifetime);
	PowerSaving::Changes() | rpl::on_next([=] {
		invalidate(false);
	}, _lifetime);
}

BackdropCache::~BackdropCache() {
	for (auto i = BackdropCaches().begin(); i != BackdropCaches().end();) {
		if (!i->second || i->second.data() == this) {
			i = BackdropCaches().erase(i);
		} else {
			++i;
		}
	}
}

void BackdropCache::prepare(
		not_null<Window::SessionController*> controller,
		not_null<Ui::ChatTheme*> theme,
		not_null<QWidget*> consumer) {
	const auto end = std::remove_if(
		_consumers.begin(),
		_consumers.end(),
		[](const auto &widget) { return !widget; });
	_consumers.erase(end, _consumers.end());
	if (ranges::none_of(_consumers, [&](const auto &widget) {
		return widget.data() == consumer.get();
	})
		&& _consumers.size() < kGlassConsumerLimit) {
		_consumers.push_back(consumer.get());
	}
	if (_theme.get() != theme.get()) {
		_themeLifetime.destroy();
		_theme = base::make_weak(theme);
		theme->repaintBackgroundRequests() | rpl::on_next([=] {
			checkBackground();
		}, _themeLifetime);
		invalidate(true);
	}
	const auto fingerprint = Fingerprint(theme->background());
	if (_fingerprint != fingerprint) {
		_fingerprint = fingerprint;
		invalidate(true);
	}
	if (!_owner) {
		return;
	}
	const auto area = _owner->size();
	const auto ratio = _owner->devicePixelRatioF();
	if (_area != area || _deviceRatio != ratio) {
		_area = area;
		_deviceRatio = ratio;
		invalidate(true);
	}
	if (!_dirty || _running || _area.isEmpty()) {
		return;
	}
	const auto interval = PowerSaving::On(PowerSaving::kChatBackground)
		? kGlassSlowFrameInterval
		: kGlassFrameInterval;
	const auto remaining = _lastCapture + interval - crl::now();
	if (remaining > 0) {
		_refreshTimer.callOnce(remaining);
		return;
	}
	capture(controller);
}

void BackdropCache::checkBackground() {
	if (const auto theme = _theme.get()) {
		const auto fingerprint = Fingerprint(theme->background());
		const auto changed = (_fingerprint != fingerprint);
		_fingerprint = fingerprint;
		invalidate(changed);
	}
}

void BackdropCache::invalidate(bool reset) {
	_dirty = true;
	if (reset) {
		++_generation;
		_source = QImage();
		_blurred = QImage();
	}
	if (!_refreshTimer.isActive()) {
		_refreshTimer.callOnce(kGlassFrameInterval);
	}
}

void BackdropCache::repaintConsumers() {
	if (_owner) {
		_owner->update();
	}
	for (const auto &consumer : _consumers) {
		if (consumer && !consumer->isHidden()) {
			consumer->update();
		}
	}
}

void BackdropCache::capture(
		not_null<Window::SessionController*> controller) {
	const auto theme = _theme.get();
	if (!_owner || !theme || theme->background().giftId) {
		return;
	}
	const auto pixels = float64(_area.width()) * _area.height();
	const auto scale = std::min(
		_deviceRatio / 2.,
		std::sqrt(kGlassSourcePixels / pixels));
	const auto size = QSize(
		std::max(1, int(std::floor(_area.width() * scale))),
		std::max(1, int(std::floor(_area.height() * scale))));
	auto source = QImage(size, QImage::Format_ARGB32_Premultiplied);
	source.setDevicePixelRatio(scale);
	auto fill = theme->background().colorForFill.value_or(
		Ui::CountAverageColor(theme->background().colors));
	fill.setAlpha(255);
	source.fill(fill);
	{
		auto p = QPainter(&source);
		Window::SectionWidget::PaintBackground(
			p,
			theme,
			_area,
			QRect(QPoint(), _area),
			controller->isGifPausedAtLeastFor(Window::GifPauseReason::Any));
	}
	_dirty = false;
	_running = true;
	_lastCapture = crl::now();
	const auto generation = ++_generation;
	const auto radius = std::max(1, int(std::round(
		st::lunagramGlassBlurRadius * scale)));
	const auto weak = base::make_weak(this);
	crl::async([
		weak,
		source = std::move(source),
		generation,
		radius,
		scale
	]() mutable {
		const auto average = Ui::CountAverageColor(source);
		const auto dark = (0.2126 * average.redF()
			+ 0.7152 * average.greenF()
			+ 0.0722 * average.blueF()) < 0.35;
		auto blurred = Images::BlurLargeImage(QImage(source), radius);
		crl::on_main(weak, [=,
			source = std::move(source),
			blurred = std::move(blurred)
		]() mutable {
			if (const auto cache = weak.get()) {
				cache->accept(
					generation,
					std::move(source),
					std::move(blurred),
					scale,
					dark);
			}
		});
	});
}

void BackdropCache::accept(
		uint64 generation,
		QImage source,
		QImage blurred,
		float64 scale,
		bool dark) {
	_running = false;
	if (generation == _generation && _owner) {
		_source = std::move(source);
		_blurred = std::move(blurred);
		_sampleScale = scale;
		_dark = dark;
	}
	repaintConsumers();
}

const QImage &BackdropCache::source() const {
	return _source;
}

const QImage &BackdropCache::blurred() const {
	return _blurred;
}

float64 BackdropCache::sampleScale() const {
	return _sampleScale;
}

bool BackdropCache::dark() const {
	return _dark;
}

[[nodiscard]] not_null<BackdropCache*> CacheFor(
		not_null<MainWidget*> owner) {
	auto &cache = BackdropCaches()[owner];
	if (!cache) {
		cache = new BackdropCache(owner);
	}
	return cache.data();
}

[[nodiscard]] QPainterPath PanelShape(QRectF bounds, int radius) {
	auto result = QPainterPath();
	result.addRoundedRect(bounds, radius, radius);
	return result;
}

void PaintGlassEdge(QPainter &p, QRect bounds, int radius) {
	auto shadow = QColor(0, 0, 0, st::lunagramGlassShadowAlpha);
	p.setPen(QPen(shadow, st::lunagramGlassShadowWidth));
	p.setBrush(Qt::NoBrush);
	p.drawRoundedRect(
		bounds.translated(0, st::lunagramGlassShadowOffset),
		radius,
		radius);
	auto highlight = QLinearGradient(bounds.topLeft(), bounds.bottomRight());
	highlight.setColorAt(
		0.,
		QColor(255, 255, 255, st::lunagramGlassHighlightAlpha));
	highlight.setColorAt(0.45, QColor(255, 255, 255, 0));
	highlight.setColorAt(1., QColor(0, 0, 0, st::lunagramGlassShadeAlpha));
	p.setPen(QPen(QBrush(highlight), st::lunagramGlassHighlightWidth));
	p.drawRoundedRect(bounds, radius, radius);
}

} // namespace

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

void PaintGlassPanel(
		not_null<Window::SessionController*> controller,
		not_null<Ui::ChatTheme*> theme,
		not_null<QWidget*> widget,
		QPainter &p,
		QRect bounds,
		QColor tint,
		int radius) {
	const auto owner = controller->content();
	if (!ReferenceDesignEnabled()
		|| theme->background().giftId
		|| owner->size().isEmpty()
		|| (widget.get() != owner.get() && !owner->isAncestorOf(widget.get()))) {
		PaintGlassPanel(p, bounds, tint, radius);
		return;
	}
	if (bounds.isEmpty()) {
		return;
	}
	const auto cache = CacheFor(owner);
	cache->prepare(controller, theme, widget);
	const auto rounding = radius ? radius : st::lunagramReferencePanelRadius;
	const auto shape = PanelShape(bounds, rounding);
	const auto origin = widget->mapTo(owner, QPoint());
	const auto sidebar = (rounding == st::lunagramReferenceCardRadius);
	const auto alpha = sidebar
		? st::lunagramGlassSidebarTintAlpha
		: cache->dark()
		? st::lunagramGlassDarkTintAlpha
		: st::lunagramGlassTintAlpha;
	tint.setAlpha(std::min(tint.alpha(), alpha));
	p.save();
	p.setRenderHint(QPainter::Antialiasing);
	p.setRenderHint(QPainter::SmoothPixmapTransform);
	{
		p.save();
		p.setClipPath(shape, Qt::IntersectClip);
		if (!cache->blurred().isNull()) {
			p.drawImage(QRect(-origin, owner->size()), cache->blurred());
		}
		p.fillPath(shape, tint);
		if (!cache->source().isNull()) {
			const auto half = std::min(bounds.width(), bounds.height()) / 2;
			const auto rim = std::min(st::lunagramGlassRefractionWidth, half);
			const auto inner = bounds.adjusted(rim, rim, -rim, -rim);
			const auto ring = inner.isEmpty()
				? shape
				: shape.subtracted(PanelShape(
					inner,
					std::max(rounding - rim, 0)));
			p.setClipPath(ring, Qt::IntersectClip);
			p.setOpacity(p.opacity() * st::lunagramGlassRefractionOpacity);
			const auto shift = std::min(
				st::lunagramGlassRefractionShift,
				std::max(half - st::lineWidth, 0));
			const auto sample = QRectF(bounds.translated(origin)).adjusted(
				shift,
				shift,
				-shift,
				-shift);
			const auto scale = cache->sampleScale();
			p.drawImage(
				bounds,
				cache->source(),
				QRectF(
					sample.x() * scale,
					sample.y() * scale,
					sample.width() * scale,
					sample.height() * scale));
		}
		p.restore();
	}
	PaintGlassEdge(p, bounds, rounding);
	p.restore();
}

} // namespace Lunagram

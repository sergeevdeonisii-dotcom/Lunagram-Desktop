#include "lunagram/window_chrome.h"

#include "base/event_filter.h"
#include "base/invoke_queued.h"
#include "lang/lang_keys.h"
#include "ui/platform/ui_platform_window_title.h"
#include "ui/widgets/rp_window.h"
#include "ui/abstract_button.h"
#include "ui/painter.h"
#include "window/window_controller.h"
#include "window/window_session_controller.h"

#include <QtGui/QtEvents>
#include <array>

#include "styles/style_lunagram_design.h"
#include "styles/style_widgets.h"

namespace Lunagram {
namespace {

using Control = Ui::Platform::TitleControl;

class TrafficLightButton final : public Ui::AbstractButton {
public:
	TrafficLightButton(QWidget *parent, Control control);

protected:
	void paintEvent(QPaintEvent *e) override;
	void onStateChanged(State was, StateChangeSource source) override;

private:
	const Control _control;

};

[[nodiscard]] QColor ControlColor(Control control) {
	switch (control) {
	case Control::Close: return QColor(255, 95, 87);
	case Control::Minimize: return QColor(254, 188, 46);
	case Control::Maximize: return QColor(40, 200, 64);
	default: Unexpected("Unknown traffic light control");
	}
}

TrafficLightButton::TrafficLightButton(QWidget *parent, Control control)
: AbstractButton(parent)
, _control(control) {
	resize(st::lunagramTrafficLightHitSize, st::lunagramTrafficLightHitSize);
	setFocusPolicy(Qt::StrongFocus);
	setPointerCursor(false);
	show();
}

void TrafficLightButton::paintEvent(QPaintEvent *e) {
	auto p = Painter(this);
	auto highQuality = PainterHighQualityEnabler(p);
	const auto color = isDisabled() || !window()->isActiveWindow()
		? QColor(185, 192, 181)
		: ControlColor(_control);
	const auto center = QPoint(width() / 2, height() / 2);
	const auto radius = st::lunagramTrafficLightRadius;
	p.setPen(QPen(color.darker(112), st::lineWidth));
	p.setBrush(isDown() ? color.darker(108) : color);
	p.drawEllipse(center, radius, radius);
	if (!isOver() && !isDown() && !hasFocus()) {
		return;
	}
	const auto half = st::lunagramTrafficLightGlyphSize / 2;
	p.setPen(QPen(QColor(0, 0, 0, 128), st::lunagramTrafficLightGlyphWidth));
	p.setBrush(Qt::NoBrush);
	switch (_control) {
	case Control::Close:
		p.drawLine(center + QPoint(-half, -half), center + QPoint(half, half));
		p.drawLine(center + QPoint(-half, half), center + QPoint(half, -half));
		break;
	case Control::Minimize:
		p.drawLine(center + QPoint(-half, 0), center + QPoint(half, 0));
		break;
	case Control::Maximize:
		p.drawRect(QRect(
			center - QPoint(half, half),
			QSize(2 * half, 2 * half)));
		break;
	default:
		break;
	}
}

void TrafficLightButton::onStateChanged(State was, StateChangeSource source) {
	update();
}

} // namespace

WindowChrome::WindowChrome(
		not_null<Ui::RpWindow*> window,
		Fn<void()> visibilityChanged)
: RpWidget(window->body())
, _window(window)
, _visibilityChanged(std::move(visibilityChanged))
, _close(Ui::CreateChild<TrafficLightButton>(this, Control::Close))
, _minimize(Ui::CreateChild<TrafficLightButton>(this, Control::Minimize))
, _maximizeRestore(Ui::CreateChild<TrafficLightButton>(this, Control::Maximize)) {
	hide();
	const auto buttons = std::array{ _close, _minimize, _maximizeRestore };
	const auto size = st::lunagramTrafficLightHitSize;
	auto left = st::lunagramTrafficLightLeft - size / 2;
	const auto top = st::lunagramTrafficLightTop - size / 2;
	for (const auto button : buttons) {
		button->move(left, top);
		left += st::lunagramTrafficLightSpacing;
	}
	_close->setClickedCallback([=] {
		_window->close();
	});
	_minimize->setClickedCallback([=] {
		_window->setWindowState(
			_window->windowState() | Qt::WindowMinimized);
	});
	_maximizeRestore->setClickedCallback([=] {
		const auto state = _window->windowState();
		_window->setWindowState((state & Qt::WindowMaximized)
			? state & ~Qt::WindowMaximized
			: state | Qt::WindowMaximized);
	});
	tr::lng_close() | rpl::on_next([=](const QString &text) {
		_close->setAccessibleName(text);
	}, lifetime());
	tr::lng_minimize_window() | rpl::on_next([=](const QString &text) {
		_minimize->setAccessibleName(text);
	}, lifetime());
	tr::lng_maximize_window() | rpl::on_next([=] {
		refreshButtons();
	}, lifetime());
	_window->windowActiveValue() | rpl::on_next([=] {
		refreshButtons();
	}, lifetime());
	_window->events() | rpl::filter([](not_null<QEvent*> event) {
		return event->type() == QEvent::WindowStateChange;
	}) | rpl::on_next([=] {
		refreshButtons();
	}, lifetime());
	_window->hitTestRequests() | rpl::filter([=] {
		return !isHidden();
	}) | rpl::on_next([=](not_null<Ui::Platform::HitTestRequest*> request) {
		const auto point = mapFrom(_window, request->point);
		if (!rect().contains(point)) {
			return;
		}
		request->result = ranges::any_of(buttons, [&](const auto button) {
			return button->geometry().contains(point);
		}) ? Ui::Platform::HitTestResult::Client
			: Ui::Platform::HitTestResult::Caption;
	}, lifetime());
}

void WindowChrome::setCaptionArea(
		not_null<QWidget*> source,
		QRect area,
		Fn<bool()> sourceValid) {
	const auto sourceChanged = (_captionSource != source.get());
	_captionSource = source.get();
	_captionArea = area;
	_sourceValid = std::move(sourceValid);
	if (sourceChanged) {
		observeCaptionSource();
	}
	refreshCaption();
}

void WindowChrome::clearCaptionSource() {
	_captionSource = nullptr;
	_captionArea = QRect();
	_sourceValid = nullptr;
	_sourceLifetime.destroy();
	refreshCaption();
}

void WindowChrome::observeCaptionSource() {
	_sourceLifetime.destroy();
	const auto source = _captionSource;
	for (auto widget = source.data()
		; widget && widget != parentWidget()
		; widget = widget->parentWidget()) {
		const auto filter = base::install_event_filter(
			this,
			widget,
			[=](not_null<QEvent*> event) {
				if (!source || _captionSource != source) {
					return base::EventFilterResult::Continue;
				}
				switch (event->type()) {
				case QEvent::ParentChange:
					InvokeQueued(this, [=] {
						if (source && _captionSource == source) {
							observeCaptionSource();
							refreshCaption();
						}
					});
					break;
				case QEvent::Show:
				case QEvent::Hide:
				case QEvent::ShowToParent:
				case QEvent::HideToParent:
				case QEvent::Move:
				case QEvent::Resize:
					refreshCaption();
					break;
				default:
					break;
				}
				return base::EventFilterResult::Continue;
			});
		_sourceLifetime.add([
			filter = QPointer<QObject>(filter.get()),
			watched = QPointer<QWidget>(widget)] {
			if (watched && filter) {
				watched->removeEventFilter(filter);
			}
			if (filter) {
				filter->deleteLater();
			}
		});
		const auto destroyed = QObject::connect(
			widget,
			&QObject::destroyed,
			this,
			[=] { clearCaptionSource(); });
		_sourceLifetime.add([destroyed] {
			QObject::disconnect(destroyed);
		});
	}
}

bool WindowChrome::captionSourceShown() const {
	if (!_captionSource
		|| _captionArea.isEmpty()
		|| !_sourceValid
		|| !_sourceValid()) {
		return false;
	}
	auto widget = _captionSource.data();
	while (widget && widget != parentWidget()) {
		if (widget->isHidden()) {
			return false;
		}
		widget = widget->parentWidget();
	}
	return widget == parentWidget();
}

void WindowChrome::refreshCaption() {
	const auto shown = captionSourceShown();
	if (shown) {
		setGeometry(QRect(
			_captionSource->mapTo(parentWidget(), _captionArea.topLeft()),
			_captionArea.size()));
		refreshButtons();
	}
	if (shown == isHidden()) {
		setVisible(shown);
		_visibilityChanged();
	}
	if (shown) {
		raise();
	}
}

void WindowChrome::refreshButtons() {
	_maximizeRestore->setDisabled(
		_window->minimumSize() == _window->maximumSize());
	_maximizeRestore->setAccessibleName(_window->isMaximized()
		? tr::lng_restore_window(tr::now)
		: tr::lng_maximize_window(tr::now));
	_close->update();
	_minimize->update();
	_maximizeRestore->update();
}

void UpdateWindowChromeCaption(
		not_null<Window::SessionController*> controller,
		not_null<QWidget*> source,
		QRect localCaption) {
	if (controller->window().sessionController() != controller.get()) {
		return;
	}
	controller->window().widget()->setReferenceCaptionArea(
		controller,
		source,
		localCaption);
}

} // namespace Lunagram

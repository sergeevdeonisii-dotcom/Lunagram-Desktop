#include "lunagram/composer.h"

#include "lang/lang_keys.h"
#include "lunagram/lunagram_settings.h"
#include "main/main_session.h"
#include "ui/effects/animations.h"
#include "ui/toast/toast.h"
#include "ui/widgets/fields/input_field.h"
#include "ui/painter.h"
#include "window/window_session_controller.h"

#include <QtCore/QPointer>
#include <QtWidgets/QGraphicsOpacityEffect>

#include <algorithm>

#include "styles/style_chat.h"
#include "styles/style_chat_helpers.h"
#include "styles/style_layers.h"
#include "styles/style_widgets.h"

namespace Lunagram {
namespace {

constexpr auto kTypingSlow = crl::time(240);
constexpr auto kTypingNormal = crl::time(140);
constexpr auto kTypingFast = crl::time(80);

struct ComposerEffectsState {
	QPointer<QGraphicsOpacityEffect> effect;
	Ui::Animations::Simple animation;
	QString text;
	int mode = 0;
	int speed = 1;
};

crl::time TypingDuration(int speed) {
	return (speed == 0) ? kTypingSlow
		: (speed == 2) ? kTypingFast
		: kTypingNormal;
}

void RefreshEffects(
		not_null<Main::Session*> session,
		not_null<ComposerEffectsState*> state) {
	state->mode = std::clamp(IntValue(session, "typing_mode"), 0, 2);
	state->speed = std::clamp(IntValue(session, "typing_speed", 1), 0, 2);
	if (!state->mode && state->effect) {
		state->animation.stop();
		state->effect->setOpacity(1.);
		state->effect->setEnabled(false);
	}
}

void ComposerChanged(
		not_null<Ui::InputField*> field,
		not_null<ComposerEffectsState*> state) {
	const auto text = field->getTextWithTags().text;
	const auto inserted = (text.size() > state->text.size());
	state->text = text;
	const auto trigger = inserted
		&& state->mode
		&& !field->isHidden()
		&& !anim::Disabled()
		&& ((state->mode == 1) || (!text.isEmpty() && text.back().isSpace()));
	if (!trigger || !state->effect) {
		return;
	}
	state->effect->setEnabled(true);
	state->animation.start([=](float64 opacity) {
		if (state->effect) {
			state->effect->setOpacity(opacity);
			if (opacity >= 1.) {
				state->effect->setEnabled(false);
			}
		}
	}, 0.9, 1., TypingDuration(state->speed), anim::easeOutCirc);
}

} // namespace

PendingSend::PendingSend(
		not_null<Window::SessionController*> controller,
		crl::time delay,
		Fn<void()> send)
: _controller(base::make_weak(controller.get()))
, _session(base::make_weak(&controller->session()))
, _sessionId(controller->session().uniqueId())
, _delay(delay)
, _send(std::move(send))
, _timer([=] { finish(); }) {
}

PendingSend::~PendingSend() {
	hideToast();
}

void PendingSend::start() {
	const auto controller = _controller.get();
	if (!controller) {
		_pending = false;
		_send = nullptr;
		return;
	}
	const auto weak = base::make_weak(this);
	_toast = controller->showToast(Ui::Toast::Config{
		.text = tr::lng_lunagram_undo_pending(
			tr::now,
			lt_seconds,
			tr::marked(QString::number(_delay / 1000., 'f', 1)),
			lt_link,
			tr::link(tr::lng_lunagram_undo_cancel(tr::now)),
			tr::marked),
		.filter = [=](const auto &...) {
			if (const auto strong = weak.get()) {
				strong->cancel();
			}
			return false;
		},
		.acceptinput = true,
		.duration = _delay,
		.infinite = true,
	});
	_timer.callOnce(_delay, Qt::PreciseTimer);
}

void PendingSend::hideToast() {
	if (const auto toast = _toast.get()) {
		toast->hide();
	}
	_toast = nullptr;
}

void PendingSend::cancel() {
	if (!_pending) {
		return;
	}
	_pending = false;
	_timer.cancel();
	_send = nullptr;
	hideToast();
	if (const auto controller = _controller.get()) {
		controller->showToast(tr::lng_lunagram_undo_cancelled(tr::now));
	}
}

bool PendingSend::pending() const {
	return _pending;
}

void PendingSend::finish() {
	if (!_pending) {
		return;
	}
	const auto session = _session.get();
	const auto controller = _controller.get();
	if (!session
		|| !controller
		|| !_toast
		|| session->uniqueId() != _sessionId
		|| &controller->session() != session) {
		cancel();
		return;
	}
	_pending = false;
	hideToast();
	if (auto send = base::take(_send)) {
		send();
	}
}

std::shared_ptr<PendingSend> QueueUndoSend(
		not_null<Window::SessionController*> controller,
		Fn<void()> send) {
	const auto requested = IntValue(&controller->session(), "undo_delay");
	if (requested <= 0) {
		return nullptr;
	}
	const auto delay = std::clamp(requested, 400, 5000);
	auto result = std::make_shared<PendingSend>(
		controller,
		delay,
		std::move(send));
	result->start();
	return result;
}

void InitComposerEffects(
		not_null<Main::Session*> session,
		not_null<Ui::InputField*> field,
		Fn<void()> repaint) {
	if (field->graphicsEffect()) {
		return;
	}
	const auto state = field->lifetime().make_state<ComposerEffectsState>();
	state->effect = new QGraphicsOpacityEffect(field);
	state->effect->setOpacity(1.);
	state->effect->setEnabled(false);
	field->setGraphicsEffect(state->effect.data());
	state->text = field->getTextWithTags().text;
	RefreshEffects(session, state);
	const auto weakSession = base::make_weak(session.get());
	Changes(session) | rpl::on_next([=] {
		if (const auto current = weakSession.get()) {
			RefreshEffects(current, state);
			repaint();
		}
	}, field->lifetime());
	field->changes() | rpl::on_next([=] {
		if (weakSession) {
			ComposerChanged(field, state);
		}
	}, field->lifetime());
}

void PaintComposerBackground(
		QPainter &p,
		const QRect &bounds,
		not_null<Main::Session*> session,
		bool fillBackground) {
	if (fillBackground) {
		p.fillRect(bounds, st::historyReplyBg->c);
	}
	if (!Enabled(session, Flag::Glass)) {
		return;
	}
	const auto opacity = std::clamp(IntValue(session, "glass_opacity", 75), 35, 95);
	auto background = st::boxBg->c;
	background.setAlpha(opacity * 255 / 100);
	auto border = st::activeButtonBg->c;
	border.setAlpha(90);
	const auto padding = st::historySendPadding;
	const auto panel = bounds.adjusted(padding, padding, -padding, -padding);
	p.save();
	p.setRenderHint(QPainter::Antialiasing);
	p.setBrush(background);
	p.setPen(QPen(border, st::lineWidth));
	p.drawRoundedRect(panel, st::boxRadius, st::boxRadius);
	p.restore();
}

} // namespace Lunagram

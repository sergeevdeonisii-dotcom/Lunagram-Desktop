#pragma once

#include "base/timer.h"
#include "base/weak_ptr.h"

#include <QtCore/QRect>

#include <memory>

class QPainter;

namespace Main {
class Session;
} // namespace Main

namespace Ui {
class InputField;
} // namespace Ui

namespace Ui::Toast {
class Instance;
} // namespace Ui::Toast

namespace Window {
class SessionController;
} // namespace Window

namespace Lunagram {

class PendingSend final : public base::has_weak_ptr {
public:
	PendingSend(
		not_null<Window::SessionController*> controller,
		crl::time delay,
		Fn<void()> send);
	~PendingSend();

	void start();
	void cancel();
	[[nodiscard]] bool pending() const;

private:
	void finish();
	void hideToast();

	base::weak_ptr<Window::SessionController> _controller;
	base::weak_ptr<Main::Session> _session;
	const uint64 _sessionId = 0;
	const crl::time _delay = 0;
	Fn<void()> _send;
	base::Timer _timer;
	base::weak_ptr<Ui::Toast::Instance> _toast;
	bool _pending = true;

};

[[nodiscard]] std::shared_ptr<PendingSend> QueueUndoSend(
	not_null<Window::SessionController*> controller,
	Fn<void()> send);
void InitComposerEffects(
	not_null<Main::Session*> session,
	not_null<Ui::InputField*> field,
	Fn<void()> repaint);
void PaintComposerBackground(
	QPainter &p,
	const QRect &bounds,
	not_null<Main::Session*> session,
	bool fillBackground = true);

} // namespace Lunagram

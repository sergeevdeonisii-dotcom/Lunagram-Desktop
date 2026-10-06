#pragma once

#include "ui/rp_widget.h"

namespace Ui {
class AbstractButton;
class RpWindow;
} // namespace Ui

namespace Window {
class SessionController;
} // namespace Window

namespace Lunagram {

class WindowChrome final : public Ui::RpWidget {
public:
	WindowChrome(
		not_null<Ui::RpWindow*> window,
		Fn<void()> visibilityChanged);

	void setCaptionArea(
		not_null<QWidget*> source,
		QRect area,
		Fn<bool()> sourceValid,
		QRect menuArea,
		Fn<void()> menuClicked);
	void clearCaptionSource();

private:
	void observeCaptionSource();
	void refreshCaption();
	void refreshButtons();
	void rememberNormalGeometry();
	void handleWindowEvent(not_null<QEvent*> event);
	void handleWindowStateChange();
	void toggleMaximized();
	[[nodiscard]] bool captionSourceShown() const;

	const not_null<Ui::RpWindow*> _window;
	const Fn<void()> _visibilityChanged;
	const not_null<Ui::AbstractButton*> _close;
	const not_null<Ui::AbstractButton*> _minimize;
	const not_null<Ui::AbstractButton*> _maximizeRestore;
	const not_null<Ui::AbstractButton*> _menu;
	QPointer<QWidget> _captionSource;
	QRect _captionArea;
	QRect _menuArea;
	QRect _normalGeometry;
	Fn<bool()> _sourceValid;
	Fn<void()> _menuClicked;
	rpl::lifetime _sourceLifetime;
	Qt::WindowStates _lastWindowState = Qt::WindowNoState;
	uint64 _restoreSerial = 0;
	bool _restorePending = false;

};

void UpdateWindowChromeCaption(
	not_null<Window::SessionController*> controller,
	not_null<QWidget*> source,
	QRect localCaption,
	QRect menuArea = {},
	Fn<void()> menuClicked = nullptr);

} // namespace Lunagram

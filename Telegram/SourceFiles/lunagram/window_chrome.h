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
		Fn<bool()> sourceValid);
	void clearCaptionSource();

private:
	void observeCaptionSource();
	void refreshCaption();
	void refreshButtons();
	[[nodiscard]] bool captionSourceShown() const;

	const not_null<Ui::RpWindow*> _window;
	const Fn<void()> _visibilityChanged;
	const not_null<Ui::AbstractButton*> _close;
	const not_null<Ui::AbstractButton*> _minimize;
	const not_null<Ui::AbstractButton*> _maximizeRestore;
	QPointer<QWidget> _captionSource;
	QRect _captionArea;
	Fn<bool()> _sourceValid;
	rpl::lifetime _sourceLifetime;

};

void UpdateWindowChromeCaption(
	not_null<Window::SessionController*> controller,
	not_null<QWidget*> source,
	QRect localCaption);

} // namespace Lunagram

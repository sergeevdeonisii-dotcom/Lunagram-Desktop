#pragma once

#include "ui/rp_widget.h"

#include <array>

namespace Ui {
class IconButton;
} // namespace Ui

namespace Window {
class SessionController;
} // namespace Window

namespace Lunagram {

class NavigationBar final : public Ui::RpWidget {
public:
	NavigationBar(
		QWidget *parent,
		not_null<Window::SessionController*> controller,
		Fn<void()> showChats);

protected:
	void resizeEvent(QResizeEvent *e) override;

private:
	std::array<Ui::IconButton*, 4> _buttons = {};

};

} // namespace Lunagram

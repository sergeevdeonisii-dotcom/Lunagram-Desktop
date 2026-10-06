#include "lunagram/navigation.h"

#include "calls/calls_box_controller.h"
#include "data/data_user.h"
#include "lang/lang_keys.h"
#include "lunagram/chat_vault.h"
#include "main/main_session.h"
#include "ui/widgets/buttons.h"
#include "window/window_session_controller.h"

#include "styles/style_lunagram_design.h"

namespace Lunagram {

NavigationBar::NavigationBar(
		QWidget *parent,
		not_null<Window::SessionController*> controller,
		Fn<void()> showChats)
: RpWidget(parent) {
	_buttons = {
		Ui::CreateChild<Ui::IconButton>(this, st::lunagramNavigationProfile),
		Ui::CreateChild<Ui::IconButton>(this, st::lunagramNavigationCalls),
		Ui::CreateChild<Ui::IconButton>(this, st::lunagramNavigationChats),
		Ui::CreateChild<Ui::IconButton>(this, st::lunagramNavigationSettings),
	};
	_buttons[0]->setAccessibleName(tr::lng_menu_my_profile(tr::now));
	_buttons[1]->setAccessibleName(tr::lng_menu_calls(tr::now));
	_buttons[2]->setAccessibleName(tr::lng_filters_all(tr::now));
	_buttons[3]->setAccessibleName(tr::lng_menu_settings(tr::now));
	_buttons[0]->setClickedCallback([=] {
		controller->showPeerInfo(controller->session().user());
	});
	_buttons[1]->setClickedCallback([=] {
		if (!VaultRestricted(&controller->session())) {
			Calls::ShowCallsBox(controller);
		}
	});
	_buttons[2]->setClickedCallback(std::move(showChats));
	_buttons[3]->setClickedCallback([=] { controller->showSettings(); });
	for (const auto button : _buttons) {
		button->show();
	}
}

void NavigationBar::resizeEvent(QResizeEvent *e) {
	RpWidget::resizeEvent(e);
	for (auto i = 0; i != int(_buttons.size()); ++i) {
		const auto button = _buttons[i];
		button->moveToLeft(
			((2 * i + 1) * width() / (2 * int(_buttons.size())))
				- button->width() / 2,
			(height() - button->height()) / 2);
	}
}

} // namespace Lunagram

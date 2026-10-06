#pragma once

#include "data/data_peer_id.h"

class HistoryItem;
class PeerData;

namespace Main {
class Session;
} // namespace Main

namespace Info {
class AbstractController;
class ContentMemento;
} // namespace Info

namespace Ui::Menu {
struct MenuCallback;
} // namespace Ui::Menu

namespace Window {
class SessionController;
class SectionMemento;
} // namespace Window

namespace Lunagram {

[[nodiscard]] bool IsVaultChat(not_null<Main::Session*> session, PeerId peer);
[[nodiscard]] bool IsChatLocked(not_null<Main::Session*> session, PeerId peer);
[[nodiscard]] bool VaultRestricted(not_null<Main::Session*> session);
[[nodiscard]] bool ShouldHideNotification(not_null<HistoryItem*> item);
[[nodiscard]] bool AllowVaultInfo(
	not_null<Main::Session*> session,
	not_null<Info::ContentMemento*> memento);
[[nodiscard]] bool AllowVaultInfoController(
	not_null<Main::Session*> session,
	not_null<Info::AbstractController*> controller);
[[nodiscard]] bool AllowVaultSection(
	not_null<Main::Session*> session,
	not_null<Window::SectionMemento*> memento);
[[nodiscard]] rpl::producer<> VaultChanges(not_null<Main::Session*> session);
[[nodiscard]] rpl::producer<bool> VaultProtectionValue(
	not_null<Main::Session*> session);
void LockVault(not_null<Main::Session*> session);
void LockAllVaults();
void ShowVaultBox(not_null<Window::SessionController*> controller);
void AddChatVaultActions(
	not_null<Window::SessionController*> controller,
	not_null<PeerData*> peer,
	const Ui::Menu::MenuCallback &addAction);

} // namespace Lunagram

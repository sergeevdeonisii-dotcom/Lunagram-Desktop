#pragma once

#include "data/data_peer_id.h"

class HistoryItem;
class PeerData;

namespace Window {
class SessionController;
} // namespace Window

namespace Ui::Menu {
struct MenuCallback;
} // namespace Ui::Menu

namespace Lunagram {

void ShowProfilesBox(not_null<Window::SessionController*> controller);
void ShowJournalBox(not_null<Window::SessionController*> controller);
void ExportSettings(not_null<Window::SessionController*> controller);
void ImportSettings(not_null<Window::SessionController*> controller);
void ShowNotesBox(
	not_null<Window::SessionController*> controller,
	PeerId peerId);
void AddChatToolsActions(
	not_null<Window::SessionController*> controller,
	not_null<PeerData*> peer,
	const Ui::Menu::MenuCallback &addAction);
void RecordPostedNotification(
	not_null<HistoryItem*> item,
	const QString &title,
	const TextWithEntities &preview);

} // namespace Lunagram

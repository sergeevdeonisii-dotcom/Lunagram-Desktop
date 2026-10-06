#include "lunagram/chat_vault.h"

#include "core/application.h"
#include "data/data_document.h"
#include "data/data_session.h"
#include "history/view/history_view_chat_section.h"
#include "history/history.h"
#include "history/history_item.h"
#include "info/info_content_widget.h"
#include "info/info_controller.h"
#include "info/info_memento.h"
#include "lang/lang_keys.h"
#include "lunagram/secure_storage.h"
#include "main/main_session.h"
#include "media/player/media_player_instance.h"
#include "ui/boxes/confirm_box.h"
#include "ui/layers/generic_box.h"
#include "ui/widgets/fields/password_input.h"
#include "ui/widgets/menu/menu_add_action_callback.h"
#include "ui/widgets/buttons.h"
#include "ui/widgets/labels.h"
#include "ui/widgets/tooltip.h"
#include "window/notifications_manager.h"
#include "window/window_session_controller.h"

#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QRegularExpression>
#include <QtGui/QGuiApplication>
#include <QtWidgets/QApplication>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/rand.h>

#include "styles/style_boxes.h"
#include "styles/style_layers.h"
#include "styles/style_menu_icons.h"
#include "styles/style_settings.h"
#include "styles/style_widgets.h"

namespace Lunagram {
namespace {

constexpr auto kIterations = 600000;
constexpr auto kSaltBytes = 32;
constexpr auto kHashBytes = 32;
constexpr auto kMaxChats = 256;
constexpr auto kMaxStore = 64 * 1024;

struct VaultState {
	base::flat_set<PeerId> peers;
	QByteArray salt;
	QByteArray hash;
	rpl::event_stream<> changes;
	uint64 epoch = 0;
	crl::time retryAfter = 0;
	int failures = 0;
	bool valid = true;
	bool unlocked = false;
	bool busy = false;
};

base::flat_map<Main::Session*, std::unique_ptr<VaultState>> States;

bool Restricted(const VaultState &state) {
	return !state.valid || (!state.unlocked && !state.peers.empty());
}

bool Protected(const VaultState &state) {
	return !state.valid || !state.peers.empty();
}

bool UniqueProperties(const QByteArray &payload) {
	const auto expression = QRegularExpression(
		uR"json("((?:[^"\\]|\\.)*)"\s*:)json"_q);
	auto names = base::flat_set<QString>();
	auto matches = expression.globalMatch(QString::fromUtf8(payload));
	while (matches.hasNext()) {
		const auto encoded = matches.next().captured(1).toUtf8();
		const auto decoded = QJsonDocument::fromJson("[\"" + encoded + "\"]");
		if (!decoded.isArray() || decoded.array().size() != 1
			|| !names.emplace(decoded.array().at(0).toString()).second) {
			return false;
		}
	}
	return true;
}

void Load(not_null<Main::Session*> session, VaultState &state) {
	const auto payload = ReadPrivate(session, u"chat-vault"_q);
	if (payload.isEmpty()) {
		state.valid = !PrivateExists(session, u"chat-vault"_q);
		return;
	}
	if (payload.size() > kMaxStore) {
		state.valid = false;
		return;
	}
	const auto document = QJsonDocument::fromJson(payload);
	const auto object = document.object();
	const auto peers = object.value(u"peers"_q);
	if (!UniqueProperties(payload)
		|| !document.isObject() || object.size() != 5
		|| object.value(u"version"_q).toInt() != 1
		|| object.value(u"owner"_q).toString()
			!= QString::number(session->uniqueId())
		|| !object.value(u"salt"_q).isString()
		|| !object.value(u"hash"_q).isString()
		|| !peers.isArray() || peers.toArray().size() > kMaxChats) {
		state.valid = false;
		return;
	}
	const auto salt = object.value(u"salt"_q).toString().toLatin1();
	const auto hash = object.value(u"hash"_q).toString().toLatin1();
	state.salt = QByteArray::fromBase64(salt);
	state.hash = QByteArray::fromBase64(hash);
	const auto disabled = salt.isEmpty() && hash.isEmpty()
		&& peers.toArray().isEmpty();
	if (!disabled && (state.salt.size() != kSaltBytes
		|| state.hash.size() != kHashBytes
		|| state.salt.toBase64() != salt || state.hash.toBase64() != hash)) {
		state.valid = false;
		return;
	}
	for (const auto &value : peers.toArray()) {
		auto ok = false;
		const auto text = value.toString();
		const auto id = text.toULongLong(&ok);
		const auto peer = PeerId(id);
		if (!value.isString() || !ok || !id || QString::number(id) != text
			|| (!peerIsUser(peer) && !peerIsChat(peer) && !peerIsChannel(peer))
			|| !(id & PeerId::kChatTypeMask)
			|| !state.peers.emplace(peer).second) {
			state.valid = false;
			return;
		}
	}
}

VaultState &State(not_null<Main::Session*> session) {
	const auto existing = States.find(session.get());
	if (existing != end(States)) {
		return *existing->second;
	}
	auto state = std::make_unique<VaultState>();
	Load(session, *state);
	const auto result = state.get();
	States.emplace(session.get(), std::move(state));
	session->lifetime().add([=] { States.erase(session.get()); });
	return *result;
}

bool Save(not_null<Main::Session*> session, const VaultState &state) {
	if (!state.valid || state.peers.size() > kMaxChats) {
		return false;
	}
	auto peers = QJsonArray();
	for (const auto id : state.peers) {
		peers.push_back(QString::number(id.value));
	}
	return WritePrivate(session, u"chat-vault"_q, QJsonDocument(QJsonObject{
		{ u"version"_q, 1 },
		{ u"owner"_q, QString::number(session->uniqueId()) },
		{ u"salt"_q, QString::fromLatin1(state.salt.toBase64()) },
		{ u"hash"_q, QString::fromLatin1(state.hash.toBase64()) },
		{ u"peers"_q, peers },
	}).toJson(QJsonDocument::Compact));
}

bool Foreground() {
	return QGuiApplication::applicationState() == Qt::ApplicationActive
		&& !Core::App().passcodeLocked()
		&& !Core::App().screenIsLocked();
}

QByteArray Derive(QByteArray pin, const QByteArray &salt) {
	const auto cleanup = gsl::finally([&] {
		OPENSSL_cleanse(pin.data(), pin.size());
	});
	auto result = QByteArray(kHashBytes, '\0');
	const auto success = PKCS5_PBKDF2_HMAC(
		pin.constData(),
		int(pin.size()),
		reinterpret_cast<const unsigned char*>(salt.constData()),
		int(salt.size()),
		kIterations,
		EVP_sha256(),
		int(result.size()),
		reinterpret_cast<unsigned char*>(result.data()));
	return (success == 1) ? result : QByteArray();
}

void ShowManagement(not_null<Window::SessionController*> controller);

void FinishPin(
		not_null<Main::Session*> session,
		base::weak_ptr<Window::SessionController> controller,
		QPointer<Ui::GenericBox> box,
		uint64 epoch,
		QByteArray salt,
		QByteArray derived,
		bool creating) {
	auto &state = State(session);
	if (state.epoch != epoch) {
		return;
	}
	state.busy = false;
	const auto strong = controller.get();
	if (!strong || !box || !Foreground()
		|| &strong->session() != session.get()) {
		return;
	}
	if (derived.size() != kHashBytes) {
		strong->showToast(tr::lng_lunagram_vault_storage_error(tr::now));
		return;
	}
	if (creating) {
		const auto oldSalt = state.salt;
		const auto oldHash = state.hash;
		state.salt = std::move(salt);
		state.hash = std::move(derived);
		if (!Save(session, state)) {
			state.salt = oldSalt;
			state.hash = oldHash;
			strong->showToast(tr::lng_lunagram_vault_storage_error(tr::now));
			return;
		}
	} else if (CRYPTO_memcmp(
			derived.constData(),
			state.hash.constData(),
			kHashBytes) != 0) {
		++state.failures;
		state.retryAfter = crl::now() + std::min(state.failures, 10) * 5000;
		strong->showToast(tr::lng_lunagram_vault_wrong_pin(tr::now));
		return;
	}
	state.failures = 0;
	state.retryAfter = 0;
	state.unlocked = true;
	box->closeBox();
	state.changes.fire({});
	if (controller && state.epoch == epoch && state.unlocked && Foreground()) {
		ShowManagement(controller.get());
	}
}

void SubmitPin(
		not_null<Window::SessionController*> controller,
		not_null<Ui::GenericBox*> box,
		not_null<Ui::PasswordInput*> field,
		Ui::PasswordInput *confirm,
		bool creating) {
	const auto session = &controller->session();
	auto &state = State(session);
	if (!state.valid || state.busy || !Foreground()) {
		return;
	} else if (crl::now() < state.retryAfter) {
		controller->showToast(tr::lng_lunagram_vault_retry(tr::now));
		return;
	}
	auto pin = field->text().toUtf8();
	const auto valid = pin.size() >= 8 && pin.size() <= 64
		&& ranges::all_of(pin, [](char ch) { return ch >= '0' && ch <= '9'; });
	if (!valid || (confirm && confirm->text() != field->text())) {
		OPENSSL_cleanse(pin.data(), pin.size());
		controller->showToast(tr::lng_lunagram_vault_pin_invalid(tr::now));
		return;
	}
	auto salt = state.salt;
	if (creating) {
		salt = QByteArray(kSaltBytes, '\0');
		if (RAND_bytes(
				reinterpret_cast<unsigned char*>(salt.data()),
				int(salt.size())) != 1) {
			OPENSSL_cleanse(pin.data(), pin.size());
			controller->showToast(tr::lng_lunagram_vault_storage_error(tr::now));
			return;
		}
	}
	field->setText(QString());
	if (confirm) {
		confirm->setText(QString());
	}
	state.busy = true;
	const auto epoch = ++state.epoch;
	const auto weakSession = base::make_weak(session);
	const auto weakController = base::make_weak(controller);
	const auto weakBox = QPointer<Ui::GenericBox>(box.get());
	crl::async([=, pin = std::move(pin)]() mutable {
		auto derived = Derive(std::move(pin), salt);
		crl::on_main(weakSession, [=, derived = std::move(derived)]() mutable {
			FinishPin(
				weakSession.get(),
				weakController,
				weakBox,
				epoch,
				salt,
				std::move(derived),
				creating);
		});
	});
}

Ui::PasswordInput *AddPinField(
		not_null<Ui::GenericBox*> box,
		rpl::producer<QString> placeholder) {
	const auto &fieldStyle = st::defaultInputField;
	const auto row = box->addRow(object_ptr<Ui::RpWidget>(box));
	row->resize(row->width(), fieldStyle.heightMin);
	const auto field = Ui::CreateChild<Ui::PasswordInput>(
		row,
		fieldStyle,
		std::move(placeholder));
	row->sizeValue() | rpl::on_next([=](QSize size) {
		field->resize(size.width(), field->height());
	}, field->lifetime());
	field->setMaxLength(64);
	return field;
}

void ShowPin(not_null<Window::SessionController*> controller, bool creating) {
	const auto session = &controller->session();
	const auto weak = base::make_weak(controller);
	const auto weakSession = base::make_weak(session);
	controller->show(Box([=](not_null<Ui::GenericBox*> box) {
		box->setTitle(tr::lng_lunagram_vault_title());
		box->setWidth(st::boxWideWidth);
		box->addRow(object_ptr<Ui::FlatLabel>(
			box,
			tr::lng_lunagram_vault_description(),
			st::boxLabel));
		const auto field = AddPinField(
			box,
			tr::lng_lunagram_vault_pin());
		const auto confirm = creating
			? AddPinField(
				box,
				tr::lng_lunagram_vault_pin_confirm())
			: nullptr;
		box->setFocusCallback([=] { field->setFocusFast(); });
		box->addButton(creating
			? tr::lng_settings_save()
			: tr::lng_lunagram_vault_unlock(), [=] {
			if (const auto strong = weak.get()) {
				SubmitPin(strong, box, field, confirm, creating);
			}
		});
		box->addButton(tr::lng_cancel(), [=] { box->closeBox(); });
		VaultChanges(session) | rpl::on_next([=] {
			box->closeBox();
		}, box->lifetime());
		box->boxClosing() | rpl::on_next([=] {
			if (const auto current = weakSession.get()) {
				auto &state = State(current);
				if (state.busy) {
					++state.epoch;
					state.busy = false;
				}
			}
		}, box->lifetime());
	}));
}

void SetMembership(
		not_null<Window::SessionController*> controller,
		PeerId peer,
		bool enabled) {
	const auto session = &controller->session();
	auto &state = State(session);
	if (!state.valid || !state.unlocked || !Foreground()) {
		return;
	}
	const auto was = state.peers;
	if (enabled) {
		state.peers.emplace(peer);
	} else {
		state.peers.remove(peer);
	}
	if (!Save(session, state)) {
		state.peers = was;
		controller->showToast(tr::lng_lunagram_vault_storage_error(tr::now));
		return;
	}
	LockVault(session);
}

void ShowManagement(not_null<Window::SessionController*> controller) {
	const auto session = &controller->session();
	const auto weak = base::make_weak(controller);
	controller->show(Box([=](not_null<Ui::GenericBox*> box) {
		box->setTitle(tr::lng_lunagram_vault_title());
		box->setWidth(st::boxWideWidth);
		box->addRow(object_ptr<Ui::FlatLabel>(
			box,
			tr::lng_lunagram_vault_description(),
			st::boxLabel));
		box->addRow(object_ptr<Ui::FlatLabel>(
			box,
			tr::lng_lunagram_vault_manage_description(),
			st::boxLabel));
		for (const auto peerId : State(session).peers) {
			const auto peer = session->data().peerLoaded(peerId);
			const auto text = peer
				? peer->name()
				: QString::number(peerId.value);
			const auto button = box->addRow(object_ptr<Ui::SettingsButton>(
				box,
				rpl::single(text),
				st::settingsButton));
			button->setClickedCallback([=] {
				if (const auto strong = weak.get()) {
					strong->showPeerHistory(peerId);
				}
				box->closeBox();
			});
		}
		box->addButton(tr::lng_lunagram_vault_lock(), [=] {
			LockVault(session);
		});
		box->addButton(tr::lng_close(), [=] { box->closeBox(); });
		VaultChanges(session) | rpl::on_next([=] { box->closeBox(); }, box->lifetime());
	}));
}

} // namespace

bool IsVaultChat(not_null<Main::Session*> session, PeerId peer) {
	const auto &state = State(session);
	return !state.valid || state.peers.contains(peer);
}

bool IsChatLocked(not_null<Main::Session*> session, PeerId peer) {
	const auto &state = State(session);
	return !state.valid || (!state.unlocked && state.peers.contains(peer));
}

bool VaultRestricted(not_null<Main::Session*> session) {
	return Restricted(State(session));
}

bool ShouldHideNotification(not_null<HistoryItem*> item) {
	return IsChatLocked(&item->history()->session(), item->history()->peer->id);
}

rpl::producer<> VaultChanges(not_null<Main::Session*> session) {
	return State(session).changes.events();
}

rpl::producer<bool> VaultProtectionValue(not_null<Main::Session*> session) {
	return rpl::single(Protected(State(session))) | rpl::then(
		VaultChanges(session) | rpl::map([=] {
			return Protected(State(session));
		}));
}

bool AllowVaultInfo(
		not_null<Main::Session*> session,
		not_null<Info::ContentMemento*> memento) {
	const auto locked = [&](PeerData *peer) {
		return peer && IsChatLocked(session, peer->id);
	};
	if (locked(memento->peer()) || locked(memento->storiesPeer())
		|| locked(memento->musicPeer()) || locked(memento->giftsPeer())
		|| locked(memento->starrefPeer()) || locked(memento->statisticsTag().peer)
		|| IsChatLocked(session, memento->migratedPeerId())
		|| IsChatLocked(session, memento->pollContextId().peer)
		|| IsChatLocked(session, memento->reactionsContextId().peer)) {
		return false;
	}
	return !VaultRestricted(session)
		|| memento->peer()
		|| memento->section().type() == Info::Section::Type::Settings;
}

bool AllowVaultSection(
		not_null<Main::Session*> session,
		not_null<Window::SectionMemento*> memento) {
	if (const auto info = dynamic_cast<Info::Memento*>(memento.get())) {
		return AllowVaultInfo(session, info->content());
	} else if (const auto chat = dynamic_cast<HistoryView::ChatMemento*>(memento.get())) {
		return !IsChatLocked(session, chat->id().history->peer->id);
	}
	return !VaultRestricted(session);
}

bool AllowVaultInfoController(
		not_null<Main::Session*> session,
		not_null<Info::AbstractController*> controller) {
	const auto locked = [&](PeerData *peer) {
		return peer && IsChatLocked(session, peer->id);
	};
	if (locked(controller->peer()) || locked(controller->storiesPeer())
		|| locked(controller->musicPeer()) || locked(controller->giftsPeer())
		|| locked(controller->starrefPeer())
		|| locked(controller->statisticsTag().peer)
		|| IsChatLocked(session, controller->migratedPeerId())
		|| IsChatLocked(session, controller->pollContextId().peer)
		|| IsChatLocked(session, controller->reactionsContextId().peer)) {
		return false;
	}
	return !VaultRestricted(session)
		|| controller->peer()
		|| controller->section().type() == Info::Section::Type::Settings;
}

void LockVault(not_null<Main::Session*> session) {
	auto &state = State(session);
	++state.epoch;
	state.busy = false;
	state.unlocked = false;
	if (Protected(state)) {
		auto popups = std::vector<QPointer<QWidget>>();
		for (const auto widget : QApplication::topLevelWidgets()) {
			if (widget->windowType() == Qt::Popup) {
				popups.push_back(widget);
			}
		}
		for (const auto &popup : popups) {
			if (popup) {
				popup->close();
			}
		}
		Ui::Tooltip::Hide();
		const auto player = Media::Player::instance();
		const auto lockedPlayback = [&](AudioMsgId::Type type) {
			const auto current = player->current(type);
			const auto document = current.audio();
			return document && &document->session() == session.get()
				&& IsChatLocked(session, current.contextId().peer);
		};
		if (lockedPlayback(AudioMsgId::Type::Voice)
			|| lockedPlayback(AudioMsgId::Type::Song)) {
			player->stopAndClose();
		}
		Core::App().closeMediaView();
		Core::App().notifications().clearFromSession(session);
	}
	if (Protected(state) || !state.hash.isEmpty()) {
		state.changes.fire({});
	}
}

void LockAllVaults() {
	auto sessions = std::vector<Main::Session*>();
	for (const auto &[session, state] : States) {
		sessions.push_back(session);
	}
	for (const auto session : sessions) {
		LockVault(session);
	}
}

void ShowVaultBox(not_null<Window::SessionController*> controller) {
	auto &state = State(&controller->session());
	if (!state.valid) {
		controller->showToast(tr::lng_lunagram_vault_storage_error(tr::now));
	} else if (!Foreground()) {
		return;
	} else if (state.unlocked) {
		ShowManagement(controller);
	} else {
		ShowPin(controller, state.hash.isEmpty());
	}
}

void AddChatVaultActions(
		not_null<Window::SessionController*> controller,
		not_null<PeerData*> peer,
		const Ui::Menu::MenuCallback &addAction) {
	const auto session = &controller->session();
	const auto &state = State(session);
	if (!state.valid || state.hash.isEmpty()) {
		return;
	} else if (!state.unlocked) {
		addAction(tr::lng_lunagram_vault_unlock(tr::now), crl::guard(controller, [=] {
			ShowVaultBox(controller);
		}), &st::menuIconLock);
		return;
	}
	const auto enabled = state.peers.contains(peer->id);
	addAction(enabled
		? tr::lng_lunagram_vault_remove(tr::now)
		: tr::lng_lunagram_vault_add(tr::now), crl::guard(controller, [=] {
		SetMembership(controller, peer->id, !enabled);
	}), &st::menuIconLock);
}

} // namespace Lunagram

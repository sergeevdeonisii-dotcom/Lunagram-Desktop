#include "lunagram/local_tools.h"

#include "core/application.h"
#include "core/file_utilities.h"
#include "data/data_media_types.h"
#include "data/data_peer.h"
#include "data/data_session.h"
#include "history/history.h"
#include "history/history_item.h"
#include "lang/lang_keys.h"
#include "lunagram/chat_vault.h"
#include "lunagram/gifts_profile.h"
#include "lunagram/lunagram_settings.h"
#include "main/main_session.h"
#include "ui/boxes/confirm_box.h"
#include "ui/layers/generic_box.h"
#include "ui/text/text_utilities.h"
#include "ui/widgets/fields/input_field.h"
#include "ui/widgets/menu/menu_add_action_callback.h"
#include "ui/widgets/buttons.h"
#include "ui/widgets/labels.h"
#include "window/window_session_controller.h"

#include <QtCore/QDateTime>
#include <QtCore/QFile>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QLocale>
#include <QtCore/QRandomGenerator>
#include <QtCore/QRegularExpression>
#include <QtCore/QSaveFile>
#include <array>

#include "styles/style_boxes.h"
#include "styles/style_layers.h"
#include "styles/style_menu_icons.h"
#include "styles/style_widgets.h"

namespace Lunagram {
namespace {

constexpr auto kSettingsLimit = 64 * 1024;
constexpr auto kNoteLimit = 4000;
constexpr auto kJournalLimit = 200;
constexpr auto kJournalAge = int64(30) * 24 * 60 * 60 * 1000;
constexpr auto kProfiles = std::array{ "normal", "work", "custom" };
constexpr auto kFlagKeys = std::array{
	std::pair{ "preserve_deleted", Flag::PreserveDeleted },
	std::pair{ "record_edits", Flag::RecordEdits },
	std::pair{ "journal", Flag::Journal },
	std::pair{ "glass", Flag::Glass },
	std::pair{ "emergency", Flag::Emergency },
	std::pair{ "local_rating", Flag::LocalRating },
	std::pair{ "local_anonymous", Flag::LocalAnonymous },
	std::pair{ "local_verification", Flag::LocalVerification },
};
constexpr auto kIntKeys = std::array{
	"rating_level", "rating_progress", "anonymous_price",
};

struct ComposerPreference {
	const char *name = nullptr;
	int minimum = 0;
	int maximum = 0;
	int fallback = 0;
};

constexpr auto kComposerPreferences = std::array{
	ComposerPreference{ "formatting", 0, 6, 0 },
	ComposerPreference{ "undo_delay", 0, 5000, 0 },
	ComposerPreference{ "typing_mode", 0, 2, 0 },
	ComposerPreference{ "typing_speed", 0, 2, 1 },
	ComposerPreference{ "glass_opacity", 35, 95, 75 },
};

struct Profiles {
	QJsonObject snapshots;
	QString active;
};

QString Key(const char *name) {
	return QString::fromLatin1(name);
}

bool ValidProfile(const QString &profile) {
	return ranges::any_of(kProfiles, [&](const char *name) {
		return profile == Key(name);
	});
}

bool ValidInteger(const QJsonValue &value, int minimum, int maximum) {
	return value.isDouble()
		&& value.toDouble() >= minimum
		&& value.toDouble() <= maximum
		&& value.toDouble() == value.toInt();
}

bool ValidValues(const QJsonObject &values) {
	const auto legacySize = kFlagKeys.size() + kIntKeys.size() + 1;
	if (values.size() < legacySize
		|| values.size() > legacySize + kComposerPreferences.size()) {
		return false;
	}
	for (const auto &name : values.keys()) {
		const auto known = (name == u"anonymous_number"_q)
			|| ranges::any_of(kFlagKeys, [&](const auto &entry) {
				return name == Key(entry.first);
			})
			|| ranges::any_of(kIntKeys, [&](const char *entry) {
				return name == Key(entry);
			})
			|| ranges::any_of(kComposerPreferences, [&](const auto &entry) {
				return name == Key(entry.name);
			});
		if (!known) {
			return false;
		}
	}
	for (const auto &[name, flag] : kFlagKeys) {
		if (!values.value(Key(name)).isBool()) {
			return false;
		}
	}
	if (!ValidInteger(values.value(u"rating_level"_q), 1, 100)
		|| !ValidInteger(values.value(u"rating_progress"_q), 1, 999)
		|| !ValidInteger(values.value(u"anonymous_price"_q), 1000, 10000)) {
		return false;
	}
	for (const auto &preference : kComposerPreferences) {
		const auto key = Key(preference.name);
		if (values.contains(key)
			&& !ValidInteger(values.value(key), preference.minimum, preference.maximum)) {
			return false;
		}
	}
	const auto undo = values.value(u"undo_delay"_q).toInt();
	if (undo != 0 && undo < 400) {
		return false;
	}
	const auto digits = values.value(u"anonymous_number"_q);
	return digits.isString()
		&& digits.toString().size() == 8
		&& ranges::all_of(digits.toString(), [](QChar ch) {
			return ch >= QChar('0') && ch <= QChar('9');
		});
}

QJsonObject CaptureValues(not_null<Main::Session*> session) {
	auto result = QJsonObject();
	for (const auto &[name, flag] : kFlagKeys) {
		result.insert(Key(name), Enabled(session, flag));
	}
	result.insert(u"rating_level"_q, std::clamp(
		IntValue(session, "rating_level", 1), 1, 100));
	result.insert(u"rating_progress"_q, std::clamp(
		IntValue(session, "rating_progress", QRandomGenerator::global()->bounded(200, 851)),
		1,
		999));
	result.insert(u"anonymous_price"_q, std::clamp(
		IntValue(session, "anonymous_price", QRandomGenerator::global()->bounded(1000, 10001)),
		1000,
		10000));
	result.insert(u"anonymous_number"_q, LocalAnonymousNumber(session).mid(3));
	for (const auto &preference : kComposerPreferences) {
		auto value = std::clamp(
			IntValue(session, preference.name, preference.fallback),
			preference.minimum,
			preference.maximum);
		if (Key(preference.name) == u"undo_delay"_q && value != 0) {
			value = std::max(value, 400);
		}
		result.insert(Key(preference.name), value);
	}
	return result;
}

void ApplyValues(not_null<Main::Session*> session, const QJsonObject &values) {
	Expects(ValidValues(values));
	for (const auto &[name, flag] : kFlagKeys) {
		SetEnabled(session, flag, values.value(Key(name)).toBool());
	}
	for (const auto name : kIntKeys) {
		SetIntValue(session, name, values.value(Key(name)).toInt());
	}
	for (const auto &preference : kComposerPreferences) {
		SetIntValue(
			session,
			preference.name,
			values.value(Key(preference.name)).toInt(preference.fallback));
	}
	SetStringValue(
		session,
		"anonymous_number",
		values.value(u"anonymous_number"_q).toString());
}

std::optional<Profiles> ReadProfiles(not_null<Main::Session*> session) {
	const auto content = ReadPrivate(session, u"profiles"_q);
	if (content.isEmpty()) {
		if (PrivateExists(session, u"profiles"_q)) {
			return std::nullopt;
		}
		auto snapshots = QJsonObject();
		const auto values = CaptureValues(session);
		for (const auto name : kProfiles) {
			auto snapshot = values;
			if (Key(name) == u"work"_q) {
				snapshot.insert(u"glass"_q, false);
			}
			snapshots.insert(Key(name), snapshot);
		}
		return Profiles{ std::move(snapshots), u"normal"_q };
	}
	if (content.size() > kSettingsLimit) {
		return std::nullopt;
	}
	const auto document = QJsonDocument::fromJson(content);
	if (!document.isObject()) {
		return std::nullopt;
	}
	auto object = document.object();
	const auto active = object.take(u"active"_q).toString();
	if (!ValidProfile(active) || object.size() != kProfiles.size()) {
		return std::nullopt;
	}
	for (const auto name : kProfiles) {
		const auto value = object.value(Key(name));
		if (!value.isObject() || !ValidValues(value.toObject())) {
			return std::nullopt;
		}
	}
	return Profiles{ std::move(object), active };
}

bool WriteProfiles(not_null<Main::Session*> session, Profiles profiles) {
	profiles.snapshots.insert(u"active"_q, profiles.active);
	const auto content = QJsonDocument(profiles.snapshots).toJson(QJsonDocument::Compact);
	return content.size() <= kSettingsLimit
		&& WritePrivate(session, u"profiles"_q, content);
}

QString ProfileName(const QString &profile) {
	return (profile == u"work"_q)
		? tr::lng_lunagram_profile_work(tr::now)
		: (profile == u"custom"_q)
		? tr::lng_lunagram_profile_custom(tr::now)
		: tr::lng_lunagram_profile_normal(tr::now);
}

rpl::producer<QString> ProfileNameValue(const QString &profile) {
	return (profile == u"work"_q)
		? tr::lng_lunagram_profile_work()
		: (profile == u"custom"_q)
		? tr::lng_lunagram_profile_custom()
		: tr::lng_lunagram_profile_normal();
}

void SwitchProfile(
		not_null<Window::SessionController*> controller,
		const QString &profile) {
	const auto session = &controller->session();
	auto profiles = ReadProfiles(session);
	if (!profiles || !ValidProfile(profile)) {
		controller->showToast(tr::lng_lunagram_private_write_failed(tr::now));
		return;
	} else if (profiles->active == profile) {
		return;
	}
	profiles->snapshots.insert(profiles->active, CaptureValues(session));
	profiles->active = profile;
	const auto values = profiles->snapshots.value(profile).toObject();
	if (!WriteProfiles(session, *profiles)) {
		controller->showToast(tr::lng_lunagram_private_write_failed(tr::now));
		return;
	}
	ApplyValues(session, values);
}

std::optional<QJsonArray> ReadJournal(not_null<Main::Session*> session) {
	const auto content = ReadPrivate(session, u"notification_journal"_q);
	if (content.isEmpty()) {
		if (PrivateExists(session, u"notification_journal"_q)) {
			return std::nullopt;
		}
		return QJsonArray();
	} else if (content.size() > kJournalLimit * 8192) {
		return std::nullopt;
	}
	const auto document = QJsonDocument::fromJson(content);
	if (!document.isArray() || document.array().size() > kJournalLimit) {
		return std::nullopt;
	}
	auto result = QJsonArray();
	const auto now = QDateTime::currentMSecsSinceEpoch();
	for (const auto &value : document.array()) {
		if (!value.isObject()) {
			return std::nullopt;
		}
		const auto entry = value.toObject();
		const auto when = entry.value(u"when"_q);
		if (entry.size() != 5
			|| !entry.value(u"id"_q).isString()
			|| !entry.value(u"peer"_q).isString()
			|| !entry.value(u"title"_q).isString()
			|| !entry.value(u"preview"_q).isString()
			|| !when.isDouble()
			|| when.toDouble() < 0
			|| when.toDouble() > now
			|| entry.value(u"title"_q).toString().size() > 256
			|| entry.value(u"preview"_q).toString().size() > 1024) {
			return std::nullopt;
		}
		auto valid = false;
		const auto peerId = entry.value(u"peer"_q).toString().toULongLong(&valid);
		if (!valid || !peerId) {
			return std::nullopt;
		}
		if (now - int64(when.toDouble()) <= kJournalAge) {
			const auto peer = session->data().peerLoaded(PeerId(peerId));
			if (!peer || (peer->allowsForwarding() && !peer->messagesTTL())) {
				result.push_back(entry);
			}
		}
	}
	return result;
}

QString SafePreview(const TextWithEntities &preview) {
	auto result = preview.text;
	auto spoilers = std::vector<EntityInText>();
	for (const auto &entity : preview.entities) {
		if (entity.type() == EntityType::Spoiler) {
			spoilers.push_back(entity);
		}
	}
	ranges::sort(spoilers, ranges::greater(), &EntityInText::offset);
	for (const auto &entity : spoilers) {
		if (entity.offset() >= 0 && entity.offset() <= result.size()) {
			result.replace(entity.offset(), entity.length(), u"•••"_q);
		}
	}
	return TextUtilities::SingleLine(result).left(1024);
}

void SettingsImported(
		not_null<Window::SessionController*> controller,
		const QByteArray &content) {
	const auto invalid = [&] {
		controller->showToast(tr::lng_lunagram_settings_import_invalid(tr::now));
	};
	if (content.isEmpty() || content.size() > kSettingsLimit) {
		invalid();
		return;
	}
	const auto propertyPattern = QRegularExpression(
		uR"json("((?:[^"\\]|\\.)*)"\s*:)json"_q);
	auto propertyNames = base::flat_set<QString>();
	auto matches = propertyPattern.globalMatch(QString::fromUtf8(content));
	while (matches.hasNext()) {
		const auto match = matches.next();
		const auto keyDocument = QJsonDocument::fromJson(
			QByteArray("[\"") + match.captured(1).toUtf8() + "\"]");
		if (!keyDocument.isArray() || keyDocument.array().size() != 1) {
			invalid();
			return;
		}
		const auto name = keyDocument.array().at(0).toString();
		if (propertyNames.contains(name)) {
			invalid();
			return;
		}
		propertyNames.emplace(name);
	}
	const auto document = QJsonDocument::fromJson(content);
	if (!document.isObject()) {
		invalid();
		return;
	}
	const auto object = document.object();
	const auto profile = object.value(u"profile"_q).toString();
	const auto values = object.value(u"values"_q);
	if (object.size() != 4
		|| object.value(u"format"_q).toString() != u"lunagram-settings"_q
		|| !ValidInteger(object.value(u"version"_q), 1, 1)
		|| !ValidProfile(profile)
		|| !values.isObject()
		|| !ValidValues(values.toObject())) {
		invalid();
		return;
	}
	const auto session = &controller->session();
	auto profiles = ReadProfiles(session);
	if (!profiles) {
		controller->showToast(tr::lng_lunagram_private_write_failed(tr::now));
		return;
	}
	profiles->snapshots.insert(profile, values);
	if (!WriteProfiles(session, *profiles)) {
		controller->showToast(tr::lng_lunagram_private_write_failed(tr::now));
		return;
	}
	if (profiles->active == profile) {
		ApplyValues(session, values.toObject());
	}
	controller->showToast(tr::lng_lunagram_settings_import_done(
		tr::now,
		lt_name,
		ProfileName(profile)));
}

} // namespace

void ShowProfilesBox(not_null<Window::SessionController*> controller) {
	const auto profiles = ReadProfiles(&controller->session());
	if (!profiles) {
		controller->showToast(tr::lng_lunagram_private_write_failed(tr::now));
		return;
	}
	const auto weak = base::make_weak(controller);
	const auto identity = controller->session().uniqueId();
	controller->show(Box([=](not_null<Ui::GenericBox*> box) {
		box->setTitle(tr::lng_lunagram_profiles_title());
		box->setWidth(st::boxWideWidth);
		box->addRow(object_ptr<Ui::FlatLabel>(
			box,
			tr::lng_lunagram_profiles_description(),
			st::boxLabel));
		for (const auto name : kProfiles) {
			const auto profile = Key(name);
			const auto button = box->addRow(object_ptr<Ui::RoundButton>(
				box,
				ProfileNameValue(profile) | rpl::map([=](const QString &label) {
					return profile == profiles->active ? u"✓ "_q + label : label;
				}),
				st::defaultBoxButton));
			button->setClickedCallback([=] {
				if (const auto strong = weak.get()) {
					if (strong->session().uniqueId() == identity) {
						SwitchProfile(strong, profile);
					}
				}
				box->closeBox();
			});
		}
		box->addButton(tr::lng_close(), [=] { box->closeBox(); });
	}));
}

void ExportSettings(not_null<Window::SessionController*> controller) {
	const auto profiles = ReadProfiles(&controller->session());
	if (!profiles) {
		controller->showToast(tr::lng_lunagram_private_write_failed(tr::now));
		return;
	}
	const auto content = QJsonDocument(QJsonObject{
		{ u"format"_q, u"lunagram-settings"_q },
		{ u"version"_q, 1 },
		{ u"profile"_q, profiles->active },
		{ u"values"_q, CaptureValues(&controller->session()) },
	}).toJson(QJsonDocument::Indented);
	const auto identity = controller->session().uniqueId();
	FileDialog::GetWritePath(
		Core::App().getFileDialogParent(),
		tr::lng_lunagram_settings_export_title(tr::now),
		tr::lng_lunagram_settings_json_filter(tr::now),
		u"lunagram-settings.json"_q,
		crl::guard(controller, [=](const QString &path) {
			if (path.isEmpty() || controller->session().uniqueId() != identity) {
				return;
			}
			auto file = QSaveFile(path);
			if (!file.open(QIODevice::WriteOnly)
				|| file.write(content) != content.size()
				|| !file.commit()) {
				controller->showToast(tr::lng_lunagram_settings_export_failed(tr::now));
				return;
			}
			controller->showToast(tr::lng_lunagram_settings_export_done(tr::now));
		}));
}

void ImportSettings(not_null<Window::SessionController*> controller) {
	const auto identity = controller->session().uniqueId();
	FileDialog::GetOpenPath(
		Core::App().getFileDialogParent(),
		tr::lng_lunagram_settings_import_title(tr::now),
		tr::lng_lunagram_settings_json_filter(tr::now),
		crl::guard(controller, [=](const FileDialog::OpenResult &result) {
			if (controller->session().uniqueId() != identity) {
				return;
			}
			if (!result.remoteContent.isEmpty()) {
				SettingsImported(controller, result.remoteContent);
			} else if (!result.paths.empty()) {
				auto file = QFile(result.paths.front());
				if (!file.open(QIODevice::ReadOnly) || file.size() > kSettingsLimit) {
					controller->showToast(tr::lng_lunagram_settings_import_invalid(tr::now));
					return;
				}
				SettingsImported(controller, file.read(kSettingsLimit + 1));
			}
		}));
}

void ShowNotesBox(
		not_null<Window::SessionController*> controller,
		PeerId peerId) {
	const auto session = &controller->session();
	if (IsChatLocked(session, peerId)) {
		controller->showToast(tr::lng_lunagram_notes_vault_locked(tr::now));
		return;
	}
	const auto name = u"note_"_q + QString::number(peerId.value);
	const auto content = ReadPrivate(session, name);
	const auto note = QString::fromUtf8(content);
	if (!peerId || content.size() > kNoteLimit * 4
		|| note.size() > kNoteLimit
		|| note.toUtf8() != content) {
		controller->showToast(tr::lng_lunagram_private_write_failed(tr::now));
		return;
	}
	const auto weak = base::make_weak(controller);
	const auto identity = session->uniqueId();
	controller->show(Box([=](not_null<Ui::GenericBox*> box) {
		box->setTitle(tr::lng_lunagram_notes_title());
		box->setWidth(st::boxWideWidth);
		box->addRow(object_ptr<Ui::FlatLabel>(
			box,
			tr::lng_lunagram_notes_description(),
			st::boxLabel));
		const auto field = box->addRow(object_ptr<Ui::InputField>(
			box,
			st::defaultInputField,
			Ui::InputField::Mode::MultiLine,
			tr::lng_lunagram_notes_placeholder()));
		field->setMaxLength(kNoteLimit);
		field->setText(note);
		VaultChanges(session) | rpl::on_next([=] {
			const auto strong = weak.get();
			if (!strong || strong->session().uniqueId() != identity
				|| IsChatLocked(&strong->session(), peerId)) {
				box->closeBox();
			}
		}, box->lifetime());
		box->addButton(tr::lng_settings_save(), [=] {
			const auto strong = weak.get();
			if (!strong || strong->session().uniqueId() != identity) {
				box->closeBox();
				return;
			}
			const auto text = field->getLastText();
			if (IsChatLocked(&strong->session(), peerId)) {
				box->closeBox();
				return;
			} else if (text.size() > kNoteLimit
				|| !WritePrivate(&strong->session(), name, text.toUtf8())) {
				strong->showToast(tr::lng_lunagram_private_write_failed(tr::now));
				return;
			}
			box->closeBox();
		});
		box->addButton(tr::lng_cancel(), [=] { box->closeBox(); });
	}));
}

void RecordPostedNotification(
		not_null<HistoryItem*> item,
		const QString &title,
		const TextWithEntities &preview) {
	const auto peer = item->history()->peer;
	const auto session = &peer->session();
	if (!Enabled(session, Flag::Journal)
		|| Core::App().passcodeLocked()
		|| Core::App().screenIsLocked()
		|| Enabled(session, Flag::Emergency)
		|| IsVaultChat(session, peer->id)
		|| IsChatLocked(session, peer->id)
		|| !peer->allowsForwarding()
		|| peer->messagesTTL()
		|| item->forbidsForward()
		|| item->ttlDestroyAt()
		|| item->mediaDestroyAt()
		|| item->isEphemeral()
		|| (item->media() && item->media()->ttlSeconds())
		|| item->lunagramRetainedDeleted()
		|| peer->isNotificationsUser()
		|| peer->isVerifyCodes()
		|| title.isEmpty()
		|| preview.text.isEmpty()) {
		return;
	}
	auto journal = ReadJournal(session);
	if (!journal) {
		return;
	}
	const auto peerKey = QString::number(peer->id.value);
	const auto id = peerKey + ':' + QString::number(item->id.bare);
	if (ranges::any_of(*journal, [&](const auto &value) {
		return value.toObject().value(u"id"_q).toString() == id;
	})) {
		return;
	}
	while (journal->size() >= kJournalLimit) {
		journal->removeAt(0);
	}
	journal->push_back(QJsonObject{
		{ u"id"_q, id },
		{ u"peer"_q, peerKey },
		{ u"when"_q, QDateTime::currentMSecsSinceEpoch() },
		{ u"title"_q, title.left(256) },
		{ u"preview"_q, SafePreview(preview) },
	});
	const auto saved = WritePrivate(
		session,
		u"notification_journal"_q,
		QJsonDocument(*journal).toJson(QJsonDocument::Compact));
	if (!saved) {
		return;
	}
}

void ShowJournalBox(not_null<Window::SessionController*> controller) {
	if (Core::App().passcodeLocked() || Core::App().screenIsLocked()) {
		return;
	}
	const auto journal = ReadJournal(&controller->session());
	if (!journal) {
		controller->showToast(tr::lng_lunagram_private_write_failed(tr::now));
		return;
	}
	if (!WritePrivate(
		&controller->session(),
		u"notification_journal"_q,
		QJsonDocument(*journal).toJson(QJsonDocument::Compact))) {
		controller->showToast(tr::lng_lunagram_private_write_failed(tr::now));
		return;
	}
	const auto weak = base::make_weak(controller);
	const auto identity = controller->session().uniqueId();
	controller->show(Box([=](not_null<Ui::GenericBox*> box) {
		box->setTitle(tr::lng_lunagram_journal_title());
		box->setWidth(st::boxWideWidth);
		if (const auto strong = weak.get()) {
			VaultChanges(&strong->session()) | rpl::on_next([=] {
				box->closeBox();
			}, box->lifetime());
		}
		box->addRow(object_ptr<Ui::FlatLabel>(
			box,
			tr::lng_lunagram_journal_description(),
			st::boxLabel));
		auto shown = false;
		for (auto i = journal->size(); i != 0; --i) {
			const auto entry = journal->at(i - 1).toObject();
			const auto peerId = PeerId(entry.value(u"peer"_q).toString().toULongLong());
			const auto strong = weak.get();
			if (!strong || strong->session().uniqueId() != identity
				|| !strong->session().data().peerLoaded(peerId)
				|| IsVaultChat(&strong->session(), peerId)
				|| IsChatLocked(&strong->session(), peerId)) {
				continue;
			}
			const auto when = QDateTime::fromMSecsSinceEpoch(
				int64(entry.value(u"when"_q).toDouble()));
			const auto text = QLocale().toString(when, QLocale::ShortFormat)
				+ u" · "_q + entry.value(u"title"_q).toString()
				+ '\n' + entry.value(u"preview"_q).toString();
			box->addRow(object_ptr<Ui::FlatLabel>(
				box,
				rpl::single(text),
				st::boxLabel));
			shown = true;
		}
		if (!shown) {
			box->addRow(object_ptr<Ui::FlatLabel>(
				box,
				tr::lng_lunagram_journal_empty(),
				st::boxLabel));
		}
		box->addButton(tr::lng_lunagram_journal_clear(), [=] {
			const auto strong = weak.get();
			if (!strong || strong->session().uniqueId() != identity) {
				return;
			}
			const auto guard = QPointer<Ui::GenericBox>(box.get());
			strong->show(Ui::MakeConfirmBox({
				.text = tr::lng_lunagram_journal_clear_confirm(),
				.confirmed = crl::guard(strong, [=](Fn<void()> close) {
					if (!WritePrivate(
						&strong->session(),
						u"notification_journal"_q,
						QByteArray("[]"))) {
						strong->showToast(tr::lng_lunagram_private_write_failed(tr::now));
						return;
					}
					if (guard) {
						guard->closeBox();
					}
					close();
				}),
				.confirmText = tr::lng_lunagram_journal_clear(),
			}));
		});
		box->addButton(tr::lng_close(), [=] { box->closeBox(); });
	}));
}

void AddChatToolsActions(
		not_null<Window::SessionController*> controller,
		not_null<PeerData*> peer,
		const Ui::Menu::MenuCallback &addAction) {
	if (&peer->session() != &controller->session()) {
		return;
	}
	const auto id = peer->id;
	addAction(
		tr::lng_lunagram_notes_title(tr::now),
		crl::guard(controller, [=] { ShowNotesBox(controller, id); }),
		&st::menuIconEdit);
	addAction(
		tr::lng_lunagram_journal_title(tr::now),
		crl::guard(controller, [=] { ShowJournalBox(controller); }),
		&st::menuIconNotifications);
	AddChatVaultActions(controller, peer, addAction);
}

} // namespace Lunagram

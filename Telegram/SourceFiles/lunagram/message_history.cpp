#include "lunagram/message_history.h"

#include "data/data_media_types.h"
#include "data/data_session.h"
#include "history/history.h"
#include "history/history_item.h"
#include "history/history_item_components.h"
#include "history/history_item_helpers.h"
#include "iv/iv_rich_page.h"
#include "lunagram/lunagram_settings.h"
#include "lunagram/secure_storage.h"
#include "main/main_session.h"

#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>

namespace Lunagram {
namespace {

constexpr auto kMaxRecords = 3000;
constexpr auto kMaxDeleted = 1000;
constexpr auto kMaxVersions = 20;
constexpr auto kMaxEditedMessages = 300;
constexpr auto kMaxText = 4096;
constexpr auto kMaxMessageBytes = 256 * 1024;
constexpr auto kMaxStoreBytes = 48 * 1024 * 1024;
constexpr auto kSaveDelay = crl::time(1500);

bool CanRecord(not_null<HistoryItem*> item) {
	return item->isRegular()
		&& !item->isScheduled()
		&& !item->isBusinessShortcut()
		&& !item->isWelcomeTemplate()
		&& !item->isEphemeral()
		&& !item->ttlDestroyAt()
		&& !item->mediaDestroyAt()
		&& !item->forbidsForward()
		&& item->history()->peer->allowsForwarding()
		&& !item->history()->peer->messagesTTL()
		&& (!item->media()
			|| (!item->media()->ttlSeconds() && item->media()->allowsForward()));
}

bool SafeMessage(const MTPMessage &message) {
	if (message.type() != mtpc_message) {
		return false;
	}
	const auto &data = message.c_message();
	if (data.vid().v <= 0
		|| data.is_noforwards()
		|| data.vttl_period().has_value()
		|| data.vquick_reply_shortcut_id().has_value()) {
		return false;
	}
	const auto media = data.vmedia();
	return !media || media->match([](const MTPDmessageMediaPhoto &data) {
		return !data.vttl_seconds().has_value();
	}, [](const MTPDmessageMediaDocument &data) {
		return !data.vttl_seconds().has_value();
	}, [](const MTPDmessageMediaEmpty &) {
		return true;
	}, [](const MTPDmessageMediaWebPage &) {
		return true;
	}, [](const MTPDmessageMediaContact &) {
		return true;
	}, [](const MTPDmessageMediaGeo &) {
		return true;
	}, [](const MTPDmessageMediaVenue &) {
		return true;
	}, [](const MTPDmessageMediaDice &) {
		return true;
	}, [](const MTPDmessageMediaGame &) {
		return true;
	}, [](const MTPDmessageMediaPoll &) {
		return true;
	}, [](const auto &) {
		return false;
	});
}

QByteArray Serialize(const MTPMessage &message) {
	auto buffer = mtpBuffer();
	message.write(buffer);
	const auto size = qsizetype(buffer.size()) * qsizetype(sizeof(mtpPrime));
	return (size <= kMaxMessageBytes)
		? QByteArray(reinterpret_cast<const char*>(buffer.data()), size)
		: QByteArray();
}

std::optional<MTPMessage> Parse(const QByteArray &bytes) {
	if (bytes.isEmpty()
		|| bytes.size() > kMaxMessageBytes
		|| bytes.size() % sizeof(mtpPrime)) {
		return std::nullopt;
	}
	auto buffer = mtpBuffer(bytes.size() / sizeof(mtpPrime));
	memcpy(buffer.data(), bytes.constData(), bytes.size());
	const auto end = buffer.constData() + buffer.size();
	auto from = buffer.constData();
	auto result = MTPMessage();
	return result.read(from, end) && from == end && SafeMessage(result)
		? std::make_optional(std::move(result))
		: std::nullopt;
}

} // namespace

MessageHistory::MessageHistory(not_null<Main::Session*> session)
: _session(session)
, _saveTimer([=] { save(); }) {
	load();
}

MessageHistory::~MessageHistory() {
	if (_dirty) {
		save();
	}
}

void MessageHistory::load() {
	const auto bytes = ReadPrivate(_session, u"message-history"_q);
	if (bytes.isEmpty()) {
		_valid = !PrivateExists(_session, u"message-history"_q);
		return;
	} else if (bytes.size() > kMaxStoreBytes) {
		_valid = false;
		return;
	}
	const auto root = QJsonDocument::fromJson(bytes).object();
	if (root.value(u"schema"_q).toInt() != 1
		|| root.value(u"owner"_q).toString()
			!= QString::number(_session->uniqueId())
		|| !root.value(u"records"_q).isArray()) {
		_valid = false;
		return;
	}
	for (const auto &value : root.value(u"records"_q).toArray()) {
		const auto object = value.toObject();
		const auto raw = QByteArray::fromBase64(
			object.value(u"message"_q).toString().toLatin1());
		const auto message = Parse(raw);
		if (!message) {
			_valid = false;
			return;
		}
		const auto id = FullMsgId(PeerFromMessage(*message), IdFromMessage(*message));
		auto record = Record{
			.message = raw,
			.editDate = message->c_message().vedit_date().value_or_empty(),
			.order = object.value(u"order"_q).toString().toULongLong(),
			.deleted = object.value(u"deleted"_q).toBool(),
		};
		_order = std::max(_order, record.order);
		for (const auto &value : object.value(u"versions"_q).toArray()) {
			const auto version = value.toObject();
			record.versions.push_back({
				.date = version.value(u"date"_q).toInt(),
				.text = version.value(u"text"_q).toString().left(kMaxText),
			});
			if (record.versions.size() == kMaxVersions) {
				break;
			}
		}
		_records.emplace(id, std::move(record));
		if (_records.size() == kMaxRecords) {
			break;
		}
	}
	trim();
}

bool MessageHistory::save() {
	if (!_valid || !_dirty) {
		return _valid;
	}
	auto records = QJsonArray();
	for (const auto &[id, record] : _records) {
		auto versions = QJsonArray();
		for (const auto &version : record.versions) {
			versions.push_back(QJsonObject{
				{ u"date"_q, int(version.date) },
				{ u"text"_q, version.text },
			});
		}
		records.push_back(QJsonObject{
			{ u"message"_q, QString::fromLatin1(record.message.toBase64()) },
			{ u"deleted"_q, record.deleted },
			{ u"order"_q, QString::number(record.order) },
			{ u"versions"_q, versions },
		});
	}
	const auto bytes = QJsonDocument(QJsonObject{
		{ u"schema"_q, 1 },
		{ u"owner"_q, QString::number(_session->uniqueId()) },
		{ u"records"_q, records },
	}).toJson(QJsonDocument::Compact);
	if (bytes.size() > kMaxStoreBytes
		|| !WritePrivate(_session, u"message-history"_q, bytes)) {
		return false;
	}
	_dirty = false;
	_saveTimer.cancel();
	return true;
}

void MessageHistory::trim() {
	auto bytes = qsizetype(0);
	auto deleted = 0;
	auto edited = 0;
	for (const auto &[id, record] : _records) {
		bytes += record.message.size() * 2 + 1024;
		for (const auto &version : record.versions) {
			bytes += version.text.size() * 6 + 64;
		}
		deleted += record.deleted ? 1 : 0;
		edited += record.versions.empty() ? 0 : 1;
	}
	while (edited > kMaxEditedMessages) {
		auto oldest = _records.end();
		for (auto i = _records.begin(); i != _records.end(); ++i) {
			if (!i->second.versions.empty()
				&& (oldest == _records.end()
					|| i->second.order < oldest->second.order)) {
				oldest = i;
			}
		}
		for (const auto &version : oldest->second.versions) {
			bytes -= version.text.size() * 6 + 64;
		}
		oldest->second.versions.clear();
		--edited;
	}
	while (_records.size() > kMaxRecords
		|| deleted > kMaxDeleted
		|| bytes > kMaxStoreBytes / 2) {
		auto oldest = _records.end();
		for (auto i = _records.begin(); i != _records.end(); ++i) {
			if (deleted > kMaxDeleted && !i->second.deleted) {
				continue;
			}
			if (oldest == _records.end()
				|| (!i->second.deleted && oldest->second.deleted)
				|| (i->second.deleted == oldest->second.deleted
					&& i->second.order < oldest->second.order)) {
				oldest = i;
			}
		}
		if (oldest == _records.end()) {
			break;
		}
		bytes -= oldest->second.message.size() * 2 + 1024;
		for (const auto &version : oldest->second.versions) {
			bytes -= version.text.size() * 6 + 64;
		}
		deleted -= oldest->second.deleted ? 1 : 0;
		_records.erase(oldest);
	}
}

void MessageHistory::scheduleSave() {
	_dirty = true;
	if (!_saveTimer.isActive()) {
		_saveTimer.callOnce(kSaveDelay);
	}
}

void MessageHistory::observe(
		not_null<HistoryItem*> item,
		const MTPMessage &message) {
	if (!_valid
		|| _localRemovals.contains(item->fullId())
		|| isDeleted(item->fullId())) {
		return;
	}
	if (!CanRecord(item) || !SafeMessage(message)) {
		if (_records.contains(item->fullId())) {
			forgetObserved(item->fullId());
		}
		return;
	}
	if (!Enabled(_session, Flag::PreserveDeleted)
		&& !Enabled(_session, Flag::RecordEdits)) {
		return;
	}
	const auto bytes = Serialize(message);
	if (bytes.isEmpty()) {
		return;
	}
	const auto editDate = message.c_message().vedit_date().value_or_empty();
	auto &record = _records[item->fullId()];
	if (editDate < record.editDate || record.message == bytes) {
		return;
	}
	record.message = bytes;
	record.editDate = editDate;
	record.order = ++_order;
	trim();
	scheduleSave();
}

void MessageHistory::recordEdit(
		not_null<HistoryItem*> item,
		const MTPMessage &message) {
	if (!_valid
		|| !Enabled(_session, Flag::RecordEdits)
		|| !CanRecord(item)
		|| !SafeMessage(message)
		|| isDeleted(item->fullId())) {
		return;
	}
	const auto &data = message.c_message();
	const auto editDate = data.vedit_date().value_or_empty();
	const auto previous = item->Get<HistoryMessageEdited>();
	const auto previousDate = previous ? previous->date : item->date();
	const auto before = item->originalText().text.left(kMaxText);
	const auto edition = HistoryMessageEdition(_session, data);
	const auto after = (edition.richPage
		? Iv::FlattenRichPageSummary(edition.richPage).text
		: edition.textWithEntities.text).left(kMaxText);
	if (!editDate || editDate < previousDate || before == after) {
		return;
	}
	const auto bytes = Serialize(message);
	if (bytes.isEmpty()) {
		return;
	}
	auto &record = _records[item->fullId()];
	auto &versions = record.versions;
	if (versions.empty() || versions.back().text != before) {
		versions.push_back({ previousDate, before });
	}
	versions.push_back({ editDate, after });
	if (versions.size() > kMaxVersions) {
		versions.erase(versions.begin(), versions.end() - kMaxVersions);
	}
	record.message = bytes;
	record.editDate = editDate;
	record.order = ++_order;
	trim();
	_dirty = true;
	save();
}

bool MessageHistory::retain(not_null<HistoryItem*> item) {
	if (!CanRecord(item) || !isDeleted(item->fullId())) {
		return false;
	}
	item->setLunagramRetainedDeleted(true);
	item->history()->owner().requestItemResize(item);
	return true;
}

void MessageHistory::retainDeletedBatch(const std::vector<FullMsgId> &ids) {
	if (!_valid || !Enabled(_session, Flag::PreserveDeleted)) {
		return;
	}
	auto changed = base::flat_set<FullMsgId>();
	for (const auto id : ids) {
		const auto i = _records.find(id);
		if (_localRemovals.contains(id)
			|| i == _records.end()
			|| i->second.deleted) {
			continue;
		}
		const auto peer = _session->data().peerLoaded(id.peer);
		const auto item = _session->data().message(id);
		if ((peer && (!peer->allowsForwarding() || peer->messagesTTL()))
			|| (item && !CanRecord(item))) {
			continue;
		}
		i->second.deleted = true;
		i->second.order = ++_order;
		changed.emplace(id);
	}
	if (changed.empty()) {
		return;
	}
	trim();
	_dirty = true;
	if (!save()) {
		for (const auto id : changed) {
			const auto i = _records.find(id);
			if (i != _records.end()) {
				i->second.deleted = false;
			}
		}
	}
}

void MessageHistory::retainNonChannelDeletedBatch(
		const QVector<MTPint> &ids) {
	auto wanted = base::flat_set<MsgId>();
	for (const auto &id : ids) {
		wanted.emplace(id.v);
	}
	auto candidates = std::vector<FullMsgId>();
	for (const auto &[id, record] : _records) {
		if (!peerIsChannel(id.peer) && wanted.contains(id.msg)) {
			candidates.push_back(id);
		}
	}
	retainDeletedBatch(candidates);
}

bool MessageHistory::isDeleted(FullMsgId id) const {
	const auto i = _records.find(id);
	return _valid && i != _records.end() && i->second.deleted;
}

bool MessageHistory::forget(FullMsgId id) {
	const auto i = _records.find(id);
	if (!_valid || i == _records.end()) {
		return _valid;
	}
	auto previous = i->second;
	_records.erase(i);
	_dirty = true;
	if (save()) {
		_localRemovals.emplace(id);
		return true;
	}
	_records.emplace(id, std::move(previous));
	return false;
}

void MessageHistory::forgetObserved(FullMsgId id) {
	_localRemovals.emplace(id);
	if (_localRemovals.size() > kMaxRecords) {
		_localRemovals.erase(_localRemovals.begin());
	}
	if (!forget(id)) {
		_valid = false;
	}
}

void MessageHistory::forgetRange(PeerId peer, TimeId from, TimeId till) {
	auto remove = std::vector<FullMsgId>();
	for (const auto &[id, record] : _records) {
		if (id.peer != peer) {
			continue;
		}
		if (!from && !till) {
			remove.push_back(id);
		} else if (const auto message = Parse(record.message)) {
			const auto date = message->c_message().vdate().v;
			if (date >= from && date <= till) {
				remove.push_back(id);
			}
		}
	}
	for (const auto id : remove) {
		_localRemovals.emplace(id);
		const auto record = _records.find(id);
		if (record != _records.end()) {
			_records.erase(record);
		}
	}
	while (_localRemovals.size() > kMaxRecords) {
		_localRemovals.erase(_localRemovals.begin());
	}
	if (!remove.empty()) {
		_dirty = true;
		if (!save()) {
			_valid = false;
		}
	}
}

bool MessageHistory::clear() {
	if (!_valid) {
		return false;
	}
	auto previous = base::take(_records);
	_dirty = true;
	if (save()) {
		return true;
	}
	_records = std::move(previous);
	return false;
}

std::vector<EditVersion> MessageHistory::versions(FullMsgId id) const {
	const auto i = _records.find(id);
	return (_valid && i != _records.end())
		? i->second.versions
		: std::vector<EditVersion>();
}

QVector<MTPMessage> MessageHistory::mergeDeleted(
		not_null<History*> history,
		const QVector<MTPMessage> &messages,
		bool lowerEdge,
		bool upperEdge) const {
	if (!_valid || !history->peer->allowsForwarding()
		|| history->peer->messagesTTL()) {
		return messages;
	}
	auto ids = base::flat_set<MsgId>();
	auto minimum = MsgId();
	auto maximum = MsgId();
	for (const auto &message : messages) {
		const auto id = IdFromMessage(message);
		ids.emplace(id);
		minimum = !minimum ? id : std::min(minimum, id);
		maximum = std::max(maximum, id);
	}
	if (messages.isEmpty()) {
		if (!lowerEdge && upperEdge) {
			minimum = history->maxMsgId();
		} else if (lowerEdge && !upperEdge) {
			maximum = history->minMsgId();
		}
	}
	auto result = messages;
	for (const auto &[id, record] : _records) {
		if (id.peer != history->peer->id
			|| !record.deleted
			|| ids.contains(id.msg)
			|| (!lowerEdge && id.msg < minimum)
			|| (!upperEdge && id.msg > maximum)) {
			continue;
		}
		const auto loaded = history->owner().message(id);
		if (loaded && loaded->mainView()) {
			continue;
		}
		if (const auto parsed = Parse(record.message)) {
			result.push_back(*parsed);
		}
	}
	ranges::sort(result, std::greater(), [](const MTPMessage &message) {
		return IdFromMessage(message);
	});
	return result;
}

} // namespace Lunagram

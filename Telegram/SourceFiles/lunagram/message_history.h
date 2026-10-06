#pragma once

#include "base/timer.h"
#include "data/data_types.h"

class History;
class HistoryItem;

namespace Main {
class Session;
} // namespace Main

namespace Lunagram {

struct EditVersion {
	TimeId date = 0;
	QString text;
};

class MessageHistory final {
public:
	explicit MessageHistory(not_null<Main::Session*> session);
	~MessageHistory();

	void observe(not_null<HistoryItem*> item, const MTPMessage &message);
	void recordEdit(not_null<HistoryItem*> item, const MTPMessage &message);
	[[nodiscard]] bool retain(not_null<HistoryItem*> item);
	void retainDeletedBatch(const std::vector<FullMsgId> &ids);
	void retainNonChannelDeletedBatch(const QVector<MTPint> &ids);
	[[nodiscard]] bool isDeleted(FullMsgId id) const;
	[[nodiscard]] bool forget(FullMsgId id);
	void forgetObserved(FullMsgId id);
	void forgetRange(PeerId peer, TimeId from = 0, TimeId till = 0);
	[[nodiscard]] bool clear();
	[[nodiscard]] std::vector<EditVersion> versions(FullMsgId id) const;
	[[nodiscard]] QVector<MTPMessage> mergeDeleted(
		not_null<History*> history,
		const QVector<MTPMessage> &messages,
		bool lowerEdge,
		bool upperEdge) const;

private:
	struct Record {
		QByteArray message;
		std::vector<EditVersion> versions;
		TimeId editDate = 0;
		uint64 order = 0;
		bool deleted = false;
	};

	void load();
	bool save();
	void trim();
	void scheduleSave();

	const not_null<Main::Session*> _session;
	base::flat_map<FullMsgId, Record> _records;
	base::flat_set<FullMsgId> _localRemovals;
	base::Timer _saveTimer;
	uint64 _order = 0;
	bool _valid = true;
	bool _dirty = false;

};

} // namespace Lunagram

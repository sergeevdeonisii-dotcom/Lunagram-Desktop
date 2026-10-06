#include "lunagram/lunagram_settings.h"

#include "core/application.h"
#include "core/core_settings.h"
#include "main/main_session.h"

#include <array>

namespace Lunagram {
namespace {

rpl::event_stream<uint64> Changed;

std::string Key(not_null<Main::Session*> session, std::string_view name) {
	return "lunagram/" + std::to_string(session->uniqueId())
		+ '/' + std::string(name);
}

std::string_view FlagName(Flag flag) {
	constexpr auto names = std::array{
		"preserve_deleted",
		"record_edits",
		"journal",
		"glass",
		"emergency",
		"local_rating",
		"local_anonymous",
		"local_verification",
	};
	const auto index = static_cast<size_t>(flag);
	return (index < names.size()) ? names[index] : "invalid";
}

void Notify(not_null<Main::Session*> session) {
	Core::App().saveSettingsDelayed();
	Changed.fire_copy(session->uniqueId());
}

} // namespace

bool Enabled(not_null<Main::Session*> session, Flag flag) {
	const auto fallback = (flag == Flag::RecordEdits || flag == Flag::Glass);
	return Core::App().settings().readPref<bool>(
		Key(session, FlagName(flag)),
		fallback);
}

void SetEnabled(not_null<Main::Session*> session, Flag flag, bool enabled) {
	if (Enabled(session, flag) == enabled) {
		return;
	}
	Core::App().settings().writePref<bool>(Key(session, FlagName(flag)), enabled);
	Notify(session);
}

int IntValue(
		not_null<Main::Session*> session,
		std::string_view name,
		int fallback) {
	const auto data = Core::App().settings().readPref<QByteArray>(
		Key(session, name));
	auto valid = false;
	const auto value = data.toInt(&valid);
	return valid ? value : fallback;
}

void SetIntValue(
		not_null<Main::Session*> session,
		std::string_view name,
		int value) {
	Core::App().settings().writePref<QByteArray>(
		Key(session, name),
		QByteArray::number(value));
	Notify(session);
}

QString StringValue(
		not_null<Main::Session*> session,
		std::string_view name,
		const QString &fallback) {
	const auto data = Core::App().settings().readPref<QByteArray>(
		Key(session, name));
	return data.isNull() ? fallback : QString::fromUtf8(data);
}

void SetStringValue(
		not_null<Main::Session*> session,
		std::string_view name,
		const QString &value) {
	Core::App().settings().writePref<QByteArray>(
		Key(session, name),
		value.toUtf8());
	Notify(session);
}

rpl::producer<> Changes(not_null<Main::Session*> session) {
	const auto identity = session->uniqueId();
	return Changed.events()
		| rpl::filter([=](uint64 value) { return value == identity; })
		| rpl::map([](uint64) { return rpl::empty_value(); });
}

} // namespace Lunagram

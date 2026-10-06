#pragma once

#include "lunagram/secure_storage.h"

#include <QtCore/QString>
#include <string_view>

namespace Main {
class Session;
} // namespace Main

namespace Lunagram {

[[nodiscard]] bool ReferenceDesignEnabled();

enum class Flag {
	PreserveDeleted,
	RecordEdits,
	Journal,
	Glass,
	Emergency,
	LocalRating,
	LocalAnonymous,
	LocalVerification,
};

[[nodiscard]] bool Enabled(not_null<Main::Session*> session, Flag flag);
void SetEnabled(not_null<Main::Session*> session, Flag flag, bool enabled);
[[nodiscard]] int IntValue(
	not_null<Main::Session*> session,
	std::string_view name,
	int fallback = 0);
void SetIntValue(
	not_null<Main::Session*> session,
	std::string_view name,
	int value);
[[nodiscard]] QString StringValue(
	not_null<Main::Session*> session,
	std::string_view name,
	const QString &fallback = {});
void SetStringValue(
	not_null<Main::Session*> session,
	std::string_view name,
	const QString &value);
[[nodiscard]] rpl::producer<> Changes(not_null<Main::Session*> session);

} // namespace Lunagram

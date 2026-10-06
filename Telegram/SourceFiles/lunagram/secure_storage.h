#pragma once

#include <QtCore/QByteArray>
#include <QtCore/QString>

namespace Main {
class Session;
} // namespace Main

namespace Lunagram {

[[nodiscard]] bool PrivateExists(
	not_null<Main::Session*> session,
	const QString &name);
[[nodiscard]] QByteArray ReadPrivate(
	not_null<Main::Session*> session,
	const QString &name);
[[nodiscard]] bool WritePrivate(
	not_null<Main::Session*> session,
	const QString &name,
	const QByteArray &payload);

} // namespace Lunagram

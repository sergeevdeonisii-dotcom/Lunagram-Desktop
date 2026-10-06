#include "lunagram/secure_storage.h"

#include "lunagram/private_codec.h"
#include "main/main_session.h"
#include "settings.h"

#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QRegularExpression>
#include <QtCore/QSaveFile>
#include <optional>

namespace Lunagram {
namespace {

constexpr auto kMaximumBytes = PrivateCodec::MaximumBytes;

QString Path(not_null<Main::Session*> session, const QString &name) {
	const auto valid = QRegularExpression(u"^[a-z][a-z0-9_-]{0,63}$"_q);
	if (cWorkingDir().isEmpty() || !valid.match(name).hasMatch()) {
		return {};
	}
	return QDir(cWorkingDir()).filePath(
		u"tdata/lunagram/%1/%2.bin"_q
			.arg(session->uniqueId())
			.arg(name));
}

QByteArray Entropy(not_null<Main::Session*> session, const QString &name) {
	return u"Lunagram/1/%1/%2"_q.arg(session->uniqueId()).arg(name).toUtf8();
}

std::optional<QByteArray> Read(
		const QString &path,
		const QByteArray &entropy) {
	auto file = QFile(path);
	if (!file.open(QIODevice::ReadOnly)
		|| file.size() > kMaximumBytes + 65536) {
		return std::nullopt;
	}
	return PrivateCodec::Unprotect(file.readAll(), entropy);
}

} // namespace

bool PrivateExists(
		not_null<Main::Session*> session,
		const QString &name) {
	const auto path = Path(session, name);
	return !path.isEmpty() && QFileInfo::exists(path);
}

QByteArray ReadPrivate(
		not_null<Main::Session*> session,
		const QString &name) {
	const auto path = Path(session, name);
	return path.isEmpty()
		? QByteArray()
		: Read(path, Entropy(session, name)).value_or(QByteArray());
}

bool WritePrivate(
		not_null<Main::Session*> session,
		const QString &name,
		const QByteArray &payload) {
	const auto path = Path(session, name);
	if (path.isEmpty() || payload.size() > kMaximumBytes) {
		return false;
	}
	const auto entropy = Entropy(session, name);
	if (QFileInfo::exists(path) && !Read(path, entropy).has_value()) {
		return false;
	}
	const auto sealed = PrivateCodec::Protect(payload, entropy);
	if (!sealed || !QDir().mkpath(QFileInfo(path).absolutePath())) {
		return false;
	}
	auto file = QSaveFile(path);
	return file.open(QIODevice::WriteOnly)
		&& file.write(*sealed) == sealed->size()
		&& file.commit();
}

} // namespace Lunagram

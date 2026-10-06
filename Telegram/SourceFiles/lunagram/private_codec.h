#pragma once

#include <QtCore/QByteArray>
#include <optional>

namespace Lunagram::PrivateCodec {

inline constexpr auto MaximumBytes = qsizetype(64 * 1024 * 1024);
inline constexpr auto MaximumSealedBytes = MaximumBytes + 65536;

[[nodiscard]] std::optional<QByteArray> Protect(
	const QByteArray &payload,
	const QByteArray &entropy);
[[nodiscard]] std::optional<QByteArray> Unprotect(
	const QByteArray &sealed,
	const QByteArray &entropy);

} // namespace Lunagram::PrivateCodec

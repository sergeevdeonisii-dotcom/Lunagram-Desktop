#include "lunagram/private_codec.h"

#include <limits>
#include <memory>

#ifdef Q_OS_WIN
#include <windows.h>
#include <wincrypt.h>
#endif // Q_OS_WIN

namespace Lunagram::PrivateCodec {
namespace {

const auto kMagic = QByteArray("LUNADP01", 8);

#ifdef Q_OS_WIN
DATA_BLOB Blob(const QByteArray &bytes) {
	return DATA_BLOB{
		DWORD(bytes.size()),
		reinterpret_cast<BYTE*>(const_cast<char*>(bytes.constData())),
	};
}
#endif // Q_OS_WIN

} // namespace

std::optional<QByteArray> Protect(
		const QByteArray &payload,
		const QByteArray &entropy) {
	if (payload.size() > MaximumBytes
		|| entropy.size() > std::numeric_limits<quint32>::max()) {
		return std::nullopt;
	}
#ifdef Q_OS_WIN
	auto input = Blob(payload);
	auto aad = Blob(entropy);
	auto output = DATA_BLOB{};
	if (!CryptProtectData(
		&input,
		L"Lunagram private data",
		&aad,
		nullptr,
		nullptr,
		CRYPTPROTECT_UI_FORBIDDEN,
		&output)) {
		return std::nullopt;
	}
	const auto release = std::unique_ptr<void, decltype(&LocalFree)>(
		output.pbData,
		&LocalFree);
	if (output.cbData > MaximumSealedBytes - kMagic.size()) {
		return std::nullopt;
	}
	return kMagic + QByteArray(
		reinterpret_cast<const char*>(output.pbData),
		output.cbData);
#else // Q_OS_WIN
	return std::nullopt;
#endif // Q_OS_WIN
}

std::optional<QByteArray> Unprotect(
		const QByteArray &sealed,
		const QByteArray &entropy) {
	if (!sealed.startsWith(kMagic)
		|| sealed.size() > MaximumSealedBytes
		|| entropy.size() > std::numeric_limits<quint32>::max()) {
		return std::nullopt;
	}
#ifdef Q_OS_WIN
	auto input = DATA_BLOB{
		DWORD(sealed.size() - kMagic.size()),
		reinterpret_cast<BYTE*>(const_cast<char*>(
			sealed.constData() + kMagic.size())),
	};
	auto aad = Blob(entropy);
	auto output = DATA_BLOB{};
	if (!CryptUnprotectData(
		&input,
		nullptr,
		&aad,
		nullptr,
		nullptr,
		CRYPTPROTECT_UI_FORBIDDEN,
		&output)) {
		return std::nullopt;
	}
	const auto release = std::unique_ptr<void, decltype(&LocalFree)>(
		output.pbData,
		&LocalFree);
	if (output.cbData > MaximumBytes) {
		return std::nullopt;
	}
	return QByteArray(
		reinterpret_cast<const char*>(output.pbData),
		output.cbData);
#else // Q_OS_WIN
	return std::nullopt;
#endif // Q_OS_WIN
}

} // namespace Lunagram::PrivateCodec

#include "lunagram/private_codec.h"

#include <QtCore/QCoreApplication>
#include <array>
#include <iostream>

namespace {

using Lunagram::PrivateCodec::Protect;
using Lunagram::PrivateCodec::Unprotect;

int Failed = 0;
int Passed = 0;

void Check(bool result, const char *name) {
	if (result) {
		++Passed;
		std::cout << "PASS " << name << '\n';
	} else {
		++Failed;
		std::cerr << "FAIL " << name << '\n';
	}
}

bool RoundTrip(const QByteArray &payload, const QByteArray &entropy) {
	const auto sealed = Protect(payload, entropy);
	if (!sealed) {
		return false;
	}
	const auto plain = Unprotect(*sealed, entropy);
	return plain && *plain == payload;
}

void CodecCases() {
	const auto entropy = QByteArray("Lunagram/1/123/notification_journal");
	auto binary = QByteArray();
	for (auto i = 0; i != 256; ++i) {
		binary.append(char(i));
	}
	Check(RoundTrip(binary, entropy), "binary roundtrip with embedded zeros");
	Check(RoundTrip(QByteArray(), entropy), "empty payload roundtrip");
	Check(RoundTrip(binary, QByteArray()), "empty entropy roundtrip");
	const auto sealed = Protect(binary, entropy);
	Check(sealed.has_value(), "native protection succeeds");
	if (!sealed) {
		return;
	}
	Check(sealed->startsWith("LUNADP01"), "existing format magic preserved");
	Check(!Unprotect(*sealed, QByteArray("Lunagram/1/123/chat_note")),
		"different role entropy rejected");
	Check(!Unprotect(*sealed, QByteArray("Lunagram/1/124/notification_journal")),
		"different account entropy rejected");
	Check(!Unprotect(*sealed, QByteArray()), "missing entropy rejected");
	Check(!Unprotect(QByteArray(), entropy), "empty sealed data rejected");
	Check(!Unprotect(QByteArray("LUNADP01"), entropy), "magic alone rejected");
	auto badMagic = *sealed;
	badMagic[0] = 'X';
	Check(!Unprotect(badMagic, entropy), "bad magic rejected");
	const auto positions = std::array{
		qsizetype(8),
		sealed->size() / 2,
		sealed->size() - 1,
	};
	auto tamperRejected = true;
	for (const auto position : positions) {
		auto tampered = *sealed;
		tampered[position] = char(tampered.at(position) ^ 0x80);
		tamperRejected = !Unprotect(tampered, entropy) && tamperRejected;
	}
	Check(tamperRejected, "header body and signature tampering rejected");
	auto truncationRejected = true;
	for (auto length = qsizetype(0); length < sealed->size(); ++length) {
		truncationRejected = !Unprotect(sealed->first(length), entropy)
			&& truncationRejected;
	}
	Check(truncationRejected, "all shorter sealed prefixes rejected");
	{
		const auto oversize = QByteArray(
			Lunagram::PrivateCodec::MaximumBytes + 1,
			'x');
		Check(!Protect(oversize, entropy), "payload above 64 MiB rejected");
	}
	{
		auto oversize = QByteArray(
			Lunagram::PrivateCodec::MaximumSealedBytes + 1,
			'x');
		oversize.replace(0, 8, "LUNADP01");
		Check(!Unprotect(oversize, entropy), "sealed size bound rejected");
	}
	{
		const auto maximum = QByteArray(
			Lunagram::PrivateCodec::MaximumBytes,
			'L');
		Check(RoundTrip(maximum, entropy), "64 MiB boundary roundtrip");
	}
}

} // namespace

int main(int argc, char *argv[]) {
	const auto application = QCoreApplication(argc, argv);
	CodecCases();
	std::cout << Passed << " passed, " << Failed << " failed.\n";
	return Failed ? 1 : 0;
}

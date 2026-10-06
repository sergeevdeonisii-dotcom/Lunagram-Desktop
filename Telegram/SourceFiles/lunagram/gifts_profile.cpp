#include "lunagram/gifts_profile.h"

#include "data/data_peer_values.h"
#include "data/data_user.h"
#include "lang/lang_keys.h"
#include "lunagram/chat_vault.h"
#include "lunagram/lunagram_settings.h"
#include "main/main_session.h"
#include "ui/controls/userpic_button.h"
#include "ui/layers/generic_box.h"
#include "ui/layers/show.h"
#include "ui/text/format_values.h"
#include "ui/text/text_utilities.h"
#include "ui/widgets/labels.h"

#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QRandomGenerator>
#include <array>

#include "styles/style_boxes.h"
#include "styles/style_info.h"
#include "styles/style_layers.h"
#include "styles/style_premium.h"

namespace Lunagram {
namespace {

constexpr auto kThresholds = std::array<int, 101>{
	0,
	1, 5000, 12000, 19000, 27000, 36000, 46000, 57000, 68000, 81000,
	94000, 107000, 120000, 133000, 146000, 160000, 173000, 186000, 199000, 212000,
	225000, 238000, 251000, 265000, 278000, 291000, 304000, 317000, 330000, 343000,
	356000, 370000, 383000, 396000, 409000, 422000, 435000, 448000, 461000, 475000,
	488000, 501000, 514000, 527000, 540000, 553000, 566000, 580000, 593000, 606000,
	619000, 632000, 645000, 658000, 671000, 685000, 698000, 711000, 724000, 737000,
	750000, 763000, 776000, 790000, 803000, 816000, 829000, 842000, 855000, 868000,
	881000, 885000, 908000, 921000, 934000, 947000, 960000, 973000, 986000, 1000000,
	1400000, 1960000, 2744000, 3842000, 5379000, 7531000, 10543000, 14760000,
	20664000, 28930000, 40502000, 56703000, 79384000, 111138949, 155596417,
	217837627, 304976379, 426972112, 597768211, 836885652,
};

rpl::event_stream<std::pair<uint64, uint64>> PinsChanged;

QString PinsName(not_null<PeerData*> peer) {
	return u"gift_pins_"_q + QString::number(peer->id.value);
}

rpl::producer<> SettingsValue(not_null<Main::Session*> session) {
	return rpl::single(rpl::empty) | rpl::then(Changes(session));
}

} // namespace

QString GiftIdentity(const Data::SavedStarGift &gift) {
	if (gift.manageId) {
		return gift.manageId.isUser()
			? u"message:"_q + QString::number(gift.manageId.userMessageId().bare)
			: u"saved:"_q + QString::number(gift.manageId.chatSavedId());
	} else if (gift.info.unique && !gift.info.unique->slug.isEmpty()) {
		return u"slug:"_q + gift.info.unique->slug;
	}
	return u"gift:%1:%2:%3"_q
		.arg(gift.info.id)
		.arg(gift.date)
		.arg(gift.giftNum);
}

base::flat_set<QString> GiftPins(not_null<PeerData*> peer) {
	auto result = base::flat_set<QString>();
	const auto document = QJsonDocument::fromJson(
		ReadPrivate(&peer->session(), PinsName(peer)));
	if (document.isArray()) {
		for (const auto &value : document.array()) {
			if (value.isString() && !value.toString().isEmpty()) {
				result.emplace(value.toString());
			}
		}
	}
	return result;
}

rpl::producer<> GiftPinChanges(not_null<PeerData*> peer) {
	const auto identity = std::pair<uint64, uint64>{
		peer->session().uniqueId(),
		peer->id.value,
	};
	return PinsChanged.events()
		| rpl::filter([=](const auto &value) { return value == identity; })
		| rpl::to_empty;
}

bool SaveGiftPins(
		not_null<PeerData*> peer,
		const base::flat_set<QString> &pins) {
	const auto existing = ReadPrivate(&peer->session(), PinsName(peer));
	if (!existing.isEmpty()) {
		const auto document = QJsonDocument::fromJson(existing);
		if (!document.isArray()
			|| ranges::any_of(document.array(), [](const auto &value) {
				return !value.isString();
			})) {
			return false;
		}
	}
	auto array = QJsonArray();
	for (const auto &pin : pins) {
		array.push_back(pin);
	}
	if (!WritePrivate(
		&peer->session(),
		PinsName(peer),
		QJsonDocument(array).toJson(QJsonDocument::Compact))) {
		return false;
	}
	PinsChanged.fire({ peer->session().uniqueId(), peer->id.value });
	return true;
}

Data::StarsRating DisplayRating(
		not_null<PeerData*> peer,
		Data::StarsRating original) {
	const auto session = &peer->session();
	if (!peer->isSelf() || !Enabled(session, Flag::LocalRating)) {
		return original;
	}
	const auto level = std::clamp(IntValue(session, "rating_level", 1), 1, 100);
	const auto current = kThresholds[level];
	if (level == 100) {
		return { level, current, current, 0 };
	}
	auto progress = IntValue(session, "rating_progress", 0);
	if (progress < 1 || progress > 999) {
		progress = QRandomGenerator::global()->bounded(200, 851);
		SetIntValue(session, "rating_progress", progress);
	}
	const auto next = kThresholds[level + 1];
	const auto stars = current + std::max(
		1,
		int((int64(next) - current) * progress / 1000));
	return { level, stars, current, next };
}

rpl::producer<Data::StarsRating> DisplayRatingValue(
		not_null<PeerData*> peer) {
	return rpl::combine(
		Data::StarsRatingValue(peer),
		SettingsValue(&peer->session())
	) | rpl::map([=](Data::StarsRating original, auto) {
		return DisplayRating(peer, original);
	});
}

bool HasLocalAnonymousNumber(not_null<UserData*> user) {
	return user->isSelf() && Enabled(&user->session(), Flag::LocalAnonymous);
}

QString LocalAnonymousNumber(not_null<Main::Session*> session) {
	const auto value = StringValue(session, "anonymous_number", u"00000000"_q);
	auto digits = QString();
	for (const auto ch : value) {
		if (ch >= QChar('0') && ch <= QChar('9') && digits.size() < 8) {
			digits.append(ch);
		}
	}
	return u"888"_q + digits.leftJustified(8, QChar('0'));
}

rpl::producer<TextWithEntities> ProfilePhoneValue(
		not_null<UserData*> user,
		rpl::producer<TextWithEntities> original) {
	return rpl::combine(
		std::move(original),
		SettingsValue(&user->session())
	) | rpl::map([=](const TextWithEntities &value, auto) {
		return HasLocalAnonymousNumber(user)
			? tr::link(tr::marked(Ui::FormatPhone(
				LocalAnonymousNumber(&user->session()))))
			: value;
	});
}

rpl::producer<TextWithEntities> LocalVerificationValue(
		not_null<UserData*> user) {
	return rpl::combine(
		SettingsValue(&user->session()),
		tr::lng_lunagram_verification_local_text()
	) | rpl::map([=](auto, const QString &text) {
		return (user->isSelf()
			&& Enabled(&user->session(), Flag::LocalVerification))
			? tr::marked(text)
			: tr::marked();
	});
}

void ShowAnonymousNumber(
		std::shared_ptr<Ui::Show> show,
		not_null<UserData*> user) {
	if (!HasLocalAnonymousNumber(user)
		|| IsChatLocked(&user->session(), user->id)) {
		return;
	}
	const auto session = &user->session();
	auto price = IntValue(session, "anonymous_price", 0);
	if (price < 1000 || price > 10000) {
		price = QRandomGenerator::global()->bounded(1000, 10001);
		SetIntValue(session, "anonymous_price", price);
	}
	const auto number = Ui::FormatPhone(LocalAnonymousNumber(session));
	show->show(Box([=](not_null<Ui::GenericBox*> box) {
		box->setTitle(tr::lng_lunagram_anonymous_sheet_title());
		box->setWidth(st::boxWideWidth);
		VaultChanges(session) | rpl::on_next([=] {
			box->closeBox();
		}, box->lifetime());
		box->addRow(
			object_ptr<Ui::UserpicButton>(
				box,
				user,
				st::premiumGiftsUserpicButton),
			st::boxRowPadding,
			style::al_top)->setAttribute(Qt::WA_TransparentForMouseEvents);
		box->addRow(object_ptr<Ui::FlatLabel>(
			box,
			rpl::single(user->name()),
			st::boxLabel));
		box->addRow(object_ptr<Ui::FlatLabel>(
			box,
			rpl::single(number),
			st::boxLabel));
		box->addRow(object_ptr<Ui::FlatLabel>(
			box,
			tr::lng_lunagram_anonymous_sheet_price(
				lt_cost,
				rpl::single(QString::number(price))),
			st::boxLabel));
		box->addRow(object_ptr<Ui::FlatLabel>(
			box,
			tr::lng_lunagram_anonymous_sheet_description(),
			st::boxLabel));
		box->addButton(tr::lng_profile_copy_phone(), [=] {
			TextUtilities::SetClipboardText({ number });
			box->closeBox();
		});
		box->addButton(tr::lng_close(), [=] { box->closeBox(); });
	}));
}

} // namespace Lunagram

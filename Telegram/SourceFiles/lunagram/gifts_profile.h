#pragma once

#include "base/flat_set.h"
#include "data/data_peer_common.h"
#include "data/data_star_gift.h"

class UserData;

namespace Ui {
class Show;
} // namespace Ui

namespace Lunagram {

[[nodiscard]] QString GiftIdentity(const Data::SavedStarGift &gift);
[[nodiscard]] base::flat_set<QString> GiftPins(not_null<PeerData*> peer);
[[nodiscard]] rpl::producer<> GiftPinChanges(not_null<PeerData*> peer);
[[nodiscard]] bool SaveGiftPins(
	not_null<PeerData*> peer,
	const base::flat_set<QString> &pins);
[[nodiscard]] Data::StarsRating DisplayRating(
	not_null<PeerData*> peer,
	Data::StarsRating original);
[[nodiscard]] rpl::producer<Data::StarsRating> DisplayRatingValue(
	not_null<PeerData*> peer);
[[nodiscard]] bool HasLocalAnonymousNumber(not_null<UserData*> user);
[[nodiscard]] QString LocalAnonymousNumber(not_null<Main::Session*> session);
[[nodiscard]] rpl::producer<TextWithEntities> ProfilePhoneValue(
	not_null<UserData*> user,
	rpl::producer<TextWithEntities> original);
[[nodiscard]] rpl::producer<TextWithEntities> LocalVerificationValue(
	not_null<UserData*> user);
void ShowAnonymousNumber(
	std::shared_ptr<Ui::Show> show,
	not_null<UserData*> user);

} // namespace Lunagram

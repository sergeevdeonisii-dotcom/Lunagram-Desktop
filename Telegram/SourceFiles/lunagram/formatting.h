#pragma once

struct TextWithEntities;

namespace Main {
class Session;
} // namespace Main

namespace Lunagram {

void ApplyAutomaticFormatting(
	not_null<Main::Session*> session,
	TextWithEntities &text);

} // namespace Lunagram

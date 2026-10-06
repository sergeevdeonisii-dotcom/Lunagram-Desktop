#include "lunagram/formatting.h"

#include "lunagram/lunagram_settings.h"
#include "ui/text/text_entity.h"

#include <algorithm>
#include <vector>

namespace Lunagram {
namespace {

struct Interval {
	int from = 0;
	int till = 0;
};

EntityType FormattingType(int value) {
	switch (value) {
	case 1: return EntityType::Bold;
	case 2: return EntityType::Italic;
	case 3: return EntityType::Code;
	case 4: return EntityType::Underline;
	case 5: return EntityType::StrikeOut;
	case 6: return EntityType::Blockquote;
	default: return EntityType::Invalid;
	}
}

bool IsProtected(EntityType existing, EntityType selected) {
	return selected == EntityType::Code
		|| existing == EntityType::Code
		|| existing == EntityType::Pre
		|| existing == EntityType::Blockquote
		|| existing == selected
		|| (selected == EntityType::Bold && existing == EntityType::Semibold);
}

std::vector<Interval> ProtectedIntervals(
		const TextWithEntities &text,
		EntityType selected) {
	auto result = std::vector<Interval>();
	for (const auto &entity : text.entities) {
		if (!entity.validForText(text.text.size())
			|| !IsProtected(entity.type(), selected)) {
			continue;
		}
		auto from = entity.offset();
		auto till = from + entity.length();
		if (selected == EntityType::Blockquote) {
			while (from > 0 && text.text[from - 1] != '\n') {
				--from;
			}
			while (till < text.text.size() && text.text[till] != '\n') {
				++till;
			}
		}
		result.push_back({ from, till });
	}
	ranges::sort(result, {}, &Interval::from);
	auto merged = std::vector<Interval>();
	for (const auto interval : result) {
		if (!merged.empty() && merged.back().till >= interval.from) {
			merged.back().till = std::max(merged.back().till, interval.till);
		} else {
			merged.push_back(interval);
		}
	}
	return merged;
}

void AddFormatting(
		TextWithEntities &text,
		EntityType selected,
		Interval interval) {
	while (interval.from < interval.till && text.text[interval.from].isSpace()) {
		++interval.from;
	}
	while (interval.till > interval.from && text.text[interval.till - 1].isSpace()) {
		--interval.till;
	}
	if (interval.from == interval.till) {
		return;
	}
	const auto type = (selected == EntityType::Code
		&& text.text.mid(interval.from, interval.till - interval.from).contains('\n'))
		? EntityType::Pre
		: selected;
	text.entities.push_back(EntityInText(
		type,
		interval.from,
		interval.till - interval.from));
}

} // namespace

void ApplyAutomaticFormatting(
		not_null<Main::Session*> session,
		TextWithEntities &text) {
	const auto selected = FormattingType(IntValue(session, "formatting"));
	if (selected == EntityType::Invalid || text.text.isEmpty()) {
		return;
	}
	const auto protectedIntervals = ProtectedIntervals(text, selected);
	auto from = 0;
	for (const auto interval : protectedIntervals) {
		AddFormatting(text, selected, { from, interval.from });
		from = interval.till;
	}
	AddFormatting(text, selected, { from, int(text.text.size()) });
	ranges::stable_sort(text.entities, [](const auto &left, const auto &right) {
		return (left.offset() != right.offset())
			? (left.offset() < right.offset())
			: (left.length() > right.length());
	});
}

} // namespace Lunagram

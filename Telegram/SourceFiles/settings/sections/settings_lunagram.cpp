#include "settings/sections/settings_lunagram.h"

#include "base/weak_ptr.h"
#include "lang/lang_keys.h"
#include "lunagram/chat_vault.h"
#include "lunagram/local_tools.h"
#include "lunagram/lunagram_settings.h"
#include "main/main_session.h"
#include "settings/settings_builder.h"
#include "settings/settings_common_session.h"
#include "settings/sections/settings_main.h"
#include "ui/layers/generic_box.h"
#include "ui/vertical_list.h"
#include "ui/widgets/checkbox.h"
#include "ui/widgets/fields/input_field.h"
#include "ui/widgets/labels.h"
#include "window/themes/window_theme.h"
#include "window/window_session_controller.h"

#include <QtCore/QRegularExpression>
#include <QtCore/QUrl>
#include <QtGui/QDesktopServices>

#include "styles/style_boxes.h"
#include "styles/style_layers.h"
#include "styles/style_menu_icons.h"
#include "styles/style_settings.h"

namespace Settings {
namespace {

using namespace Builder;

enum class Page { General, Advanced, Messages, Profile, LocalData };
struct Choice {
	int value = 0;
	QString text;
};

const tr::phrase<> &Title(Page page) {
	switch (page) {
	case Page::General: return tr::lng_lunagram_settings;
	case Page::Advanced: return tr::lng_lunagram_advanced;
	case Page::Messages: return tr::lng_lunagram_messages;
	case Page::Profile: return tr::lng_lunagram_profile;
	case Page::LocalData: return tr::lng_lunagram_local_data;
	}
	Unexpected("Lunagram settings page.");
}

const BuildHelper &Meta(Page page);
void BuildContent(Page page, SectionBuilder &builder);

template <Page Kind>
class Panel final : public Section<Panel<Kind>> {
public:
	Panel(
		QWidget *parent,
		not_null<Window::SessionController*> controller);

	rpl::producer<QString> title() override;

};

template <Page Kind>
Panel<Kind>::Panel(
	QWidget *parent,
	not_null<Window::SessionController*> controller)
: Section<Panel<Kind>>(parent, controller) {
	const auto content = Ui::CreateChild<Ui::VerticalLayout>(this);
	this->build(content, Meta(Kind).build);
	Ui::ResizeFitChild(this, content);
}

template <Page Kind>
rpl::producer<QString> Panel<Kind>::title() {
	return Title(Kind)();
}

const auto kGeneral = BuildHelper({
	.id = Panel<Page::General>::Id(),
	.parentId = MainId(),
	.title = &Title(Page::General),
	.icon = &st::menuIconPalette,
}, [](SectionBuilder &builder) { BuildContent(Page::General, builder); });
const auto kAdvanced = BuildHelper({
	.id = Panel<Page::Advanced>::Id(),
	.parentId = MainId(),
	.title = &Title(Page::Advanced),
	.icon = &st::menuIconManage,
}, [](SectionBuilder &builder) { BuildContent(Page::Advanced, builder); });
const auto kMessages = BuildHelper({
	.id = Panel<Page::Messages>::Id(),
	.parentId = Panel<Page::Advanced>::Id(),
	.title = &Title(Page::Messages),
	.icon = &st::menuIconChatBubble,
}, [](SectionBuilder &builder) { BuildContent(Page::Messages, builder); });
const auto kProfile = BuildHelper({
	.id = Panel<Page::Profile>::Id(),
	.parentId = Panel<Page::Advanced>::Id(),
	.title = &Title(Page::Profile),
	.icon = &st::menuIconProfile,
}, [](SectionBuilder &builder) { BuildContent(Page::Profile, builder); });
const auto kLocalData = BuildHelper({
	.id = Panel<Page::LocalData>::Id(),
	.parentId = Panel<Page::Advanced>::Id(),
	.title = &Title(Page::LocalData),
	.icon = &st::menuIconArchive,
}, [](SectionBuilder &builder) { BuildContent(Page::LocalData, builder); });

const BuildHelper &Meta(Page page) {
	switch (page) {
	case Page::General: return kGeneral;
	case Page::Advanced: return kAdvanced;
	case Page::Messages: return kMessages;
	case Page::Profile: return kProfile;
	case Page::LocalData: return kLocalData;
	}
	Unexpected("Lunagram settings metadata.");
}

void Toggle(
		SectionBuilder &builder,
		QString id,
		const tr::phrase<> &title,
		Lunagram::Flag flag) {
	const auto session = builder.session();
	const auto checkbox = builder.addCheckbox({
		.id = std::move(id),
		.title = title(),
		.checked = Lunagram::Enabled(session, flag),
	});
	if (!checkbox) {
		return;
	}
	checkbox->checkedChanges() | rpl::on_next([=](bool enabled) {
		Lunagram::SetEnabled(session, flag, enabled);
	}, checkbox->lifetime());
	Lunagram::Changes(session) | rpl::on_next([=] {
		checkbox->setChecked(
			Lunagram::Enabled(session, flag),
			Ui::Checkbox::NotifyAboutChange::DontNotify);
	}, checkbox->lifetime());
}

void Action(
		SectionBuilder &builder,
		QString id,
		const tr::phrase<> &title,
		Fn<void(not_null<Window::SessionController*>)> callback) {
	const auto controller = builder.controller();
	builder.addButton({
		.id = std::move(id),
		.title = title(),
		.onClick = [=] { if (controller) { callback(controller); } },
	});
}

void Select(
		SectionBuilder &builder,
		std::string_view name,
		const tr::phrase<> &title,
		int fallback,
		std::vector<Choice> choices) {
	const auto session = builder.session();
	const auto controller = builder.controller();
	const auto key = std::string(name);
	const auto label = [=] {
		const auto current = Lunagram::IntValue(session, key, fallback);
		for (const auto &choice : choices) {
			if (choice.value == current) {
				return choice.text;
			}
		}
		return QString();
	};
	builder.addButton({
		.id = u"lunagram/"_q + QString::fromStdString(key),
		.title = title(),
		.label = rpl::single(rpl::empty)
			| rpl::then(Lunagram::Changes(session))
			| rpl::map(label),
		.onClick = [=, title = &title] {
			if (!controller) {
				return;
			}
			const auto weak = base::make_weak(controller);
			const auto identity = session->uniqueId();
			controller->show(Box([=](not_null<Ui::GenericBox*> box) {
				box->setTitle((*title)());
				const auto group = std::make_shared<Ui::RadiobuttonGroup>(
					Lunagram::IntValue(session, key, fallback));
				for (const auto &choice : choices) {
					box->addRow(object_ptr<Ui::Radiobutton>(
						box, group, choice.value, choice.text, st::settingsSendType),
						st::settingsSendTypePadding);
				}
				group->setChangedCallback([=](int value) {
					const auto strong = weak.get();
					if (strong && strong->session().uniqueId() == identity) {
						Lunagram::SetIntValue(&strong->session(), key, value);
					}
					box->closeBox();
				});
				box->addButton(tr::lng_cancel(), [=] { box->closeBox(); });
			}));
		},
	});
}

void ShowProfileValue(
		not_null<Window::SessionController*> controller,
		bool number) {
	const auto weak = base::make_weak(controller);
	const auto session = &controller->session();
	const auto identity = session->uniqueId();
	controller->show(Box([=](not_null<Ui::GenericBox*> box) {
		box->setTitle(number
			? tr::lng_lunagram_anonymous_digits()
			: tr::lng_lunagram_rating_level());
		box->addRow(object_ptr<Ui::FlatLabel>(box,
			number ? tr::lng_lunagram_anonymous_digits_description()
				: tr::lng_lunagram_rating_local_description(), st::boxLabel));
		const auto field = box->addRow(object_ptr<Ui::InputField>(
			box, st::defaultInputField, Ui::InputField::Mode::SingleLine));
		field->setMaxLength(number ? 8 : 3);
		field->setText(number
			? Lunagram::StringValue(session, "anonymous_number", u"00000000"_q)
			: QString::number(Lunagram::IntValue(session, "rating_level", 1)));
		box->addButton(tr::lng_settings_save(), [=] {
			const auto strong = weak.get();
			if (!strong || strong->session().uniqueId() != identity) {
				box->closeBox();
				return;
			}
			const auto text = field->getLastText().trimmed();
			auto valid = false;
			const auto level = text.toInt(&valid);
			if ((number && !QRegularExpression(u"^[0-9]{8}$"_q).match(text).hasMatch())
				|| (!number && (!valid || level < 1 || level > 100))) {
				field->showError();
				return;
			}
			if (number) {
				Lunagram::SetStringValue(&strong->session(), "anonymous_number", text);
			} else {
				Lunagram::SetIntValue(&strong->session(), "rating_progress", 0);
				Lunagram::SetIntValue(&strong->session(), "rating_level", level);
			}
			box->closeBox();
		});
		box->addButton(tr::lng_cancel(), [=] { box->closeBox(); });
	}));
}

void BuildContent(Page page, SectionBuilder &builder) {
	using Flag = Lunagram::Flag;
	builder.addSkip();
	if (page == Page::General) {
		builder.addSubsectionTitle(tr::lng_lunagram_appearance());
		Toggle(builder, u"lunagram/glass"_q, tr::lng_lunagram_glass, Flag::Glass);
		Select(builder, "glass_opacity", tr::lng_lunagram_glass_opacity, 75,
			{ { 35, u"35%"_q }, { 50, u"50%"_q }, { 75, u"75%"_q }, { 95, u"95%"_q } });
		builder.addDividerText(tr::lng_lunagram_glass_description());
		Action(builder, u"lunagram/theme-glass"_q, tr::lng_lunagram_theme_glass, [](auto controller) {
			if (Window::Theme::Apply(u":/lunagram/themes/glass.tdesktop-theme"_q)) {
				Window::Theme::KeepApplied();
			} else {
				controller->showToast(tr::lng_lunagram_theme_failed(tr::now));
			}
		});
		Action(builder, u"lunagram/theme-black"_q, tr::lng_lunagram_theme_black, [](auto controller) {
			if (Window::Theme::Apply(u":/lunagram/themes/black.tdesktop-theme"_q)) {
				Window::Theme::KeepApplied();
			} else {
				controller->showToast(tr::lng_lunagram_theme_failed(tr::now));
			}
		});
		Action(builder, u"lunagram/theme-pearl"_q, tr::lng_lunagram_theme_pearl, [](auto controller) {
			if (Window::Theme::Apply(u":/lunagram/themes/pearl.tdesktop-theme"_q)) {
				Window::Theme::KeepApplied();
			} else {
				controller->showToast(tr::lng_lunagram_theme_failed(tr::now));
			}
		});
		Select(builder, "typing_mode", tr::lng_lunagram_typing_animation, 0, {
			{ 0, tr::lng_lunagram_disabled(tr::now) },
			{ 1, tr::lng_lunagram_typing_letters(tr::now) },
			{ 2, tr::lng_lunagram_typing_words(tr::now) },
		});
		Select(builder, "typing_speed", tr::lng_lunagram_typing_speed, 1, {
			{ 0, tr::lng_lunagram_slow(tr::now) },
			{ 1, tr::lng_lunagram_normal(tr::now) },
			{ 2, tr::lng_lunagram_fast(tr::now) },
		});
		builder.addDivider();
		Toggle(builder, u"lunagram/low-data"_q, tr::lng_lunagram_low_data, Flag::Emergency);
		builder.addDividerText(tr::lng_lunagram_low_data_description());
		Action(builder, u"lunagram/profiles"_q, tr::lng_lunagram_profiles_title, Lunagram::ShowProfilesBox);
		Action(builder, u"lunagram/updates"_q, tr::lng_lunagram_updates, [](auto) {
			QDesktopServices::openUrl(QUrl(u"https://github.com/sergeevdeonisii-dotcom/Lunagram-Desktop/releases"_q));
		});
		builder.addDividerText(tr::lng_lunagram_updates_description());
	} else if (page == Page::Advanced) {
		builder.addSectionButton({
			.title = Title(Page::Messages)(),
			.targetSection = Panel<Page::Messages>::Id(),
			.icon = { &st::menuIconChatBubble },
		});
		builder.addSectionButton({
			.title = Title(Page::Profile)(),
			.targetSection = Panel<Page::Profile>::Id(),
			.icon = { &st::menuIconProfile },
		});
		builder.addSectionButton({
			.title = Title(Page::LocalData)(),
			.targetSection = Panel<Page::LocalData>::Id(),
			.icon = { &st::menuIconArchive },
		});
		builder.addDividerText(tr::lng_lunagram_advanced_description());
	} else if (page == Page::Messages) {
		Toggle(builder, u"lunagram/keep-deleted"_q, tr::lng_lunagram_keep_deleted, Flag::PreserveDeleted);
		Toggle(builder, u"lunagram/record-edits"_q, tr::lng_lunagram_record_edits, Flag::RecordEdits);
		builder.addDividerText(tr::lng_lunagram_history_description());
		Select(builder, "undo_delay", tr::lng_lunagram_undo_delay, 0, {
			{ 0, tr::lng_lunagram_disabled(tr::now) },
			{ 1000, u"1 s"_q }, { 2000, u"2 s"_q }, { 3000, u"3 s"_q }, { 5000, u"5 s"_q },
		});
		builder.addDividerText(tr::lng_lunagram_undo_description());
		Select(builder, "formatting", tr::lng_lunagram_formatting, 0, {
			{ 0, tr::lng_lunagram_disabled(tr::now) },
			{ 1, tr::lng_lunagram_bold(tr::now) },
			{ 2, tr::lng_lunagram_italic(tr::now) },
			{ 3, tr::lng_lunagram_monospace(tr::now) },
			{ 4, tr::lng_lunagram_underline(tr::now) },
			{ 5, tr::lng_lunagram_strike(tr::now) },
			{ 6, tr::lng_lunagram_quote(tr::now) },
		});
	} else if (page == Page::Profile) {
		Toggle(builder, u"lunagram/local-rating"_q, tr::lng_lunagram_rating_local_title, Flag::LocalRating);
		Action(builder, u"lunagram/rating-level"_q, tr::lng_lunagram_rating_level, [](auto c) { ShowProfileValue(c, false); });
		builder.addDividerText(tr::lng_lunagram_rating_local_description());
		Toggle(builder, u"lunagram/local-number"_q, tr::lng_lunagram_anonymous_local_label, Flag::LocalAnonymous);
		Action(builder, u"lunagram/anonymous-digits"_q, tr::lng_lunagram_anonymous_digits, [](auto c) { ShowProfileValue(c, true); });
		builder.addDividerText(tr::lng_lunagram_anonymous_sheet_description());
		Toggle(builder, u"lunagram/local-marker"_q, tr::lng_lunagram_verification_local_label, Flag::LocalVerification);
		builder.addDividerText(tr::lng_lunagram_verification_local_text());
	} else if (page == Page::LocalData) {
		Toggle(builder, u"lunagram/journal-enabled"_q, tr::lng_lunagram_journal_title, Flag::Journal);
		Action(builder, u"lunagram/journal"_q, tr::lng_lunagram_journal_title, Lunagram::ShowJournalBox);
		builder.addDividerText(tr::lng_lunagram_journal_description());
		Action(builder, u"lunagram/vault"_q, tr::lng_lunagram_vault_title, Lunagram::ShowVaultBox);
		builder.addDivider();
		Action(builder, u"lunagram/export"_q, tr::lng_lunagram_settings_export_title, Lunagram::ExportSettings);
		Action(builder, u"lunagram/import"_q, tr::lng_lunagram_settings_import_title, Lunagram::ImportSettings);
		builder.addDividerText(tr::lng_lunagram_local_data_description());
	}
	builder.addSkip();
}

} // namespace

Type LunagramId() {
	return Panel<Page::General>::Id();
}

Type LunagramAdvancedId() {
	return Panel<Page::Advanced>::Id();
}

} // namespace Settings

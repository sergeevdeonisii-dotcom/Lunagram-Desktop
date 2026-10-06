#pragma once

#include "base/basic_types.h"

#include <QtCore/QRect>
#include <QtCore/QString>
#include <QtGui/QColor>
#include <QtGui/QImage>

class Painter;
class QPainter;
class QWidget;

namespace Ui {
class ChatTheme;
} // namespace Ui

namespace Window {
class SessionController;
} // namespace Window

namespace Lunagram {

struct GlassBackdrop {
	QImage source;
	QImage blurred;
	QRect area;
	float64 scale = 1.;
	bool dark = false;
};

[[nodiscard]] QString ReferenceFontFamily(const QString &preferred);
[[nodiscard]] not_null<Ui::ChatTheme*> ReferenceChatTheme(
	not_null<Window::SessionController*> controller);

void EnsureReferenceAppearance();

[[nodiscard]] const GlassBackdrop &PrepareGlassBackdrop(
	not_null<QWidget*> widget,
	QRect area,
	uint64 revision,
	Fn<void(Painter&, QRect)> paint,
	Ui::ChatTheme *theme = nullptr);
void ClearGlassBackdrop(not_null<QWidget*> widget);

void PaintReferenceBackdrop(
	QPainter &p,
	not_null<Window::SessionController*> controller,
	not_null<Ui::ChatTheme*> theme,
	not_null<QWidget*> widget,
	QRect clip);

void PaintReferenceBackdrop(
	not_null<Window::SessionController*> controller,
	not_null<Ui::ChatTheme*> theme,
	not_null<QWidget*> widget,
	QRect clip);

void PaintGlassPanel(
	QPainter &p,
	QRect bounds,
	QColor background,
	int radius = 0);

void PaintGlassPanel(
	QPainter &p,
	QRect bounds,
	QColor tint,
	const GlassBackdrop &backdrop,
	int radius = 0);

void PaintGlassPanel(
	not_null<Window::SessionController*> controller,
	not_null<Ui::ChatTheme*> theme,
	not_null<QWidget*> widget,
	QPainter &p,
	QRect bounds,
	QColor tint,
	int radius = 0);

} // namespace Lunagram

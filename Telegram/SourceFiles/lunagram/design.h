#pragma once

#include "base/basic_types.h"

#include <QtCore/QRect>
#include <QtGui/QColor>

class QPainter;
class QWidget;

namespace Ui {
class ChatTheme;
} // namespace Ui

namespace Window {
class SessionController;
} // namespace Window

namespace Lunagram {

void EnsureReferenceAppearance();

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
	not_null<Window::SessionController*> controller,
	not_null<Ui::ChatTheme*> theme,
	not_null<QWidget*> widget,
	QPainter &p,
	QRect bounds,
	QColor tint,
	int radius = 0);

} // namespace Lunagram

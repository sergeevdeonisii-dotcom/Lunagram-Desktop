#pragma once

#include <QtCore/QRect>
#include <QtGui/QColor>

class QPainter;

namespace Lunagram {

void EnsureReferenceAppearance();

void PaintGlassPanel(
	QPainter &p,
	QRect bounds,
	QColor background,
	int radius = 0);

} // namespace Lunagram

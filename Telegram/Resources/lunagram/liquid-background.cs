using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Text.RegularExpressions;
using System.Xml;

public static class LiquidBackground {
    public static byte[] Render(string patternPath) {
        var document = new XmlDocument();
        using (var input = File.OpenRead(patternPath))
        using (var gzip = new GZipStream(input, CompressionMode.Decompress)) {
            document.Load(gzip);
        }
        using (var bitmap = new Bitmap(960, 800, PixelFormat.Format32bppArgb))
        using (var graphics = Graphics.FromImage(bitmap)) {
            using (var gradient = new LinearGradientBrush(
                new Rectangle(0, 0, bitmap.Width, bitmap.Height),
                Color.FromArgb(129, 188, 130),
                Color.FromArgb(197, 212, 173),
                LinearGradientMode.Vertical)) {
                gradient.InterpolationColors = new ColorBlend {
                    Colors = new[] {
                        Color.FromArgb(129, 188, 130),
                        Color.FromArgb(162, 200, 153),
                        Color.FromArgb(197, 212, 173)
                    },
                    Positions = new[] { 0f, 0.5f, 1f }
                };
                graphics.FillRectangle(gradient, 0, 0, bitmap.Width, bitmap.Height);
            }
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var patternBrush = new SolidBrush(Color.FromArgb(18, 67, 111, 70))) {
                var paths = new List<GraphicsPath>();
                try {
                    foreach (XmlNode element in document.GetElementsByTagName("path")) {
                        paths.Add(ParsePath(element.Attributes["d"].Value));
                    }
                    for (var top = 0f; top < bitmap.Height; top += 1243.2f) {
                        for (var left = -60f; left < bitmap.Width; left += 604.8f) {
                            var state = graphics.Save();
                            graphics.TranslateTransform(left, top);
                            graphics.ScaleTransform(0.42f, 0.42f);
                            foreach (var path in paths) {
                                graphics.FillPath(patternBrush, path);
                            }
                            graphics.Restore(state);
                        }
                    }
                } finally {
                    foreach (var path in paths) {
                        path.Dispose();
                    }
                }
            }
            using (var output = new MemoryStream()) {
                bitmap.Save(output, ImageFormat.Png);
                return output.ToArray();
            }
        }
    }

    private static GraphicsPath ParsePath(string data) {
        var tokens = Regex.Matches(data, @"[A-Za-z]|[-+]?(?:\d*\.?\d+)(?:[eE][-+]?\d+)?");
        var path = new GraphicsPath(FillMode.Winding);
        var index = 0;
        var command = ' ';
        var previous = ' ';
        var point = PointF.Empty;
        var start = PointF.Empty;
        var control = PointF.Empty;
        while (index < tokens.Count) {
            if (char.IsLetter(tokens[index].Value[0])) {
                command = tokens[index++].Value[0];
            }
            var relative = char.IsLower(command);
            var current = char.ToUpperInvariant(command);
            if (current == 'Z') {
                path.CloseFigure();
                point = start;
                previous = command;
                command = ' ';
                continue;
            }
            if (current == 'M') {
                point = ReadPoint(tokens, ref index, relative ? point : PointF.Empty);
                path.StartFigure();
                start = point;
                previous = command;
                command = relative ? 'l' : 'L';
                continue;
            }
            if (current == 'L' || current == 'H' || current == 'V') {
                var target = point;
                if (current == 'L') {
                    target = ReadPoint(tokens, ref index, relative ? point : PointF.Empty);
                } else if (current == 'H') {
                    target.X = ReadNumber(tokens, ref index) + (relative ? point.X : 0);
                } else {
                    target.Y = ReadNumber(tokens, ref index) + (relative ? point.Y : 0);
                }
                path.AddLine(point, target);
                point = target;
            } else if (current == 'C' || current == 'S') {
                var origin = relative ? point : PointF.Empty;
                var first = point;
                if (current == 'C') {
                    first = ReadPoint(tokens, ref index, origin);
                } else if (char.ToUpperInvariant(previous) == 'C'
                    || char.ToUpperInvariant(previous) == 'S') {
                    first = new PointF(2 * point.X - control.X, 2 * point.Y - control.Y);
                }
                var second = ReadPoint(tokens, ref index, origin);
                var target = ReadPoint(tokens, ref index, origin);
                path.AddBezier(point, first, second, target);
                control = second;
                point = target;
            } else {
                path.Dispose();
                throw new FormatException("Unsupported Telegram pattern command: " + command);
            }
            previous = command;
        }
        return path;
    }

    private static PointF ReadPoint(MatchCollection tokens, ref int index, PointF origin) {
        var x = ReadNumber(tokens, ref index) + origin.X;
        var y = ReadNumber(tokens, ref index) + origin.Y;
        return new PointF(x, y);
    }

    private static float ReadNumber(MatchCollection tokens, ref int index) {
        return float.Parse(tokens[index++].Value, CultureInfo.InvariantCulture);
    }

}

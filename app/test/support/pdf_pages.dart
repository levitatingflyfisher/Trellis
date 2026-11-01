import 'dart:typed_data';

import 'package:intake_core/intake_core.dart';

/// PDF pages laid out by hand, the way PDFium reports them, for tests
/// that need a PDF without PDFium: each line is (x, baseline, text, size).
typedef PdfTestLine = ({double x, double y, String text, double size});

PdfTestLine pdfLine(double x, double y, String text, {double size = 10}) =>
    (x: x, y: y, text: text, size: size);

PdfPageChars pdfPage(List<PdfTestLine> lines) {
  final text = StringBuffer();
  final boxes = <double>[];
  final sizes = <double>[];
  for (final line in lines) {
    final adv = line.size / 2;
    for (var i = 0; i < line.text.length; i++) {
      final x = line.x + i * adv;
      final space = line.text[i] == ' ';
      text.write(line.text[i]);
      boxes.addAll([
        x,
        line.y,
        x + (space ? adv : adv * 0.9),
        space ? line.y : line.y + line.size * 0.7,
      ]);
      sizes.add(line.size);
    }
    text.write('\r\n');
    boxes.addAll(List.filled(8, 0));
    sizes.addAll([line.size, line.size]);
  }
  return PdfPageChars(
      width: 600,
      height: 800,
      text: text.toString(),
      boxes: Float32List.fromList(boxes),
      sizes: Float32List.fromList(sizes));
}

/// A page with a heading and one paragraph.
PdfPageChars pdfProsePage(String heading, List<String> lines) => pdfPage([
      pdfLine(50, 740, heading, size: 18),
      for (var i = 0; i < lines.length; i++) pdfLine(50, 700 - i * 12.0, lines[i]),
    ]);

// Reads lines "id<TAB>text" on stdin and writes "id<TAB>phonemes" with the
// phonemes separated by "|" (a space token is "_"). Training uses this,
// so the voice learns from exactly what the app will say.
import 'dart:convert';
import 'dart:io';

import 'package:korean_g2p/korean_g2p.dart';

Future<void> main() async {
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final tab = line.indexOf('\t');
    if (tab < 0) continue;
    final ps = phonemes(line.substring(tab + 1));
    stdout.writeln('${line.substring(0, tab)}\t'
        '${ps.map((p) => p == ' ' ? '_' : p).join('|')}');
  }
}

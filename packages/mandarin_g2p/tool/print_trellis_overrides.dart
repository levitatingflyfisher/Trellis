import 'dart:convert';

import 'package:mandarin_g2p/mandarin_g2p.dart';

/// Prints Trellis's word readings as JSON, for tool/golden_v2.py.
void main() => print(jsonEncode(trellisPhraseOverrides));

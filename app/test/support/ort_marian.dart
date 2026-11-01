/// The real-model checks' bridge to ONNX Runtime: flutter_onnxruntime
/// reaches the runtime over a platform channel that `flutter test` lacks,
/// so the graphs run in Python (test/support/ort_session_server.py) and
/// everything else is the app's own code. Shared by the English to
/// Japanese and Japanese to English checks.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:trellis/features/reader/translation/marian_types.dart';

/// 1 minus the character edit distance over the longer length.
double textSimilarity(String a, String b) {
  final x = a.runes.toList(), y = b.runes.toList();
  if (x.isEmpty && y.isEmpty) return 1;
  var prev = List<int>.generate(y.length + 1, (j) => j);
  for (var i = 1; i <= x.length; i++) {
    final row = List<int>.filled(y.length + 1, 0)..[0] = i;
    for (var j = 1; j <= y.length; j++) {
      final cost = x[i - 1] == y[j - 1] ? 0 : 1;
      row[j] = [prev[j] + 1, row[j - 1] + 1, prev[j - 1] + cost]
          .reduce((p, q) => p < q ? p : q);
    }
    prev = row;
  }
  final longer = x.length > y.length ? x.length : y.length;
  return 1 - prev[y.length] / longer;
}

class OrtServer {
  final Process _process;
  final StreamIterator<String> _lines;
  final String version;

  OrtServer(this._process, this._lines, this.version);

  static Future<OrtServer> start(
      String python, Map<String, String> sessions) async {
    final script = '${Directory.current.path}/test/support/ort_session_server.py';
    final process = await Process.start(python, [
      '-I',
      script,
      for (final e in sessions.entries) '${e.key}=${e.value}',
    ]);
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    final lines = StreamIterator(process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter()));
    if (!await lines.moveNext()) {
      throw StateError('the ONNX Runtime helper did not start');
    }
    final hello = jsonDecode(lines.current) as Map<String, dynamic>;
    return OrtServer(process, lines, hello['ort'] as String);
  }

  Future<Map<String, dynamic>> ask(Map<String, Object?> request) async {
    _process.stdin.writeln(jsonEncode(request));
    await _process.stdin.flush();
    if (!await _lines.moveNext()) {
      throw StateError('the ONNX Runtime helper stopped');
    }
    return jsonDecode(_lines.current) as Map<String, dynamic>;
  }

  Future<int> live() async => (await ask({'op': 'live'}))['live'] as int;

  Future<void> close() async {
    await _process.stdin.close();
    await _process.exitCode;
  }
}

class OrtRunner implements MarianSessionRunner {
  final OrtServer server;
  final String session;
  OrtRunner(this.server, this.session);

  @override
  Future<Map<String, MTensor>> run(Map<String, MTensor> feeds,
      {Set<String>? fetch}) async {
    final reply = await server.ask({
      'op': 'run',
      'session': session,
      'feeds': {for (final e in feeds.entries) e.key: encodeTensor(e.value)},
      'fetch': fetch?.toList(),
    });
    final outputs = reply['outputs'] as Map<String, dynamic>;
    return {
      for (final e in outputs.entries)
        e.key: decodeTensor(e.value as Map<String, dynamic>),
    };
  }

  @override
  Future<void> release(Iterable<MTensor> tensors) async {
    final ids = [
      for (final t in tensors)
        if (t.handle case final int id) id,
    ];
    if (ids.isEmpty) return;
    await server.ask({'op': 'release', 'handles': ids});
  }
}

Map<String, Object?> encodeTensor(MTensor t) {
  if (t.handle case final int id) return {'handle': id};
  final Uint8List bytes = switch (t.type) {
    MTensorType.int64 => Int64List.fromList([for (final v in t.data) v.toInt()])
        .buffer
        .asUint8List(),
    MTensorType.float32 =>
      Float32List.fromList([for (final v in t.data) v.toDouble()])
          .buffer
          .asUint8List(),
    MTensorType.boolean =>
      Uint8List.fromList([for (final v in t.data) v == 0 ? 0 : 1]),
  };
  return {
    'dtype': t.type.name,
    'shape': t.shape,
    'b64': base64Encode(bytes),
  };
}

MTensor decodeTensor(Map<String, dynamic> m) {
  final type = MTensorType.values.byName(m['dtype'] as String);
  final shape = (m['shape'] as List).cast<int>();
  if (m['handle'] case final int id) return MTensor.handle(id, shape, type);
  final bytes = base64Decode(m['b64'] as String);
  final List<num> data = switch (type) {
    MTensorType.int64 => bytes.buffer.asInt64List(),
    MTensorType.float32 => bytes.buffer.asFloat32List(),
    MTensorType.boolean => bytes,
  };
  return MTensor(data, shape, type);
}

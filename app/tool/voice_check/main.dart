/// The voices on a real device, outside the app: an entry point built on
/// its own (`flutter build apk -t tool/voice_check/main.dart`) that runs
/// Trellis's own engines through the phone's ONNX Runtime plugin, and
/// sends back what they said as WAV, for a speech-recognition check on
/// the desktop.
///
/// The files come from a small server on the desktop
/// (`tool/voice_check/voicecheck_server.py`, reached through `adb reverse tcp:8765
/// tcp:8765`), into the app's own folder: Android 14 lets an app read
/// nothing the shell put in its external folder. Results go back the
/// same way.
///
/// Layout under `<app support>/voicecheck/`:
///  * `<lang>/` for a Pocket TTS language: `text_conditioner.onnx`,
///    `flow_lm_main.onnx`, `flow_lm_flow.onnx`, `tokenizer.json`,
///    `voice.safetensors`, `sentences.txt` (one per line);
///  * `mimi_decoder.onnx`, shared;
///  * `zh/` for Chinese: `model.onnx`, `voice.bin`, the seven front-end
///    files by role name (`jiebaDict` ...), `sentences.txt`.
/// Results go back as `<lang>_<n>.wav` and one line per sentence in
/// `voicecheck.log`: `VOICECHECK lang n seconds-of-audio seconds-taken rtf nan`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:trellis/features/reader/speech/kokoro/kokoro_engine.dart';
import 'package:trellis/features/reader/speech/kokoro/kokoro_model.dart';
import 'package:trellis/features/reader/speech/pocket/pocket_engine.dart';
import 'package:trellis/features/reader/speech/pocket/pocket_model.dart';
import 'package:trellis/features/reader/speech/pocket/pocket_text.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';
import 'package:trellis/features/reader/speech/wav.dart';

const _roles = [
  'jiebaDict',
  'finalsegHmm',
  'possegHmm',
  'pinyinSingle',
  'pinyinPhrases',
  'pinyinAux',
  'misakiTables',
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Center(
      child: Text('voice check', textDirection: TextDirection.ltr)));
  final support = (await getApplicationSupportDirectory()).path;
  // Android may start a second engine (and a second main) when the
  // activity is made again; only the first run goes on.
  try {
    File('$support/voicecheck.lock').createSync(exclusive: true);
  } on FileSystemException {
    return;
  }
  final root = Directory('$support/voicecheck');
  if (root.existsSync()) root.deleteSync(recursive: true);
  final http = HttpClient();
  const host = 'http://127.0.0.1:8765';
  Future<List<int>> get(String path) async {
    final res = await (await http.getUrl(Uri.parse('$host/$path'))).close();
    return [for (final chunk in await res.toList()) ...chunk];
  }

  Future<void> put(String name, List<int> bytes) async {
    final req = await http.putUrl(Uri.parse('$host/out/$name'));
    req.contentLength = bytes.length;
    req.add(bytes);
    await (await req.close()).drain<void>();
  }

  Future<void> say(String line) async {
    debugPrint(line);
    await put('voicecheck.log', utf8.encode('$line\n'));
  }

  for (final path in utf8.decode(await get('list.txt')).split('\n')) {
    if (path.trim().isEmpty) continue;
    final f = File('${root.path}/$path');
    f.parent.createSync(recursive: true);
    final res = await (await http.getUrl(Uri.parse('$host/$path'))).close();
    if (res.statusCode != 200) {
      await say('VOICECHECK MISSING $path ${res.statusCode}');
      await res.drain<void>();
      continue;
    }
    final part = File('${f.path}.part');
    await res.pipe(part.openWrite());
    if (part.lengthSync() != res.contentLength) {
      await say('VOICECHECK SHORT $path ${part.lengthSync()} of '
          '${res.contentLength}');
    }
    part.renameSync(f.path);
  }
  await say('VOICECHECK FILES ${root.listSync(recursive: true).length}');
  final langs = root
      .listSync()
      .whereType<Directory>()
      .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
      .toList()
    ..sort();
  for (final lang in langs) {
    final dir = '${root.path}/$lang';
    final SynthesisSpeechEngine engine;
    if (lang == 'zh') {
      engine = KokoroSpeechEngine(
        voicePath: '$dir/voice.bin',
        openModel: () => openKokoroModel('$dir/model.onnx'),
        loadFrontEnd: () =>
            loadKokoroFrontEnd({for (final r in _roles) r: '$dir/$r'}),
      );
    } else {
      final language = PocketLanguage.byTag(lang)!;
      final files = PocketVoiceFiles(
        textConditioner: '$dir/text_conditioner.onnx',
        main: '$dir/flow_lm_main.onnx',
        flow: '$dir/flow_lm_flow.onnx',
        mimi: '${root.path}/mimi_decoder.onnx',
        tokenizer: '$dir/tokenizer.json',
        voice: '$dir/voice.safetensors',
      );
      engine = PocketSpeechEngine(
          language: language, open: () => openPocketModel(files, language));
    }
    final sentences = File('$dir/sentences.txt')
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .toList();
    for (var n = 0; n < sentences.length; n++) {
      final watch = Stopwatch()..start();
      try {
        final r = await engine.synthesize(sentences[n], lang: lang);
        final taken = watch.elapsedMilliseconds / 1000;
        final seconds = r.samples.length / r.sampleRate;
        final nan = r.samples.any((s) => s.isNaN);
        await put('${lang}_$n.wav', wavBytes(r.samples, r.sampleRate));
        await say('VOICECHECK $lang $n ${seconds.toStringAsFixed(2)} '
            '${taken.toStringAsFixed(2)} '
            '${(taken / (seconds == 0 ? 1 : seconds)).toStringAsFixed(3)} '
            '$nan');
      } catch (e) {
        await say('VOICECHECK $lang $n FAILED $e');
      }
    }
    await engine.dispose();
  }
  await say('VOICECHECK DONE');
}

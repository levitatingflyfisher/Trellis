import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart' show UnigramTokenizer;
import 'package:trellis/features/reader/speech/pocket/pocket_loop.dart';
import 'package:trellis/features/reader/speech/pocket/pocket_text.dart';
import 'package:trellis/features/reader/translation/marian_types.dart';

/// The Pocket TTS loop with every graph faked: what it feeds each graph,
/// when it stops, and that every handle it is given back is released.
class _Handle {
  final String name;
  _Handle(this.name);
  @override
  String toString() => name;
}

class _Runner implements MarianSessionRunner {
  final Map<String, MTensor> Function(Map<String, MTensor> feeds) body;
  final calls = <Map<String, MTensor>>[];
  final created = <Object>[];
  final released = <Object>[];
  _Runner(this.body);

  @override
  Future<Map<String, MTensor>> run(Map<String, MTensor> feeds,
      {Set<String>? fetch}) async {
    calls.add(feeds);
    final out = body(feeds);
    for (final t in out.values) {
      if (t.handle != null) created.add(t.handle!);
    }
    return out;
  }

  @override
  Future<void> release(Iterable<MTensor> tensors) async {
    for (final t in tensors) {
      if (t.handle != null) released.add(t.handle!);
    }
  }
}

UnigramTokenizer _tokenizer() => UnigramTokenizer.fromJson(jsonEncode({
      'model': {
        'type': 'Unigram',
        'unk_id': 0,
        'byte_fallback': true,
        'vocab': [
          ['<unk>', 0.0],
          for (var b = 0; b < 256; b++)
            ['<0x${b.toRadixString(16).toUpperCase().padLeft(2, '0')}>', -20.0],
          ['▁', -1.0],
          ['.', -1.0],
          [',', -1.0],
          ['!', -1.0],
          ['?', -1.0],
          ['▁Hallo', -1.0],
          ['▁Welt', -1.0],
        ],
      },
    }));

void main() {
  late _Runner conditioner, mainLm, flow, mimi;
  late List<double> eosScript; // eos logit per frame (after the prefill)
  var frameCalls = 0;
  var handles = 0;
  MTensor h(String name) => MTensor.handle(_Handle('$name#${handles++}'), const [1]);

  setUp(() {
    frameCalls = 0;
    eosScript = [];
    conditioner = _Runner((f) => {
          'embeddings': h('emb'),
          'latent_mean': MTensor(List.filled(32, 1.0), const [32]),
          'latent_std': MTensor(List.filled(32, 2.0), const [32]),
        });
    mainLm = _Runner((f) {
      final prefill = (f['sequence']!.shape[1]) == 0;
      final eos = prefill
          ? -10.0
          : (frameCalls < eosScript.length ? eosScript[frameCalls] : -10.0);
      if (!prefill) frameCalls++;
      return {
        'conditioning': h('cond'),
        'eos_logit': MTensor([eos], const [1, 1]),
        for (var i = 0; i < 6; i++) 'new_cache_$i': h('cache$i'),
      };
    });
    flow = _Runner((f) => {
          'flow_dir': MTensor(List.filled(32, 1.0), const [1, 32]),
        });
    mimi = _Runner((f) => {
          'audio': MTensor(
              List.filled(f['latent']!.shape[1] * pocketSamplesPerFrame, 0.5),
              [1, 1, f['latent']!.shape[1] * pocketSamplesPerFrame]),
          for (var k = 0; k < 12; k++) 'new_state_$k': h('mimi$k'),
        });
  });

  final voice = PocketVoice([
    for (var i = 0; i < 6; i++)
      MTensor.handle(_Handle('voice$i'), const [2, 1, 124, 16, 64]),
  ]);

  PocketGenerator generator() => PocketGenerator(
        conditioner: conditioner,
        main: mainLm,
        flow: flow,
        mimi: mimi,
        tokenizer: _tokenizer(),
        language: PocketLanguage.german,
        noise: (c, f) => Float32List(32)..fillRange(0, 32, 1.0),
      );

  test('the end logit is ignored before frame 6; from its first firing, '
      'frames_after_eos more frames run and the last is not kept', () async {
    // Fires at frame 5 (too early) and again at 6. A short text: the
    // guess is 3, plus 2, so 5 frames after: frames 0..10 are kept.
    eosScript = [-9, -9, -9, -9, -9, 0, 0, 0, 0, 0, 0, 0, 0];
    final audio = await generator().synthesize('Hallo Welt', voice);
    expect(audio.length, 11 * pocketSamplesPerFrame);
    expect(mimi.calls.single['latent']!.shape, [1, 11, 32]);
  });

  test('an end logit of exactly -4 does not count (the rule is strict)',
      () async {
    eosScript = [for (var i = 0; i < 40; i++) i < 8 ? -9.0 : -4.0];
    eosScript[10] = -3.9;
    final audio = await generator().synthesize('Hallo Welt', voice);
    expect(audio.length, (10 + 5) * pocketSamplesPerFrame);
  });

  test('with no end, it stops at Kyutai’s cap and decodes 12 frames a '
      'call', () async {
    final tokens = _tokenizer().encode('Hallo Welt.').length;
    final cap = pocketMaxFrames(tokens);
    final audio = await generator().synthesize('Hallo Welt', voice);
    expect(audio.length, cap * pocketSamplesPerFrame);
    expect(mimi.calls.map((c) => c['latent']!.shape[1]),
        [for (var i = 0; i < cap; i += 12) cap - i < 12 ? cap - i : 12]);
  });

  test('prefill gets the voice caches and the text; the first frame is '
      'NaN; each next frame is the last latent', () async {
    eosScript = [-9, -9, -9, -9, -9, -9, 0];
    await generator().synthesize('Hallo Welt', voice);
    final prefill = mainLm.calls.first;
    expect(prefill['sequence']!.shape, [1, 0, 32]);
    expect(prefill['text_embeddings']!.handle.toString(), startsWith('emb'));
    expect(prefill['cache_0']!.handle.toString(), 'voice0');
    final first = mainLm.calls[1];
    expect(first['sequence']!.data.every((v) => (v as double).isNaN), isTrue);
    expect(first['text_embeddings']!.shape, [1, 0, 1024]);
    // z = 1, temperature 0.3, one flow step adding 1: x = sqrt(0.3) + 1.
    final second = mainLm.calls[2];
    for (final v in second['sequence']!.data) {
      expect(v, closeTo(1.5477225575, 1e-6));
    }
  });

  test('the flow net runs once per frame at 1 step, four times at 4, '
      'with s and t stepping through 0..1', () async {
    eosScript = [-9, -9, -9, -9, -9, -9, 0];
    await generator().synthesize('Hallo Welt', voice, steps: 4);
    final perFrame = flow.calls.take(4).toList();
    expect(perFrame.map((c) => c['s']!.data.single), [0, 0.25, 0.5, 0.75]);
    expect(perFrame.map((c) => c['t']!.data.single), [0.25, 0.5, 0.75, 1.0]);
  });

  test('latents reach Mimi in its own space (times std, plus mean) and '
      'the first 5 ms fade in', () async {
    eosScript = [-9, -9, -9, -9, -9, -9, 0];
    final audio = await generator().synthesize('Hallo Welt', voice);
    final latent = mimi.calls.first['latent']!.data;
    expect(latent.first, closeTo(1.5477225575 * 2 + 1, 1e-5));
    expect(audio[0], 0);
    expect(audio[119], closeTo(0.5, 1e-6));
    expect(audio[60], closeTo(0.5 * 60 / 119, 1e-6));
    final state = mimi.calls.first;
    expect(state['state_11']!.type, MTensorType.int64);
    expect(state['state_1']!.shape, [2, 1, 250, 8, 64]);
  });

  test('every handle the graphs give back is released once; the voice '
      'is never released', () async {
    eosScript = [-9, -9, -9, -9, -9, -9, 0];
    await generator().synthesize('Hallo Welt', voice);
    for (final r in [conditioner, mainLm, flow, mimi]) {
      expect(r.released.toSet(), r.created.toSet(), reason: '$r');
      expect(r.released.length, r.released.toSet().length);
    }
    final all = [for (final r in [mainLm, conditioner, mimi]) ...r.released];
    expect(all.whereType<_Handle>().where((x) => x.name.startsWith('voice')),
        isEmpty);
  });

  test('two sentences over the chunk limit start each chunk from the '
      'voice again', () async {
    eosScript = List.filled(400, 0);
    final long = List.filled(30, 'Hallo Welt').join(' ');
    await generator().synthesize('$long. $long.', voice);
    final fromVoice = mainLm.calls
        .where((c) => c['cache_0']!.handle.toString() == 'voice0')
        .length;
    expect(fromVoice, greaterThan(1));
  });
}

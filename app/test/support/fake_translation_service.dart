import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/reader/translation/translation_service.dart';
import 'package:trellis/features/reader/translation/translator.dart';

import 'fake_sentence_translator.dart';
import 'fake_services.dart';

ModelSpec fakePair(String src, String tgt, int bytes) => ModelSpec(
      id: 'opus-mt-$src-$tgt',
      task: ModelTask.translation,
      files: [
        ModelFile(
            url: 'https://example.test/$src-$tgt.onnx',
            sha256: 'a' * 64,
            bytes: bytes),
      ],
      licenses: const ['CC-BY-4.0'],
      minTier: DeviceTier.t2,
      langs: {tgt},
      sourceLang: src,
    );

/// A small hub-and-spoke catalog with round sizes: es and de both ways,
/// ar out of English, ja into English only.
final fakeTranslationRegistry = ModelRegistry([
  fakePair('en', 'es', 100000000),
  fakePair('es', 'en', 110000000),
  fakePair('en', 'de', 200000000),
  fakePair('de', 'en', 210000000),
  fakePair('en', 'ar', 120000000),
  fakePair('ja', 'en', 300000000),
]);

/// A [TranslationService] over [store] whose models translate with
/// [translateFn] (default `'<target>:<sentence>'`). Every model it opens
/// is kept in [opened] for assertions.
class FakeTranslation {
  final FakeModelStore store;
  final String Function(ModelSpec spec, String sentence)? translateFn;
  final List<FakeSentenceTranslator> opened = [];
  late final TranslationService service = TranslationService(
    registry: fakeTranslationRegistry,
    tier: DeviceTier.t2,
    store: store,
    openSpec: _open,
  );

  FakeTranslation({Set<String>? installed, int beats = 1, this.translateFn})
      : store = FakeModelStore(downloadedIds: installed, beats: beats);

  Future<SentenceTranslator?> _open(ModelSpec spec) async {
    if (!await store.isDownloaded(spec)) return null;
    final t = FakeSentenceTranslator((s) =>
        translateFn?.call(spec, s) ?? '${spec.langs!.single}:$s');
    opened.add(t);
    return t;
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/models/model_store.dart';
import 'package:trellis/features/transcribe/transcribe_executor.dart';
import 'package:trellis/services/device_services.dart';

import '../support/fake_services.dart';

/// DeviceServices.lookupDefinition: the ONE call ReaderScreen closes over
/// for Campaign 4 Phase 3, mirroring resolveSpeechEngine's own shape --
/// registry selection (pickModel) + the download-honesty gate, then an
/// actual on-disk StarDict lookup. Built once per DeviceServices instance
/// and reused (the residency law every lazy-open in this file follows).
void main() {
  late Directory dir;
  setUp(() =>
      dir = Directory.systemTemp.createTempSync('trellis-dict-services'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  ModelSpec dictSpec() =>
      ModelRegistry.starter().byId('wiktionary-en-en-stardict')!;

  Uint8List be16(int v) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);
  Uint8List be32(int v) =>
      (ByteData(4)..setUint32(0, v, Endian.big)).buffer.asUint8List();

  /// Writes a tiny real StarDict set directly into the layout's own
  /// [DiskModelStore.dictionaryDirOf] path -- as if a real download had
  /// already extracted there -- so `isDownloaded` and the actual parse/
  /// lookup both exercise real files, not a mock.
  void writeFixtureDictionary(DiskModelStore store, ModelSpec spec) {
    final layout = spec.dictionaryArchiveLayout!;
    final dictDir = Directory(store.dictionaryDirOf(spec))
      ..createSync(recursive: true);

    const ifoRaw = '''
StarDict's dict ifo file
version=3.0.0
bookname=Fixture
wordcount=1
idxfilesize=1
sametypesequence=h
''';
    File('${dictDir.path}/${layout.ifoFileName}').writeAsStringSync(ifoRaw);

    const word = 'hello';
    const def = '<b>hello</b><br>a greeting';
    final idx = BytesBuilder()
      ..add(word.codeUnits)
      ..addByte(0)
      ..add(be32(0))
      ..add(be32(utf8.encode(def).length));
    File('${dictDir.path}/${layout.idxFileName}')
        .writeAsBytesSync(idx.toBytes());

    final compressed = Deflate(utf8.encode(def)).getBytes();
    final extra = BytesBuilder()
      ..add(be16(1))
      ..add(be16(utf8.encode(def).length))
      ..add(be16(1))
      ..add(be16(compressed.length));
    final extraBytes = extra.toBytes();
    final subfield = BytesBuilder()
      ..addByte(0x52)
      ..addByte(0x41)
      ..add(be16(extraBytes.length))
      ..add(extraBytes);
    final gz = BytesBuilder()
      ..addByte(0x1f)
      ..addByte(0x8b)
      ..addByte(0x08)
      ..addByte(0x04)
      ..add([0, 0, 0, 0])
      ..addByte(0x00)
      ..addByte(0x03)
      ..add(be16(subfield.length))
      ..add(subfield.toBytes())
      ..add(compressed);
    File('${dictDir.path}/${layout.dictFileName}')
        .writeAsBytesSync(gz.toBytes());
  }

  DeviceServices services({required DiskModelStore modelStore}) =>
      DeviceServices(
        supportDir: dir,
        modelStore: modelStore,
        registry: ModelRegistry.starter(),
        decoder: FakeDecoder(),
        audioFetcher: FakeAudioFetcher(),
        executor: InlineTranscribeExecutor(),
        foregroundGate: RecordingForegroundGate(),
        engineFor: (_) => ScriptedEngineSpec(chunkJsons: defaultScript()),
        tier: DeviceTier.t0,
      );

  test('no dictionary downloaded means no definition', () async {
    final store = DiskModelStore(baseDir: Directory('${dir.path}/models'));
    final s = services(modelStore: store);
    expect(await s.lookupDefinition('hello'), isNull);
  });

  test('a downloaded dictionary resolves a real definition, HTML stripped',
      () async {
    final store = DiskModelStore(baseDir: Directory('${dir.path}/models'));
    writeFixtureDictionary(store, dictSpec());
    final s = services(modelStore: store);

    final def = await s.lookupDefinition('hello');
    expect(def, isNotNull);
    expect(def, contains('a greeting'));
    expect(def, isNot(contains('<b>')), reason: 'HTML tags stripped');
  });

  test('a word not in the dictionary (not even a prefix) returns null',
      () async {
    final store = DiskModelStore(baseDir: Directory('${dir.path}/models'));
    writeFixtureDictionary(store, dictSpec());
    final s = services(modelStore: store);

    expect(await s.lookupDefinition('zzznothing'), isNull);
  });

  test('the dictionary is parsed once and reused across lookups (the '
      'residency law)', () async {
    final store = DiskModelStore(baseDir: Directory('${dir.path}/models'));
    writeFixtureDictionary(store, dictSpec());
    final s = services(modelStore: store);

    final first = await s.lookupDefinition('hello');
    // Delete the on-disk files -- if the second call re-reads from disk
    // it will find nothing; if it reuses the parsed dictionary it still
    // answers.
    await Directory(store.dictionaryDirOf(dictSpec())).delete(recursive: true);
    final second = await s.lookupDefinition('hello');
    expect(second, first);
  });
}

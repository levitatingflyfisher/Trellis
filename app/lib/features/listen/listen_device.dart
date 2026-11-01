/// [ListenChain] on a real device: whisper through the transcribe
/// coordinator, the on-device translators, the downloaded voice, and
/// ffmpeg to pack the result. Kept apart from the chain so the chain
/// stays testable with stand-ins.
library;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:loom_core/loom_core.dart' as core;
import 'package:ml_runtime/ml_runtime.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../models/consent.dart';
import '../models/format.dart';
import '../models/model_store.dart';
import '../models/models_screen.dart' show modelLabel;
import '../reader/speech/supertonic_voice_handle.dart'
    show supertonicSupportedLangs;
import '../reader/translation/language_names.dart';
import '../reader/translation/sentence_units.dart';
import '../reader/translation/translation_job.dart';
import '../transcribe/transcribe_coordinator.dart';
import 'listen_chain.dart';

/// The languages whose speech this device can save to a file: those the
/// downloaded voice speaks. English is left out; it is what most
/// episodes already are.
List<String> savableListenLanguages() =>
    [for (final l in supertonicSupportedLangs) if (l != 'en') l]..sort();

ModelSpec? _voiceSpec(DeviceServices services, String lang) =>
    services.registry.pickModel(ModelTask.tts, services.tier,
        // One voice file speaks every language in its list, and is
        // registered under English.
        langHint: supertonicSupportedLangs.contains(lang) ? 'en' : lang);

String? _base(String? lang) {
  final b = lang?.trim().toLowerCase().split(RegExp('[-_]')).first;
  return b == null || b.isEmpty ? null : b;
}

/// Everything listening to [work] in [lang] would download, for the one
/// consent dialog before the chain starts (ADR-0003 law 6). Empty when
/// it is all here already.
Future<List<DownloadItem>> listenDownloads({
  required AppDatabase db,
  required DeviceServices services,
  required TranscribeCoordinator transcriber,
  required Work work,
  required Episode episode,
  required String lang,
}) async {
  final items = <DownloadItem>[];
  final url = episode.enclosureUrl;
  if (url != null && (await db.spineDao.alignmentsOf(work.id)).isEmpty) {
    final plan = await transcriber.planFor(workId: work.id, enclosureUrl: url);
    if (plan.needsModel) {
      items.add(DownloadItem('${modelLabel(plan.model.id)} '
          '(${formatBytes(plan.model.sizeBytes)}), one time'));
    }
    if (plan.needsAudio) {
      items.add(DownloadItem(
          'This episode’s audio (size depends on the episode)'));
    }
  }
  final route = await services.translation
      ?.route(_base(work.lang) ?? 'en', lang);
  for (final leg in route?.missing ?? const []) {
    items.add(DownloadItem('${languageDisplayName(leg.source)} to '
        '${languageDisplayName(leg.target)} translator, '
        '${formatBytes(leg.missingBytes)}, one time'));
  }
  final voice = _voiceSpec(services, lang);
  if (voice != null && !await services.modelStore.isDownloaded(voice)) {
    items.add(DownloadItem('${modelLabel(voice.id)} '
        '(${formatBytes(voice.sizeBytes)}), one time'));
  }
  return items;
}

Future<bool> _ensure(ModelStore store, ModelSpec spec) async {
  if (await store.isDownloaded(spec)) return true;
  try {
    return await store.download(spec).done == ModelInstallOutcome.installed;
  } catch (_) {
    return false;
  }
}

/// The chain wired to this device.
ListenChain deviceListenChain({
  required AppDatabase db,
  required DeviceServices services,
  required TranscribeCoordinator transcriber,
}) {
  return ListenChain(
    db: db,
    audioFileFor: services.audioFileFor,
    tempDir: Directory('${services.supportDir.path}/spoken-temp'),
    encode: packSpoken,
    foreground: services.foregroundGate,
    transcribe: (work, episode) async {
      await transcriber.start(
          workId: work.id,
          title: work.title,
          enclosureUrl: episode.enclosureUrl!,
          lang: work.lang,
          translate: false);
      while (transcriber.isActive(work.id)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    },
    translate: (work, source, target, progress) async {
      final service = services.translation;
      final route = await service?.route(source, target);
      if (service == null || route == null) {
        return 'Trellis has no translator from '
            '${languageDisplayName(source)} to '
            '${languageDisplayName(target)}.';
      }
      for (final leg in route.missing) {
        if (!await _ensure(services.modelStore, leg.spec)) {
          return 'The translator’s download didn’t finish. What arrived '
              'is kept; try again.';
        }
      }
      final kinds = {for (final k in core.SegmentKind.values) k.name: k};
      final run = TranslationRun(
        dao: db.spineDao,
        workId: work.id,
        units: sentenceUnitsOf([
          for (final r in await db.spineDao.segmentsOf(work.id))
            core.Segment(
                idx: r.idx,
                kind: kinds[r.kind] ?? core.SegmentKind.prose,
                text: r.body),
        ]),
        target: target,
        steps: [
          for (final leg in route.legs)
            TranslationStep(
                lang: leg.target, open: () => service.open(leg.spec)),
        ],
      );
      void beat() => progress(run.state.doneUnits, run.state.totalUnits);
      run.addListener(beat);
      await run.start();
      run.removeListener(beat);
      return run.state.phase == TranslationJobPhase.done
          ? null
          : 'The translator couldn’t finish. Try downloading its language '
              'again in Models.';
    },
    voiceFor: (lang) async {
      final spec = _voiceSpec(services, lang);
      if (spec == null || !supertonicSupportedLangs.contains(lang)) {
        return null;
      }
      if (!await _ensure(services.modelStore, spec)) return null;
      final engine = await services.speechEngineFor(spec);
      if (engine == null) return null;
      return (
        // The voice's plain name, for the episode's page.
        name: 'Supertonic',
        say: (String text) => engine.synthesize(text, lang: lang),
      );
    },
  );
}

/// Packs [wav] into a small file beside it with ffmpeg, tagged as a
/// machine-made voice: Opus first (about 11 MB an hour), then two
/// fallbacks. Null when no encoder took it or there is no ffmpeg here
/// (anything but Android); the WAV is then what is kept.
Future<File?> packSpoken(File wav, {required String title}) async {
  if (!Platform.isAndroid) return null;
  final stem = wav.path.substring(0, wav.path.length - 4);
  const tries = [
    (codec: 'libopus', ext: '.ogg', rate: '24k'),
    (codec: 'libvorbis', ext: '.ogg', rate: '48k'),
    (codec: 'aac', ext: '.m4a', rate: '48k'),
  ];
  for (final t in tries) {
    final out = File('$stem${t.ext}');
    try {
      if (out.existsSync()) out.deleteSync();
      // Arguments as a list: nothing in a title or a path can break out
      // of a quoted command line.
      final session = await FFmpegKit.executeWithArguments([
        '-y', '-i', wav.path, '-ac', '1',
        '-c:a', t.codec, '-b:a', t.rate,
        '-metadata', 'title=$title',
        '-metadata',
        'comment=Machine-made voice. Translated and spoken on a device '
            'by Trellis.',
        out.path,
      ]);
      if (ReturnCode.isSuccess(await session.getReturnCode()) &&
          out.existsSync() &&
          out.lengthSync() > 0) {
        return out;
      }
    } catch (_) {
      // Try the next one.
    }
    if (out.existsSync()) out.deleteSync();
  }
  return null;
}

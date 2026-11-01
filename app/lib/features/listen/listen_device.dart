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
import '../player/player_controller.dart';
import '../reader/reader_prefs.dart' show readAloudSystemVoicePrefix;
import '../reader/speech/phone_voice.dart';
import '../reader/speech/supertonic_voice_handle.dart'
    show supertonicSupportedLangs;
import '../reader/translation/language_names.dart';
import '../reader/translation/sentence_units.dart';
import '../reader/translation/translation_job.dart';
import '../reader/translation/translation_route.dart' show planRoute;
import '../feeds/background/feed_check_platform.dart';
import '../feeds/background/feed_check_settings.dart';
import '../transcribe/transcribe_coordinator.dart';
import 'listen_chain.dart';
import 'listen_jobs.dart';
import 'listen_languages.dart';
import 'saved_voice.dart';
import 'make_ahead_jobs.dart';

/// The languages whose speech this device can save to a file: those the
/// downloaded voice speaks (it is fetched when first needed), and those
/// the phone has a voice of its own for.
List<String> savableListenLanguages(DeviceServices services) => [
      ...{
        for (final l in supertonicSupportedLangs)
          if (_voiceSpec(services, l) != null) l,
        ...services.phoneVoices.langs,
      }
    ]..sort();

/// Every language the one tap could make an episode in [workLang] (or,
/// with none of its own, its show's [feedLang]) in, sorted into those it
/// offers and those it can't, with the reason. See [ListenLanguages].
ListenLanguages listenLanguagesOf(DeviceServices services,
    {required String? workLang, required String? feedLang}) {
  if (services.translation == null) return const ListenLanguages();
  final source = listenSourceLanguage(workLang: workLang, feedLang: feedLang);
  final pairs = services.registry.translationPairsAt(services.tier);
  final translated = <String>{
    for (final s in pairs) ...?s.langs,
    for (final s in pairs) ?s.sourceLang,
  };
  final savable = savableListenLanguages(services).toSet();
  return sortListenLanguages(
    source: source,
    candidates: {...translated, ...savable},
    translated: translated,
    canSave: savable.contains,
    hasRoute: (lang) =>
        planRoute(services.registry, services.tier,
            source: source,
            target: lang,
            // Only whether a route exists is asked, not what it would
            // download.
            missingBytesOf: (_) => 0) !=
        null,
  );
}

/// The languages the one tap can make for an episode in [workLang] (or,
/// with none of its own, its show's [feedLang]): each one a voice on this
/// device can save and a translator reaches from the episode's language,
/// by its own pair or by way of English. Never the episode's own
/// language. Empty when there is none, and the page then shows no button.
List<String> listenLanguagesFor(DeviceServices services,
        {required String? workLang, required String? feedLang}) =>
    listenLanguagesOf(services, workLang: workLang, feedLang: feedLang)
        .offered;

/// What the language dialog says about the languages it does not list.
String? listenMissingNoteFor(DeviceServices services,
    {required String? workLang, required String? feedLang}) {
  final source = listenSourceLanguage(workLang: workLang, feedLang: feedLang);
  return listenMissingNote(
      listenLanguagesOf(services, workLang: workLang, feedLang: feedLang),
      source: source);
}

ModelSpec? _voiceSpec(DeviceServices services, String lang) =>
    services.registry.pickModel(ModelTask.tts, services.tier,
        // One voice file speaks every language in its list, and is
        // registered under English.
        langHint: supertonicSupportedLangs.contains(lang) ? 'en' : lang);

/// The voice that saves [work] in [lang], by [savedVoiceKind], with the
/// choice made for [lang] in Read aloud's voices (by the work's profile);
/// null when no voice here can. [download] is the downloaded voice when
/// it is the one and still has to be fetched.
Future<
    ({
      SavedVoiceKind kind,
      ModelSpec? spec,
      String? phoneVoice,
      ModelSpec? download,
    })?> _savedVoicePlan(
    AppDatabase db, DeviceServices services, Work work, String lang) async {
  final spec =
      supertonicSupportedLangs.contains(lang) ? _voiceSpec(services, lang) : null;
  final phone = services.phoneVoices;
  final phoneSpeaks = phone.saver != null && phone.langs.contains(lang);
  String? choice;
  try {
    choice = (await db.profilesDao.readerPrefs(work.profileId)).voices[lang];
  } catch (_) {
    choice = null; // No choice to honour: the rule decides.
  }
  final here = spec != null && await services.modelStore.isDownloaded(spec);
  final kind = savedVoiceKind(
      downloadedSpeaks: spec != null,
      downloadedHere: here,
      phoneSpeaks: phoneSpeaks,
      choice: choice);
  if (kind == null) return null;
  String? phoneVoice;
  if (choice != null && choice.startsWith(readAloudSystemVoicePrefix)) {
    final name = choice.substring(readAloudSystemVoicePrefix.length);
    // Only a voice still installed: one since removed falls back to the
    // language's own default.
    if (phone.voices.any((v) => v.name == name && v.lang == lang)) {
      phoneVoice = name;
    }
  }
  return (
    kind: kind,
    spec: spec,
    phoneVoice: phoneVoice,
    download: kind == SavedVoiceKind.downloaded && !here ? spec : null,
  );
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
  final route = await services.translation?.route(
      listenSourceLanguage(
          workLang: work.lang,
          feedLang: await db.feedsDao.languageOfWorkFeed(work.id)),
      lang);
  for (final leg in route?.missing ?? const []) {
    items.add(DownloadItem('${languageDisplayName(leg.source)} to '
        '${languageDisplayName(leg.target)} translator, '
        '${formatBytes(leg.missingBytes)}, one time'));
  }
  final voice = (await _savedVoicePlan(db, services, work, lang))?.download;
  if (voice != null) {
    items.add(DownloadItem('${modelLabel(voice.id)} '
        '(${formatBytes(voice.sizeBytes)}), one time'));
  }
  return items;
}

/// The models making [work] in [lang] would fetch, and nothing else: what
/// make ahead's one consent covers, and what it refuses to do without.
/// With [forShow] the transcriber counts even when this episode happens
/// to have its transcript, since the next one will not.
Future<List<DownloadItem>> listenModelDownloads({
  required AppDatabase db,
  required DeviceServices services,
  required TranscribeCoordinator transcriber,
  required Work work,
  required Episode episode,
  required String lang,
  required bool forShow,
}) async {
  final items = <DownloadItem>[];
  final url = episode.enclosureUrl;
  if (url != null &&
      (forShow || (await db.spineDao.alignmentsOf(work.id)).isEmpty)) {
    final plan = await transcriber.planFor(workId: work.id, enclosureUrl: url);
    if (plan.needsModel) {
      items.add(DownloadItem('${modelLabel(plan.model.id)} '
          '(${formatBytes(plan.model.sizeBytes)}), one time'));
    }
  }
  final route = await services.translation?.route(
      listenSourceLanguage(
          workLang: work.lang,
          feedLang: await db.feedsDao.languageOfWorkFeed(work.id)),
      lang);
  for (final leg in route?.missing ?? const []) {
    items.add(DownloadItem('${languageDisplayName(leg.source)} to '
        '${languageDisplayName(leg.target)} translator, '
        '${formatBytes(leg.missingBytes)}, one time'));
  }
  final voice = (await _savedVoicePlan(db, services, work, lang))?.download;
  if (voice != null) {
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
  final translations = <int, TranslationRun>{};
  return ListenChain(
    db: db,
    audioFileFor: services.audioFileFor,
    tempDir: Directory('${services.supportDir.path}/spoken-temp'),
    encode: packSpoken,
    foreground: services.foregroundGate,
    stopTranscribing: transcriber.cancel,
    stopTranslating: (workId) => translations[workId]?.cancel(),
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
      translations[work.id] = run;
      run.addListener(beat);
      try {
        await run.start();
      } finally {
        run.removeListener(beat);
        translations.remove(work.id);
      }
      return run.state.phase == TranslationJobPhase.done
          ? null
          : 'The translator couldn’t finish. Try downloading its language '
              'again in Models.';
    },
    voiceFor: (work, lang) async {
      final plan = await _savedVoicePlan(db, services, work, lang);
      final saver = services.phoneVoices.saver;
      switch (plan?.kind) {
        case null:
          return null;
        case SavedVoiceKind.phone:
          if (saver == null) return null;
          final dir = Directory('${services.supportDir.path}/spoken-temp/phone');
          return (
            name: phoneVoiceName(services.phoneVoices.engine),
            say: (String text) => sayWithPhone(saver, text,
                lang: lang, voice: plan!.phoneVoice, dir: dir),
          );
        case SavedVoiceKind.downloaded:
          final spec = plan!.spec!;
          if (!await _ensure(services.modelStore, spec)) return null;
          final engine = await services.speechEngineFor(spec);
          if (engine == null) return null;
          return (
            // The voice's plain name, for the episode's page.
            name: 'Supertonic',
            say: (String text) => engine.synthesize(text, lang: lang),
          );
      }
    },
  );
}

/// The one owner of the one tap on this device: the chain, which
/// languages an episode can be made in, and what making one downloads.
ListenJobs deviceListenJobs({
  required AppDatabase db,
  required DeviceServices services,
  required TranscribeCoordinator transcriber,
  PlayerController? player,
}) =>
    ListenJobs(
      db: db,
      chain:
          deviceListenChain(db: db, services: services, transcriber: transcriber),
      languagesFor: ({required workLang, required feedLang}) =>
          listenLanguagesFor(services, workLang: workLang, feedLang: feedLang),
      sortedFor: ({required workLang, required feedLang}) =>
          listenLanguagesOf(services, workLang: workLang, feedLang: feedLang),
      askVoices: services.phoneVoices.saver == null
          ? null
          : services.phoneVoices.refresh,
      voices: services.phoneVoices,
      openVoiceSettings: services.phoneVoices.saver?.openSettings,
      downloadsFor: (work, episode, lang) => listenDownloads(
          db: db,
          services: services,
          transcriber: transcriber,
          work: work,
          episode: episode,
          lang: lang),
      player: player,
      makeAhead: _deviceMakeAhead(db, services, transcriber),
    );

/// Null where the system cannot say whether the phone is on Wi-Fi and
/// charging: there is nothing to make ahead by.
MakeAhead? _deviceMakeAhead(AppDatabase db, DeviceServices services,
    TranscribeCoordinator transcriber) {
  final scheduler = createFeedCheckScheduler();
  if (!scheduler.available ||
      scheduler is! NetworkMeter ||
      scheduler is! ChargingMeter) {
    return null;
  }
  return MakeAhead(
    db: db,
    audioFileFor: services.audioFileFor,
    conditionsMet: () => wifiAndCharging(
        (scheduler as NetworkMeter).isMetered,
        (scheduler as ChargingMeter).isCharging),
    askForPass: scheduler.requestMakeAhead,
    modelsNeeded: (work, episode, lang, {required forShow}) =>
        listenModelDownloads(
            db: db,
            services: services,
            transcriber: transcriber,
            work: work,
            episode: episode,
            lang: lang,
            forShow: forShow),
  );
}

/// Packs [wav] into a small file beside it with ffmpeg, tagged as a
/// machine-made voice and named ([voice]): Opus first (about 11 MB an hour), then two
/// fallbacks. Null when no encoder took it or there is no ffmpeg here
/// (anything but Android); the WAV is then what is kept.
Future<File?> packSpoken(File wav,
    {required String title, required String voice}) async {
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
        'comment=Machine-made voice ($voice). Translated and spoken on a '
            'device by Trellis.',
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

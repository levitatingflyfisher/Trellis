/// A real audio file for a translated episode (1.6.0, owner: "produces an
/// audio file that can be shared, downloaded, cached, and not have to run
/// the heavy engine every time").
///
/// Read aloud makes its sound a sentence at a time and throws it away.
/// This makes the whole spoken translation once, into one file, with the
/// time of every sentence, and stores it as an episode of its own beside
/// the original. Being an ordinary episode is the point: the player, the
/// queue, downloads, storage and the page that lights the words as they
/// are heard all work on it with no code of their own.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:loom_core/loom_core.dart'
    show containsCjk, joinSentences, segmentCjkRun;

import '../../db/database.dart';
import '../intake/paste_intake.dart' show epochDayUtcNow;
import '../reader/speech/speech_engine.dart';
import '../reader/speech/wav.dart' show resample;
import '../reader/translation/language_names.dart';
import '../transcribe/transcript_writer.dart' show encodeWordTimingBlob;

/// The pause after a sentence, and the longer one after a paragraph.
const sentenceGapMs = 250;
const segmentGapMs = 450;

/// One sentence as it was said: which of the original's segments it
/// belongs to, and when it starts and ends in the file.
typedef SpokenSentence = ({int seg, String text, int startMs, int endMs});

class SpokenRender {
  final List<SpokenSentence> sentences;
  final int sampleRate;
  final int durationMs;
  const SpokenRender(
      {required this.sentences,
      required this.sampleRate,
      required this.durationMs});
}

/// The render was called off; nothing is left on disk.
class SpokenCancelled implements Exception {
  const SpokenCancelled();
}

/// Says [sentences] in order with [synth] into one 16-bit mono WAV at
/// [wav], written as it goes so an hour of speech is never held in
/// memory. A sentence the voice cannot say is left out. Throws
/// [SpokenCancelled] when [cancelled] turns true, and [StateError] when
/// nothing could be said at all.
Future<SpokenRender> renderSpoken({
  required List<({int seg, String text})> sentences,
  required Future<SynthResult> Function(String text) synth,
  required File wav,
  void Function(int done, int total)? onProgress,
  bool Function()? cancelled,
}) async {
  await wav.parent.create(recursive: true);
  final out = await wav.open(mode: FileMode.write);
  final said = <SpokenSentence>[];
  var rate = 0;
  var samples = 0; // written so far
  int ms(int n) => rate == 0 ? 0 : (n * 1000 / rate).round();
  try {
    await out.writeFrom(Uint8List(44)); // the header, filled in at the end
    for (var i = 0; i < sentences.length; i++) {
      if (cancelled?.call() ?? false) throw const SpokenCancelled();
      final s = sentences[i];
      SynthResult? r;
      try {
        r = await synth(s.text);
      } on SpokenCancelled {
        rethrow;
      } catch (_) {
        r = null;
      }
      if (r != null && r.samples.isNotEmpty) {
        if (rate == 0) rate = r.sampleRate;
        // One file has one rate; a voice may hand a sentence at another.
        final sound = resample(r.samples, from: r.sampleRate, to: rate);
        if (said.isNotEmpty) {
          final gap = said.last.seg == s.seg ? sentenceGapMs : segmentGapMs;
          final silent = gap * rate ~/ 1000;
          await out.writeFrom(Uint8List(silent * 2));
          samples += silent;
        }
        final pcm = ByteData(sound.length * 2);
        for (var k = 0; k < sound.length; k++) {
          pcm.setInt16(k * 2, (sound[k].clamp(-1.0, 1.0) * 32767).round(),
              Endian.little);
        }
        final start = samples;
        await out.writeFrom(pcm.buffer.asUint8List());
        samples += sound.length;
        said.add(
            (seg: s.seg, text: s.text, startMs: ms(start), endMs: ms(samples)));
      }
      onProgress?.call(i + 1, sentences.length);
    }
    if (said.isEmpty) throw StateError('nothing could be said');
    await out.setPosition(0);
    await out.writeFrom(_wavHeader(samples * 2, rate));
  } catch (_) {
    await out.close();
    if (wav.existsSync()) wav.deleteSync();
    rethrow;
  }
  await out.close();
  return SpokenRender(
      sentences: said, sampleRate: rate, durationMs: ms(samples));
}

Uint8List _wavHeader(int dataLength, int sampleRate) {
  final b = ByteData(44);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, dataLength, Endian.little);
  return b.buffer.asUint8List();
}

final _gaps = RegExp(r'\s+');

/// `[[word, tStartMs, tEndMs], …]` for a sentence said from [startMs] to
/// [endMs]: the voice gives no word times, so each word takes a share of
/// the sentence by its length. An estimate, close enough to light the
/// word being said; the sentence's own times are exact. A Chinese or
/// Japanese run is split into the units the page shows (`segmentCjkRun`),
/// so each of those gets its own share too.
List<List<Object>> estimateWordTimings(String text, int startMs, int endMs) {
  final words = [
    for (final w in text.trim().split(_gaps))
      if (w.isNotEmpty) ...(containsCjk(w) ? segmentCjkRun(w) : [w])
  ];
  if (words.isEmpty) return const [];
  final weights = [for (final w in words) w.length + 1];
  final total = weights.fold(0, (a, b) => a + b);
  final rows = <List<Object>>[];
  var at = startMs, used = 0;
  for (var i = 0; i < words.length; i++) {
    used += weights[i];
    final end = i == words.length - 1
        ? endMs
        : startMs + ((endMs - startMs) * used / total).round();
    rows.add([words[i], at, end]);
    at = end;
  }
  return rows;
}

/// The guid of the spoken translation of work [originalId] into [lang]:
/// how it is found again, so it is made once.
String spokenGuid(int originalId, String lang) => 'spoken:$originalId:$lang';

/// The spoken translation of [originalId] into [lang], when one has been
/// made; null otherwise.
Future<int?> spokenEpisodeOf(AppDatabase db, int originalId, String lang) async {
  final row = await (db.select(db.episodes)
        ..where((e) => e.guid.equals(spokenGuid(originalId, lang)))
        ..limit(1))
      .getSingleOrNull();
  return row?.workId;
}

/// Every spoken translation into [lang] that has been made, as its
/// original's work id to its own: what a whole list asks at once, in one
/// query rather than one a row.
Future<Map<int, int>> spokenEpisodesIn(AppDatabase db, String lang) async {
  final rows = await (db.select(db.episodes)
        ..where((e) => e.guid.like('spoken:%:$lang')))
      .get();
  return {
    for (final r in rows) ?int.tryParse(r.guid.split(':')[1]): r.workId,
  };
}

/// Stores [render] as an episode of [original]'s show: its text is the
/// translation, a segment for each of the original's, with the times the
/// page lights by; its audio is [audio], moved to where the player looks
/// for a download. Returns the episode's work id. One made before for
/// the same original and language is replaced in place.
///
/// The address it carries can never be fetched (`.invalid` never
/// resolves): the file on the device is the episode.
Future<int> storeSpokenEpisode({
  required AppDatabase db,
  required Work original,
  required String lang,
  required String voice,
  required SpokenRender render,
  required File audio,
  required File Function(int workId, String url) audioFileFor,
}) async {
  final ext = audio.path.substring(audio.path.lastIndexOf('.'));
  final url =
      'https://spoken.trellis.invalid/${original.id}-$lang$ext';
  final episode = await db.feedsDao.episodeOf(original.id);
  if (episode == null) {
    throw StateError('only an episode can be spoken as one');
  }

  // The translation's paragraphs, in the original's order.
  final segs = <int>[];
  final bySeg = <int, List<SpokenSentence>>{};
  for (final s in render.sentences) {
    (bySeg[s.seg] ??= (() {
      segs.add(s.seg);
      return <SpokenSentence>[];
    })())
        .add(s);
  }
  final language = languageDisplayName(lang);
  final about = [
    'This is “${original.title}” in $language, spoken by a machine-made '
        'voice ($voice).',
    'The words were translated on this device from a transcript made on '
        'this device, so both can be wrong in places.',
  ];

  final existing = await spokenEpisodeOf(db, original.id, lang);
  final workId = await db.transaction(() async {
    final int id;
    if (existing != null) {
      id = existing;
      await (db.delete(db.positions)..where((p) => p.workId.equals(id))).go();
      await (db.delete(db.alignments)..where((a) => a.workId.equals(id)))
          .go();
      await (db.delete(db.segments)..where((s) => s.workId.equals(id))).go();
      await (db.delete(db.workNotes)..where((n) => n.workId.equals(id))).go();
      await (db.update(db.episodes)..where((e) => e.workId.equals(id)))
          .write(EpisodesCompanion(enclosureUrl: Value(url)));
      await (db.update(db.works)..where((w) => w.id.equals(id)))
          .write(WorksCompanion(sourceUrl: Value(url)));
    } else {
      id = await db.spineDao.insertWork(
          profileId: original.profileId,
          kind: 'episode',
          title: '${original.title} ($language)',
          persistence: original.persistence,
          firstSeenEpochDay: epochDayUtcNow(),
          sourceUrl: url,
          lang: lang);
      await db.feedsDao.insertEpisode(
          workId: id,
          feedId: episode.feedId,
          guid: spokenGuid(original.id, lang),
          enclosureUrl: url,
          // Just after the original, so the two sit together in the show.
          publishedAtMs: episode.publishedAtMs + 1);
    }
    await db.spineDao.insertSegments(id, [
      for (final (i, seg) in segs.indexed)
        (
          idx: i,
          kind: 'prose',
          text: joinSentences([for (final s in bySeg[seg]!) s.text])
        ),
    ]);
    await db.batch((b) => b.insertAll(db.alignments, [
          for (final (i, seg) in segs.indexed)
            AlignmentsCompanion.insert(
                workId: id,
                segmentIdx: i,
                tStartMs: bySeg[seg]!.first.startMs,
                tEndMs: bySeg[seg]!.last.endMs,
                wordTimings: Value(encodeWordTimingBlob([
                  for (final s in bySeg[seg]!)
                    ...estimateWordTimings(s.text, s.startMs, s.endMs),
                ]))),
        ]));
    await db.feedsDao.fillNotes(id,
        html: [
          for (final p in about)
            '<p>${const HtmlEscape(HtmlEscapeMode.element).convert(p)}</p>'
        ].join(),
        plain: about.join(' '));
    return id;
  });

  final dest = audioFileFor(workId, url);
  await dest.parent.create(recursive: true);
  if (dest.existsSync()) dest.deleteSync();
  try {
    audio.renameSync(dest.path);
  } on FileSystemException {
    audio.copySync(dest.path);
    audio.deleteSync();
  }
  return workId;
}

import 'dart:convert';

import 'migration_report.dart';
import 'ohprimer_sanitize.dart';
import 'row_payload.dart';

/// The result of an ohPrimer donor import: row maps + the calm diff report.
class PrimerImportResult {
  final RowTables tables;
  final MigrationReport report;

  const PrimerImportResult({required this.tables, required this.report});
}

/// Imports the donor ohPrimer's plaintext JSON backup (index.html
/// `exportBackup`: `{version:1, exportedAt, profile:{name,pid,prefs,stats,
/// feeds}, books, extracts}`) into our row maps, with the donor's own
/// import discipline ported:
///
///  - **prototype-pollution key rejection** ([sanitizePrimerValue]);
///  - **id re-scoping** — books collide by `(filename, size)` under the
///    target profile, exactly the donor's `reidBookForProfile`; unlike the
///    donor, an extract's book reference is re-scoped the same way so
///    imported cards keep pointing at the imported works;
///  - **dedupe** — books by re-scoped id (newer `lastReadAt` wins), extracts
///    by id, feeds by url;
///  - the donor's **10 000-record inflation-bomb cap**.
///
/// Deliberately dropped, never imported (tested absent):
///  - **ML caches** — Whisper word timings, MT translations, figure blobs.
///    Works rows are built from an allowlist, so unknown donor fields stay
///    behind by construction; the app regenerates these on device.
///  - **everything in the donor's `prefs`** — model-download consents,
///    proxy egress consent, parent PIN, BYOK API key, dormant sync seed.
///    Consents never travel; secrets never travel.
///
/// Named lossy mappings (each pinned by a test):
///  - the donor's reading `position` is a global word offset over the
///    donor's own tokenization; the spine cursor is `(segmentIdx, wordIdx)`,
///    so it is imported under `segmentIdx 0` and the reader clamps;
///  - `nextReview` (epoch ms) truncates to `dueEpochDay` — time of day lost;
///  - the donor kept no lapse counter — `lapses` is reconstructed as the
///    count of failing grades (g < 3) in the review history.
abstract final class OhPrimerImporter {
  /// The donor's `MAX_IMPORT_RECORDS` guard, ported verbatim.
  static const int maxImportRecords = 10000;

  static const int _msPerDay = 86400000;

  /// Parses [jsonText] and maps books/positions/extracts/feeds into row
  /// maps re-scoped to [profileId].
  ///
  /// Throws [FormatException] for non-JSON input or any `version` other
  /// than the donor's only shipped version (1) — donor parity.
  static PrimerImportResult importJson(
    String jsonText, {
    required String profileId,
  }) {
    final Object? root;
    try {
      root = jsonDecode(jsonText);
    } on FormatException {
      throw const FormatException('Not valid JSON');
    }
    if (root is! Map<String, dynamic> || root['version'] != 1) {
      throw const FormatException('Unsupported backup format');
    }

    final skipped = <String, int>{};
    void skip(String reason, [int count = 1]) {
      if (count <= 0) return;
      skipped[reason] = (skipped[reason] ?? 0) + count;
    }

    // ── Books → works + segments + positions ──────────────────────────
    final rawBooks = root['books'];
    var bookList = rawBooks is List ? rawBooks : const <Object?>[];
    if (bookList.length > maxImportRecords) {
      skip('records past the donor import cap',
          bookList.length - maxImportRecords);
      bookList = bookList.sublist(0, maxImportRecords);
    }

    // Dedupe by re-scoped id first (donor rule: collide by (filename,size),
    // newer lastReadAt wins) so duplicates never emit duplicate segments.
    final winners = <String, Map<String, Object?>>{};
    for (final raw in bookList) {
      if (raw is! Map) continue;
      final book = sanitizePrimerValue(raw)! as Map<String, Object?>;
      final id = _rescopeBookId(book, profileId);
      final existing = winners[id];
      if (existing != null) {
        if (_epochMs(existing['lastReadAt']) >= _epochMs(book['lastReadAt'])) {
          skip('duplicate book (kept the newer copy)');
          continue;
        }
        skip('duplicate book (kept the newer copy)');
      }
      winners[id] = book;
    }

    final workRows = <Map<String, Object?>>[];
    final segmentRows = <Map<String, Object?>>[];
    final positionRows = <Map<String, Object?>>[];
    winners.forEach((workId, book) {
      // Allowlist, not blocklist: ML caches (wordTimings, translations) and
      // the parsed body's figure blobs stay behind by construction.
      workRows.add({
        'id': workId,
        'profileId': profileId,
        'kind': book['kind'] is String ? book['kind'] : 'book',
        'title': book['title'] is String ? book['title'] : _filenameOf(book),
        'filename': _filenameOf(book),
        'size': _sizeOf(book),
        'source': book['source'] is Map ? book['source'] : null,
        'wordCount': book['wordCount'] is num
            ? (book['wordCount'] as num).toInt()
            : null,
        'priority':
            book['priority'] is num ? (book['priority'] as num).toInt() : 0,
        'addedAt':
            book['addedAt'] is num ? (book['addedAt'] as num).toInt() : null,
        'lastReadAt': _epochMs(book['lastReadAt']),
        'detectedLang':
            book['sourceLang'] is String ? book['sourceLang'] : null,
        'persistence': 'work', // a kept book is a work; ephemera never export
      });

      final parsed = book['parsed'];
      final blocks = parsed is Map ? parsed['blocks'] : null;
      if (blocks is List) {
        var idx = 0;
        for (final raw in blocks) {
          final segment = _segmentFromBlock(raw);
          if (segment == null) {
            skip('unrecognized block type in a book body');
            continue;
          }
          segmentRows.add({
            'workId': workId,
            'idx': idx++,
            'kind': segment.kind,
            'text': segment.text,
          });
        }
      }

      final position =
          book['position'] is num ? (book['position'] as num).toInt() : 0;
      if (position > 0) {
        // NAMED lossy mapping: a donor position is a global word offset over
        // the donor's own tokenization; the spine cursor is (segment, word).
        // Imported under segmentIdx 0 — the reader clamps on first open.
        positionRows.add({
          'profileId': profileId,
          'workId': workId,
          'segmentIdx': 0,
          'wordIdx': position,
          'lastModality': 'read',
          'updatedAt': _epochMs(book['lastReadAt']),
        });
      }
    });

    // ── Extracts → cards + revlog ─────────────────────────────────────
    final rawExtracts = root['extracts'];
    var extractList = rawExtracts is List ? rawExtracts : const <Object?>[];
    if (extractList.length > maxImportRecords) {
      skip('records past the donor import cap',
          extractList.length - maxImportRecords);
      extractList = extractList.sublist(0, maxImportRecords);
    }

    final cardRows = <Map<String, Object?>>[];
    final revlogRows = <Map<String, Object?>>[];
    final seenExtractIds = <String>{};
    for (final raw in extractList) {
      if (raw is! Map) continue;
      final extract = sanitizePrimerValue(raw)! as Map<String, Object?>;
      final id = extract['id'];
      if (id is! String || id.isEmpty || !seenExtractIds.add(id)) {
        skip('extract without an id or a duplicate of one already imported');
        continue;
      }

      // Reconstruct lapses + revlog from the donor's review history.
      var lapses = 0;
      final history = extract['history'];
      if (history is List) {
        for (final entry in history) {
          if (entry is! Map) continue;
          final t = entry['t'];
          final g = entry['g'];
          if (t is! num || g is! num) continue;
          if (g < 3) lapses++;
          revlogRows.add({
            'profileId': profileId,
            'itemId': id,
            'at': t.toInt(),
            'grade': g.toInt(),
          });
        }
      }

      final nextReview = extract['nextReview'];
      final bookId = extract['bookId'];
      cardRows.add({
        'profileId': profileId,
        'itemId': id,
        'courseId': null, // extracts are their own deck, not course items
        'workId': bookId is String && bookId.isNotEmpty
            ? _rescopeBookId({'id': bookId}, profileId)
            : null,
        'kind': extract['kind'] is String ? extract['kind'] : 'passage',
        // SM-2 state — donor names on the left of each mapping:
        // EF -> ease, interval -> intervalDays, reps -> reps.
        'ease': extract['EF'] is num ? (extract['EF'] as num).toDouble() : 2.5,
        'intervalDays': extract['interval'] is num
            ? (extract['interval'] as num).toInt()
            : 0,
        'reps': extract['reps'] is num ? (extract['reps'] as num).toInt() : 0,
        'lapses': lapses,
        // NAMED lossy mapping: epoch ms truncates to epoch day.
        'dueEpochDay':
            nextReview is num ? nextReview.toInt() ~/ _msPerDay : null,
        'createdAt': extract['createdAt'] is num
            ? (extract['createdAt'] as num).toInt()
            : null,
        'focusWord':
            extract['focusWord'] is String ? extract['focusWord'] : null,
        'context': extract['context'] is String ? extract['context'] : null,
        'wordIdx':
            extract['wordIdx'] is num ? (extract['wordIdx'] as num).toInt() : null,
        'focusIdx': extract['focusIdx'] is num
            ? (extract['focusIdx'] as num).toInt()
            : null,
        'focusEndIdx': extract['focusEndIdx'] is num
            ? (extract['focusEndIdx'] as num).toInt()
            : null,
        'chapterTitle':
            extract['chapterTitle'] is String ? extract['chapterTitle'] : null,
        'bookTitle':
            extract['bookTitle'] is String ? extract['bookTitle'] : null,
      });
    }

    // ── Profile → profiles + feeds ────────────────────────────────────
    final rawProfile = root['profile'];
    final profile = rawProfile is Map
        ? sanitizePrimerValue(rawProfile)! as Map<String, Object?>
        : const <String, Object?>{};

    final stats = profile['stats'] is Map
        ? profile['stats'] as Map<String, Object?>
        : const <String, Object?>{};
    final profileRows = <Map<String, Object?>>[
      {
        'id': profileId,
        'name': profile['name'] is String ? profile['name'] : 'Reader',
        // prefs are deliberately never read: consents, parent PIN, BYOK API
        // key and the dormant sync seed all live there. Never travel.
        'stats': {
          'wordsRead': _statOf(stats, 'wordsRead'),
          'minutes': _statOf(stats, 'minutes'),
          'sessions': _statOf(stats, 'sessions'),
        },
      },
    ];

    final feedRows = <Map<String, Object?>>[];
    final seenFeedUrls = <String>{};
    final feeds = profile['feeds'];
    if (feeds is List) {
      for (final raw in feeds) {
        if (raw is! Map) continue;
        final url = raw['url'];
        if (url is! String || url.isEmpty) {
          skip('feed without an address');
          continue;
        }
        if (!seenFeedUrls.add(url)) {
          skip('duplicate feed');
          continue;
        }
        feedRows.add({
          'profileId': profileId,
          'url': url,
          'title': raw['title'] is String ? raw['title'] : url,
        });
      }
    }

    final tables = <String, List<Map<String, Object?>>>{
      for (final name in espalierBackupTables) name: const [],
    };
    tables['profiles'] = profileRows;
    tables['works'] = workRows;
    tables['segments'] = segmentRows;
    tables['positions'] = positionRows;
    tables['cards'] = cardRows;
    tables['revlog'] = revlogRows;
    tables['feeds'] = feedRows;

    final imported = <String, int>{
      for (final entry in tables.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value.length,
    };

    return PrimerImportResult(
      tables: tables,
      report: MigrationReport(
        imported: imported,
        skipped: skipped,
        dropped: const [
          'On-device ML caches (word timings, translations, figure data) '
              'stayed behind — this app can regenerate them from the source.',
          'Model-download and proxy consents never travel; this device will '
              'ask fresh.',
          'Reader settings — including the parent PIN and any API key — '
              'stay on the old device.',
        ],
      ),
    );
  }

  /// The donor's `reidBookForProfile`, ported: rebuild the id under the
  /// target profile from `(filename, size)`, falling back to the old id's
  /// `pid::filename::size` parts, then `unknown`/`0`.
  static String _rescopeBookId(Map<String, Object?> book, String profileId) =>
      '$profileId::${_filenameOf(book)}::${_sizeOf(book)}';

  static String _filenameOf(Map<String, Object?> book) {
    final filename = book['filename'];
    if (filename is String && filename.isNotEmpty) return filename;
    final parts = (book['id'] is String ? book['id']! as String : '')
        .split('::');
    if (parts.length > 1 && parts[1].isNotEmpty) return parts[1];
    return 'unknown';
  }

  static int _sizeOf(Map<String, Object?> book) {
    final size = book['size'];
    if (size is num) return size.toInt();
    final parts = (book['id'] is String ? book['id']! as String : '')
        .split('::');
    if (parts.length > 2) return int.tryParse(parts[2]) ?? 0;
    return 0;
  }

  static int _epochMs(Object? v) => v is num ? v.toInt() : 0;

  static int _statOf(Map<String, Object?> stats, String key) =>
      stats[key] is num ? (stats[key] as num).toInt() : 0;

  /// Maps a donor parsed block to a spine segment, or null for a block this
  /// importer does not recognize.
  static ({String kind, String text})? _segmentFromBlock(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    if (type == 'chapter') {
      final title = raw['title'];
      return (kind: 'heading', text: title is String ? title : '');
    }
    if (type == 'text') {
      final text = raw['text'];
      return (kind: 'prose', text: text is String ? text : '');
    }
    if (type == 'segment') {
      final kind = raw['kind'];
      if (kind is! String || kind.isEmpty) return null;
      final content = raw['content'];
      if (kind == 'figure') {
        // Figure bytes never round-trip (the donor export empties them);
        // the alt text is what remains meaningful.
        final alt = content is Map ? content['alt'] : null;
        return (kind: 'figure', text: alt is String ? alt : '');
      }
      return (kind: kind, text: content is String ? content : '');
    }
    return null;
  }
}

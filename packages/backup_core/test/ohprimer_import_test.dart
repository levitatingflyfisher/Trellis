import 'dart:convert';

import 'package:backup_core/backup_core.dart';
import 'package:test/test.dart';

/// A donor-faithful ohPrimer export (index.html `exportBackup`):
/// `{version:1, exportedAt, profile:{name,pid,prefs,stats,feeds}, books,
/// extracts}` — prefs carry the consents and secrets that must never travel.
Map<String, Object?> donorExport({
  List<Object?>? books,
  List<Object?>? extracts,
  List<Object?>? feeds,
  Map<String, Object?>? prefsOverride,
}) =>
    {
      'version': 1,
      'exportedAt': '2026-08-01T00:00:00.000Z',
      'profile': {
        'name': 'Reader',
        'pid': 'gentle-oak-1234',
        'prefs': prefsOverride ??
            {
              'wpm': 300,
              'theme': 'auto',
              'parentPin': '4321',
              'sync': {'relayUrl': '', 'seed': 'deadbeefcafe'},
              'ai': {'provider': 'anthropic', 'key': 'sk-secret-key'},
              'egressConsent': {'proxy': 1754000000000},
              'modelConsent': {'whisper-tiny': 1754000000001},
            },
        'stats': {'wordsRead': 100, 'minutes': 5, 'sessions': 2},
        'feeds': feeds ??
            [
              {'url': 'https://a.example/feed.xml', 'title': 'A'},
            ],
      },
      'books': books ?? [],
      'extracts': extracts ?? [],
    };

Map<String, Object?> walden() => {
      'id': 'gentle-oak-1234::walden.epub::4242',
      'profileIdx': 'gentle-oak-1234',
      'kind': 'book',
      'title': 'Walden',
      'filename': 'walden.epub',
      'size': 4242,
      'source': {'kind': 'file', 'label': 'walden.epub'},
      'wordCount': 5000,
      'position': 1234,
      'priority': 0,
      'addedAt': 1753000000000,
      'lastReadAt': 1754000000000,
      'sourceLang': 'en',
      // ML caches the import must leave behind:
      'wordTimings': [
        {'i': 0, 'start': 0.0, 'end': 0.4},
      ],
      'translations': {
        'es': ['Fui a los bosques'],
      },
      'parsed': {
        'title': 'Walden',
        'blocks': [
          {'type': 'chapter', 'title': 'Economy'},
          {'type': 'text', 'text': 'I went to the woods'},
          {'type': 'segment', 'kind': 'code', 'content': 'x = 1'},
          {
            'type': 'segment',
            'kind': 'figure',
            'content': {'src': 'fig.png', 'alt': 'a pond'},
          },
        ],
        'skipped': 0,
        'toc': [],
        'spineAnchors': [],
        'figureBlobs': <String, Object?>{},
      },
    };

Map<String, Object?> extractCard() => {
      'id': 'ext::gentle-oak-1234::123::abc12',
      'profileIdx': 'gentle-oak-1234',
      'bookId': 'gentle-oak-1234::walden.epub::4242',
      'createdAt': 1753500000000,
      'EF': 2.3,
      'reps': 2,
      'interval': 6,
      'nextReview': 1786061234567,
      'history': [
        {'t': 1785000000000, 'g': 5},
        {'t': 1785100000000, 'g': 2},
      ],
      'kind': 'word',
      'bookTitle': 'Walden',
      'wordIdx': 1200,
      'focusIdx': 3,
      'focusEndIdx': 3,
      'focusWord': 'woods',
      'context': 'I went to the woods',
      'chapterTitle': 'Economy',
    };

PrimerImportResult run(Map<String, Object?> export) =>
    OhPrimerImporter.importJson(jsonEncode(export), profileId: 'p1');

void main() {
  group('sanitizePrimerValue (donor sanitizeImported, ported)', () {
    test('strips __proto__/constructor/prototype keys recursively', () {
      final dirty = {
        '__proto__': {'polluted': true},
        'ok': 1,
        'nested': {
          'constructor': 'bad',
          'list': [
            {'prototype': 'bad', 'keep': 2},
          ],
        },
      };
      final clean = sanitizePrimerValue(dirty) as Map;
      expect(clean.containsKey('__proto__'), isFalse);
      expect(clean['ok'], 1);
      final nested = clean['nested'] as Map;
      expect(nested.containsKey('constructor'), isFalse);
      final inList = (nested['list'] as List).single as Map;
      expect(inList.containsKey('prototype'), isFalse);
      expect(inList['keep'], 2);
    });

    test('donor parity: depth caps at 30 — deeper values pass unchanged',
        () {
      Object? chain = {'__proto__': 'deep'};
      for (var i = 0; i < 32; i++) {
        chain = {'d': chain};
      }
      var node = sanitizePrimerValue(chain);
      while (node is Map && node.containsKey('d')) {
        node = node['d'];
      }
      // The polluting key survived below the donor's cap — exact parity
      // with index.html sanitizeImported (depth>30 returns v as-is).
      expect((node as Map).containsKey('__proto__'), isTrue);
    });

    test('scalars and null pass through', () {
      expect(sanitizePrimerValue(null), isNull);
      expect(sanitizePrimerValue(42), 42);
      expect(sanitizePrimerValue('x'), 'x');
    });
  });

  group('OhPrimerImporter — shape and re-scoping', () {
    test('rejects non-JSON and wrong version (donor parity)', () {
      expect(
        () => OhPrimerImporter.importJson('not json', profileId: 'p1'),
        throwsFormatException,
      );
      expect(
        () => run(donorExport()..['version'] = 2),
        throwsFormatException,
      );
      expect(
        () => OhPrimerImporter.importJson('[1,2]', profileId: 'p1'),
        throwsFormatException,
      );
    });

    test('maps profile/books/positions/extracts/feeds into row maps', () {
      final result = run(donorExport(
        books: [walden()],
        extracts: [extractCard()],
      ));

      expect(result.tables['profiles'], [
        {
          'id': 'p1',
          'name': 'Reader',
          'stats': {'wordsRead': 100, 'minutes': 5, 'sessions': 2},
        },
      ]);

      final work = result.tables['works']!.single;
      expect(work['id'], 'p1::walden.epub::4242'); // re-scoped to us
      expect(work['profileId'], 'p1');
      expect(work['kind'], 'book');
      expect(work['title'], 'Walden');
      expect(work['detectedLang'], 'en');
      expect(work['persistence'], 'work');
      expect(work['wordCount'], 5000);
      expect(work['lastReadAt'], 1754000000000);

      expect(result.tables['segments'], [
        {
          'workId': 'p1::walden.epub::4242',
          'idx': 0,
          'kind': 'heading',
          'text': 'Economy',
        },
        {
          'workId': 'p1::walden.epub::4242',
          'idx': 1,
          'kind': 'prose',
          'text': 'I went to the woods',
        },
        {
          'workId': 'p1::walden.epub::4242',
          'idx': 2,
          'kind': 'code',
          'text': 'x = 1',
        },
        {
          'workId': 'p1::walden.epub::4242',
          'idx': 3,
          'kind': 'figure',
          'text': 'a pond',
        },
      ]);

      final position = result.tables['positions']!.single;
      expect(position['workId'], 'p1::walden.epub::4242');
      expect(position['profileId'], 'p1');
      expect(position['wordIdx'], 1234);
      expect(position['lastModality'], 'read');

      final card = result.tables['cards']!.single;
      expect(card['itemId'], 'ext::gentle-oak-1234::123::abc12');
      expect(card['profileId'], 'p1');
      expect(card['courseId'], isNull); // extracts are not course items
      expect(card['workId'], 'p1::walden.epub::4242'); // re-scoped with book
      expect(card['focusWord'], 'woods');

      expect(result.tables['feeds'], [
        {'profileId': 'p1', 'url': 'https://a.example/feed.xml', 'title': 'A'},
      ]);

      expect(result.report.imported['works'], 1);
      expect(result.report.imported['cards'], 1);
    });

    test('a book id is rebuilt from filename+size even when only the old '
        'id carries them (donor reidBookForProfile fallback)', () {
      final result = run(donorExport(books: [
        {'id': 'old-pid::doc.txt::77', 'lastReadAt': 1},
        {'lastReadAt': 2},
      ]));
      final ids =
          result.tables['works']!.map((w) => w['id']).toList();
      expect(ids, containsAll(['p1::doc.txt::77', 'p1::unknown::0']));
    });

    test('duplicate books collide by (filename,size); the newer lastReadAt '
        'wins regardless of order (donor merge rule)', () {
      final older = walden()..['lastReadAt'] = 100;
      final newer = walden()
        ..['lastReadAt'] = 200
        ..['title'] = 'Walden (fresh)';

      for (final ordering in [
        [older, newer],
        [newer, older],
      ]) {
        final result = run(donorExport(books: ordering));
        final work = result.tables['works']!.single;
        expect(work['title'], 'Walden (fresh)');
        expect(result.report.skipped.values.fold<int>(0, (a, b) => a + b), 1);
      }
    });

    test('extracts dedupe by id; an extract with no id is skipped '
        '(donor parity)', () {
      final result = run(donorExport(extracts: [
        extractCard(),
        extractCard(), // exact duplicate id
        (extractCard()..remove('id')),
      ]));
      expect(result.tables['cards'], hasLength(1));
      expect(result.report.skipped.values.fold<int>(0, (a, b) => a + b), 2);
    });

    test('feeds dedupe by url and require one (donor parity)', () {
      final result = run(donorExport(feeds: [
        {'url': 'https://a.example/feed.xml', 'title': 'A'},
        {'url': 'https://a.example/feed.xml', 'title': 'dupe'},
        {'title': 'no url'},
      ]));
      expect(result.tables['feeds'], hasLength(1));
      expect(result.report.skipped.values.fold<int>(0, (a, b) => a + b), 2);
    });

    test('the donor 10000-record inflation cap is ported', () {
      final books = List<Object?>.generate(
        OhPrimerImporter.maxImportRecords + 1,
        (i) => {'id': 'x::f$i.txt::$i', 'filename': 'f$i.txt', 'size': i},
      );
      final result = run(donorExport(books: books));
      expect(
          result.tables['works'], hasLength(OhPrimerImporter.maxImportRecords));
      expect(result.report.skipped.values.fold<int>(0, (a, b) => a + b), 1);
    });

    test('an unknown block type is skipped and counted', () {
      final book = walden();
      ((book['parsed'] as Map)['blocks'] as List).add({'type': 'weird'});
      final result = run(donorExport(books: [book]));
      expect(result.tables['segments'], hasLength(4));
      expect(result.report.skipped.keys.join(' '), contains('block'));
    });
  });

  group('OhPrimerImporter — SRS mapping', () {
    test('EF/reps/interval map onto ease/reps/intervalDays; nextReview (ms) '
        'truncates to dueEpochDay — the time of day is the NAMED lossy field',
        () {
      final result = run(donorExport(extracts: [extractCard()]));
      final card = result.tables['cards']!.single;
      expect(card['ease'], 2.3);
      expect(card['reps'], 2);
      expect(card['intervalDays'], 6);
      // 1786061234567 ms ~/ 86400000 = epoch day 20672; the 12:07 UTC
      // time-of-day the donor stored is truncated away.
      expect(card['dueEpochDay'], 20672);
    });

    test('the donor stored no lapse counter — lapses are reconstructed as '
        'the count of failing grades (g<3) in the review history', () {
      final result = run(donorExport(extracts: [extractCard()]));
      expect(result.tables['cards']!.single['lapses'], 1); // one g:2
    });

    test('review history becomes revlog rows', () {
      final result = run(donorExport(extracts: [extractCard()]));
      expect(result.tables['revlog'], [
        {
          'profileId': 'p1',
          'itemId': 'ext::gentle-oak-1234::123::abc12',
          'at': 1785000000000,
          'grade': 5,
        },
        {
          'profileId': 'p1',
          'itemId': 'ext::gentle-oak-1234::123::abc12',
          'at': 1785100000000,
          'grade': 2,
        },
      ]);
    });

    test('missing SRS fields fall back to the donor defaults '
        '(EF 2.5, reps 0, interval 0)', () {
      final bare = {
        'id': 'ext::old::1::a',
        'kind': 'passage',
        'focusWord': 'x',
      };
      final result = run(donorExport(extracts: [bare]));
      final card = result.tables['cards']!.single;
      expect(card['ease'], 2.5);
      expect(card['reps'], 0);
      expect(card['intervalDays'], 0);
      expect(card['lapses'], 0);
    });
  });

  group('OhPrimerImporter — what never travels', () {
    test('ML caches (word timings, translations, figure blobs) are dropped '
        'and the report says so', () {
      final result = run(donorExport(books: [walden()]));
      final encoded = jsonEncode(result.tables);
      expect(encoded, isNot(contains('wordTimings')));
      expect(encoded, isNot(contains('translations')));
      expect(encoded, isNot(contains('figureBlobs')));
      expect(result.tables['layers'], isEmpty);
      expect(result.tables['alignments'], isEmpty);
      expect(result.report.dropped.join(' '), contains('regenerate'));
    });

    test('model consents, proxy consent, parent PIN, API key and sync seed '
        'NEVER travel — tested absent from every row', () {
      final result = run(donorExport(
        books: [walden()],
        extracts: [extractCard()],
      ));
      final encoded = jsonEncode(result.tables);
      expect(encoded, isNot(contains('modelConsent')));
      expect(encoded, isNot(contains('egressConsent')));
      expect(encoded, isNot(contains('consent')));
      expect(encoded, isNot(contains('parentPin')));
      expect(encoded, isNot(contains('sk-secret-key')));
      expect(encoded, isNot(contains('deadbeefcafe')));
      expect(result.tables['profiles']!.single.containsKey('prefs'), isFalse);
      expect(result.tables.containsKey('consents'), isFalse);
      expect(result.report.dropped.join(' '), contains('consent'));
    });

    test('prototype-polluting keys in donor records never reach the rows',
        () {
      final book = walden()..['__proto__'] = {'evil': true};
      ((book['parsed'] as Map))['constructor'] = 'evil';
      final result = run(donorExport(books: [book]));
      final encoded = jsonEncode(result.tables);
      expect(encoded, isNot(contains('__proto__')));
      expect(encoded, isNot(contains('evil')));
    });
  });

  group('OhPrimerImporter — result contract', () {
    test('tables carry the full canonical shape and re-encode under our '
        'own envelope law', () {
      final result = run(donorExport(
        books: [walden()],
        extracts: [extractCard()],
      ));
      expect(result.tables.keys.toSet(), espalierBackupTables.toSet());
      expect(
        () => RowPayload.encode(result.tables,
            createdAt: DateTime.utc(2026, 8, 6)),
        returnsNormally,
      );
    });

    test('the donor position is a global word offset over the donor\'s own '
        'tokenization — imported under segmentIdx 0 as the NAMED lossy '
        'mapping (the reader clamps on first open)', () {
      final result = run(donorExport(books: [walden()]));
      final position = result.tables['positions']!.single;
      expect(position['segmentIdx'], 0);
      expect(position['wordIdx'], 1234);
    });

    test('a book never opened (position 0) produces no position row', () {
      final book = walden()..['position'] = 0;
      final result = run(donorExport(books: [book]));
      expect(result.tables['positions'], isEmpty);
    });
  });
}

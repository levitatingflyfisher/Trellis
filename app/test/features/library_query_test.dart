import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart' hide Alignment;
import 'package:trellis/features/library/library_query.dart';

/// Phase 2 (Campaign 5): a small pure query model over the library —
/// evaluated in Dart, no schema change, no dependency on drift at all.
/// Every field is optional and AND-combined: an unset field is ignored,
/// a set field must match.
void main() {
  Work work({
    int id = 1,
    String kind = 'book',
    String title = 'A title',
    bool pinned = false,
    int? finishedEpochDay,
  }) =>
      Work(
          id: id,
          profileId: 1,
          kind: kind,
          title: title,
          sourceUrl: null,
          lang: null,
          persistence: 'work',
          firstSeenEpochDay: 1,
          pinned: pinned,
          showTranslationLayer: false,
          finishedEpochDay: finishedEpochDay);

  Episode episode({
    int workId = 1,
    int feedId = 1,
    int? readAtMs,
    int publishedAtMs = 1000,
  }) =>
      Episode(
          workId: workId,
          feedId: feedId,
          guid: 'g',
          enclosureUrl: 'https://a/1.mp3',
          durationMs: null,
          publishedAtMs: publishedAtMs,
          readAtMs: readAtMs,
          archivedAtMs: null);

  group('text search — matches the title, case-insensitive', () {
    test('a substring match passes', () {
      final e = (work: work(title: 'Attention Sovereignty'), episode: null, feedTitle: null);
      expect(
          matchesLibraryQuery(e, const LibraryQuery(textSearch: 'sovereignty')),
          isTrue);
    });

    test('no match fails', () {
      final e = (work: work(title: 'Attention Sovereignty'), episode: null, feedTitle: null);
      expect(matchesLibraryQuery(e, const LibraryQuery(textSearch: 'xyz')),
          isFalse);
    });

    test('an unset search matches everything', () {
      final e = (work: work(title: 'Anything'), episode: null, feedTitle: null);
      expect(matchesLibraryQuery(e, const LibraryQuery()), isTrue);
    });
  });

  group('type — mapped from the real work kinds, "course" deliberately '
      'absent (courses are never spine works)', () {
    test('book/article/episode(podcast)/note each map correctly', () {
      expect(
          matchesLibraryQuery((work: work(kind: 'book'), episode: null, feedTitle: null),
              const LibraryQuery(types: {LibraryItemType.book})),
          isTrue);
      expect(
          matchesLibraryQuery(
              (work: work(kind: 'article'), episode: null, feedTitle: null),
              const LibraryQuery(types: {LibraryItemType.article})),
          isTrue);
      expect(
          matchesLibraryQuery((work: work(kind: 'episode'), episode: episode(), feedTitle: 'F'),
              const LibraryQuery(types: {LibraryItemType.podcast})),
          isTrue);
      expect(
          matchesLibraryQuery((work: work(kind: 'note'), episode: null, feedTitle: null),
              const LibraryQuery(types: {LibraryItemType.note})),
          isTrue);
    });

    test('a mismatched type fails', () {
      final e = (work: work(kind: 'book'), episode: null, feedTitle: null);
      expect(
          matchesLibraryQuery(e, const LibraryQuery(types: {LibraryItemType.article})),
          isFalse);
    });

    test('an empty type set matches every kind', () {
      final e = (work: work(kind: 'book'), episode: null, feedTitle: null);
      expect(matchesLibraryQuery(e, const LibraryQuery()), isTrue);
    });
  });

  group('feed/source — only episode works can match a feedId', () {
    test('matches the episode\'s own feed', () {
      final e = (
        work: work(kind: 'episode'),
        episode: episode(feedId: 7),
        feedTitle: 'F'
      );
      expect(matchesLibraryQuery(e, const LibraryQuery(feedId: 7)), isTrue);
    });

    test('a different feedId fails', () {
      final e = (
        work: work(kind: 'episode'),
        episode: episode(feedId: 7),
        feedTitle: 'F'
      );
      expect(matchesLibraryQuery(e, const LibraryQuery(feedId: 8)), isFalse);
    });

    test('a non-episode work never matches a feedId filter', () {
      final e = (work: work(kind: 'book'), episode: null, feedTitle: null);
      expect(matchesLibraryQuery(e, const LibraryQuery(feedId: 7)), isFalse);
    });
  });

  group('read state — episode.readAtMs for episodes, '
      'work.finishedEpochDay for everything else', () {
    test('an episode with readAtMs set counts as read', () {
      final e = (
        work: work(kind: 'episode'),
        episode: episode(readAtMs: 500),
        feedTitle: 'F'
      );
      expect(
          matchesLibraryQuery(e, const LibraryQuery(readState: ReadState.read)),
          isTrue);
      expect(
          matchesLibraryQuery(
              e, const LibraryQuery(readState: ReadState.unread)),
          isFalse);
    });

    test('a book with finishedEpochDay set counts as read', () {
      final e = (
        work: work(kind: 'book', finishedEpochDay: 20),
        episode: null,
        feedTitle: null
      );
      expect(
          matchesLibraryQuery(e, const LibraryQuery(readState: ReadState.read)),
          isTrue);
    });

    test('an unfinished book counts as unread', () {
      final e = (work: work(kind: 'book'), episode: null, feedTitle: null);
      expect(
          matchesLibraryQuery(
              e, const LibraryQuery(readState: ReadState.unread)),
          isTrue);
    });
  });

  group('pinned', () {
    test('pinned:true keeps only pinned works', () {
      expect(
          matchesLibraryQuery(
              (work: work(pinned: true), episode: null, feedTitle: null),
              const LibraryQuery(pinned: true)),
          isTrue);
      expect(
          matchesLibraryQuery(
              (work: work(pinned: false), episode: null, feedTitle: null),
              const LibraryQuery(pinned: true)),
          isFalse);
    });
  });

  group('AND-combined — every set field must match', () {
    test('type matches but read state fails -> no match', () {
      final e = (
        work: work(kind: 'book'),
        episode: null,
        feedTitle: null,
      ); // unread
      expect(
          matchesLibraryQuery(
              e,
              const LibraryQuery(
                  types: {LibraryItemType.book}, readState: ReadState.read)),
          isFalse);
    });
  });

  group('JSON round-trip — the saved-view persistence codec', () {
    test('every field survives encode/decode', () {
      const q = LibraryQuery(
          textSearch: 'aurora',
          types: {LibraryItemType.article, LibraryItemType.podcast},
          feedId: 3,
          readState: ReadState.unread,
          pinned: true);
      final decoded = LibraryQuery.fromJson(q.toJson());
      expect(decoded.textSearch, 'aurora');
      expect(decoded.types, {LibraryItemType.article, LibraryItemType.podcast});
      expect(decoded.feedId, 3);
      expect(decoded.readState, ReadState.unread);
      expect(decoded.pinned, true);
    });

    test('an empty query round-trips to an empty query', () {
      const q = LibraryQuery();
      final decoded = LibraryQuery.fromJson(q.toJson());
      expect(decoded.textSearch, isNull);
      expect(decoded.types, isEmpty);
      expect(decoded.feedId, isNull);
      expect(decoded.readState, ReadState.any);
      expect(decoded.pinned, isNull);
    });
  });

  group('isEmpty — distinguishes a real filter from a no-op one', () {
    test('the default query is empty', () {
      expect(const LibraryQuery().isEmpty, isTrue);
    });

    test('a blank text search is still empty', () {
      expect(const LibraryQuery(textSearch: '').isEmpty, isTrue);
    });

    test('any single set field makes it non-empty', () {
      expect(const LibraryQuery(textSearch: 'x').isEmpty, isFalse);
      expect(
          const LibraryQuery(types: {LibraryItemType.book}).isEmpty, isFalse);
      expect(const LibraryQuery(feedId: 1).isEmpty, isFalse);
      expect(const LibraryQuery(readState: ReadState.unread).isEmpty,
          isFalse);
      expect(const LibraryQuery(pinned: true).isEmpty, isFalse);
    });
  });
}

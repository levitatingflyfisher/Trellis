/// Feed-item ingestion into the spine (ADR-0002): every item IS a work —
/// audio items are `episode` works whose sourceUrl is the enclosure, text
/// items are `article` works whose sourceUrl is the link. All arrive as
/// ephemera; promotion is the user's hand (ADR-0003 law 2).
///
/// Also here: the published-date parser (comms_core deliberately leaves feed
/// dates raw — the donor never parsed them at that layer) and the breaker
/// state's persisted-json codec.
library;

import 'dart:convert';

import 'package:comms_core/comms_core.dart';

import '../../db/database.dart';
import 'feed_rules.dart';

/// RFC-822/1123 (`Wed, 05 Aug 2026 12:00:00 +0200`, seconds and weekday
/// optional, numeric or named zone) or ISO-8601. Null on garbage — the
/// caller falls back to arrival time, keeping the river's one ordering
/// honest rather than inventing a date.
int? parsePublishedMs(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  final m = _rfc822.firstMatch(t);
  if (m != null) {
    final month = _months.indexOf(m.group(2)!.toLowerCase());
    if (month >= 0) {
      var year = int.parse(m.group(3)!);
      if (year < 100) year += year >= 70 ? 1900 : 2000; // RFC-822 two-digit
      final utc = DateTime.utc(
        year,
        month + 1,
        int.parse(m.group(1)!),
        int.parse(m.group(4)!),
        int.parse(m.group(5)!),
        int.parse(m.group(6) ?? '0'),
      );
      final offsetMin = _zoneOffsetMinutes(m.group(7));
      return utc
          .subtract(Duration(minutes: offsetMin))
          .millisecondsSinceEpoch;
    }
  }
  final iso = DateTime.tryParse(t);
  return iso?.toUtc().millisecondsSinceEpoch;
}

final _rfc822 = RegExp(
    r'^(?:[A-Za-z]{3},\s*)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{2,4})\s+'
    r'(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\s+(\S+))?$');

const _months = [
  'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
];

/// RFC-822 zone → minutes east of UTC. Unknown named zones read as UTC
/// (the RFC's own advice for unrecognized zones).
int _zoneOffsetMinutes(String? zone) {
  if (zone == null || zone.isEmpty) return 0;
  final num = RegExp(r'^([+-])(\d{2})(\d{2})$').firstMatch(zone);
  if (num != null) {
    final sign = num.group(1) == '-' ? -1 : 1;
    return sign *
        (int.parse(num.group(2)!) * 60 + int.parse(num.group(3)!));
  }
  return switch (zone.toUpperCase()) {
    'EDT' => -4 * 60,
    'EST' || 'CDT' => -5 * 60,
    'CST' || 'MDT' => -6 * 60,
    'MST' || 'PDT' => -7 * 60,
    'PST' => -8 * 60,
    _ => 0, // GMT, UT, UTC, Z, unknown
  };
}

/// The breaker fields that persist on the feed row ([Feeds.breakerJson]).
/// URL, title and validators live in their own columns; this json carries
/// only the transition state comms_core owns.
String encodeBreakerState(FeedRefreshState s) => jsonEncode({
      'consecutiveFailures': s.consecutiveFailures,
      'broken': s.broken,
      if (s.lastError != null) 'lastError': s.lastError,
      if (s.throttledUntilMs != null) 'throttledUntilMs': s.throttledUntilMs,
      if (s.lastCheckedMs != null) 'lastCheckedMs': s.lastCheckedMs,
    });

FeedRefreshState decodeBreakerState(
    {required String url,
    required String title,
    required String? etag,
    required String? lastModified,
    required String json}) {
  Map<String, Object?> m;
  try {
    m = (jsonDecode(json) as Map).cast<String, Object?>();
  } catch (_) {
    m = const {};
  }
  return FeedRefreshState(
    url: url,
    title: title,
    etag: etag,
    lastModified: lastModified,
    consecutiveFailures: (m['consecutiveFailures'] as num?)?.toInt() ?? 0,
    broken: m['broken'] as bool? ?? false,
    lastError: m['lastError'] as String?,
    throttledUntilMs: (m['throttledUntilMs'] as num?)?.toInt(),
    lastCheckedMs: (m['lastCheckedMs'] as num?)?.toInt(),
  );
}

/// Convenience: a feed row → the pure refresh state comms_core transitions.
FeedRefreshState stateOfFeed(Feed feed) => decodeBreakerState(
    url: feed.url,
    title: feed.title,
    etag: feed.etag,
    lastModified: feed.lastModified,
    json: feed.breakerJson);

/// Item identity for dedupe: link, else enclosure URL, else title#date.
String guidOf(FeedItem item) {
  if (item.link.isNotEmpty) return item.link;
  if (item.audio.isNotEmpty) return item.audio;
  return '${item.title}#${item.date}';
}

/// Inserts unseen items as ephemeron works + episode rows in one
/// transaction. Returns how many were new.
///
/// [rules] (Campaign 5 Phase 3), evaluated per item against the FIRST
/// matching rule (see [evaluateFeedRules]): skip means no row is created
/// at all — not even counted toward [seen], so a still-skipped item is
/// simply re-evaluated (and re-skipped) on the next refresh, which is the
/// honest reading of "never enters"; markReadOnArrival and autoKeep both
/// insert normally, then apply the same transition Let-it-pass/Keep
/// perform by hand. An empty (or absent) rule list is every feed's
/// default and behaves exactly as ingestion did before this parameter
/// existed.
Future<int> ingestFeedItems(
    {required AppDatabase db,
    required int profileId,
    required int feedId,
    required List<FeedItem> items,
    required int nowMs,
    List<FeedRule> rules = const []}) async {
  final seen = await db.feedsDao.guidsOf(feedId);
  var added = 0;
  await db.transaction(() async {
    for (final item in items) {
      final guid = guidOf(item);
      if (!seen.add(guid)) continue;
      final action = rules.isEmpty
          ? null
          : evaluateFeedRules(rules,
              title: item.title, description: item.desc);
      if (action == FeedRuleAction.skip) continue;
      final enclosureUrl = item.enclosure?.url;
      // Tracker stripping (Campaign 5 Phase 4, the Miniflux lesson) applies
      // only to the article LINK, never the enclosure: a signed CDN/audio
      // URL's query params can be load-bearing, the same reason feed fetch
      // URLs themselves are never touched. guidOf (above) already ran on
      // the RAW item — stripping sourceUrl here can never make an
      // already-seen item look new.
      final sourceUrl = enclosureUrl ??
          (item.link.isEmpty ? null : canonicalizeForDedup(item.link));
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: enclosureUrl != null ? 'episode' : 'article',
          title: item.title.isEmpty ? 'Untitled' : item.title,
          persistence: 'ephemeron',
          firstSeenEpochDay: nowMs ~/ Duration.millisecondsPerDay,
          sourceUrl: sourceUrl);
      if (item.desc.isNotEmpty) {
        await db.spineDao.insertSegments(
            workId, [(idx: 0, kind: 'prose', text: item.desc)]);
      }
      await db.feedsDao.insertEpisode(
          workId: workId,
          feedId: feedId,
          guid: guid,
          enclosureUrl: enclosureUrl,
          publishedAtMs: parsePublishedMs(item.date) ?? nowMs);
      if (action == FeedRuleAction.markReadOnArrival) {
        await db.feedsDao.setReadAt(workId, nowMs);
      } else if (action == FeedRuleAction.autoKeep) {
        // The same transition Keep performs by hand (river_triage.dart).
        await db.spineDao.promoteWork(workId);
        await db.feedsDao.setReadAt(workId, nowMs);
      }
      added++;
    }
  });
  return added;
}

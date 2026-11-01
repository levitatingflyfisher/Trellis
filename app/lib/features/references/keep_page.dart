/// Keeping a cited page on the device (frozen references, owner ask of 21
/// and 24 Oct 2026: "frozen copies" of what a text cites, as Gwern's site
/// keeps them). A kept page is the readable article at the address, with
/// its own links, filed by address without its #fragment and dated by the
/// day it was kept. It is never fetched again.
///
/// The caller has the person's yes already (the one consent dialog, or a
/// setting they turned on); the lexical guard still runs here, and the
/// fetcher's own guard on every redirect hop.
library;

import 'package:comms_core/comms_core.dart';

import '../../db/database.dart';
import '../intake/article_fetch.dart';

/// What keeping one page came to.
sealed class KeepOutcome {
  const KeepOutcome();
}

/// The page is kept as work [workId] (now, or on an earlier day).
final class PageKept extends KeepOutcome {
  final int workId;
  const PageKept(this.workId);
}

/// The page could not be kept; [message] is one calm sentence.
final class PageNotKept extends KeepOutcome {
  final String message;
  const PageNotKept(this.message);
}

/// Keeps the page [href] points to for [profileId], dated [epochDay].
/// Never throws.
Future<KeepOutcome> keepLinkedPage({
  required AppDatabase db,
  required HttpFetcher fetcher,
  required int profileId,
  required String href,
  required int epochDay,
}) async {
  final key = keptKeyOf(href);
  final have = await db.spineDao.keptCopyOf(profileId, key);
  if (have != null) return PageKept(have.id);
  final Uri url;
  try {
    url = assertSafeFetchUrl(key);
  } on UnsafeUrlException catch (e) {
    return PageNotKept(e.message);
  } catch (_) {
    return const PageNotKept('That address can’t be kept.');
  }
  final outcome = await fetchArticle(fetcher: fetcher, url: url);
  switch (outcome) {
    case ArticleRefused(:final message):
      return PageNotKept(message);
    case ArticleFetched(:final article, :final rows, :final links):
      final id = await db.spineDao.storeKeptCopy(
          profileId: profileId,
          href: key,
          title: article.title.isEmpty ? url.host : article.title,
          epochDay: epochDay,
          rows: rows,
          links: links);
      return PageKept(id);
  }
}

/// [keepLinkedPage] for each distinct page among [hrefs], one at a time,
/// in order: each page's outcome by its address without the fragment.
/// [onProgress] hears after each page; [stopped] is asked before each
/// next one.
Future<Map<String, KeepOutcome>> keepLinkedPages({
  required AppDatabase db,
  required HttpFetcher fetcher,
  required int profileId,
  required Iterable<String> hrefs,
  required int epochDay,
  void Function(int done, int total)? onProgress,
  bool Function()? stopped,
}) async {
  final keys = <String>{for (final h in hrefs) keptKeyOf(h)}.toList();
  final out = <String, KeepOutcome>{};
  for (final key in keys) {
    if (stopped?.call() ?? false) break;
    out[key] = await keepLinkedPage(
        db: db,
        fetcher: fetcher,
        profileId: profileId,
        href: key,
        epochDay: epochDay);
    onProgress?.call(out.length, keys.length);
  }
  return out;
}

/// The device setting "Keep linked pages when saving": `on` keeps the
/// pages a newly saved article links to, right after it is saved. Off
/// until turned on, since each page is a request to another site.
const keepLinkedPagesKey = 'keep_linked_pages';

/// Keeps the pages work [workId] links to when [keepLinkedPagesKey] is
/// on: the save's own follow-on, never its condition. Never throws.
Future<void> keepLinkedPagesIfAsked({
  required AppDatabase db,
  required HttpFetcher fetcher,
  required int profileId,
  required int workId,
  required int epochDay,
}) async {
  try {
    if (await db.deviceSettingsDao.read(keepLinkedPagesKey) != 'on') return;
    final links = await db.spineDao.linksOf(workId);
    if (links.isEmpty) return;
    await keepLinkedPages(
        db: db,
        fetcher: fetcher,
        profileId: profileId,
        hrefs: [for (final l in links) l.href],
        epochDay: epochDay);
  } catch (_) {
    // A closed database or a lost connection keeps nothing more; the
    // text itself is already saved.
  }
}

/// Share to Trellis (1.5.5): what another app hands in through Android's
/// share sheet, routed by what it is. Bots' daily reports, a link, a
/// book: every source is on the same footing, so a shared text or page
/// is an ordinary row of Latest under the profile's Shared source, saved
/// through the same intake as a paste or a "From the web" add.
///
/// The share is the consent (ADR-0003 law 6, amended 1.5.5): the person
/// picked this one address out of another app and sent it here, which
/// names exactly what leaves the device, so no second dialog asks again.
/// The SSRF guard still runs first, and nothing else is ever fetched.
///
/// A link is saved before any byte moves: [ShareIntake.take] writes the
/// bare link to Latest at once, and [ShareIntake.fetchPageFor] fills that
/// same row with the article when the page arrives. A slow or absent
/// network never leaves a share unanswered, and a link that couldn't be
/// read is tried again when it is shared again or opened.
library;

import 'dart:convert';
import 'dart:io';

import 'package:comms_core/comms_core.dart';
import 'package:crypto/crypto.dart';
import 'package:intake_core/intake_core.dart'
    show extractArticle, naturalCompareAudiobookNames;

import '../../db/database.dart';
import '../models/format.dart';
import 'article_fetch.dart';
import 'audiobook_import.dart';
import 'audiobook_picker_gateway.dart' show audiobookExtensions;
import 'epub_intake.dart';
import 'paste_intake.dart' show storePastedText;

/// One file another app shared, already copied into app storage by the
/// platform side; [path] is that copy, which the intake removes when done.
class SharedFile {
  final String path;
  final String name;
  final String? mimeType;
  const SharedFile({required this.path, required this.name, this.mimeType});

  Map<String, Object?> toJson() =>
      {'path': path, 'name': name, 'mimeType': mimeType};
}

/// A file the platform side would not copy, and why: `tooBig` (with the
/// size when the sender told it, and the limit), `unsupported`, `stalled`
/// (it stopped arriving) or `failed`.
class SharedRefusal {
  final String name;
  final String reason;
  final int? bytes;
  final int? limit;
  const SharedRefusal(
      {required this.name, required this.reason, this.bytes, this.limit});

  Map<String, Object?> toJson() =>
      {'name': name, 'reason': reason, 'bytes': bytes, 'limit': limit};

  static SharedRefusal? fromJson(Object? m) {
    if (m is! Map || m['reason'] is! String) return null;
    return SharedRefusal(
        name: (m['name'] as String?) ?? 'shared',
        reason: m['reason'] as String,
        bytes: (m['bytes'] as num?)?.toInt(),
        limit: (m['limit'] as num?)?.toInt());
  }
}

String _megabytes(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

/// What to tell the person about a file the platform refused.
String refusalMessage(SharedRefusal r) => switch (r.reason) {
      'tooBig' => switch ((r.bytes, r.limit)) {
          (final int b, final int l) =>
            'Too big to share (${_megabytes(b)}; the limit is ${_megabytes(l)}).',
          (null, final int l) => 'Too big to share (the limit is ${_megabytes(l)}).',
          _ => 'That file is too big to share.',
        },
      'unsupported' => 'Trellis can’t open that kind of file.',
      'stalled' => 'The file stopped arriving, so it wasn’t saved.',
      _ => 'That file couldn’t be read.',
    };

/// One share: text (a link or words), files, or both.
class SharedPayload {
  final String? text;

  /// `EXTRA_SUBJECT`: a browser's page title, an email's subject.
  final String? subject;

  /// The sharing app's name, when Android said who it was.
  final String? sourceApp;
  final List<SharedFile> files;

  /// Files the platform side refused to copy; they never reach [files].
  final List<SharedRefusal> refused;
  const SharedPayload({
    this.text,
    this.subject,
    this.sourceApp,
    this.files = const [],
    this.refused = const [],
  });

  /// The channel's own shape, so a waiting share is stored as it came.
  Map<String, Object?> toJson() => {
        'text': text,
        'subject': subject,
        'sourceApp': sourceApp,
        'files': [for (final f in files) f.toJson()],
        'refused': [for (final r in refused) r.toJson()],
      };

  /// One share as `ShareInbox.kt` sends it, or as [toJson] stored it.
  factory SharedPayload.fromJson(Map<Object?, Object?> m) => SharedPayload(
        text: m['text'] as String?,
        subject: m['subject'] as String?,
        sourceApp: m['sourceApp'] as String?,
        files: [
          for (final f in (m['files'] as List?) ?? const [])
            if (f is Map && f['path'] is String)
              SharedFile(
                  path: f['path'] as String,
                  name: (f['name'] as String?) ?? 'shared',
                  mimeType: f['mimeType'] as String?),
        ],
        refused: [
          for (final r in (m['refused'] as List?) ?? const [])
            ?SharedRefusal.fromJson(r),
        ],
      );
}

sealed class ShareOutcome {
  const ShareOutcome();
}

/// Saved, or found already saved: [workId] is the work to open.
final class ShareSaved extends ShareOutcome {
  final int workId;

  /// In Latest (texts and pages); false for books and audiobooks, which
  /// their imports put in the Library.
  final bool inLatest;

  /// The same address, or the same text within a minute, was shared
  /// before: nothing new was made.
  final bool existing;

  /// Set while the row is a bare link whose page is still to be read:
  /// hand this outcome to [ShareIntake.fetchPageFor].
  final Uri? pageToFetch;

  /// Whether reading that page may still turn up a feed to offer; false
  /// once the person already chose "Save this page".
  final bool askAboutFeeds;

  /// How many works this share made (several files at once), and how
  /// many of its files couldn't be opened.
  final int count;
  final int failed;
  const ShareSaved(
    this.workId, {
    required this.inLatest,
    this.existing = false,
    this.pageToFetch,
    this.askAboutFeeds = true,
    this.count = 1,
    this.failed = 0,
  });
}

/// A shared link's row now holds the article it links to.
final class ShareUpgraded extends ShareOutcome {
  final int workId;
  const ShareUpgraded(this.workId);
}

/// A feed, or a page that stands for one: the person chooses between
/// following it and saving the page.
final class ShareOffersFeed extends ShareOutcome {
  final String feedUrl;
  final String name;
  final Uri pageUrl;

  /// The page as already fetched, so "Save this page" needn't fetch again.
  final String? html;
  final String? sourceApp;

  /// The link row this share already saved, if it got that far: kept on
  /// "Save this page", dropped once the feed is followed instead.
  final int? linkWorkId;
  const ShareOffersFeed({
    required this.feedUrl,
    required this.name,
    required this.pageUrl,
    this.html,
    this.sourceApp,
    this.linkWorkId,
  });
}

/// Nothing (more) could be saved; [message] says why, as a sentence.
/// [workId] is set when a link row stands anyway.
final class ShareRefused extends ShareOutcome {
  final String message;
  final int? workId;
  const ShareRefused(this.message, {this.workId});
}

/// The whole share, when it is one web address and nothing else: a
/// report that merely contains links stays a text.
Uri? singleUrlIn(String text) {
  final t = text.trim();
  if (t.isEmpty || t.contains(RegExp(r'\s'))) return null;
  final uri = Uri.tryParse(t);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  return uri.host.isEmpty ? null : uri;
}

const _titleCap = 80;

/// A shared text's title: its first line with any heading marks taken
/// off, capped, or "Shared 25 Oct" when it has none.
String sharedTitle(String text, int nowMs) {
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final bare = line.replaceFirst(RegExp(r'^#+\s*'), '').trim();
    if (bare.isEmpty) break;
    return bare.length <= _titleCap
        ? bare
        : '${bare.substring(0, _titleCap - 1).trimRight()}…';
  }
  return 'Shared ${formatDay(nowMs)}';
}

/// What a shared text file may be, read whole into memory. The platform
/// side caps the copy the same way; this is the second guard.
const maxSharedTextBytes = 8 * 1024 * 1024;

/// A double tap on Share, or a bot that sends twice, is one share.
const _sameTextWindow = Duration(minutes: 1);

enum _FileKind { epub, audio, text, html, other }

_FileKind _kindOf(SharedFile f) {
  final mime = (f.mimeType ?? '').toLowerCase();
  final dot = f.name.lastIndexOf('.');
  final ext = dot < 0 ? '' : f.name.substring(dot + 1).toLowerCase();
  if (mime == 'application/epub+zip' || ext == 'epub') return _FileKind.epub;
  if (mime.startsWith('audio/') || audiobookExtensions.contains(ext)) {
    return _FileKind.audio;
  }
  if (mime == 'text/html' || ext == 'html' || ext == 'htm') {
    return _FileKind.html;
  }
  if (mime == 'text/plain' ||
      mime == 'text/markdown' ||
      mime == 'text/x-markdown' ||
      const ['txt', 'md', 'markdown'].contains(ext)) {
    return _FileKind.text;
  }
  return _FileKind.other;
}

Future<String> _readFileText(String path) async =>
    utf8.decode(await File(path).readAsBytes(), allowMalformed: true);

int _fileSize(String path) {
  try {
    return File(path).lengthSync();
  } on FileSystemException {
    return 0;
  }
}

void _deleteCopy(String path) {
  try {
    File(path).deleteSync();
  } on FileSystemException {
    // Already gone; the cache is the system's to clear anyway.
  }
}

class ShareIntake {
  ShareIntake({
    required this.db,
    required this.profileId,
    required this.fetcher,
    this.audiobooks,
    DateTime Function()? now,
    Future<String> Function(String path)? readText,
    int Function(String path)? sizeOf,
    void Function(String path)? discard,
    Future<int> Function(String path, String name)? importBook,
  }) : _now = now ?? DateTime.now,
       _readText = readText ?? _readFileText,
       _sizeOf = sizeOf ?? _fileSize,
       _discard = discard ?? _deleteCopy,
       _importBook = importBook;

  final AppDatabase db;
  final int profileId;
  final HttpFetcher fetcher;

  /// The local-audio import; null where there is none (the web tier),
  /// and shared audio is then refused.
  final AudiobookImportRepository? audiobooks;
  final DateTime Function() _now;
  final Future<String> Function(String path) _readText;
  final int Function(String path) _sizeOf;
  final void Function(String path) _discard;
  final Future<int> Function(String path, String name)? _importBook;

  /// Link rows whose page is being read right now: a second share or an
  /// open of the same row doesn't fetch it twice.
  final Set<int> _reading = {};

  int get _nowMs => _now().millisecondsSinceEpoch;

  /// Routes one share, touching only the database: whatever needs the
  /// network comes after, through [fetchPageFor]. Never throws: every
  /// failure is a [ShareRefused].
  Future<ShareOutcome> take(SharedPayload p) async =>
      _countRefused(await _take(p), p);

  Future<ShareOutcome> _take(SharedPayload p) async {
    try {
      final text = p.text ?? '';
      if (p.files.isNotEmpty) {
        final out = await _files(p);
        // A caption or link sent beside a picture is still worth keeping.
        if (out is ShareSaved) return out;
        if (text.trim().isEmpty) {
          return p.refused.isEmpty
              ? out
              : ShareRefused(refusalMessage(p.refused.first));
        }
      }
      if (text.trim().isEmpty) {
        return ShareRefused(p.refused.isEmpty
            ? 'There was nothing in that share to save.'
            : refusalMessage(p.refused.first));
      }
      final url = singleUrlIn(text);
      if (url != null) return await _link(url, p);
      return await _text(text, p.sourceApp);
    } catch (e) {
      return const ShareRefused('That share couldn’t be saved.');
    }
  }

  /// Files the platform refused count among those not opened, beside
  /// whatever this share did save.
  ShareOutcome _countRefused(ShareOutcome out, SharedPayload p) {
    if (p.refused.isEmpty || out is! ShareSaved) return out;
    return ShareSaved(out.workId,
        inLatest: out.inLatest,
        existing: out.existing,
        pageToFetch: out.pageToFetch,
        askAboutFeeds: out.askAboutFeeds,
        count: out.count,
        failed: out.failed + p.refused.length);
  }

  /// Reads the page a link row waits on, and fills the row with it; or
  /// finds a feed there and offers it. Never throws.
  Future<ShareOutcome?> fetchPageFor(ShareSaved saved,
      {String? sourceApp}) async {
    final url = saved.pageToFetch;
    if (url == null || !_reading.add(saved.workId)) return null;
    try {
      final page = await fetchPage(fetcher: fetcher, url: url);
      final String html;
      switch (page) {
        case PageRefused(message: final message):
          return ShareRefused('$message Its link is kept.',
              workId: saved.workId);
        case PageFetched(html: final h):
          html = h;
      }
      if (saved.askAboutFeeds) {
        final article = extractArticle(html, baseUrl: url.toString());
        if (article.isFeedXml) {
          return ShareOffersFeed(
              feedUrl: url.toString(),
              name: _feedTitleIn(html) ?? url.host,
              pageUrl: url,
              sourceApp: sourceApp,
              linkWorkId: saved.workId);
        }
        final advertised =
            isSiteRoot(url) ? advertisedFeedIn(html, url.toString()) : null;
        if (advertised != null) {
          return ShareOffersFeed(
              feedUrl: advertised,
              name: siteNameIn(html) ?? url.host,
              pageUrl: url,
              html: html,
              sourceApp: sourceApp,
              linkWorkId: saved.workId);
        }
      }
      return await _fill(saved.workId, url, html);
    } catch (e) {
      return ShareRefused('That page couldn’t be read. Its link is kept.',
          workId: saved.workId);
    } finally {
      _reading.remove(saved.workId);
    }
  }

  /// Opening a shared link that was never read tries its page again;
  /// null when the work is no such link, or the page still can't be read.
  Future<ShareUpgraded?> refetchIfLinkOnly(int workId) async {
    final url = await db.feedsDao.sharedLinkOnlyUrl(workId);
    if (url == null) return null;
    final out = await fetchPageFor(ShareSaved(workId,
        inLatest: true, pageToFetch: Uri.parse(url), askAboutFeeds: false));
    return out is ShareUpgraded ? out : null;
  }

  /// "Save this page" from the subscribe sheet: the link row (made now if
  /// the share hadn't yet), filled from the page already in hand, or left
  /// for [fetchPageFor] to read without asking about the feed again.
  Future<ShareOutcome> savePage(ShareOffersFeed offer) async {
    try {
      final id = offer.linkWorkId ??
          await _keepLink(offer.pageUrl,
              sourceApp: offer.sourceApp, subject: null);
      final html = offer.html;
      if (html != null) {
        final filled = await _fill(id, offer.pageUrl, html);
        if (filled is ShareUpgraded) return ShareSaved(id, inLatest: true);
      }
      return ShareSaved(id,
          inLatest: true,
          existing: offer.linkWorkId != null && html == null,
          pageToFetch: html == null ? offer.pageUrl : null,
          askAboutFeeds: false);
    } catch (e) {
      return const ShareRefused('That page couldn’t be saved.');
    }
  }

  /// The feed was followed instead: the bare link this share saved a
  /// moment ago goes, since the feed now brings the site's posts.
  Future<void> dropLink(ShareOffersFeed offer) async {
    final id = offer.linkWorkId;
    if (id == null) return;
    if (await db.feedsDao.sharedLinkOnlyUrl(id) == null) return;
    await db.spineDao.deleteWorks([id]);
  }

  Future<ShareOutcome> _text(String text, String? sourceApp) async {
    final nowMs = _nowMs;
    final hash = sha256.convert(utf8.encode(text)).toString().substring(0, 16);
    final again = await db.feedsDao.sharedTextSince(
      profileId,
      hash,
      nowMs - _sameTextWindow.inMilliseconds,
    );
    if (again != null) {
      return ShareSaved(again, inLatest: true, existing: true);
    }
    final id = await _intoLatest(
      guid: 'text:$hash:$nowMs',
      sourceApp: sourceApp,
      store: () => storePastedText(
        db,
        profileId: profileId,
        text: text,
        title: sharedTitle(text, nowMs),
        persistence: 'ephemeron',
      ),
    );
    return ShareSaved(id, inLatest: true);
  }

  Future<ShareOutcome> _link(Uri shared, SharedPayload p) async {
    final Uri url;
    try {
      // Trackers come off before anything: the same article shared from
      // two apps is one share, and the tracker never leaves the device.
      url = stripTrackingParams(
          assertSafeFetchUrl(shared.removeFragment().toString()));
    } on UnsafeUrlException catch (e) {
      return ShareRefused(e.message);
    }
    final existing =
        await db.feedsDao.workBySharedUrl(profileId, url.toString());
    if (existing != null) {
      final unread = await db.feedsDao.sharedLinkOnlyUrl(existing);
      return ShareSaved(existing,
          inLatest: true,
          existing: true,
          pageToFetch: unread == null ? null : url,
          askAboutFeeds: false);
    }

    final known = knownFeedOf(url);
    if (known != null) {
      return ShareOffersFeed(
          feedUrl: known.feedUrl,
          name: known.name,
          pageUrl: url,
          sourceApp: p.sourceApp);
    }
    if (looksLikeFeedUrl(url.toString())) {
      return ShareOffersFeed(
          feedUrl: url.toString(),
          name: url.host,
          pageUrl: url,
          sourceApp: p.sourceApp);
    }
    final id = await _keepLink(url, sourceApp: p.sourceApp, subject: p.subject);
    return ShareSaved(id, inLatest: true, pageToFetch: url);
  }

  /// Fills link row [workId] with the article on [html], in place.
  Future<ShareOutcome> _fill(int workId, Uri url, String html) async {
    final article = articleFromHtml(html, url);
    if (article is! ArticleFetched) {
      return ShareRefused(
          'No readable article was found there. Its link is kept.',
          workId: workId);
    }
    await db.spineDao.replaceBody(workId,
        kind: 'article', title: article.article.title, rows: article.rows);
    return ShareUpgraded(workId);
  }

  /// The bare link, saved before the page is read. Latest is an archive
  /// (ADR-0019): a page that can't be read stays kept as its link.
  Future<int> _keepLink(Uri url,
      {required String? sourceApp, required String? subject}) {
    final title =
        (subject ?? '').trim().isEmpty ? url.toString() : subject!.trim();
    return _intoLatest(
      guid: url.toString(),
      sourceApp: sourceApp,
      store: () => storePastedText(
        db,
        profileId: profileId,
        text: url.toString(),
        title: title,
        sourceUrl: url.toString(),
        persistence: 'ephemeron',
      ),
    );
  }

  /// Stores a work and its Latest row under the Shared source in one
  /// transaction, segments before the row, so the search index's trigger
  /// reads the body when the row lands.
  Future<int> _intoLatest({
    required String guid,
    required String? sourceApp,
    required Future<int> Function() store,
  }) {
    return db.transaction(() async {
      final feedId = await db.feedsDao.sharedFeedId(profileId);
      final workId = await store();
      await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: guid,
        publishedAtMs: _nowMs,
        sourceLabel: sourceApp,
      );
      return workId;
    });
  }

  /// Each file on its own: one that can't be opened doesn't lose the rest.
  Future<ShareOutcome> _files(SharedPayload p) async {
    final saved = <ShareSaved>[];
    final audio = <SharedFile>[];
    var failed = 0;
    try {
      for (final f in p.files) {
        try {
          switch (_kindOf(f)) {
            case _FileKind.epub:
              final importBook = _importBook;
              final id = importBook != null
                  ? await importBook(f.path, f.name)
                  : await importEpubFile(
                      db: db,
                      profileId: profileId,
                      path: f.path,
                      sourceName: f.name,
                    );
              saved.add(ShareSaved(id, inLatest: false));
            case _FileKind.audio:
              audio.add(f);
            case _FileKind.text:
              final out = await _textFile(f, p.sourceApp);
              if (out is ShareSaved) {
                saved.add(out);
              } else {
                failed++;
              }
            case _FileKind.html:
              final out = await _htmlFile(f, p.sourceApp);
              if (out is ShareSaved) {
                saved.add(out);
              } else {
                failed++;
              }
            case _FileKind.other:
              failed++;
          }
        } catch (e) {
          failed++;
        }
      }
      final repository = audiobooks;
      if (audio.isNotEmpty && repository == null) failed += audio.length;
      if (audio.isNotEmpty && repository != null) {
        try {
          final picked = [for (final f in audio) (path: f.path, name: f.name)];
          final first = ([...audio]
                ..sort((a, b) => naturalCompareAudiobookNames(a.name, b.name)))
              .first
              .name;
          final dot = first.lastIndexOf('.');
          final outcome = await repository.import(
            profileId: profileId,
            picked: picked,
            title: dot > 0 ? first.substring(0, dot) : first,
          );
          if (outcome != null) {
            saved.add(ShareSaved(outcome.workId, inLatest: false));
          } else {
            failed += audio.length;
          }
        } catch (e) {
          failed += audio.length;
        }
      }
    } finally {
      for (final f in p.files) {
        _discard(f.path);
      }
    }
    if (saved.isEmpty) {
      return const ShareRefused('Trellis can’t open that kind of file.');
    }
    final last = saved.last;
    return ShareSaved(
      last.workId,
      inLatest: saved.every((s) => s.inLatest),
      existing: saved.length == 1 && last.existing,
      count: saved.length,
      failed: failed,
    );
  }

  Future<String?> _boundedText(SharedFile f) async =>
      _sizeOf(f.path) > maxSharedTextBytes ? null : _readText(f.path);

  Future<ShareOutcome> _textFile(SharedFile f, String? sourceApp) async {
    final text = await _boundedText(f);
    if (text == null) {
      return const ShareRefused('That file is too large to read here.');
    }
    return _text(text, sourceApp);
  }

  Future<ShareOutcome> _htmlFile(SharedFile f, String? sourceApp) async {
    final html = await _boundedText(f);
    if (html == null) {
      return const ShareRefused('That file is too large to read here.');
    }
    final base = Uri.file(f.name);
    final article = articleFromHtml(html, base);
    if (article is! ArticleFetched) {
      final plain = extractArticle(html).text;
      return plain.trim().isEmpty
          ? const ShareRefused('There was nothing in that file to read.')
          : _text(plain, sourceApp);
    }
    final nowMs = _nowMs;
    final id = await _intoLatest(
      guid: 'file:${f.name}:$nowMs',
      sourceApp: sourceApp,
      store: () async {
        final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: article.article.title.isEmpty
              ? sharedTitle(article.article.text, nowMs)
              : article.article.title,
          persistence: 'ephemeron',
          firstSeenEpochDay: nowMs ~/ Duration.millisecondsPerDay,
        );
        await db.spineDao.insertSegments(workId, article.rows);
        return workId;
      },
    );
    return ShareSaved(id, inLatest: true);
  }
}

final _titleRe = RegExp(
  r'<title[^>]*>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</title>',
  caseSensitive: false,
  dotAll: true,
);

final _siteNameRe = RegExp(
  // Quote marks as escapes: either kind may wrap an attribute.
  r'<meta[^>]+property=[\x22\x27]og:site_name[\x22\x27][^>]*'
  r'content=[\x22\x27]([^\x22\x27]+)[\x22\x27]',
  caseSensitive: false,
);

String _unescape(String t) => t
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");

/// A feed's own name, for "Subscribe to …", read straight off its XML.
String? _feedTitleIn(String xml) {
  final t = _titleRe.firstMatch(xml)?.group(1)?.trim();
  if (t == null || t.isEmpty) return null;
  return _unescape(t);
}

/// A site's name from its front page, for "Subscribe to …": the page's
/// declared site name, else its title. Never an article heading, which on
/// a front page is only the newest post's.
String? siteNameIn(String html) {
  final named = _siteNameRe.firstMatch(html)?.group(1)?.trim();
  if (named != null && named.isNotEmpty) return _unescape(named);
  return _feedTitleIn(html);
}

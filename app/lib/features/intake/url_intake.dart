import 'dart:async';

import 'package:comms_core/comms_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intake_core/intake_core.dart' show BookContents;

import '../../db/database.dart';
import '../../services/device_services.dart' show WebFetchLane;
import '../models/consent.dart';
import '../references/keep_page.dart' show keepLinkedPagesIfAsked;
import 'article_fetch.dart';
import 'book_fetch.dart';
import 'docx_intake.dart';
import 'paste_intake.dart' show epochDayUtcNow, showPasteIntakeDialog;
import '../shared/capped_body.dart';

/// The URL intake's storing half: an extracted article as one article
/// work. The share sheet stores through here too.
Future<int> storeArticle(AppDatabase db,
    {required int profileId,
    required ArticleFetched fetched,
    String persistence = 'work'}) async {
  final workId = await db.spineDao.insertWork(
      profileId: profileId,
      kind: 'article',
      title: fetched.article.title,
      persistence: persistence,
      firstSeenEpochDay: epochDayUtcNow(),
      sourceUrl: fetched.article.url);
  await db.spineDao.insertSegments(workId, fetched.rows);
  await db.spineDao.insertLinks(workId, fetched.links);
  return workId;
}

/// "Open a link": paste a URL, pass the ONE consent chokepoint, preview the
/// extracted article, confirm — and it lands as a persistent spine work.
///
/// Since 1.6.19 the link may also be a Word document, which opens as a
/// book, or a web book's contents page of chapter links, which offers the
/// whole book: after a second consent naming every chapter's address, the
/// chapters are brought in one by one and land as one book.
///
/// The order is a law (ADR-0003 law 6): the lexical SSRF guard runs first
/// (a refused address never even earns a dialog), then [confirmDownload]
/// names the exact URL that would leave the device, and only the explicit
/// yes lets a byte move. Errors arrive as sentences from [fetchArticle];
/// this screen owns only input, wait, preview and the calm inline error —
/// the same split as the subscribe screen.
///
/// Pops the new work id after a confirmed add, null otherwise.
class UrlIntakeScreen extends StatefulWidget {
  final AppDatabase db;
  final int profileId;
  final HttpFetcher fetcher;

  /// Fetch honesty, the localMlAvailable pattern's sibling: in the browser
  /// most sites refuse cross-site reads, so this door must say upfront that
  /// many fetches will fail there — before the user types, consents, and
  /// waits. Tests pin both tiers explicitly.
  final bool webTier;

  /// The web tier's fetch-routing decision. When a
  /// household daemon answers same-origin, the CORS warning above would be
  /// a lie — this swaps it for one quiet, accurate line instead. Native
  /// tiers never probe, so this stays [WebFetchLane.direct] there and
  /// [webTier] alone gates the (absent) note.
  final WebFetchLane lane;

  /// A web book already found (a shared contents page, 1.6.19): the
  /// screen opens on its card.
  final BookContents? book;

  const UrlIntakeScreen(
      {super.key,
      required this.db,
      required this.profileId,
      required this.fetcher,
      this.webTier = kIsWeb,
      this.lane = WebFetchLane.direct,
      this.book});

  @override
  State<UrlIntakeScreen> createState() => _UrlIntakeScreenState();
}

class _UrlIntakeScreenState extends State<UrlIntakeScreen> {
  final _url = TextEditingController();
  bool _busy = false;
  String? _error;
  ArticleFetched? _preview;
  BookContents? _book;
  DocxRows? _document;

  /// While a book's chapters arrive: how many are in hand, of how many.
  (int, int)? _chapters;

  @override
  void initState() {
    super.initState();
    _book = widget.book;
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final raw = _url.text.trim();
    if (raw.isEmpty || _busy) return;

    // Bare hosts get https:// — the guard itself stays strict.
    final candidate = raw.contains('://') ? raw : 'https://$raw';
    final Uri url;
    try {
      url = assertSafeFetchUrl(candidate);
    } on UnsafeUrlException catch (e) {
      setState(() => _error = e.message);
      return;
    }

    // THE chokepoint, before any byte moves. Size honesty: unknowable here.
    final ok = await confirmDownload(context, items: [
      DownloadItem('$url (size unknown until it arrives)'),
    ]);
    if (!ok || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome = await fetchLink(fetcher: widget.fetcher, url: url);
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (outcome) {
        case LinkRefused(:final message):
          _error = message;
        case LinkDocument(:final rows):
          _document = rows;
          _documentUrl = url;
        case LinkPage(:final article, :final book):
          _book = book;
          switch (article) {
            case ArticleFetched():
              _preview = article;
            case ArticleRefused(:final message):
              if (book == null) _error = message;
          }
      }
    });
  }

  Uri? _documentUrl;

  void _reset() => setState(() {
        _preview = null;
        _book = null;
        _document = null;
        _documentUrl = null;
      });

  Future<void> _addDocument() async {
    final workId = await storeBookRows(widget.db,
        profileId: widget.profileId,
        rows: _document!,
        sourceUrl: _documentUrl?.toString());
    if (!mounted) return;
    Navigator.of(context).pop(workId);
  }

  /// The whole book: a second consent names every chapter's address, then
  /// the chapters arrive one by one.
  Future<void> _addBook() async {
    final book = _book!;
    final ok = await confirmDownload(context, items: [
      DownloadItem('${book.chapters.length} chapters of “${book.title}”, '
          'sizes unknown until they arrive:'),
      for (final c in book.chapters) DownloadItem('${c.url}'),
    ]);
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _chapters = (0, book.chapters.length);
    });
    final outcome = await fetchBook(
        fetcher: widget.fetcher,
        book: book,
        onChapter: (done, total) {
          if (mounted) setState(() => _chapters = (done, total));
        });
    if (!mounted) return;
    switch (outcome) {
      case BookRefused(:final message):
        setState(() {
          _busy = false;
          _chapters = null;
          _error = message;
        });
      case BookFetched(:final rows):
        final workId = await storeBookRows(widget.db,
            profileId: widget.profileId,
            rows: rows,
            sourceUrl: book.contentsUrl.toString());
        if (!mounted) return;
        Navigator.of(context).pop(workId);
    }
  }

  /// Opens the paste dialog carrying the address, so the work still says
  /// where it came from; a pasted work closes this screen like an add.
  Future<void> _pasteInstead() async {
    final raw = _url.text.trim();
    final workId = await showPasteIntakeDialog(context,
        db: widget.db,
        profileId: widget.profileId,
        sourceUrl: raw.isEmpty
            ? null
            : (raw.contains('://') ? raw : 'https://$raw'));
    if (workId != null && mounted) Navigator.of(context).pop(workId);
  }

  Future<void> _add() async {
    final workId = await storeArticle(widget.db,
        profileId: widget.profileId, fetched: _preview!);
    unawaited(keepLinkedPagesIfAsked(
        db: widget.db,
        fetcher: widget.fetcher,
        profileId: widget.profileId,
        workId: workId,
        epochDay: epochDayUtcNow()));
    if (!mounted) return;
    Navigator.of(context).pop(workId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _preview;
    final book = _book;
    final document = _document;
    return Scaffold(
      appBar: AppBar(title: const Text('Open a link')),
      body: CappedBody(child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: book != null
                  ? _bookCard(theme, book, preview)
                  : document != null
                      ? _documentCard(theme, document)
                      : preview == null
                          ? _input(theme)
                          : _previewCard(theme, preview),
            ),
          ),
        ),
      )),
    );
  }

  Widget _input(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
            'Paste the address of an article, a Word document, or a web '
            'book’s contents page. You will see exactly what would be '
            'fetched before anything is.',
            style: theme.textTheme.bodyMedium),
        if (widget.webTier) ...[
          const SizedBox(height: 12),
          if (widget.lane == WebFetchLane.skein)
            Text('Fetching through your Skein on this computer.',
                key: const Key('url-intake-skein-note'),
                style: theme.textTheme.bodySmall)
          else
            Text(
                "Most sites don’t let web pages read them, so fetching from "
                'the browser often fails. The installed app fetches directly '
                '— and pasting the text always works.',
                key: const Key('url-intake-web-note'),
                style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 16),
        TextField(
          key: const Key('url-intake-field'),
          controller: _url,
          autofocus: true,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _fetch(),
          // The field's own outline turns to the error colour too; the
          // sentence sits below as ordinary wrapping text (a field's
          // errorText is one line and ellipsizes at large text).
          decoration: InputDecoration(
              labelText: 'Web address',
              hintText: 'example.org/essay',
              error: _error == null ? null : const SizedBox.shrink()),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          // Urgency is colour + icon + word (fleet colour language;
          // dfh-04), and a refusal comes with a way forward (audit rank
          // 7): pasting the page's text always works.
          Row(
            key: const Key('url-intake-error-row'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline,
                  size: 20, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_error!,
                    key: const Key('url-intake-error'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('url-intake-paste-instead'),
            onPressed: _pasteInstead,
            icon: const Icon(Icons.content_paste),
            label: const Text('Paste the text instead'),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          key: const Key('url-intake-fetch'),
          onPressed: _busy ? null : _fetch,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.public),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Fetch article'),
          ),
        ),
      ],
    );
  }

  Widget _previewCard(ThemeData theme, ArticleFetched preview) {
    final article = preview.article;
    final n = preview.rows.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(article.title,
            style: theme.textTheme.headlineSmall,
            maxLines: 3,
            overflow: TextOverflow.ellipsis),
        if (article.byline != null) ...[
          const SizedBox(height: 4),
          Text('by ${article.byline}', style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: 8),
        Text(n == 1 ? '1 passage' : '$n passages',
            style: theme.textTheme.bodyMedium),
        if (article.url != null) ...[
          const SizedBox(height: 4),
          Text(article.url!,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
            key: const Key('url-intake-add'),
            onPressed: _add,
            icon: const Icon(Icons.add),
            label: const Text('Add to library')),
        const SizedBox(height: 12),
        TextButton(
            onPressed: _reset,
            child: const Text('Try a different address')),
      ],
    );
  }

  Widget _documentCard(ThemeData theme, DocxRows document) {
    final n = document.rows.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(document.title,
            style: theme.textTheme.headlineSmall,
            maxLines: 3,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        Text('A Word document, ${n == 1 ? '1 passage' : '$n passages'}',
            style: theme.textTheme.bodyMedium),
        const SizedBox(height: 24),
        FilledButton.icon(
            key: const Key('url-intake-add'),
            onPressed: _addDocument,
            icon: const Icon(Icons.add),
            label: const Text('Add to library')),
        const SizedBox(height: 12),
        TextButton(
            onPressed: _reset, child: const Text('Try a different address')),
      ],
    );
  }

  Widget _bookCard(ThemeData theme, BookContents book, ArticleFetched? page) {
    final n = book.chapters.length;
    final names = book.chapters.take(3).map((c) => c.title).join(', ');
    final progress = _chapters;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(book.title,
            style: theme.textTheme.headlineSmall,
            maxLines: 3,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        Text('A book of $n chapters: $names${n > 3 ? '…' : ''}',
            key: const Key('url-intake-book-chapters'),
            style: theme.textTheme.bodyMedium),
        const SizedBox(height: 4),
        Text(book.contentsUrl.toString(),
            style: theme.textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              key: const Key('url-intake-error'),
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600)),
        ],
        const SizedBox(height: 24),
        if (progress != null) ...[
          LinearProgressIndicator(
              value: progress.$2 == 0 ? null : progress.$1 / progress.$2),
          const SizedBox(height: 8),
          Text(
              'Bringing in chapter ${progress.$1 < progress.$2 ? progress.$1 + 1 : progress.$2} '
              'of ${progress.$2}…',
              key: const Key('url-intake-book-progress'),
              style: theme.textTheme.bodyMedium),
        ] else ...[
          FilledButton.icon(
              key: const Key('url-intake-add-book'),
              onPressed: _busy ? null : _addBook,
              icon: const Icon(Icons.menu_book),
              label: Text('Add the book ($n chapters)')),
          if (page != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
                key: const Key('url-intake-add'),
                onPressed: _busy ? null : _add,
                child: const Text('Add this page only')),
          ],
          const SizedBox(height: 12),
          TextButton(
              onPressed: _reset,
              child: const Text('Try a different address')),
        ],
      ],
    );
  }
}

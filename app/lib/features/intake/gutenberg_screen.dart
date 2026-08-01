import 'package:comms_core/comms_core.dart' show HttpFetcher;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intake_core/intake_core.dart' show GutendexBook;

import '../../db/database.dart';
import '../../services/device_services.dart' show WebFetchLane;
import '../models/consent.dart';
import 'gutenberg_fetch.dart';
import 'paste_intake.dart' show epochDayUtcNow;

/// Project Gutenberg, through the Gutendex catalogue. This is a network
/// SEARCH surface: the typed words themselves leave the device, so the
/// screen states the endpoint plainly and NOTHING fires before the user
/// acts — type + submit IS the gesture (ADR-0003; no as-you-type search,
/// no autofire on open). Downloading a chosen book then passes the ONE
/// consent chokepoint naming the exact file URL (the url_intake precedent).
///
/// Pops the new work id after a confirmed import, null otherwise.
class GutenbergSearchScreen extends StatefulWidget {
  final AppDatabase db;
  final int profileId;
  final HttpFetcher fetcher;

  /// Fetch honesty (the url_intake sibling): gutendex.com allows browser
  /// reads, but gutenberg.org's book files do NOT (measured 2026-08-12) —
  /// so in the browser the search works and the download is refused. The
  /// door says so upfront and names the working fallback instead of
  /// inviting a search into a dead end.
  final bool webTier;

  /// The web tier's fetch-routing decision — the
  /// url_intake sibling. Through Skein both search AND the book download
  /// work same-origin, so the browser-refusal caveat below would be false;
  /// this swaps it for one quiet, accurate line instead.
  final WebFetchLane lane;

  const GutenbergSearchScreen(
      {super.key,
      required this.db,
      required this.profileId,
      required this.fetcher,
      this.webTier = kIsWeb,
      this.lane = WebFetchLane.direct});

  @override
  State<GutenbergSearchScreen> createState() => _GutenbergSearchScreenState();
}

class _GutenbergSearchScreenState extends State<GutenbergSearchScreen> {
  final _query = TextEditingController();
  bool _busy = false;

  /// The id of the book currently downloading, null when none is.
  int? _importing;
  int _receivedBytes = 0;
  String? _error;
  List<GutendexBook>? _books;
  String? _nextUrl;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty || _busy || _importing != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome = await searchGutendex(fetcher: widget.fetcher, query: q);
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (outcome) {
        case GutendexSearchRefused(message: final message):
          _error = message;
        case GutendexSearchResults(page: final page):
          _books = page.books;
          _nextUrl = page.nextUrl;
      }
    });
  }

  Future<void> _more() async {
    final next = _nextUrl;
    if (next == null || _busy || _importing != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // The next-page URL is server data; searchGutendex re-guards it.
    final outcome = await searchGutendex(fetcher: widget.fetcher, pageUrl: next);
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (outcome) {
        case GutendexSearchRefused(message: final message):
          _error = message;
        case GutendexSearchResults(page: final page):
          _books = [...?_books, ...page.books];
          _nextUrl = page.nextUrl;
      }
    });
  }

  Future<void> _import(GutendexBook book) async {
    if (_busy || _importing != null) return;
    final url = book.importUrl;
    if (url == null) {
      // Refused BEFORE consent: nothing to download, so no dialog.
      setState(() =>
          _error = 'This edition has no readable text — try another result.');
      return;
    }

    // THE chokepoint (ADR-0003 law 6), before any byte of the book moves.
    final ok = await confirmDownload(context, items: [
      DownloadItem('${book.title} — $url — size unknown until it arrives'),
    ]);
    if (!ok || !mounted) return;

    setState(() {
      _importing = book.id;
      _receivedBytes = 0;
      _error = null;
    });
    final outcome = await fetchGutenbergBook(
      fetcher: widget.fetcher,
      book: book,
      onBytes: (got) {
        if (mounted) setState(() => _receivedBytes = got);
      },
    );
    if (!mounted) return;
    switch (outcome) {
      case GutenbergBookRefused(message: final message):
        setState(() {
          _importing = null;
          _error = message;
        });
      case GutenbergBookFetched(rows: final rows, sourceUrl: final sourceUrl):
        final workId = await widget.db.spineDao.insertWork(
            profileId: widget.profileId,
            kind: 'book',
            title: book.title,
            persistence: 'work',
            firstSeenEpochDay: epochDayUtcNow(),
            sourceUrl: sourceUrl,
            lang: book.languages.isEmpty ? null : book.languages.first);
        await widget.db.spineDao.insertSegments(workId, rows);
        if (!mounted) return;
        Navigator.of(context).pop(workId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final books = _books;
    return Scaffold(
      appBar: AppBar(title: const Text('Project Gutenberg')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The endpoint, stated plainly before anything happens.
                  Text(
                      'Searches the free Project Gutenberg catalogue at '
                      'gutendex.com. Your search words are sent there when '
                      'you press Search — nothing before.',
                      style: theme.textTheme.bodyMedium),
                  if (widget.webTier) ...[
                    const SizedBox(height: 8),
                    if (widget.lane == WebFetchLane.skein)
                      Text('Fetching through your Skein on this computer.',
                          key: const Key('gutenberg-skein-note'),
                          style: theme.textTheme.bodySmall)
                    else
                      Text(
                          'In the browser, the search works but gutenberg.org '
                          'refuses the book download itself. Save the EPUB '
                          'with your browser and bring it in with Import an '
                          'EPUB — or use the installed app, which downloads '
                          'directly.',
                          key: const Key('gutenberg-web-note'),
                          style: theme.textTheme.bodySmall),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('gutenberg-search-field'),
                    controller: _query,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: const InputDecoration(
                        labelText: 'Title or author',
                        hintText: 'austen · frankenstein · marcus aurelius'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        key: const Key('gutenberg-error'),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const Key('gutenberg-search-submit'),
                    onPressed:
                        (_busy || _importing != null) ? null : _search,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.search),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Search'),
                    ),
                  ),
                  if (_importing != null) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(
                        'Bringing the book in — '
                        '${(_receivedBytes / 1024).round()} KB so far.',
                        style: theme.textTheme.bodySmall),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
            Expanded(
              child: books == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                            'Seventy-five thousand free books — search by '
                            'title or author.',
                            style: theme.textTheme.bodyMedium,
                            textAlign: TextAlign.center),
                      ),
                    )
                  : books.isEmpty
                      ? Center(
                          child: Text('No books matched those words.',
                              style: theme.textTheme.bodyMedium),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 24),
                          itemCount: books.length + (_nextUrl == null ? 0 : 1),
                          itemBuilder: (_, i) {
                            if (i == books.length) {
                              return Padding(
                                padding: const EdgeInsets.all(16),
                                child: OutlinedButton(
                                  key: const Key('gutenberg-more'),
                                  onPressed: _busy ? null : _more,
                                  child: const Text('More results'),
                                ),
                              );
                            }
                            return _bookTile(theme, books[i]);
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bookTile(ThemeData theme, GutendexBook book) {
    final parts = [
      if (book.authors.isNotEmpty) book.authors.join('; '),
      if (book.languages.isNotEmpty) book.languages.join('/'),
      '${book.downloadCount} downloads',
    ];
    return ListTile(
      key: Key('gutenberg-book-${book.id}'),
      leading: const Icon(Icons.menu_book_outlined),
      title:
          Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(parts.join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall),
      trailing: _importing == book.id
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.download_outlined),
      onTap: _importing != null ? null : () => _import(book),
    );
  }
}

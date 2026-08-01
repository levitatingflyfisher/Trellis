import 'package:comms_core/comms_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../services/device_services.dart' show WebFetchLane;
import '../models/consent.dart';
import 'article_fetch.dart';
import 'paste_intake.dart' show epochDayUtcNow;

/// "From the web": paste a URL, pass the ONE consent chokepoint, preview the
/// extracted article, confirm — and it lands as a persistent spine work.
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

  const UrlIntakeScreen(
      {super.key,
      required this.db,
      required this.profileId,
      required this.fetcher,
      this.webTier = kIsWeb,
      this.lane = WebFetchLane.direct});

  @override
  State<UrlIntakeScreen> createState() => _UrlIntakeScreenState();
}

class _UrlIntakeScreenState extends State<UrlIntakeScreen> {
  final _url = TextEditingController();
  bool _busy = false;
  String? _error;
  ArticleFetched? _preview;

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
      DownloadItem('$url — size unknown until it arrives'),
    ]);
    if (!ok || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome =
        await fetchArticle(fetcher: widget.fetcher, url: url);
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (outcome) {
        case ArticleRefused(message: final message):
          _error = message;
        case ArticleFetched():
          _preview = outcome;
      }
    });
  }

  Future<void> _add() async {
    final preview = _preview!;
    final workId = await widget.db.spineDao.insertWork(
        profileId: widget.profileId,
        kind: 'article',
        title: preview.article.title,
        persistence: 'work',
        firstSeenEpochDay: epochDayUtcNow(),
        sourceUrl: preview.article.url);
    await widget.db.spineDao.insertSegments(workId, preview.rows);
    if (!mounted) return;
    Navigator.of(context).pop(workId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('From the web')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: preview == null
                  ? _input(theme)
                  : _previewCard(theme, preview),
            ),
          ),
        ),
      ),
    );
  }

  Widget _input(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
            'Paste the address of an article. You will see exactly what '
            'would be fetched before anything is.',
            style: theme.textTheme.bodyMedium),
        if (widget.webTier) ...[
          const SizedBox(height: 12),
          if (widget.lane == WebFetchLane.skein)
            Text('Fetching through your Skein on this computer.',
                key: const Key('url-intake-skein-note'),
                style: theme.textTheme.bodySmall)
          else
            Text(
                "Most sites don't let web pages read them, so fetching from "
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
          decoration: const InputDecoration(
              labelText: 'Web address', hintText: 'example.org/essay'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              key: const Key('url-intake-error'),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error)),
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
            onPressed: () => setState(() => _preview = null),
            child: const Text('Try a different address')),
      ],
    );
  }
}

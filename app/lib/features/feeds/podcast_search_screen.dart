import 'package:comms_core/comms_core.dart' show PodcastSearchResult;
import 'package:flutter/material.dart';

import 'feeds_repository.dart';

/// Search Apple's public podcast directory. This is a network SEARCH
/// surface: the typed words themselves leave the device, so the screen
/// states the endpoint plainly and NOTHING fires before the user acts —
/// type + submit IS the gesture (ADR-0003; no as-you-type search).
///
/// Results are text only: names, no cover art — the artwork URLs the
/// directory returns are never fetched. Picking a result runs the EXISTING
/// subscribe-by-URL path on its feedUrl (auto-discovery, SSRF guard,
/// validation and the breaker all included, exactly as if the address had
/// been pasted). Pops `true` after a successful follow.
class PodcastSearchScreen extends StatefulWidget {
  final FeedsRepository repository;
  final int profileId;
  const PodcastSearchScreen(
      {super.key, required this.repository, required this.profileId});

  @override
  State<PodcastSearchScreen> createState() => _PodcastSearchScreenState();
}

class _PodcastSearchScreenState extends State<PodcastSearchScreen> {
  final _term = TextEditingController();
  bool _busy = false;
  String? _error;
  List<PodcastSearchResult>? _results;

  @override
  void dispose() {
    _term.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final term = _term.text.trim();
    if (term.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome = await widget.repository.searchPodcasts(term);
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (outcome) {
        case PodcastSearchFailure(message: final message):
          _error = message;
        case PodcastSearchSuccess(results: final results):
          _results = results;
      }
    });
  }

  Future<void> _pick(PodcastSearchResult result) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // The feedUrl came off the wire; the subscribe path re-guards it with
    // assertSafeFetchUrl before any fetch, same as a pasted address.
    final outcome = await widget.repository
        .subscribe(profileId: widget.profileId, rawUrl: result.feedUrl);
    if (!mounted) return;
    switch (outcome) {
      case SubscribeSuccess():
        Navigator.of(context).pop(true);
      case AlreadySubscribed(title: final title):
        setState(() {
          _busy = false;
          _error = 'Already following $title.';
        });
      case SubscribeFailure(message: final message):
        setState(() {
          _busy = false;
          _error = message;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final results = _results;
    return Scaffold(
      appBar: AppBar(title: const Text('Search podcasts')),
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
                      "Searches Apple's public podcast directory at "
                      'itunes.apple.com. Your search words are sent there '
                      'when you press Search — nothing before.',
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('podcast-search-field'),
                    controller: _term,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: const InputDecoration(
                        labelText: 'Show or publisher',
                        hintText: 'history of rome'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        key: const Key('podcast-search-error'),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const Key('podcast-search-submit'),
                    onPressed: _busy ? null : _search,
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
                  const SizedBox(height: 8),
                ],
              ),
            ),
            Expanded(
              child: results == null
                  ? const SizedBox.shrink()
                  : results.isEmpty
                      ? Center(
                          child: Text('No podcasts matched those words.',
                              style: theme.textTheme.bodyMedium),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 24),
                          itemCount: results.length,
                          itemBuilder: (_, i) {
                            final r = results[i];
                            // Text tiles by design: no artwork is fetched.
                            return ListTile(
                              leading: const Icon(Icons.podcasts),
                              title: Text(r.collectionName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: r.artistName.isEmpty
                                  ? null
                                  : Text(r.artistName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall),
                              trailing: const Icon(Icons.rss_feed),
                              onTap: _busy ? null : () => _pick(r),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

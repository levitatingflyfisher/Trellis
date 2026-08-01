import 'package:flutter/material.dart';

import 'feeds_repository.dart';
import 'podcast_search_screen.dart';

/// Subscribe by URL, with the podcast-directory search as the second door
/// beside it. Discovery, the SSRF guard, fetch and parse all live in
/// [FeedsRepository]; this screen owns only the input, the wait, and the
/// calm inline error. Pops `true` after a successful follow.
class SubscribeScreen extends StatefulWidget {
  final FeedsRepository repository;
  final int profileId;
  const SubscribeScreen(
      {super.key, required this.repository, required this.profileId});

  @override
  State<SubscribeScreen> createState() => _SubscribeScreenState();
}

class _SubscribeScreenState extends State<SubscribeScreen> {
  final _url = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _searchPodcasts() async {
    final followed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => PodcastSearchScreen(
            repository: widget.repository, profileId: widget.profileId)));
    if (followed == true && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _submit() async {
    final raw = _url.text.trim();
    if (raw.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.repository
        .subscribe(profileId: widget.profileId, rawUrl: raw);
    if (!mounted) return;
    switch (result) {
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
    return Scaffold(
      appBar: AppBar(title: const Text('Follow a feed')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                      'Paste a feed address, or a site — the feed is '
                      'discovered for you.',
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('subscribe-url'),
                    controller: _url,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                        labelText: 'Web address',
                        hintText: 'example.org/feed'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        key: const Key('subscribe-error'),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    key: const Key('subscribe-submit'),
                    onPressed: _busy ? null : _submit,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.rss_feed),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Follow'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('podcast-search-door'),
                    onPressed: _busy ? null : _searchPodcasts,
                    icon: const Icon(Icons.search),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Search podcasts'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

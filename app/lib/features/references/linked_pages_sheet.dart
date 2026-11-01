/// Every link of a text in one list (frozen references): its words, its
/// site, and whether its page is kept on this device. One button keeps
/// copies of all the pages not kept yet, one at a time, after the one
/// consent question names every address.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'keep_page.dart';
import 'link_sheet.dart' show keptOnLabel;

/// One link as the list shows it.
typedef LinkedPage = ({String words, String href});

class LinkedPagesSheet extends StatefulWidget {
  const LinkedPagesSheet({
    super.key,
    required this.links,
    required this.keptDays,
    required this.keep,
    required this.confirm,
    required this.onOpen,
  });

  /// In text order; a page linked twice is listed at its first link.
  final List<LinkedPage> links;

  /// The kept day of each page already kept, by the link's href.
  final Map<String, int> keptDays;

  /// Keeps one page; the reader's own [keepLinkedPage] with its seams.
  final Future<(KeepOutcome, int?)> Function(String href) keep;

  /// The one consent question for these addresses: true is a yes.
  final Future<bool> Function(List<String> hrefs) confirm;

  /// A row tapped: the reader's own link sheet for that href.
  final void Function(String href) onOpen;

  @override
  State<LinkedPagesSheet> createState() => _LinkedPagesSheetState();
}

class _LinkedPagesSheetState extends State<LinkedPagesSheet> {
  late final Map<String, int> _kept = {...widget.keptDays};
  final _failed = <String, String>{};
  int? _done;
  int _total = 0;
  bool _stop = false;

  List<LinkedPage> get _rows {
    final seen = <String>{};
    return [
      for (final l in widget.links)
        if (seen.add(_key(l.href))) l,
    ];
  }

  static String _key(String href) {
    final hash = href.indexOf('#');
    return hash < 0 ? href : href.substring(0, hash);
  }

  int? _keptDay(String href) => _kept[href] ?? _kept[_key(href)];

  List<String> get _notKept => [
        for (final l in _rows)
          if (_keptDay(l.href) == null) l.href,
      ];

  Future<void> _keepAll() async {
    final todo = _notKept;
    if (todo.isEmpty || !await widget.confirm(todo) || !mounted) return;
    setState(() {
      _done = 0;
      _total = todo.length;
      _stop = false;
    });
    for (final href in todo) {
      if (_stop || !mounted) break;
      final (outcome, day) = await widget.keep(href);
      if (!mounted) return;
      setState(() {
        _done = _done! + 1;
        switch (outcome) {
          case PageKept():
            _kept[href] = day ?? 0;
            _failed.remove(href);
          case PageNotKept(:final message):
            _failed[href] = message;
        }
      });
    }
    if (mounted) setState(() => _done = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _rows;
    final notKept = _notKept.length;
    final sites = {
      for (final h in _notKept) Uri.tryParse(h)?.host ?? h,
    }.length;
    final busy = _done != null;
    return SafeArea(
      child: Column(
        key: const Key('linked-pages'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
            child: Text('Linked pages', style: theme.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              busy
                  ? 'Keeping $_done of $_total…'
                  : notKept == 0
                      ? 'Every page this text links to is kept on this '
                          'device.'
                      : '$notKept of ${rows.length} not kept yet, from '
                          '$sites ${sites == 1 ? 'site' : 'sites'}.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (busy)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(children: [
                Expanded(
                    child: LinearProgressIndicator(
                        value: _total == 0 ? null : _done! / _total)),
                TextButton(
                  key: const Key('linked-pages-stop'),
                  onPressed: () => setState(() => _stop = true),
                  child: const Text('Stop'),
                ),
              ]),
            )
          else if (notKept > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: FilledButton.icon(
                key: const Key('linked-pages-keep-all'),
                icon: const Icon(Icons.download_outlined),
                label: Text(notKept == 1
                    ? 'Keep a copy of it'
                    : 'Keep copies of all $notKept'),
                onPressed: () => unawaited(_keepAll()),
              ),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final l in rows)
                  ListTile(
                    key: Key('linked-page-${l.href}'),
                    title: Text(l.words,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text([
                      Uri.tryParse(l.href)?.host ?? l.href,
                      if (_keptDay(l.href) case final day?)
                        keptOnLabel(day)
                      else if (_failed[l.href] case final why?)
                        why
                      else
                        'Not kept',
                    ].join(' · ')),
                    trailing: _keptDay(l.href) != null
                        ? const Icon(Icons.inventory_2_outlined)
                        : null,
                    onTap: busy ? null : () => widget.onOpen(l.href),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

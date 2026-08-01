import 'package:flutter/material.dart';

import '../../db/database.dart';

/// One profile's word ledger, newest catch first. The collection is the
/// user's own (ADR-0003 law 2: promotion requires the hand) — so there is
/// nothing here but the words: no counts, no review nags, and removal is one
/// swipe or one tap away, undo-free because the dao's add is idempotent and
/// a lost word is one long-press from coming back.
class LedgerScreen extends StatefulWidget {
  final AppDatabase db;
  final int profileId;
  const LedgerScreen(
      {super.key, required this.db, required this.profileId});

  @override
  State<LedgerScreen> createState() => _LedgerScreenState();
}

class _LedgerScreenState extends State<LedgerScreen> {
  List<WordLedgerRow>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await widget.db.ledgerDao.wordsOf(widget.profileId);
    if (!mounted) return;
    setState(() => _rows = rows);
  }

  Future<void> _remove(WordLedgerRow row) async {
    await widget.db.ledgerDao.remove(row.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: const Text('Word ledger')),
      body: switch (rows) {
        null => const Center(child: CircularProgressIndicator()),
        [] => const _EmptyState(),
        _ => ListView.builder(
            itemCount: rows.length,
            itemBuilder: (_, i) => _wordTile(rows[i]),
          ),
      },
    );
  }

  Widget _wordTile(WordLedgerRow row) {
    return Dismissible(
      key: ValueKey('ledger-row-${row.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => _remove(row),
      background: Container(
        color: Theme.of(context).colorScheme.errorContainer,
        // AlignmentDirectional: the db's Alignment row class shadows the
        // painting one in this import graph.
        alignment: AlignmentDirectional.centerEnd,
        padding: const EdgeInsets.only(right: 24),
        child: Icon(Icons.delete_outline,
            color: Theme.of(context).colorScheme.onErrorContainer),
      ),
      child: ListTile(
        title: Text(row.word),
        subtitle: row.lang == null ? null : Text(row.lang!),
        trailing: IconButton(
          key: Key('ledger-remove-${row.id}'),
          tooltip: 'Remove',
          icon: const Icon(Icons.close),
          onPressed: () => _remove(row),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_border,
                size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text('Nothing set aside yet.',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('Long-press a word while reading or listening to keep it.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

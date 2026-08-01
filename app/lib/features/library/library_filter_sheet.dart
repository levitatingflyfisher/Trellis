/// The library's filter builder as a modal bottom sheet (Campaign 9 Phase
/// 1) — the user called the old pushed-screen-with-an-Apply-button flow
/// "dated." Every control here applies LIVE: [onChanged] fires on every
/// edit, and the list behind the sheet re-filters immediately (filtering
/// was already post-hoc in-memory — nothing here touches a query). Saved-
/// view management (rename/delete/save) stays a separate pushed screen
/// ([LibraryFilterScreen]) — this sheet only offers a door to it, since
/// creating/reordering/deleting views is a different, slower-paced task
/// than adjusting a filter.
library;

import 'package:flutter/material.dart';

import '../../db/database.dart' hide Alignment;
import 'library_query.dart';

/// Sentinel [Navigator.pop] value meaning "the user wants the saved-views
/// management screen" — the caller closes this sheet then pushes
/// [LibraryFilterScreen] itself, so the two screens never nest navigators.
const String openSavedViewsManagement = 'manage-saved-views';

class LibraryFilterSheet extends StatefulWidget {
  final AppDatabase db;
  final int profileId;
  final LibraryQuery initial;

  /// Fired on every edit — live-apply, never a batched "Apply" step.
  final ValueChanged<LibraryQuery> onChanged;

  const LibraryFilterSheet(
      {super.key,
      required this.db,
      required this.profileId,
      required this.initial,
      required this.onChanged});

  @override
  State<LibraryFilterSheet> createState() => _LibraryFilterSheetState();
}

class _LibraryFilterSheetState extends State<LibraryFilterSheet> {
  late final TextEditingController _searchController;
  late Set<LibraryItemType> _types;
  late ReadState _readState;
  late bool _pinnedOnly;
  int? _feedId;
  List<Feed> _feeds = const [];

  @override
  void initState() {
    super.initState();
    _searchController =
        TextEditingController(text: widget.initial.textSearch ?? '');
    _types = {...widget.initial.types};
    _readState = widget.initial.readState;
    _pinnedOnly = widget.initial.pinned == true;
    _feedId = widget.initial.feedId;
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final feeds = await widget.db.feedsDao.feedsOf(widget.profileId);
    if (!mounted) return;
    setState(() => _feeds = feeds);
  }

  LibraryQuery get _currentQuery {
    final search = _searchController.text.trim();
    return LibraryQuery(
        textSearch: search.isEmpty ? null : search,
        types: _types,
        feedId: _feedId,
        readState: _readState,
        pinned: _pinnedOnly ? true : null);
  }

  void _emit() => widget.onChanged(_currentQuery);

  void _clearAll() {
    setState(() {
      _searchController.clear();
      _types = {};
      _readState = ReadState.any;
      _pinnedOnly = false;
      _feedId = null;
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                      child: Text('Filter', style: theme.textTheme.titleLarge)),
                  TextButton(
                    key: const Key('filter-clear-all'),
                    onPressed: _clearAll,
                    child: const Text('Clear all'),
                  ),
                  IconButton(
                    key: const Key('filter-sheet-done'),
                    tooltip: 'Done',
                    icon: const Icon(Icons.check),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('filter-search'),
                controller: _searchController,
                decoration: const InputDecoration(
                    hintText: 'Search titles', prefixIcon: Icon(Icons.search)),
                onChanged: (_) => _emit(),
              ),
              const SizedBox(height: 24),
              Text('Type', style: theme.textTheme.bodyLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in LibraryItemType.values)
                    FilterChip(
                      key: Key('filter-type-${t.name}'),
                      label: Text(_typeLabel(t)),
                      selected: _types.contains(t),
                      onSelected: (selected) => setState(() {
                        if (selected) {
                          _types.add(t);
                        } else {
                          _types.remove(t);
                        }
                        _emit();
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              Text('Read state', style: theme.textTheme.bodyLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final rs in ReadState.values)
                    ChoiceChip(
                      key: Key('filter-read-${rs.name}'),
                      label: Text(_readStateLabel(rs)),
                      selected: _readState == rs,
                      onSelected: (_) {
                        setState(() => _readState = rs);
                        _emit();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 24),
              Wrap(
                children: [
                  FilterChip(
                    key: const Key('filter-pinned-only'),
                    label: const Text('Pinned only'),
                    selected: _pinnedOnly,
                    onSelected: (selected) {
                      setState(() => _pinnedOnly = selected);
                      _emit();
                    },
                  ),
                ],
              ),
              if (_feeds.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text('Feed', style: theme.textTheme.bodyLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      key: const Key('filter-feed-any'),
                      label: const Text('Any'),
                      selected: _feedId == null,
                      onSelected: (_) {
                        setState(() => _feedId = null);
                        _emit();
                      },
                    ),
                    for (final f in _feeds)
                      ChoiceChip(
                        key: Key('filter-feed-${f.id}'),
                        label: Text(f.title.isEmpty ? f.url : f.title,
                            overflow: TextOverflow.ellipsis),
                        selected: _feedId == f.id,
                        onSelected: (_) {
                          setState(() => _feedId = f.id);
                          _emit();
                        },
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                height: 48,
                child: OutlinedButton(
                  key: const Key('open-saved-views'),
                  onPressed: () =>
                      Navigator.of(context).pop(openSavedViewsManagement),
                  child: const Text('Saved views'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _typeLabel(LibraryItemType t) => switch (t) {
        LibraryItemType.book => 'Book',
        LibraryItemType.article => 'Article',
        LibraryItemType.podcast => 'Podcast',
        LibraryItemType.note => 'Note',
      };

  String _readStateLabel(ReadState rs) => switch (rs) {
        ReadState.any => 'Any',
        ReadState.unread => 'Unread',
        ReadState.read => 'Read',
      };
}

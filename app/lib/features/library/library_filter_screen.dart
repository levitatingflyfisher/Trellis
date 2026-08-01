/// The library's filter builder and saved-view manager (Campaign 5 Phase
/// 2). LibraryScreen had no search/sort/filter of any kind before this —
/// this screen is both the filter surface AND where saved views are
/// created, reordered, and deleted; the library screen itself only shows
/// the resulting chips (calm, few controls — feed_settings_screen.dart's
/// shape is the layout precedent for a settings-style scrollable screen).
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../db/database.dart' hide Alignment;
import 'library_query.dart';

class LibraryFilterScreen extends StatefulWidget {
  final AppDatabase db;
  final int profileId;
  final LibraryQuery initial;

  const LibraryFilterScreen(
      {super.key,
      required this.db,
      required this.profileId,
      required this.initial});

  @override
  State<LibraryFilterScreen> createState() => _LibraryFilterScreenState();
}

class _LibraryFilterScreenState extends State<LibraryFilterScreen> {
  late final TextEditingController _searchController;
  late final TextEditingController _viewNameController;
  late Set<LibraryItemType> _types;
  late ReadState _readState;
  late bool _pinnedOnly;
  int? _feedId;
  List<Feed> _feeds = const [];
  List<SavedViewRow> _savedViews = const [];

  @override
  void initState() {
    super.initState();
    _searchController =
        TextEditingController(text: widget.initial.textSearch ?? '');
    _viewNameController = TextEditingController();
    _types = {...widget.initial.types};
    _readState = widget.initial.readState;
    _pinnedOnly = widget.initial.pinned == true;
    _feedId = widget.initial.feedId;
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _viewNameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final feeds = await widget.db.feedsDao.feedsOf(widget.profileId);
    final views = await widget.db.libraryDao.savedViewsOf(widget.profileId);
    if (!mounted) return;
    setState(() {
      _feeds = feeds;
      _savedViews = views;
    });
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

  void _apply() => Navigator.of(context).pop(_currentQuery);

  Future<void> _saveView() async {
    final name = _viewNameController.text.trim();
    if (name.isEmpty) return;
    await widget.db.libraryDao.createSavedView(
        profileId: widget.profileId,
        name: name,
        queryJson: jsonEncode(_currentQuery.toJson()),
        nowMs: DateTime.now().millisecondsSinceEpoch);
    if (!mounted) return;
    Navigator.of(context).pop(_currentQuery);
  }

  Future<void> _deleteView(int id) async {
    await widget.db.libraryDao.deleteSavedView(id);
    await _load();
  }

  Future<void> _moveView(SavedViewRow v, int delta) async {
    final idx = _savedViews.indexWhere((r) => r.id == v.id);
    final newPosition = (idx + delta).clamp(0, _savedViews.length - 1);
    await widget.db.libraryDao.reorderSavedView(
        profileId: widget.profileId, viewId: v.id, newPosition: newPosition);
    await _load();
  }

  void _applyView(SavedViewRow v) {
    Navigator.of(context).pop(
        LibraryQuery.fromJson(jsonDecode(v.queryJson) as Map<String, Object?>));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Filter & saved views')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('filter-search'),
              controller: _searchController,
              decoration: const InputDecoration(
                  hintText: 'Search titles', prefixIcon: Icon(Icons.search)),
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
                    onSelected: (_) => setState(() => _readState = rs),
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
                  onSelected: (selected) =>
                      setState(() => _pinnedOnly = selected),
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
                    onSelected: (_) => setState(() => _feedId = null),
                  ),
                  for (final f in _feeds)
                    ChoiceChip(
                      key: Key('filter-feed-${f.id}'),
                      label: Text(f.title.isEmpty ? f.url : f.title,
                          overflow: TextOverflow.ellipsis),
                      selected: _feedId == f.id,
                      onSelected: (_) => setState(() => _feedId = f.id),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              height: 48,
              child: FilledButton(
                key: const Key('filter-apply'),
                onPressed: _apply,
                child: const Text('Apply'),
              ),
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            Text('Save this filter as a view', style: theme.textTheme.bodyLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('filter-view-name'),
                    controller: _viewNameController,
                    decoration: const InputDecoration(hintText: 'Name it'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    key: const Key('filter-save-view'),
                    onPressed: _saveView,
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
            if (_savedViews.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('Saved views', style: theme.textTheme.bodyLarge),
              const SizedBox(height: 8),
              for (final v in _savedViews)
                ListTile(
                  key: Key('saved-view-${v.name}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(v.name,
                      overflow: TextOverflow.ellipsis, maxLines: 1),
                  onTap: () => _applyView(v),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: Key('view-up-${v.name}'),
                        tooltip: 'Move earlier',
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: () => _moveView(v, -1),
                      ),
                      IconButton(
                        key: Key('view-down-${v.name}'),
                        tooltip: 'Move later',
                        icon: const Icon(Icons.arrow_downward),
                        onPressed: () => _moveView(v, 1),
                      ),
                      IconButton(
                        key: Key('delete-view-${v.name}'),
                        tooltip: 'Delete this view',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteView(v.id),
                      ),
                    ],
                  ),
                ),
            ],
          ],
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

/// Saved-view management (Campaign 5 Phase 2; trimmed to management-only
/// in Campaign 9 Phase 1) — building/adjusting a filter now lives in the
/// live modal [LibraryFilterSheet]; this pushed screen is only for saving
/// the CURRENT filter as a named view, and reordering/deleting the views
/// already saved. feed_settings_screen.dart's shape is the layout
/// precedent for a settings-style scrollable screen.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../db/database.dart' hide Alignment;
import 'library_query.dart';

class LibraryFilterScreen extends StatefulWidget {
  final AppDatabase db;
  final int profileId;

  /// The filter currently active on the library list (or an empty one) —
  /// what "Save this filter as a view" saves. Building/editing a filter
  /// itself happens in [LibraryFilterSheet], not here.
  final LibraryQuery currentQuery;

  const LibraryFilterScreen(
      {super.key,
      required this.db,
      required this.profileId,
      required this.currentQuery});

  @override
  State<LibraryFilterScreen> createState() => _LibraryFilterScreenState();
}

class _LibraryFilterScreenState extends State<LibraryFilterScreen> {
  late final TextEditingController _viewNameController;
  List<SavedViewRow> _savedViews = const [];

  @override
  void initState() {
    super.initState();
    _viewNameController = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _viewNameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final views = await widget.db.libraryDao.savedViewsOf(widget.profileId);
    if (!mounted) return;
    setState(() => _savedViews = views);
  }

  Future<void> _saveView() async {
    final name = _viewNameController.text.trim();
    if (name.isEmpty) return;
    await widget.db.libraryDao.createSavedView(
        profileId: widget.profileId,
        name: name,
        queryJson: jsonEncode(widget.currentQuery.toJson()),
        nowMs: DateTime.now().millisecondsSinceEpoch);
    if (!mounted) return;
    Navigator.of(context).pop(widget.currentQuery);
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
      appBar: AppBar(title: const Text('Saved views')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Save the current filter as a view',
                style: theme.textTheme.bodyLarge),
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
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Text('No saved views yet.',
                    style: theme.textTheme.bodyMedium),
              ),
          ],
        ),
      ),
    );
  }
}

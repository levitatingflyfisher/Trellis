/// Campaign 4 Phase 5: Trellis Echo — a private, reader-facing year-in-
/// review over exactly what this schema records. Reached from Courses,
/// never PIN-gated (that's ParentDashboardScreen's door, a different
/// audience — a parent reviewing a household; this is the reader's own
/// screen about themselves).
///
/// Scoped to the verified premise (orientation found no reading-duration
/// or words-read tracking anywhere in this schema): works finished, active
/// reading days, words collected, cards mastered/reviewed, captures, and
/// listening REACHED (furthest audio position, not measured time —
/// [LifetimeBuilt]'s own doc comment carries the exact meaning). No
/// invented number rides along with the real ones.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Alignment;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:share_plus/share_plus.dart';

import '../../db/database.dart' hide Alignment;
import '../backup/backup_gateway.dart';
import 'echo_export.dart';

/// The production [EchoScreen.shareImage] — native only (the shell wires
/// `kIsWeb ? null : shareEchoImage`, matching the `localMlAvailable`
/// callers' "no dead button" law). Widget tests never reach this; they
/// inject their own closure and assert on the bytes it receives.
Future<void> shareEchoImage(Uint8List pngBytes) async {
  await SharePlus.instance.share(ShareParams(
    files: [XFile.fromData(pngBytes, mimeType: 'image/png', name: 'echo.png')],
    text: 'What I\'ve built, from Trellis.',
  ));
}

class EchoScreen extends StatefulWidget {
  final AppDatabase db;
  final Profile profile;

  /// Captures the shareable card as PNG bytes and hands them to the
  /// platform share sheet; null (the web tier) hides the share button
  /// entirely rather than dangling one that cannot work — the same "no
  /// dead button" law [DeviceServices.localMlAvailable]'s callers follow.
  final Future<void> Function(Uint8List pngBytes)? shareImage;

  /// The backup screen's own filesystem door, reused rather than
  /// reinvented — works on every platform file_picker supports,
  /// including a plain browser download on web.
  final BackupGateway gateway;

  EchoScreen({
    super.key,
    required this.db,
    required this.profile,
    this.shareImage,
    BackupGateway? gateway,
  }) : gateway = gateway ?? FilePickerBackupGateway();

  @override
  State<EchoScreen> createState() => _EchoScreenState();
}

class _EchoScreenState extends State<EchoScreen> {
  LifetimeBuilt? _built;
  int _cardsReviewed = 0;
  int _captures = 0;
  final GlobalKey _cardKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final built = await widget.db.householdDao.lifetimeBuiltOf(widget.profile.id);
    final reviewed = await widget.db.studyDao.totalReviewsOf(widget.profile.id);
    final captureRows =
        await widget.db.capturesDao.capturesOfProfile(widget.profile.id);
    if (!mounted) return;
    setState(() {
      _built = built;
      _cardsReviewed = reviewed;
      _captures = captureRows.length;
    });
  }

  Future<Uint8List> _captureCard() async {
    final boundary = _cardKey.currentContext!.findRenderObject()
        as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  Future<void> _share() async {
    final shareImage = widget.shareImage;
    if (shareImage == null) return;
    final bytes = await _captureCard();
    await shareImage(bytes);
  }

  Future<(List<LedgerExportWord>, List<LedgerExportCapture>)>
      _exportData() async {
    final works = await widget.db.spineDao.worksOf(widget.profile.id);
    final titleOf = {for (final w in works) w.id: w.title};
    final words = await widget.db.ledgerDao.wordsOf(widget.profile.id);
    final captureRows =
        await widget.db.capturesDao.capturesOfProfile(widget.profile.id);
    return (
      [
        for (final w in words)
          (
            word: w.word,
            lang: w.lang,
            workTitle: w.sourceWorkId == null ? null : titleOf[w.sourceWorkId],
            addedAtMs: w.addedAtMs,
          ),
      ],
      [
        for (final c in captureRows)
          (
            workTitle: titleOf[c.workId] ?? 'Unknown work',
            positionMs: c.positionMs,
            segmentIdx: c.segmentIdx,
            createdAtMs: c.createdAtMs,
          ),
      ],
    );
  }

  Future<void> _exportMarkdown() async {
    final (words, captures) = await _exportData();
    final md = buildLedgerMarkdown(
        profileName: widget.profile.name, words: words, captures: captures);
    await widget.gateway
        .saveBytes('${widget.profile.name}-word-ledger.md', Uint8List.fromList(md.codeUnits));
  }

  Future<void> _exportJson() async {
    final (words, captures) = await _exportData();
    final jsonText = buildLedgerJson(
        profileName: widget.profile.name, words: words, captures: captures);
    await widget.gateway.saveBytes(
        '${widget.profile.name}-word-ledger.json',
        Uint8List.fromList(jsonText.codeUnits));
  }

  @override
  Widget build(BuildContext context) {
    final built = _built;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trellis Echo'),
        actions: [
          PopupMenuButton<String>(
            key: const Key('echo-export-menu'),
            tooltip: 'Export',
            icon: const Icon(Icons.ios_share_outlined),
            onSelected: (value) {
              if (value == 'md') unawaited(_exportMarkdown());
              if (value == 'json') unawaited(_exportJson());
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'md', child: Text('Export as Markdown')),
              PopupMenuItem(value: 'json', child: Text('Export as JSON')),
            ],
          ),
          if (widget.shareImage != null)
            IconButton(
              key: const Key('echo-share'),
              tooltip: 'Share',
              icon: const Icon(Icons.share_outlined),
              onPressed: built == null ? null : () => unawaited(_share()),
            ),
        ],
      ),
      body: built == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: RepaintBoundary(
                  key: _cardKey,
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: _card(context, built),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _card(BuildContext context, LifetimeBuilt built) {
    final theme = Theme.of(context);
    final lines = echoLines(built,
        cardsReviewed: _cardsReviewed, captures: _captures);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.profile.name,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('What you\'ve built',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        if (lines.isEmpty)
          Text('Nothing built yet — pick up a book.',
              style: theme.textTheme.bodyLarge)
        else
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(line, style: theme.textTheme.bodyLarge),
            ),
        const SizedBox(height: 16),
        Text('Computed on this device. Nothing here ever leaves it.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

/// The card's stat lines: only what EXISTS (positive framing, ADR-0003 law
/// 5 — same convention `parent_dashboard.dart`'s `builtLines` already
/// established). Deliberately excludes any minutes-listened or words-read
/// claim — see this file's own top-of-file doc comment for why.
List<String> echoLines(LifetimeBuilt built,
    {required int cardsReviewed, required int captures}) {
  return [
    if (built.worksKept > 0)
      _n(built.worksKept, 'work in the library', 'works in the library'),
    if (built.worksFinished > 0)
      _n(built.worksFinished, 'work finished', 'works finished'),
    if (built.activeReadingDays > 0)
      _n(built.activeReadingDays, 'day of reading', 'days of reading'),
    if (built.wordsCollected > 0)
      _n(built.wordsCollected, 'word collected', 'words collected'),
    if (built.cardsMastered > 0)
      _n(built.cardsMastered, 'card mastered', 'cards mastered'),
    if (cardsReviewed > 0) _n(cardsReviewed, 'card reviewed', 'cards reviewed'),
    if (captures > 0) _n(captures, 'capture', 'captures'),
    if (built.listeningMs > 0) _reached(built.listeningMs),
    if (built.currentCourse != null)
      'Current course: ${built.currentCourse!.title} — '
          '${built.currentCourse!.mastered} of ${built.currentCourse!.total} '
          'mastered',
  ];
}

String _n(int n, String singular, String plural) =>
    n == 1 ? '1 $singular' : '$n $plural';

/// Deliberately NOT "minutes of listening" (the parent dashboard's own
/// phrasing) — [LifetimeBuilt.listeningMs] is furthest audio position
/// reached, summed per work, which can diverge from actual time spent
/// under re-listening or seeking. Echo is new copy; it says what the
/// number actually is.
String _reached(int ms) {
  final minutes = ms ~/ 60000;
  if (minutes < 60) return '${_n(minutes, 'minute', 'minutes')} of audio reached';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0
      ? '${_n(h, 'hour', 'hours')} of audio reached'
      : '$h h $m min of audio reached';
}

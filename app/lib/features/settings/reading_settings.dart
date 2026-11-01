/// The reading settings: how every text looks and how read aloud speaks.
///
/// One set of rows with two doors (board-0131): the Reading group of the
/// Settings tab, and "Reading settings" at the foot of the reader's ⋮,
/// where the bottom bar is out of sight. Both doors show these same rows,
/// so a setting is never in one and missing from the other.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../reader/reader_typography_settings_screen.dart';
import '../reader/speech/spoken_text.dart' show speakCitationsKey;
import '../references/keep_page.dart' show keepLinkedPagesKey;
import '../shared/capped_body.dart';

/// The rows. [offerSystemVoice] shows "Use the system voice", which only
/// means something when a downloaded voice exists to set aside (ADR-0006:
/// no dead settings). [onOpenVoices], when given, adds "Read aloud voices"
/// for every language.
class ReadingSettingsSection extends StatefulWidget {
  const ReadingSettingsSection({
    super.key,
    required this.db,
    required this.profileId,
    this.offerSystemVoice = false,
    this.onOpenVoices,
  });

  final AppDatabase db;
  final int profileId;
  final bool offerSystemVoice;
  final Future<void> Function(BuildContext context)? onOpenVoices;

  @override
  State<ReadingSettingsSection> createState() => _ReadingSettingsSectionState();
}

class _ReadingSettingsSectionState extends State<ReadingSettingsSection> {
  bool _systemVoice = false;
  bool _citations = false;
  bool _keepLinked = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final systemVoice = await widget.db.profilesDao.preferSystemVoice(
      widget.profileId,
    );
    final citations =
        await widget.db.deviceSettingsDao.read(speakCitationsKey) == 'on';
    final keepLinked =
        await widget.db.deviceSettingsDao.read(keepLinkedPagesKey) == 'on';
    if (!mounted) return;
    setState(() {
      _systemVoice = systemVoice;
      _citations = citations;
      _keepLinked = keepLinked;
      _loaded = true;
    });
  }

  /// Takes effect on the next read aloud; one under way finishes as it
  /// began (ADR-0006).
  Future<void> _setSystemVoice(bool on) async {
    setState(() => _systemVoice = on);
    await widget.db.profilesDao.setPreferSystemVoice(widget.profileId, on);
  }

  Future<void> _setCitations(bool on) async {
    setState(() => _citations = on);
    await widget.db.deviceSettingsDao.write(
      speakCitationsKey,
      on ? 'on' : 'off',
    );
  }

  Future<void> _setKeepLinked(bool on) async {
    setState(() => _keepLinked = on);
    await widget.db.deviceSettingsDao.write(
      keepLinkedPagesKey,
      on ? 'on' : 'off',
    );
  }

  @override
  Widget build(BuildContext context) {
    final voices = widget.onOpenVoices;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          key: const Key('settings-reading-style'),
          leading: const Icon(Icons.text_fields),
          title: const Text('Reading style'),
          subtitle: const Text('Type, size and spacing on the page'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ReaderTypographySettingsScreen(
                db: widget.db,
                profileId: widget.profileId,
              ),
            ),
          ),
        ),
        if (voices != null)
          ListTile(
            key: const Key('settings-read-aloud-voices'),
            leading: const Icon(Icons.record_voice_over_outlined),
            title: const Text('Read aloud voices'),
            subtitle: const Text('A voice for each language'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => voices(context),
          ),
        if (widget.offerSystemVoice)
          SwitchListTile(
            key: const Key('voice-preference-toggle'),
            secondary: const Icon(Icons.phone_android),
            title: const Text('Use the system voice'),
            subtitle: const Text(
              'Read aloud with the phone’s own voice, not the downloaded '
              'one.',
            ),
            value: _systemVoice,
            onChanged: _loaded ? _setSystemVoice : null,
          ),
        SwitchListTile(
          key: const Key('speak-citations-toggle'),
          secondary: const Icon(Icons.format_quote_outlined),
          title: const Text('Read citations aloud'),
          subtitle: const Text(
            'Citations, footnote marks and bare links. The page always '
            'shows them.',
          ),
          value: _citations,
          onChanged: _loaded ? _setCitations : null,
        ),
        SwitchListTile(
          key: const Key('keep-linked-pages-toggle'),
          secondary: const Icon(Icons.inventory_2_outlined),
          title: const Text('Keep linked pages when saving'),
          subtitle: const Text(
            'When you save an article, Trellis also gets the pages it '
            'links to and keeps their text on this device. Each page is a '
            'request to its site.',
          ),
          value: _keepLinked,
          onChanged: _loaded ? _setKeepLinked : null,
        ),
      ],
    );
  }
}

/// The reader's own door to [ReadingSettingsSection]: the reader takes the
/// whole screen, so the Settings tab is out of reach there.
class ReadingSettingsScreen extends StatelessWidget {
  const ReadingSettingsScreen({
    super.key,
    required this.db,
    required this.profileId,
    this.offerSystemVoice = false,
  });

  final AppDatabase db;
  final int profileId;
  final bool offerSystemVoice;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Reading settings')),
    body: CappedBody(
      child: ListView(
        key: const Key('reading-settings-list'),
        children: [
          ReadingSettingsSection(
            db: db,
            profileId: profileId,
            offerSystemVoice: offerSystemVoice,
          ),
        ],
      ),
    ),
  );
}

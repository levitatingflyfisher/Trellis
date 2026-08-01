/// Campaign 4 Phase 1: the print-reader typography settings surface — a
/// live preview paragraph (ergonomic-ux: show, don't just tell) above a
/// stack of sliders/steppers/pickers that write [ReaderPrefs] on every
/// change, the same "save as you go" idiom [preferSystemVoice] already
/// uses. RSVP and the ticker keep their own tuned displays — nothing here
/// reaches them.
library;

import 'package:flutter/material.dart';

import '../../db/database.dart';
import 'reader_prefs.dart';

class ReaderTypographySettingsScreen extends StatefulWidget {
  const ReaderTypographySettingsScreen(
      {super.key, required this.db, required this.profileId});

  final AppDatabase db;
  final int profileId;

  @override
  State<ReaderTypographySettingsScreen> createState() =>
      _ReaderTypographySettingsScreenState();
}

class _ReaderTypographySettingsScreenState
    extends State<ReaderTypographySettingsScreen> {
  ReaderTypography _t = const ReaderTypography();
  // The full blob, not just its typography — this screen only ever meant
  // to edit typography, but the blob now also carries lastPlayedWorkId
  // (Campaign 9 Phase 2). Writing a bare `ReaderPrefs(typography: next)`
  // on every change would silently drop that sibling key on the floor the
  // next time a slider moves; round-tripping through `_prefs.copyWith`
  // keeps whatever else lives in the blob untouched.
  ReaderPrefs _prefs = const ReaderPrefs();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await widget.db.profilesDao.readerPrefs(widget.profileId);
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _t = prefs.typography;
      _loaded = true;
    });
  }

  Future<void> _apply(ReaderTypography next) async {
    setState(() => _t = next);
    _prefs = _prefs.copyWith(typography: next);
    await widget.db.profilesDao.setReaderPrefs(widget.profileId, _prefs);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('reader-typography-settings-screen'),
      appBar: AppBar(title: const Text('Reading style')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _preview(context),
                const SizedBox(height: 24),
                _typefacePicker(),
                const SizedBox(height: 16),
                _slider(
                  key: const Key('fontscale-slider'),
                  label: 'Text size',
                  value: _t.fontScale,
                  min: 0.8,
                  max: 2.0,
                  onChanged: (v) => _apply(_t.copyWith(fontScale: v)),
                ),
                _slider(
                  key: const Key('lineheight-slider'),
                  label: 'Line spacing',
                  value: _t.lineHeight,
                  min: 1.2,
                  max: 2.4,
                  onChanged: (v) => _apply(_t.copyWith(lineHeight: v)),
                ),
                _slider(
                  key: const Key('maxwidth-slider'),
                  label: 'Page width',
                  value: _t.maxTextWidth,
                  min: 360,
                  max: 900,
                  onChanged: (v) => _apply(_t.copyWith(maxTextWidth: v)),
                ),
                _paragraphSpacingStepper(),
                const SizedBox(height: 16),
                _justifiedSwitch(),
              ],
            ),
    );
  }

  Widget _preview(BuildContext context) {
    final base = Theme.of(context).textTheme.bodyLarge;
    final size = base?.fontSize;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        'The quick brown fox reads this paragraph at the settings you '
        'choose below — this is exactly how your books will look.',
        key: const Key('typography-preview'),
        textAlign: _t.justified ? TextAlign.justify : TextAlign.start,
        style: base?.copyWith(
          fontFamily: readerTypefaceFontFamily(_t.typeface),
          height: _t.lineHeight,
          fontSize: size == null ? null : size * _t.fontScale,
        ),
      ),
    );
  }

  Widget _typefacePicker() {
    return Row(
      children: [
        const Text('Typeface'),
        const SizedBox(width: 16),
        Expanded(
          child: SegmentedButton<ReaderTypeface>(
            segments: const [
              ButtonSegment(value: ReaderTypeface.lora, label: Text('Lora')),
              ButtonSegment(
                  value: ReaderTypeface.nunito, label: Text('Nunito')),
            ],
            selected: {_t.typeface},
            onSelectionChanged: (s) => _apply(_t.copyWith(typeface: s.first)),
          ),
        ),
      ],
    );
  }

  Widget _slider({
    required Key key,
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        SizedBox(
          height: 48,
          child: Slider(
            key: key,
            value: value,
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Widget _paragraphSpacingStepper() {
    return Row(
      children: [
        Expanded(
            child: Text('Paragraph spacing',
                style: Theme.of(context).textTheme.labelLarge)),
        IconButton(
          key: const Key('paragraphspacing-down'),
          iconSize: 24,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: () => _apply(
              _t.copyWith(paragraphSpacing: (_t.paragraphSpacing - 4).clamp(0, 32))),
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text('${_t.paragraphSpacing.round()}dp'),
        IconButton(
          key: const Key('paragraphspacing-up'),
          iconSize: 24,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: () => _apply(
              _t.copyWith(paragraphSpacing: (_t.paragraphSpacing + 4).clamp(0, 32))),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }

  Widget _justifiedSwitch() {
    return SwitchListTile(
      key: const Key('justified-switch'),
      value: _t.justified,
      onChanged: (v) => _apply(_t.copyWith(justified: v)),
      title: const Text('Justified text'),
      subtitle: const Text(
          'Lines stretch edge to edge. This reader justifies without '
          'hyphenation, so wide gaps can appear on narrow screens or '
          'short lines — ragged-right avoids that.'),
    );
  }
}

/// Settings, the fifth bottom-bar item (board-0131/0132, owner: "I still
/// am annoyed by the three dots hiding different things on different
/// screens"; "maybe we migrate permanent things to the lower [bar]
/// including settings").
///
/// Every app-wide setting and door is here, grouped plainly, and nowhere
/// in a tab's ⋮. A tab's ⋮ holds only that screen's own actions.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../../app_version.dart';
import '../../db/database.dart';
import '../../services/device_services.dart' show SystemVoice;
import '../brain/brain_settings_screen.dart';
import '../brain/brain_store.dart';
import '../episodes/episode_actions.dart';
import '../feeds/background/feed_check_section.dart';
import '../feeds/background/feed_check_settings.dart';
import '../listen/listen_jobs.dart' show learningLanguageKey;
import '../listen/spoken_share.dart'
    show clonedVoiceShareAllowed, shareClonedVoiceAudioKey;
import '../reader/reader_prefs.dart' show ReaderPrefs;
import '../reader/speech/read_aloud_voices.dart';
import '../reader/translation/language_names.dart';
import '../reader/translation/translation_route.dart' show baseLanguage;
import '../shared/capped_body.dart';
import 'reading_settings.dart';
import 'theme_preference.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.db,
    required this.profile,
    required this.onSwitchProfile,
    this.actions,
    this.feedCheck,
    this.localMlAvailable = false,
    this.downloadedVoiceLangs,
    this.listVoices,
    this.openVoiceSettings,
    this.brainStore,
    this.onOpenModels,
    this.onOpenBackup,
    this.onOpenJobs,
    this.onOpenEcho,
    this.onOpenHeadsetKeys,
  });

  final AppDatabase db;
  final Profile profile;
  final VoidCallback onSwitchProfile;

  /// The learning language lives on its listen jobs; null hides the row
  /// where nothing can be made in another language (the web).
  final EpisodeActions? actions;

  /// The device's Wi-Fi and background-check switches; null where the
  /// system cannot run a check.
  final FeedCheckSettings? feedCheck;
  final bool localMlAvailable;

  /// The languages Trellis's own downloaded voices speak here, so "Use
  /// the system voice" has something to set aside, and the voices sheet
  /// knows which languages they read.
  final Future<Set<String>> Function()? downloadedVoiceLangs;

  /// The phone's installed voices, for Read aloud voices; null hides it.
  final Future<List<SystemVoice>?> Function()? listVoices;

  /// Opens Android's text-to-speech settings, from the voices sheet
  /// where a language has no voice. Null hides the button.
  final Future<bool> Function()? openVoiceSettings;
  final BrainStore? brainStore;
  final VoidCallback? onOpenModels;
  final VoidCallback? onOpenBackup;
  final VoidCallback? onOpenJobs;
  final VoidCallback? onOpenEcho;
  final VoidCallback? onOpenHeadsetKeys;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Set<String> _voiceLangs = const {};
  bool get _downloadedVoice => _voiceLangs.isNotEmpty;
  bool _dspDefault = false;
  bool _shareClonedVoice = false;
  String _scheduler = 'fsrs';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final id = widget.profile.id;
    final dsp = await widget.db.profilesDao.dspGlobalDefault(id);
    final scheduler = await widget.db.profilesDao.scheduler(id);
    final voiceLangs =
        await widget.downloadedVoiceLangs?.call() ?? const <String>{};
    final shareCloned = await clonedVoiceShareAllowed(widget.db);
    if (!mounted) return;
    setState(() {
      _dspDefault = dsp;
      _shareClonedVoice = shareCloned;
      _scheduler = scheduler;
      _voiceLangs = voiceLangs;
      _loaded = true;
    });
  }

  /// The owner's rule: a file in a copy of a real host's voice is a
  /// separate switch, off by default (see spoken_share.dart).
  Future<void> _setShareClonedVoice(bool on) async {
    setState(() => _shareClonedVoice = on);
    await widget.db.deviceSettingsDao
        .write(shareClonedVoiceAudioKey, on ? '1' : '0');
  }

  Future<void> _setDspDefault(bool on) async {
    setState(() => _dspDefault = on);
    await widget.db.profilesDao.setDspGlobalDefault(widget.profile.id, on);
  }

  /// The study scheduler (ADR-0009). Turning FSRS on explains, once, what
  /// it is and that progress carries over; turning it off flips at once.
  Future<void> _setFsrs(bool on) async {
    if (on) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Use FSRS for grading?'),
          content: const Text(
            'Classic is SM-2, the long-standing spaced-repetition schedule. '
            'FSRS learns each card’s own difficulty and memory curve to '
            'schedule reviews more precisely than Classic’s fixed steps. '
            'Your progress carries over when you switch, either way.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Use FSRS'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    final next = on ? 'fsrs' : 'classic';
    await widget.db.profilesDao.setScheduler(widget.profile.id, next);
    if (!mounted) return;
    setState(() => _scheduler = next);
  }

  void _openThinking() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrainSettingsScreen(
          store: widget.brainStore ?? BrainStore.production(),
          localMlAvailable: widget.localMlAvailable,
        ),
      ),
    );
  }

  Future<void> _openWifiAndData(FeedCheckSettings settings) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => SafeArea(
          child: SingleChildScrollView(
            key: const Key('wifi-and-data-sheet'),
            child: FeedCheckSection(settings: settings),
          ),
        ),
      );

  /// A voice for every language this reader meets: the learning language,
  /// and every language a work or a show names.
  Future<void> _openVoices(BuildContext context) async {
    final listVoices = widget.listVoices;
    if (listVoices == null) return;
    final db = widget.db;
    final id = widget.profile.id;
    final learning = await db.deviceSettingsDao.read(learningLanguageKey);
    final used = await db.spineDao.langsInUse(id);
    final prefs = await db.profilesDao.readerPrefs(id);
    final systemVoice = await db.profilesDao.preferSystemVoice(id);
    final installed = await listVoices();
    final langs =
        {
          for (final l in [learning, ...used]) ?baseLanguage(l),
        }.toList()..sort(
          (a, b) => languageDisplayName(a).compareTo(languageDisplayName(b)),
        );
    if (!context.mounted) return;
    var choices = prefs.voices;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ReadAloudVoicesSheet(
        langs: langs,
        neuralLangs: systemVoice ? const {} : _voiceLangs,
        installed: installed,
        choices: choices,
        systemVoiceOn: _downloadedVoice && systemVoice,
        onOpenSettings: widget.openVoiceSettings,
        onPick: (lang, voiceId) {
          choices = {...choices, lang: voiceId};
          unawaited(
            db.profilesDao.updateReaderPrefs(
              id,
              (ReaderPrefs p) =>
                  p.copyWith(voices: {...p.voices, lang: voiceId}),
            ),
          );
        },
      ),
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Semantics(
      header: true,
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );

  Widget _door(
    Key key,
    IconData icon,
    String title,
    VoidCallback onTap, {
    String? subtitle,
  }) => ListTile(
    key: key,
    leading: Icon(icon),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );

  @override
  Widget build(BuildContext context) {
    final theme = ThemePreferenceScope.maybeOf(context);
    final jobs = widget.actions?.listenJobs;
    final feedCheck = widget.feedCheck;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: CappedBody(
        // Not lazy: the page is short, and every row must exist to be
        // scrolled to at large text.
        child: SingleChildScrollView(
          key: const Key('settings-list'),
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (theme != null) ...[
                _heading('Theme'),
                ListenableBuilder(
                  listenable: theme,
                  builder: (context, _) => RadioGroup<OhThemeModePreference>(
                    groupValue: theme.value,
                    onChanged: (p) {
                      if (p != null) unawaited(theme.choose(p));
                    },
                    child: Column(
                      children: [
                        for (final p in OhThemeModePreference.values)
                          RadioListTile<OhThemeModePreference>(
                            key: Key('theme-choice-${p.name}'),
                            value: p,
                            title: Text(p.label),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              _heading('Reading'),
              // Keyed on what decides its rows, so the system-voice row
              // appears once the downloaded voice is known.
              ReadingSettingsSection(
                key: ValueKey(_downloadedVoice),
                db: widget.db,
                profileId: widget.profile.id,
                offerSystemVoice: _downloadedVoice,
                onOpenVoices: widget.listVoices == null ? null : _openVoices,
              ),
              _heading('Listening'),
              if (feedCheck != null)
                _door(
                  const Key('settings-wifi-and-data'),
                  Icons.wifi,
                  'Wi-Fi and data',
                  () => _openWifiAndData(feedCheck),
                  subtitle: 'Checking feeds and downloading',
                ),
              if (widget.localMlAvailable)
                SwitchListTile(
                  key: const Key('dsp-global-default-toggle'),
                  secondary: const Icon(Icons.graphic_eq),
                  title: const Text(
                    'Trim silence & even out volume by default',
                  ),
                  subtitle: const Text(
                    'For every show, unless its own settings say otherwise.',
                  ),
                  value: _dspDefault,
                  onChanged: _loaded ? _setDspDefault : null,
                ),
              if (widget.localMlAvailable)
                SwitchListTile(
                  key: const Key('share-cloned-voice-toggle'),
                  secondary: const Icon(Icons.record_voice_over_outlined),
                  title: const Text('Share audio made in a host’s own voice'),
                  subtitle: const Text(
                    'When off, Share sends only words for an episode spoken '
                    'in a copy of a real person’s voice. Trellis makes no '
                    'such voice yet.',
                  ),
                  value: _shareClonedVoice,
                  onChanged: _loaded ? _setShareClonedVoice : null,
                ),
              if (widget.onOpenHeadsetKeys case final open?)
                _door(
                  const Key('open-headset-keys'),
                  Icons.headphones_outlined,
                  'Headphone buttons',
                  open,
                  subtitle: 'What Next and Previous do',
                ),
              _heading('Learning'),
              if (jobs != null)
                ListenableBuilder(
                  listenable: jobs,
                  builder: (context, _) {
                    final lang = jobs.language;
                    return _door(
                      const Key('learning-language-setting'),
                      Icons.translate,
                      'Learning language',
                      () => unawaited(
                        widget.actions!.chooseLearningLanguage(context),
                      ),
                      subtitle: lang == null
                          ? 'Not chosen'
                          : languageDisplayName(lang),
                    );
                  },
                ),
              if (jobs != null)
                ListenableBuilder(
                  listenable: jobs,
                  builder: (context, _) => _door(
                    const Key('listen-clearness-setting'),
                    Icons.record_voice_over_outlined,
                    'How clearly the voice speaks',
                    () => unawaited(jobs.chooseClearness(context)),
                    subtitle: jobs.clearness.label,
                  ),
                ),
              SwitchListTile(
                key: const Key('scheduler-toggle'),
                secondary: const Icon(Icons.event_repeat),
                title: const Text('FSRS scheduling'),
                subtitle: const Text(
                  'Learns each card’s memory curve. Off '
                  'uses Classic (SM-2) fixed steps.',
                ),
                value: _scheduler == 'fsrs',
                onChanged: _loaded ? _setFsrs : null,
              ),
              _door(
                const Key('open-thinking'),
                Icons.psychology_outlined,
                'Thinking (AI helper)',
                _openThinking,
              ),
              _heading('Storage and backup'),
              if (widget.onOpenModels case final open?)
                _door(
                  const Key('open-models'),
                  Icons.storage_outlined,
                  'Models & storage',
                  open,
                ),
              if (widget.onOpenBackup case final open?)
                _door(
                  const Key('open-backup'),
                  Icons.backup_outlined,
                  'Backup & migrate',
                  open,
                ),
              if (widget.onOpenJobs case final open?)
                _door(
                  const Key('settings-jobs'),
                  Icons.downloading,
                  'Jobs',
                  open,
                  subtitle: 'Downloads, transcripts and translations',
                ),
              _heading('This reader'),
              _door(
                const Key('profile-switcher'),
                Icons.people_outline,
                'Switch reader',
                widget.onSwitchProfile,
                subtitle: widget.profile.name,
              ),
              if (widget.onOpenEcho case final open?)
                _door(
                  const Key('open-echo'),
                  Icons.auto_graph,
                  'What you’ve built',
                  open,
                ),
              _heading('About'),
              ListTile(
                key: const Key('settings-version'),
                leading: const Icon(Icons.info_outline),
                title: Text('Trellis $appVersion'),
              ),
              _door(
                const Key('settings-licences'),
                Icons.gavel_outlined,
                'Open-source licences',
                () => showLicensePage(
                  context: context,
                  applicationName: 'Trellis',
                  applicationVersion: appVersion,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

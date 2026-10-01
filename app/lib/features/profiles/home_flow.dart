import 'dart:async';

import 'package:comms_core/comms_core.dart';
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../db/search_index.dart';
import '../../services/device_services.dart';
import '../feeds/background/feed_check_platform.dart';
import '../feeds/background/feed_check_runner.dart';
import '../feeds/background/feed_check_settings.dart';
import '../feeds/feeds_repository.dart';
import '../home_widget/home_widget_host.dart';
import '../home_widget/widget_snapshot.dart';
import '../intake/share_queue.dart';
import '../intake/share_source.dart';
import '../jobs/job_center.dart';
import '../player/episode_player.dart';
import 'home_shell.dart';
import 'parent_dashboard.dart';
import 'parent_pin.dart';
import 'pin_dialogs.dart';
import '../shared/capped_body.dart';

/// The name a first launch gives its one reader.
const defaultReaderName = 'Reader';

/// The root flow, which opens into the task (operator ruling 48; audit
/// rank 5): a first launch makes a reader called "Reader" and opens their
/// shell on Latest, with no name to type; a later launch opens the reader this
/// device last had open (or the only one). The picker ("Who's reading?")
/// appears only when there is a real choice: several readers and no
/// remembered one, or the reader asked to switch. One stateful widget, no
/// routes: switching reader is a setState, not a navigation.
class HomeFlow extends StatefulWidget {
  final AppDatabase db;
  final HttpFetcher fetcher;
  final EpisodePlayer Function() createPlayer;
  final DeviceServices services;

  /// The system scheduler behind background feed checks; unavailable by
  /// default, so widget tests never reach a platform channel.
  final FeedCheckScheduler feedCheckScheduler;

  /// Shares from other apps; the shell of whichever reader is open takes
  /// them, so a share waits behind the picker and the PIN.
  final ShareSource shareSource;

  /// The home-screen widget's door; the open reader's shell writes its
  /// card and takes its taps.
  final HomeWidgetHost homeWidget;
  const HomeFlow(
      {super.key,
      required this.db,
      required this.fetcher,
      required this.createPlayer,
      required this.services,
      this.feedCheckScheduler = const UnavailableFeedCheckScheduler(),
      this.shareSource = const UnavailableShareSource(),
      this.homeWidget = const UnavailableHomeWidgetHost()});

  @override
  State<HomeFlow> createState() => _HomeFlowState();
}

class _HomeFlowState extends State<HomeFlow> {
  List<Profile>? _profiles;
  Profile? _active;
  bool _adding = false;
  bool _pinSet = false;
  late final ParentPinService _pin = ParentPinService(widget.db);

  /// Held here, above any reader's shell, so switching reader never
  /// builds a second runner for a job already in flight.
  late final JobCenter _jobs = JobCenter.forDevice(widget.db, widget.services);

  late final FeedCheckSettings _feedCheck =
      FeedCheckSettings(widget.db, widget.feedCheckScheduler);

  /// The app engine's side of a background check (ADR-0018): every reader's
  /// feeds over this engine's connection, downloads through this engine's
  /// coordinator, so they show on the Jobs screen as they run.
  late final FeedCheckRunner? _feedCheckRunner = () {
    final downloads = _jobs.downloads;
    if (!widget.feedCheckScheduler.available || downloads == null) return null;
    final repository = FeedsRepository(
        db: widget.db, fetcher: widget.fetcher, services: widget.services);
    final runner = FeedCheckRunner.withCoordinator(
      db: widget.db,
      repository: repository,
      scheduler: widget.feedCheckScheduler,
      downloads: downloads,
    );
    return runner;
  }();

  void Function()? _closeFeedCheckHost;

  /// Completes once no background check can still be writing, so this
  /// engine's own cold-start writes wait for it (ADR-0018). At once when
  /// there is no background check on this platform.
  final Completer<void> _writesReady = Completer<void>();

  /// Fills the search index an upgrade rebuilt empty (1.5.4): a writer,
  /// so it waits for the hand-over like every cold-start write.
  late final SearchBackfill _searchBackfill = SearchBackfill(widget.db);

  /// Shares from other apps, each bound to the reader open when it came.
  late final ShareQueue _shares = ShareQueue(
      db: widget.db,
      source: widget.shareSource,
      activeProfileId: () => _active?.id,
      writesReady: _writesReady.future);

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    // The readers render at once; only what writes waits for the hand-over.
    unawaited(_load());
    unawaited(_searchBackfill.run(after: _writesReady.future));
    unawaited(_shares.start());
    final runner = _feedCheckRunner;
    if (runner != null) {
      // A check running headless winds down first (a few seconds at most):
      // its downloads pause before jobs resume, so none gets a second
      // owner, and its connection closes before this one writes.
      final close = await openFeedCheckHost(
          (task, stop) => runner.run(task, stop: stop));
      if (!mounted) {
        close();
        return;
      }
      _closeFeedCheckHost = close;
    }
    _writesReady.complete();
    await _jobs.restoreAndResume();
    await _feedCheck.applyAtLaunch();
    await _feedCheckRunner?.requestAutoDownloadIfPending();
  }

  @override
  void dispose() {
    _searchBackfill.stop();
    _shares.dispose();
    _closeFeedCheckHost?.call();
    _feedCheck.dispose();
    _jobs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    var profiles = await widget.db.profilesDao.all();
    final pinSet = await _pin.isSet;
    // First launch: nothing to protect yet, so no name to type before the
    // app is usable. The reader can be renamed from the Parent dashboard.
    if (profiles.isEmpty && !pinSet && _firstLoad) {
      await widget.db.profilesDao.create(defaultReaderName);
      profiles = await widget.db.profilesDao.all();
    }
    Profile? active = _active;
    if (_firstLoad && active == null) {
      final last = await widget.db.deviceSettingsDao.lastProfileId();
      // A stale id (reader removed, or a restore replaced everyone) falls
      // back to the only reader, or to the picker.
      active = profiles.where((p) => p.id == last).firstOrNull ??
          (profiles.length == 1 ? profiles.single : null);
    }
    _firstLoad = false;
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _pinSet = pinSet;
      _active = active;
    });
  }

  bool _firstLoad = true;

  /// Leaving a reader empties the home-screen widget at once, before the
  /// picker or the PIN: the next person to pick up the phone must not see
  /// the last reader's listening and reading. The next reader's shell
  /// writes their own card when it opens.
  void _clearWidget() {
    final host = widget.homeWidget;
    if (host.available) {
      unawaited(host.push(const WidgetSnapshot(profileId: 0)));
    }
  }

  /// Opens [p]'s shell and remembers it for the next launch.
  void _open(Profile p) {
    setState(() => _active = p);
    widget.db.deviceSettingsDao.setLastProfileId(p.id);
  }

  Future<void> _create(String name) async {
    final id = await widget.db.profilesDao.create(name);
    final profiles = await widget.db.profilesDao.all();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _adding = false;
    });
    _open(profiles.firstWhere((p) => p.id == id));
  }

  /// Creating a reader is PIN-gated once a PIN exists (P5) — through THE
  /// one chokepoint. With no PIN set the gate is simply open.
  Future<void> _requestAdd() async {
    if (!await requireParentPin(context, _pin)) return;
    if (!mounted) return;
    setState(() => _adding = true);
  }

  /// The dashboard door on the picker. Renames, removals and PIN changes
  /// happen behind it, so the picker reloads when it closes.
  Future<void> _openDashboard() async {
    if (!await requireParentPin(context, _pin)) return;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ParentDashboardScreen(db: widget.db, pin: _pin)));
    final active = _active;
    if (active != null &&
        !(await widget.db.profilesDao.all()).any((p) => p.id == active.id)) {
      // The active reader was removed from the dashboard — walk back to
      // the picker rather than sit on a dangling id.
      _active = null;
      _clearWidget();
    }
    // A removed reader's waiting shares go with them.
    await _shares.purgeMissingProfiles();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final profiles = _profiles;
    if (profiles == null) {
      return const Scaffold(body: CappedBody(child: Center(child: CircularProgressIndicator())));
    }
    // First run (nothing to protect yet) walks straight into creating a
    // reader; once a PIN exists, even an empty household shows the picker
    // so the create door stays behind the gate.
    if (_adding || (profiles.isEmpty && !_pinSet)) {
      return _CreateProfileScreen(
        onCreate: _create,
        onBack: profiles.isEmpty ? null : () => setState(() => _adding = false),
      );
    }
    final active = _active;
    if (active == null) {
      return _ProfilePickerScreen(
        profiles: profiles,
        onPick: _open,
        onAdd: _requestAdd,
        onParents: _openDashboard,
      );
    }
    return HomeShell(
      db: widget.db,
      profile: active,
      onSwitchProfile: () {
        _clearWidget();
        setState(() => _active = null);
      },
      fetcher: widget.fetcher,
      createPlayer: widget.createPlayer,
      services: widget.services,
      jobs: _jobs,
      feedCheck: _feedCheck,
      writesReady: _writesReady.future,
      afterFeedsChecked: _feedCheckRunner?.requestAutoDownloadIfPending,
      shares: _shares,
      homeWidget: widget.homeWidget,
    );
  }
}

class _CreateProfileScreen extends StatefulWidget {
  final ValueChanged<String> onCreate;
  final VoidCallback? onBack;
  const _CreateProfileScreen({required this.onCreate, this.onBack});

  @override
  State<_CreateProfileScreen> createState() => _CreateProfileScreenState();
}

class _CreateProfileScreenState extends State<_CreateProfileScreen> {
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    // The button's state follows the field (it is live only with a name).
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    widget.onCreate(name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.onBack == null
          ? null
          : AppBar(leading: BackButton(onPressed: widget.onBack)),
      body: CappedBody(child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Add a reader',
                      style: Theme.of(context).textTheme.headlineMedium,
                      textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text('Each reader keeps their own library and place.',
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  TextField(
                    key: const Key('profile-name'),
                    controller: _name,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    // The button below is live only with a name, and this
                    // line says why before anyone taps (audit doet-06,
                    // humane-10: it used to return silently on an empty
                    // name).
                    decoration: const InputDecoration(
                        labelText: 'Name',
                        helperText: 'Type a name to add this reader.'),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _name.text.trim().isEmpty ? null : _submit,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Add reader'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      )),
    );
  }
}

class _ProfilePickerScreen extends StatelessWidget {
  final List<Profile> profiles;
  final ValueChanged<Profile> onPick;
  final VoidCallback onAdd;

  /// The parent-dashboard door (P5). Picking a profile never passes a gate
  /// — reading is never locked (ADR-0003); this door and [onAdd] are the
  /// only PIN-gated paths out of this screen.
  final VoidCallback onParents;
  const _ProfilePickerScreen(
      {required this.profiles,
      required this.onPick,
      required this.onAdd,
      required this.onParents});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CappedBody(child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text("Who’s reading?",
                      style: Theme.of(context).textTheme.headlineMedium,
                      textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  for (final p in profiles) ...[
                    FilledButton.tonal(
                      onPressed: () => onPick(p),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Text(p.name,
                            overflow: TextOverflow.ellipsis, maxLines: 1),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('Add a reader'),
                  ),
                  TextButton.icon(
                    onPressed: onParents,
                    icon: const Icon(Icons.supervisor_account_outlined),
                    label: const Text('Parent dashboard'),
                  ),
                ],
              ),
            ),
          ),
        ),
      )),
    );
  }
}

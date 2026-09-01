import 'package:comms_core/comms_core.dart';
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../intake/paste_intake.dart' show epochDayUtcNow;
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
/// Library, with no name to type; a later launch opens the reader this
/// device last had open (or the only one). The picker ("Who's reading?")
/// appears only when there is a real choice: several readers and no
/// remembered one, or the reader asked to switch. One stateful widget, no
/// routes: switching reader is a setState, not a navigation.
class HomeFlow extends StatefulWidget {
  final AppDatabase db;
  final HttpFetcher fetcher;
  final EpisodePlayer Function() createPlayer;
  final DeviceServices services;
  const HomeFlow(
      {super.key,
      required this.db,
      required this.fetcher,
      required this.createPlayer,
      required this.services});

  @override
  State<HomeFlow> createState() => _HomeFlowState();
}

class _HomeFlowState extends State<HomeFlow> {
  List<Profile>? _profiles;
  Profile? _active;
  bool _adding = false;
  bool _pinSet = false;
  late final ParentPinService _pin = ParentPinService(widget.db);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Boot-time ephemera sweep (ADR-0003 law 2): decayed feed items leave
    // the river before anything renders, into a recoverable soft state the
    // River announces (Restore / Let go) — never a silent delete. Promoted
    // works are untouchable by design.
    await widget.db.spineDao.sweepEphemera(todayEpochDay: epochDayUtcNow());
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
    }
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
      onSwitchProfile: () => setState(() => _active = null),
      fetcher: widget.fetcher,
      createPlayer: widget.createPlayer,
      services: widget.services,
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

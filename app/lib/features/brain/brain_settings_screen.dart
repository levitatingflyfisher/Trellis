/// The "Thinking" screen: pick the Brain tier explicitly, keep the BYOK
/// key in secure custody, and be plain that study works fully without any
/// of it.
///
/// Laws visible on this surface:
///  * the tier changes only through the user's tap ([BrainStore.pinTier] —
///    brain_wiring's no-silent-fallback law);
///  * the key is shown masked, stored only in the secret store, and
///    deleting it deletes it;
///  * cloud tiers say where bytes would go and that each use asks first
///    (ADR-0003 law 6 — the one egress chokepoint);
///  * the local-model tier is offered only where local ML exists (the
///    web-tier honesty gate, DeviceServices.localMlAvailable).
library;

import 'package:brain_wiring/brain_wiring.dart';
import 'package:flutter/material.dart';

import 'brain_store.dart';

class BrainSettingsScreen extends StatefulWidget {
  const BrainSettingsScreen(
      {super.key, required this.store, required this.localMlAvailable});

  final BrainStore store;

  /// Whether this device can run local ML at all — false on the web tier,
  /// where the local-model rung must not be offered-then-broken.
  final bool localMlAvailable;

  @override
  State<BrainSettingsScreen> createState() => _BrainSettingsScreenState();
}

class _BrainSettingsScreenState extends State<BrainSettingsScreen> {
  final _keyField = TextEditingController();
  TierSelection? _selection;
  String? _maskedKey;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyField.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final selection = await widget.store.selection();
    final masked = await widget.store.maskedAnthropicKey();
    if (!mounted) return;
    setState(() {
      _selection = selection;
      _maskedKey = masked;
    });
  }

  Future<void> _pin(BrainTier tier) async {
    await widget.store.pinTier(tier);
    await _load();
  }

  Future<void> _saveKey() async {
    final raw = _keyField.text.trim();
    if (raw.isEmpty || _saving) return;
    setState(() => _saving = true);
    await widget.store.saveAnthropicKey(raw);
    _keyField.clear();
    if (!mounted) return;
    setState(() => _saving = false);
    await _load();
  }

  Future<void> _deleteKey() async {
    await widget.store.deleteAnthropicKey();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selection = _selection;
    return Scaffold(
      appBar: AppBar(title: const Text('Thinking')),
      body: selection == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Positive framing: what a brain adds, never what is
                // missed without one. Study is complete either way.
                Text(
                    'Study works fully without a brain. One only adds '
                    'distillation and critiques — and only when you ask.',
                    key: const Key('no-brain-note'),
                    style: theme.textTheme.bodyMedium),
                const SizedBox(height: 16),
                Text('Which brain', style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                RadioGroup<BrainTier>(
                  groupValue: selection.pinnedByUser ? selection.tier : null,
                  onChanged: (tier) {
                    if (tier != null) _pin(tier);
                  },
                  child: Column(
                    children: [
                      _tierTile(
                        BrainTier.none,
                        title: 'None',
                        subtitle: 'No brain. Everything else works.',
                      ),
                      _tierTile(
                        BrainTier.byokAnthropic,
                        title: 'Your Anthropic key',
                        subtitle: 'Cloud (api.anthropic.com). Nothing '
                            'leaves this device without asking you first.',
                      ),
                      _tierTile(
                        BrainTier.stove,
                        title: 'Household stove',
                        subtitle: 'Your family desktop over the LAN — on '
                            'the roadmap.',
                      ),
                      if (widget.localMlAvailable)
                        _tierTile(
                          BrainTier.localStub,
                          title: 'Local model',
                          subtitle: 'A model on this device — on the '
                              'roadmap.',
                        ),
                    ],
                  ),
                ),
                if (selection.pinnedByUser &&
                    selection.tier == BrainTier.byokAnthropic) ...[
                  const SizedBox(height: 24),
                  _keySection(theme),
                ],
              ],
            ),
    );
  }

  Widget _tierTile(BrainTier tier,
      {required String title, required String subtitle}) {
    return RadioListTile<BrainTier>(
      key: Key('tier-${tier.name}'),
      value: tier,
      title: Text(title),
      subtitle: Text(subtitle),
    );
  }

  Widget _keySection(ThemeData theme) {
    final masked = _maskedKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('API key', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        if (masked == null) ...[
          Text('Your Anthropic brain needs its API key.',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: Text(masked,
                    key: const Key('masked-key'),
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(fontFamily: 'monospace'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              TextButton(
                key: const Key('delete-key'),
                onPressed: _deleteKey,
                child: const Text('Forget this key'),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          key: const Key('anthropic-key-field'),
          controller: _keyField,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: masked == null ? 'Paste your key' : 'Replace the key',
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('save-key'),
          onPressed: _saving ? null : _saveKey,
          child: const Text('Save key'),
        ),
        const SizedBox(height: 8),
        Text(
            'Kept in this device\'s secure storage — never the database, '
            'never a backup. Each use asks before anything is sent.',
            style: theme.textTheme.bodySmall),
      ],
    );
  }
}

import 'package:test/test.dart';
import 'package:loom_core/loom_core.dart';

/// Promotion is the user's hand: an unkept item becomes a kept work. Nothing
/// decays either way (ADR-0019), so the bit only says where an item lives.
void main() {
  Work eph(String id, int seenDay) => Work(
      id: id,
      kind: WorkKind.episode,
      persistence: Persistence.ephemeron,
      firstSeenEpochDay: seenDay);

  test('promotion makes a kept work', () {
    expect(eph('kept', 0).promote().persistence, Persistence.work);
  });

  test('promotion is idempotent and does not touch identity', () {
    final w = eph('id1', 5).promote().promote();
    expect(w.id, 'id1');
    expect(w.persistence, Persistence.work);
  });
}

import 'package:brain_wiring/brain_wiring.dart';
import 'package:test/test.dart';

void main() {
  group('Provenance', () {
    const provenance = Provenance(
      brainTier: BrainTier.byokAnthropic,
      modelId: 'claude-sonnet-5',
    );

    test('serializes tier and model id', () {
      expect(provenance.toJson(), {
        'brainTier': 'byokAnthropic',
        'modelId': 'claude-sonnet-5',
      });
    });

    test('round-trips through JSON', () {
      expect(Provenance.fromJson(provenance.toJson()), provenance);
    });

    test('fromJson rejects an unknown tier with a path-qualified error', () {
      expect(
        () => Provenance.fromJson(
            {'brainTier': 'cloudMagic', 'modelId': 'x'}),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('brainTier'),
        )),
      );
    });

    test('fromJson rejects a missing modelId', () {
      expect(
        () => Provenance.fromJson({'brainTier': 'stove'}),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('modelId'),
        )),
      );
    });

    test('value equality', () {
      expect(
        provenance,
        const Provenance(
          brainTier: BrainTier.byokAnthropic,
          modelId: 'claude-sonnet-5',
        ),
      );
      expect(
        provenance,
        isNot(const Provenance(
          brainTier: BrainTier.stove,
          modelId: 'claude-sonnet-5',
        )),
      );
    });
  });

  group('UserGesture', () {
    test('exists as a plain proof token', () {
      // The law is type-level: every inference entry point requires a
      // UserGesture with no default, so a timer cannot supply one without
      // the violation being visible at the call site.
      expect(const UserGesture(), isA<UserGesture>());
    });
  });
}

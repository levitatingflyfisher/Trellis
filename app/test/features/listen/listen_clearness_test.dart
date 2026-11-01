import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/listen/listen_clearness.dart';

/// The founding request's follow-up: "Bonus points if I can choose how
/// much they enunciate … to as crisp and clean as possible to make it
/// easy for a beginner to parse". What a saved voice can honestly vary is
/// its pace, the pause after each sentence, and (Pocket TTS only) how
/// much work goes into each sound. Each step asks for more of
/// all three than the one before; Natural is exactly what was made
/// before the setting existed.
void main() {
  test('four steps, in order, with plain names; Natural first', () {
    expect(ListenClearness.values.map((c) => c.label), [
      'Natural',
      'Clear',
      'Slow and clear',
      'Very slow',
    ]);
    for (final c in ListenClearness.values) {
      expect(c.help, isNotEmpty, reason: c.name);
      expect(c.help, isNot(contains(' — ')), reason: c.name);
    }
  });

  test('Natural is the voice as it spoke before: its own pace, no extra '
      'work, the same pauses', () {
    const n = ListenClearness.natural;
    expect(n.pace.rate, 1.0);
    expect(n.pace.careful, isFalse);
    expect(n.sentenceGapMs, 250);
    expect(n.segmentGapMs, 450);
  });

  test('each step is slower, with longer pauses, than the one before',
      () {
    const all = ListenClearness.values;
    for (var i = 1; i < all.length; i++) {
      expect(all[i].pace.rate, lessThan(all[i - 1].pace.rate),
          reason: all[i].name);
      expect(all[i].sentenceGapMs, greaterThan(all[i - 1].sentenceGapMs),
          reason: all[i].name);
      expect(all[i].segmentGapMs, greaterThan(all[i].sentenceGapMs),
          reason: all[i].name);
      expect(all[i].pace.careful, isTrue, reason: all[i].name);
    }
    // Slow enough to help, not so slow Kokoro's or the phone's stretched
    // speech falls apart.
    expect(all.last.pace.rate, greaterThanOrEqualTo(0.5));
  });

  test('the help promises a slower episode, never slower words: Pocket '
      'TTS has no speed input and slows by pausing after each sentence',
      () {
    for (final c in ListenClearness.values.skip(1)) {
      expect(c.help, isNot(contains('sounds whole')), reason: c.name);
    }
    expect(ListenClearness.clear.help, contains('overall'));
    expect(ListenClearness.slow.help, contains('overall'));
    expect(ListenClearness.verySlow.help, contains('longest pauses'));
  });

  test('the saved episode names how it was spoken', () {
    expect(ListenClearness.natural.spokenPhrase, 'spoken at a natural pace');
    expect(ListenClearness.clear.spokenPhrase, 'spoken clearly');
    expect(ListenClearness.slow.spokenPhrase, 'spoken slowly and clearly');
    expect(ListenClearness.verySlow.spokenPhrase,
        'spoken very slowly and clearly');
  });

  test('stored by name; anything unknown, or nothing, reads as Natural',
      () {
    for (final c in ListenClearness.values) {
      expect(ListenClearness.parse(c.name), c);
    }
    expect(ListenClearness.parse(null), ListenClearness.natural);
    expect(ListenClearness.parse('mumbled'), ListenClearness.natural);
  });

  test('the device setting reads Natural until it is written', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(await readListenClearness(db), ListenClearness.natural);
    await writeListenClearness(db, ListenClearness.slow);
    expect(await readListenClearness(db), ListenClearness.slow);
    expect(await db.deviceSettingsDao.read(listenClearnessKey), 'slow');
  });
}

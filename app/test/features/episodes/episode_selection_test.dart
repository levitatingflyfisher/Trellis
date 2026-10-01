import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/episodes/episode_selection.dart';

EpisodeEntry _entry(int id) => (
      work: Work(
          id: id,
          profileId: 1,
          kind: 'episode',
          title: 't$id',
          persistence: 'ephemeron',
          firstSeenEpochDay: 1,
          showTranslationLayer: false,
          pinned: false),
      episode: Episode(
          workId: id, feedId: 1, guid: 'g$id', publishedAtMs: id),
    );

void main() {
  test('a reload that drops rows drops them from the selection, and the bar '
      'hears of it after the build', () async {
    final s = EpisodeSelection()..universe = [_entry(1), _entry(2), _entry(3)];
    s
      ..enter()
      ..selectAll();
    var heard = 0;
    s.addListener(() => heard++);
    s.universe = [_entry(1)];
    expect(s.count, 1);
    expect(heard, 0, reason: 'never notifies mid-build');
    await Future<void>.delayed(Duration.zero);
    expect(heard, 1);
  });

  test('Remove download words what happened', () {
    String m(int r, int c, int k) =>
        EpisodeBulk.removedMessage((removed: r, cancelled: c, kept: k));
    expect(m(0, 0, 0), 'None of these were downloaded.');
    expect(m(2, 0, 0), 'Removed 2 downloads. You can download again any time.');
    expect(m(0, 2, 0),
        'Stopped 2 downloads in progress. You can download again any time.');
    expect(m(1, 1, 2),
        'Removed 1 download. Stopped 1 download in progress. You can download '
        'again any time. 2 episodes playing, transcribing or processing keep '
        'their downloads.');
  });
}

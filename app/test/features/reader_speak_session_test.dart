import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/media_item_mapping.dart';
import 'package:trellis/features/player/playback_session.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_tts.dart';

class FakeSession implements PlaybackSession {
  SessionClient? client;
  LockScreenTag? tag;
  final states = <SessionState>[];
  int detaches = 0;

  @override
  void attach(SessionClient c, LockScreenTag t) {
    client = c;
    tag = t;
  }

  @override
  void report(SessionClient c, SessionState s) {
    if (identical(c, client)) states.add(s);
  }

  @override
  void detach(SessionClient c) {
    if (!identical(c, client)) return;
    client = null;
    detaches++;
  }
}

/// Read aloud as a media session (1.6.0, user: "I am having an essay read
/// aloud to me but it stops when the screen goes dark, I would like it
/// treated just like media/podcast playing"). The session is what brings
/// the playback service, the notification and the lock-screen buttons;
/// these tests pin what the reader tells it and does for it.
void main() {
  late AppDatabase db;
  late FakeTtsSpeaker tts;
  late FakeSession session;
  late int profileId;
  late int workId;
  const beat = Duration(milliseconds: 100);

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tts = FakeTtsSpeaker();
    session = FakeSession();
    profileId = await db.profilesDao.create('Ada');
    workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'An essay',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'First part.'),
      (idx: 1, kind: 'prose', text: 'Second part.'),
      (idx: 2, kind: 'prose', text: 'Third part.'),
    ]);
  });
  tearDown(() => db.close());

  Future<void> pumpReader(WidgetTester tester,
      {PlaybackSession? withSession}) async {
    final work = (await db.spineDao.worksOf(profileId)).single;
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: profileId,
            work: work,
            tts: tts,
            session: withSession ?? session)));
    await tester.pumpAndSettle();
  }

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('speak-toggle')));
    await tester.pump();
  }

  Future<void> next(WidgetTester tester) async {
    await tester.pump(beat);
    await tester.pump();
  }

  void leaveTheScreen(WidgetTester tester) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
  }

  testWidgets('starting Read aloud takes the session: the work’s title, '
      '"Read aloud" under it, and playing', (tester) async {
    await pumpReader(tester);

    await start(tester);

    expect(session.client, isNotNull);
    expect(session.tag!.title, 'An essay');
    expect(session.tag!.album, 'Read aloud');
    expect(session.states.last.playing, isTrue);
    expect(session.states.last.phase, SessionPhase.ready);
  });

  testWidgets('in the session, read aloud goes on when the app leaves the '
      'screen', (tester) async {
    await pumpReader(tester);
    await start(tester);
    expect(tts.utterances, hasLength(1));

    leaveTheScreen(tester);
    await tester.pump();
    await next(tester);
    await next(tester);

    expect(tts.utterances.map((u) => u.text),
        ['First part.', 'Second part.', 'Third part.']);
    expect(tts.stops, 0);
  });

  testWidgets('with no session it still stops when the app leaves the '
      'screen: nothing would keep it alive there', (tester) async {
    await pumpReader(tester, withSession: const NoPlaybackSession());
    await start(tester);

    leaveTheScreen(tester);
    await tester.pump();
    await next(tester);

    expect(tts.utterances, hasLength(1));
    expect(tts.stops, 1);
  });

  testWidgets('the lock screen’s Pause stops the voice at its sentence and '
      'Play picks it up from there', (tester) async {
    await pumpReader(tester);
    await start(tester);
    await next(tester);
    expect(tts.utterances.last.text, 'Second part.');

    await session.client!.pause();
    await tester.pump();
    expect(session.states.last.playing, isFalse);
    expect(session.client, isNotNull, reason: 'paused, not gone');
    await next(tester);
    expect(tts.utterances, hasLength(2), reason: 'nothing more is said');

    await session.client!.play();
    await tester.pump();
    expect(tts.utterances.last.text, 'Second part.');
    expect(tts.utterances, hasLength(3));
    expect(session.states.last.playing, isTrue);
  });

  testWidgets('the notification’s Stop stops the voice', (tester) async {
    await pumpReader(tester);
    await start(tester);

    await session.client!.stop();
    await tester.pump();
    await next(tester);

    expect(tts.utterances, hasLength(1));
    expect(session.states.last.playing, isFalse);
  });

  testWidgets('the reader’s own Stop leaves the session paused, so the '
      'lock screen can pick it up', (tester) async {
    await pumpReader(tester);
    await start(tester);

    await tester.tap(find.byKey(const Key('speak-toggle')));
    await tester.pump();

    expect(session.states.last.playing, isFalse);
    expect(session.detaches, 0);
  });

  testWidgets('at the end of the text the session is let go', (tester) async {
    await pumpReader(tester);
    await start(tester);
    await next(tester);
    await next(tester);
    expect(session.detaches, 0);

    await next(tester);

    expect(session.detaches, 1);
    expect(session.client, isNull);
  });

  testWidgets('leaving the reader lets the session go', (tester) async {
    await pumpReader(tester);
    await start(tester);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(session.detaches, 1);
  });

  testWidgets('a reader that never read aloud never touches the session',
      (tester) async {
    await pumpReader(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    expect(session.tag, isNull);
    expect(session.detaches, 0);
  });
}

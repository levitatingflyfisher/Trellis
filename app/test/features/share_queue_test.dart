import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/share_intake.dart';
import 'package:trellis/features/intake/share_queue.dart';
import 'package:trellis/features/intake/share_source.dart';

class _Shares implements ShareSource {
  final waiting = <SharedPayload>[];
  VoidCallback? arrival;
  Set<String>? swept;

  @override
  Future<List<SharedPayload>> takePending() async {
    final all = [...waiting];
    waiting.clear();
    return all;
  }

  @override
  set onArrival(VoidCallback? callback) => arrival = callback;

  @override
  Future<void> sweep(Set<String> keep) async => swept = keep;
}

/// Shares wait on disk, each bound to the reader who was open when it
/// came, until that reader's shell has saved it.
void main() {
  late AppDatabase db;
  late _Shares source;
  int? active;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    source = _Shares();
    active = null;
  });
  tearDown(() => db.close());

  late List<String> discarded;
  late int ada;

  setUp(() async {
    discarded = [];
    ada = await db.profilesDao.create('Ada');
  });

  ShareQueue queue() => ShareQueue(
      db: db,
      source: source,
      activeProfileId: () => active,
      discard: discarded.add);

  test('a share is bound to the reader open when it arrives', () async {
    final q = queue();
    await q.start();
    final bo = await db.profilesDao.create('Bo');
    active = ada;
    source.waiting.add(const SharedPayload(text: 'for one'));
    source.arrival!();
    await q.idle;
    expect(await q.nextFor(bo), isNull);
    final next = (await q.nextFor(ada))!;
    expect(next.payload.text, 'for one');
    expect(next.profileId, ada);
  });

  test('with no reader open, the next reader to open takes it', () async {
    source.waiting.add(const SharedPayload(text: 'anyone'));
    final q = queue();
    await q.start();
    expect((await q.nextFor(ada))!.payload.text, 'anyone');
  });

  test('a share stays waiting until it is marked done, across a restart',
      () async {
    active = ada;
    source.waiting.add(const SharedPayload(text: 'one', files: [
      SharedFile(path: '/c/a.md', name: 'a.md', mimeType: 'text/markdown'),
    ]));
    source.waiting.add(const SharedPayload(text: 'two'));
    final first = queue();
    await first.start();
    final one = (await first.nextFor(ada))!;
    expect(one.payload.text, 'one');
    first.dispose();

    // The process died before the shell got to it: nothing is lost.
    final again = queue();
    await again.start();
    expect(source.swept, {'/c/a.md'},
        reason: 'the sweep keeps every waiting share’s copy');
    final still = (await again.nextFor(ada))!;
    expect(still.payload.text, 'one');
    expect(still.payload.files.single.name, 'a.md');
    await again.done(still.id);
    expect((await again.nextFor(ada))!.payload.text, 'two');
  });

  test('listeners hear a new share', () async {
    final q = queue();
    await q.start();
    var heard = 0;
    q.addListener(() => heard++);
    source.waiting.add(const SharedPayload(text: 'x'));
    source.arrival!();
    await q.idle;
    expect(heard, 1);
  });

  test('an attempt is written before a share is saved, so a share that '
      'kills the app is known on the next start', () async {
    active = ada;
    source.waiting.add(const SharedPayload(text: 'poison'));
    final first = queue();
    await first.start();
    final share = (await first.nextFor(ada))!;
    expect(share.attempts, 0);
    await first.attempt(share.id);
    first.dispose();

    final again = queue();
    await again.start();
    expect((await again.nextFor(ada))!.attempts, 1);
  });

  test('dropping a share removes it and its file copies', () async {
    source.waiting.add(const SharedPayload(files: [
      SharedFile(path: '/c/big.epub', name: 'big.epub'),
    ]));
    final q = queue();
    await q.start();
    final share = (await q.nextFor(ada))!;
    await q.drop(share);
    expect(await q.nextFor(ada), isNull);
    expect(discarded, ['/c/big.epub']);
  });

  test('a share whose reader was deleted is purged with its files',
      () async {
    final gone = await db.profilesDao.create('Gone');
    active = gone;
    source.waiting.add(const SharedPayload(text: 'orphan', files: [
      SharedFile(path: '/c/o.md', name: 'o.md'),
    ]));
    final q = queue();
    await q.start();
    await db.householdDao.deleteProfileCascade(gone);
    await q.purgeMissingProfiles();
    expect(discarded, ['/c/o.md']);
    expect(await q.nextFor(ada), isNull);
    expect(await db.deviceSettingsDao.read('share_pending'), isNull);
  });

  test('a stored list of the wrong shape keeps what it can and never '
      'blocks the queue', () async {
    await db.deviceSettingsDao.write(
        'share_pending',
        '[{"id": 1, "profileId": null, "payload": {"text": "kept"}}, '
            '{"id": "x"}, 7]');
    final q = queue();
    await q.start();
    expect((await q.nextFor(ada))!.payload.text, 'kept');

    await db.deviceSettingsDao.write('share_pending', '{"not": "a list"}');
    source.waiting.add(const SharedPayload(text: 'still arrives'));
    source.arrival!();
    await q.idle;
    expect((await q.nextFor(ada))!.payload.text, 'still arrives');
    expect(await db.deviceSettingsDao.read('share_pending_unreadable'),
        '{"not": "a list"}');
  });
}

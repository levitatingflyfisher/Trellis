import 'package:comms_core/comms_core.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/share_intake.dart';

import '../support/docx_fixture.dart';
import '../support/scripted_fetcher.dart';

/// A shared link to a Word document, or to a web book's contents page
/// (1.6.19, owner, 17 Nov 2026). The link row is saved at once, as any
/// shared link is; reading it then makes it the document, or offers the
/// book.
const _contentsUrl = 'http://books.test/legal/Contents.htm';
const _docUrl = 'http://books.test/legal/Iceland.docx';

const _contents = '<html><head><title>Legal Systems</title></head><body>'
    '<p><a href="Introduction.docx">Introduction</a></p>'
    '<p><a href="Iceland.docx">Saga-Period Iceland</a></p>'
    '<p><a href="Somali.docx">Somali Law</a></p></body></html>';

void main() {
  late AppDatabase db;
  late int profileId;
  late ScriptedFetcher fetcher;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    fetcher = ScriptedFetcher((u, _) => switch (u.toString()) {
          _contentsUrl => textResponse(_contents,
              headers: {'content-type': 'text/html; charset=utf-8'}),
          _docUrl => FetchResponse(
              statusCode: 200,
              // Many servers name no type for a .docx; its ending says it.
              headers: const {'content-type': 'application/octet-stream'},
              body: Stream.value(tinyDocx())),
          _ => throw const CommsException('offline'),
        });
  });
  tearDown(() => db.close());

  ShareIntake intake() => ShareIntake(
      db: db, profileId: profileId, fetcher: fetcher, discard: (_) {});

  test('a shared link to a Word document becomes that document', () async {
    final saved =
        await intake().take(const SharedPayload(text: _docUrl)) as ShareSaved;
    final out = await intake().fetchPageFor(saved);
    expect(out, isA<ShareUpgraded>());
    final work = (await db.spineDao.workById(saved.workId))!;
    expect(work.title, 'Iceland');
    expect(work.kind, 'book');
    final segs = await db.spineDao.segmentsOf(saved.workId);
    expect(segs.first.body, 'Saga-Period Iceland');
    expect(await db.spineDao.linksOf(saved.workId), hasLength(1));
  });

  test('a shared contents page offers its book; "Save this page" keeps '
      'the page instead', () async {
    final saved = await intake().take(const SharedPayload(text: _contentsUrl))
        as ShareSaved;
    final offer = await intake().fetchPageFor(saved) as ShareOffersBook;
    expect(offer.book.title, 'Legal Systems');
    expect(offer.book.chapters, hasLength(3));
    expect(offer.linkWorkId, saved.workId);

    final calls = fetcher.calls.length;
    final kept = await intake().saveContentsPage(offer);
    expect(fetcher.calls.length, calls, reason: 'the page is in hand');
    // Too short to be an article: the link row stays, saying so.
    expect(kept, isA<ShareRefused>());
    expect((kept as ShareRefused).workId, saved.workId);
  });

  test('once the book is in, the bare link to its contents page goes',
      () async {
    final saved = await intake().take(const SharedPayload(text: _contentsUrl))
        as ShareSaved;
    final offer = await intake().fetchPageFor(saved) as ShareOffersBook;
    await intake().dropContentsLink(offer);
    expect(await db.spineDao.workById(saved.workId), isNull);
  });
}

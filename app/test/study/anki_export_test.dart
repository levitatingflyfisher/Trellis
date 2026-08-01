import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/features/study/anki_export.dart';

/// The `.apkg` exporter, ported from the donor Trellis (genanki-faithful):
/// a zip of collection.anki2 (sqlite) + an empty media manifest, one note
/// per retrieval item, a subdeck per node, one card per distinct cloze
/// ordinal, stable guids, `$math$` rewritten to MathJax delimiters.
/// Scheduling is deliberately NOT exported — Anki/FSRS owns it there.
void main() {
  study.Course course() => study.parseCourseString(json.encode({
        'schemaVersion': '1.0',
        'id': 'anki-c',
        'title': 'My Course',
        'nodes': [
          {
            'id': 'n1',
            'title': 'Node One',
            'intake': 'Read.',
            'items': [
              {
                'id': 'z1',
                'type': 'cloze',
                'rung': 1,
                'text': 'The **sky** is {{c1::blue}} & {{c2::high}}.',
                'answers': {'c1': 'blue', 'c2': 'high'},
              },
              {
                'id': 'q1',
                'type': 'qa',
                'rung': 3,
                'prompt': r'What is $x^2$?',
                'answer': 'x squared\nreally',
                'acceptable': ['square'],
                'rubric': 'Mention squares.',
                'hints': ['a power'],
                'sources': ['Book 1'],
              },
            ],
          },
          {
            'id': 'n2',
            'title': 'Node Two',
            'prereqs': ['n1'],
            'intake': 'Then this.',
            'items': [
              {
                'id': 'd1',
                'type': 'discrimination',
                'rung': 2,
                'prompt': 'Pick the wet one',
                'choices': ['stone', 'water'],
                'correctIndex': 1,
                'explanation': 'Water is wet.',
              },
              {
                'id': 'p1',
                'type': 'procedure',
                'rung': 4,
                'prompt': 'Make tea',
                'steps': ['Boil', 'Steep'],
                'rubric': 'Order matters.',
              },
            ],
          },
        ],
      }));

  Future<raw.Database> openCollection(List<int> apkgBytes) async {
    final files = ZipDecoder().decodeBytes(apkgBytes);
    final col = files.findFile('collection.anki2');
    expect(col, isNotNull, reason: 'an .apkg IS a zip holding this file');
    final media = files.findFile('media');
    expect(utf8.decode(media!.content as List<int>), '{}',
        reason: 'no media travels, but the manifest must exist');
    final dir = await Directory.systemTemp.createTemp('anki_test');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/collection.anki2';
    File(path).writeAsBytesSync(col!.content as List<int>);
    final db = raw.sqlite3.open(path);
    addTearDown(db.dispose);
    return db;
  }

  test('the zip holds a genanki-faithful collection', () async {
    expect(ankiExportSupported, isTrue);
    final db = await openCollection(await buildApkgBytes(course()));

    final colRow = db.select('SELECT models, decks, conf FROM col').single;
    final models =
        (jsonDecode(colRow['models'] as String) as Map).cast<String, Object?>();
    final names = [
      for (final m in models.values) (m as Map)['name'],
    ];
    expect(names.toSet(), {'Trellis Basic', 'Trellis Cloze'});
    final clozeModel =
        models.values.cast<Map>().singleWhere((m) => m['type'] == 1);
    expect(clozeModel['name'], 'Trellis Cloze');

    final decks =
        (jsonDecode(colRow['decks'] as String) as Map).cast<String, Object?>();
    final deckNames = [for (final d in decks.values) (d as Map)['name']];
    expect(
        deckNames.toSet(),
        {'Default', 'My Course', 'My Course::Node One', 'My Course::Node Two'},
        reason: 'a subdeck per node keeps the ladder visible in Anki');
  });

  test('every item becomes a note; cloze ordinals become cards', () async {
    final db = await openCollection(await buildApkgBytes(course()));

    final notes = db.select('SELECT id, guid, mid, tags, flds FROM notes');
    expect(notes.length, 4);

    String fieldOf(String fragment) {
      for (final n in notes) {
        final flds = (n['flds'] as String).split('');
        if (flds.first.contains(fragment)) return n['flds'] as String;
      }
      fail('no note carries "$fragment"');
    }

    // Cloze text: markers intact, markdown lifted, & escaped.
    final clozeFlds = fieldOf('{{c1::blue}}');
    expect(clozeFlds.split('').first,
        'The <b>sky</b> is {{c1::blue}} &amp; {{c2::high}}.');

    // $-math becomes MathJax delimiters Anki understands.
    final qaFlds = fieldOf('What is');
    expect(qaFlds.split('').first, r'What is \(x^2\)?');
    final qaBack = qaFlds.split('')[1];
    expect(qaBack, contains('x squared<br>really'));
    expect(qaBack, contains('<b>Hints</b><br>a power'));
    expect(qaBack, contains('<b>Self-grade against</b><br>Mention squares.'));
    expect(qaBack, contains('<b>Sources</b><br>Book 1'));

    // Discrimination: lettered options up front, answer + why on the back.
    final dFlds = fieldOf('Pick the wet one');
    expect(dFlds.split('').first, contains('A. stone<br>B. water'));
    expect(dFlds.split('')[1], contains('water'));
    expect(dFlds.split('')[1], contains('Water is wet.'));

    // Procedure: numbered steps on the back.
    final pFlds = fieldOf('Make tea');
    expect(pFlds.split('')[1], contains('1. Boil<br>2. Steep'));

    // Tags: course, node, rung — the donor's convention, verbatim.
    final qaNote =
        notes.singleWhere((n) => (n['flds'] as String).contains('What is'));
    expect(qaNote['tags'], ' anki-c n1 rung-3 ');

    // Stable guid: re-exports update instead of duplicating in Anki.
    final clozeNote = notes
        .singleWhere((n) => (n['flds'] as String).contains('{{c1::blue}}'));
    final expectedGuid = base64Url
        .encode(sha1.convert(utf8.encode('anki-c:z1')).bytes.sublist(0, 8))
        .replaceAll('=', '');
    expect(clozeNote['guid'], expectedGuid);

    // One card per distinct cloze ordinal; one card for everything else.
    final cards = db.select(
        'SELECT c.ord FROM cards c WHERE c.nid = ? ORDER BY c.ord',
        [clozeNote['id']]);
    expect([for (final c in cards) c['ord']], [0, 1]);
    final qaCards =
        db.select('SELECT c.ord FROM cards c WHERE c.nid = ?', [qaNote['id']]);
    expect(qaCards.length, 1);

    // Scheduling stays home: every exported card is new.
    final scheduled = db.select(
        'SELECT COUNT(*) AS n FROM cards WHERE type != 0 OR reps != 0');
    expect(scheduled.single['n'], 0);
  });
}

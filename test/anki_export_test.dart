@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:trellis/features/curriculum/data/anki/anki_export_io.dart';
import 'package:trellis/features/curriculum/domain/models.dart';

void main() {
  final course = Course(id: 'demo', title: 'Demo Course', nodes: [
    KnowledgeNode(id: 'n0', title: 'Node Zero', intake: 'p', items: const [
      QaItem(id: 'n0-c1', rung: 1, prompt: r'What is $x$?', answer: 'It is **bold**.'),
      ClozeItem(id: 'n0-c2', rung: 2, text: 'The {{c1::cat}} sat on the {{c2::mat}}.', answers: {'c1': 'cat', 'c2': 'mat'}),
    ]),
    KnowledgeNode(id: 'n1', title: 'Node One', intake: 'p', items: const [
      DiscriminationItem(id: 'n1-c1', rung: 3, prompt: 'Pick', choices: ['A', 'B', 'C'], correctIndex: 1, explanation: 'B'),
      ProcedureItem(id: 'n1-c2', rung: 4, prompt: 'Steps', steps: ['one', 'two']),
    ]),
  ]);

  Database openCollection(Uint8List apkg) {
    final col = ZipDecoder().decodeBytes(apkg).files.firstWhere((f) => f.name == 'collection.anki2');
    final tmp = Directory.systemTemp.createTempSync();
    File('${tmp.path}/c.anki2').writeAsBytesSync(col.content as List<int>);
    return sqlite3.open('${tmp.path}/c.anki2');
  }

  test('zip has collection.anki2 + media', () {
    final names = ZipDecoder().decodeBytes(buildApkgBytes(course)).files.map((f) => f.name).toSet();
    expect(names, containsAll(<String>['collection.anki2', 'media']));
  });

  test('note and card counts match the course', () {
    final db = openCollection(buildApkgBytes(course));
    addTearDown(db.close);
    expect(db.select('select count(*) c from notes').first['c'], 4);
    expect(db.select('select count(*) c from cards').first['c'], 5); // qa1 + cloze2 + disc1 + proc1
  });

  test('ships exactly Basic + Cloze note types', () {
    final db = openCollection(buildApkgBytes(course));
    addTearDown(db.close);
    final models = jsonDecode(db.select('select models from col').first['models'] as String) as Map;
    expect(models.length, 2);
    expect(models.values.map((m) => m['type']).toList()..sort(), [0, 1]);
  });

  test('a subdeck exists per node, nested under the course', () {
    final db = openCollection(buildApkgBytes(course));
    addTearDown(db.close);
    final decks = jsonDecode(db.select('select decks from col').first['decks'] as String) as Map;
    final names = decks.values.map((d) => d['name'] as String).toList();
    expect(names.any((n) => n.startsWith('Demo Course::') && n.contains('Node Zero')), isTrue);
    expect(names.any((n) => n.contains('Node One')), isTrue);
  });

  test('cloze field preserved verbatim', () {
    final db = openCollection(buildApkgBytes(course));
    addTearDown(db.close);
    final rows = db.select('select flds from notes');
    expect(rows.where((r) => (r['flds'] as String).contains('{{c1::')).length, 1);
  });

  test('renderHtml rewrites math + bold and leaves no \$', () {
    final h = renderHtml(r'What is $x$? **bold**');
    expect(h, contains(r'\(x\)'));
    expect(h, contains('<b>bold</b>'));
    expect(h.contains(r'$'), isFalse);
  });

  test('clozeOrds are distinct and sorted', () {
    expect(clozeOrds('a {{c1::x}} {{c3::y}} {{c1::z}}'), [0, 2]);
  });
}

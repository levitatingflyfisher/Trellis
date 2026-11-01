import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/study/card_images.dart';

/// A picture picked for a card is checked, named by its bytes and kept,
/// so the course text can name it and a session can show it offline.
void main() {
  Uint8List png([int extra = 0]) => Uint8List.fromList(
      [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, extra]);
  final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2]);
  final gif = Uint8List.fromList('GIF89a..'.codeUnits);
  final webp = Uint8List.fromList('RIFF\x00\x00\x00\x00WEBPVP8 '.codeUnits);

  test('a picture is named by its bytes and its kind', () {
    final name = cardImageNameOf(png());
    expect(name, matches(RegExp(r'^[0-9a-f]{32}\.png$')));
    expect(cardImageNameOf(png()), name, reason: 'the same bytes, one name');
    expect(cardImageNameOf(png(1)), isNot(name));
    expect(cardImageNameOf(jpeg), endsWith('.jpg'));
    expect(cardImageNameOf(gif), endsWith('.gif'));
    expect(cardImageNameOf(webp), endsWith('.webp'));
  });

  test('every name it makes is one a course may hold', () {
    final raw = '{"schemaVersion":"1.0","id":"c","title":"c","nodes":[{"id":'
        '"n","title":"n","intake":"","items":[{"id":"i","type":"qa","rung":3,'
        '"prompt":"p","answer":"a","image":"${cardImageNameOf(jpeg)}"}]}]}';
    expect(study.parseCourseString(raw).nodes.single.items.single.image,
        cardImageNameOf(jpeg));
  });

  test('a file that is not a picture is refused in plain words', () {
    expect(
        () => cardImageNameOf(Uint8List.fromList('%PDF-1.7'.codeUnits)),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            'This file isn’t a picture Trellis can show. Pick a PNG, JPEG, '
                'GIF or WebP.')));
  });

  test('a picture over the size a card keeps is refused in plain words', () {
    final big = Uint8List(maxCardImageBytes + 1)..setAll(0, png());
    expect(
        () => cardImageNameOf(big),
        throwsA(isA<FormatException>().having((e) => e.message, 'message',
            'This picture is over 3 MB. Pick a smaller one.')));
  });

  test('keeping a picture stores it under its name', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final name = await keepCardImage(db, jpeg);
    expect(name, cardImageNameOf(jpeg));
    expect(await db.studyDao.cardImage(name), jpeg);
  });

  test('a course’s pictures are the names its items hold', () {
    final course = study.parseCourseString('{"schemaVersion":"1.0","id":"c",'
        '"title":"c","nodes":[{"id":"n","title":"n","intake":"","items":['
        '{"id":"a","type":"qa","rung":3,"prompt":"p","answer":"a",'
        '"image":"x.png"},{"id":"b","type":"qa","rung":3,"prompt":"p",'
        '"answer":"a"},{"id":"c","type":"cloze","rung":1,"text":"{{c1::x}}",'
        '"answers":{"c1":"x"},"image":"x.png"}]}]}');
    expect(imageNamesOf(course), {'x.png'});
  });
}

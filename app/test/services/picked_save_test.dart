import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/services/picked_save.dart';

/// The one save-finish dance behind every "save a file" affordance
/// (backup .ohbk, OPML export). file_picker's saveFile contract differs
/// per platform: mobile pickers write the bytes themselves, desktop ones
/// only return a path, and on the web the returned name means the
/// download already happened — any dart:io call after it throws.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('trellis-save'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a dismissed picker saves nothing', () async {
    expect(await finishPickedSave(null, [1, 2, 3]), isFalse);
  });

  test('on the web the download already carried the bytes', () async {
    // The "path" is just the chosen file name; touching disk would throw
    // under dart2js, so the finish must not.
    expect(
        await finishPickedSave('backup.ohbk', [1, 2, 3], isWeb: true), isTrue);
    expect(File('backup.ohbk').existsSync(), isFalse,
        reason: 'no stray file in the working directory either');
  });

  test('a desktop picker returns a path and writes nothing — we do',
      () async {
    final path = '${tmp.path}/out.opml';
    expect(await finishPickedSave(path, [10, 20], isWeb: false), isTrue);
    expect(File(path).readAsBytesSync(), [10, 20]);
  });

  test('a mobile picker already wrote — no double write', () async {
    final path = '${tmp.path}/done.ohbk';
    File(path).writeAsBytesSync([9, 9, 9]);
    expect(await finishPickedSave(path, [1], isWeb: false), isTrue);
    expect(File(path).readAsBytesSync(), [9, 9, 9],
        reason: 'the picker-written bytes are the truth');
  });
}

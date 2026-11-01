/// Pictures on cards (owner, 28 Oct: "I don't see anything stolen from
/// mochi or from anki on having cloze and images"). A picked picture is
/// checked, named by its bytes, and kept in the database (see
/// [CardImages] for why not in files); the course text names it on the
/// item, so a session shows it with no network and a backup carries it.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:file_picker/file_picker.dart';
import 'package:study_core/study_core.dart' as study;

import '../../db/database.dart';

/// The most a card's picture may weigh. Every picture rides in a backup
/// with its course, so a card keeps a picture, not a camera original.
const maxCardImageBytes = 3 * 1024 * 1024;

/// The name [bytes] are kept under: their hash and their kind, so one
/// picture is kept once. Throws [FormatException] with a plain sentence
/// for a file that is not a picture a card can show, or one too large.
String cardImageNameOf(Uint8List bytes) {
  final kind = _kindOf(bytes);
  if (kind == null) {
    throw const FormatException('This file isn’t a picture Trellis can '
        'show. Pick a PNG, JPEG, GIF or WebP.');
  }
  if (bytes.length > maxCardImageBytes) {
    throw const FormatException(
        'This picture is over 3 MB. Pick a smaller one.');
  }
  // 128 bits of the hash: a name, not a signature.
  return '${sha256.convert(bytes).toString().substring(0, 32)}.$kind';
}

/// The kind of picture [b] starts like, by its first bytes; null when it
/// is none a card shows. The bytes, not a file name, decide: a picker can
/// hand over a file with no name or the wrong one.
String? _kindOf(Uint8List b) {
  bool at(int offset, List<int> sig) {
    if (b.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (b[offset + i] != sig[i]) return false;
    }
    return true;
  }

  if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'png';
  }
  if (at(0, const [0xFF, 0xD8, 0xFF])) return 'jpg';
  if (at(0, 'GIF87a'.codeUnits) || at(0, 'GIF89a'.codeUnits)) return 'gif';
  if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) return 'webp';
  return null;
}

/// Checks [bytes], keeps them, and returns the name a card gives them.
/// Kept before the card is saved; a picture no saved card names goes the
/// next time a course is written.
Future<String> keepCardImage(AppDatabase db, Uint8List bytes) async {
  final name = cardImageNameOf(bytes);
  await db.studyDao.putCardImage(name, bytes);
  return name;
}

/// Every picture [course]'s items name.
Set<String> imageNamesOf(study.Course course) => {
      for (final n in course.nodes)
        for (final i in n.items) ?i.image,
    };

/// What the card editor needs to give a card a picture: a way to pick
/// one, and the store it is kept in.
class CardPictures {
  CardPictures(this.db, {Future<Uint8List?> Function()? pick})
      : pick = pick ?? pickCardImageBytes;

  final AppDatabase db;

  /// The picked file's bytes; null when nothing was picked.
  final Future<Uint8List?> Function() pick;

  Future<String> keep(Uint8List bytes) => keepCardImage(db, bytes);
  Future<Uint8List?> load(String name) => db.studyDao.cardImage(name);
}

/// The system's own picker, for pictures. On Android it re-encodes a
/// large photo at a lower quality first, so a camera original usually
/// fits under [maxCardImageBytes].
Future<Uint8List?> pickCardImageBytes() async {
  final result = await FilePicker.platform.pickFiles(
      type: FileType.image, withData: true, compressionQuality: 70);
  return result?.files.firstOrNull?.bytes;
}

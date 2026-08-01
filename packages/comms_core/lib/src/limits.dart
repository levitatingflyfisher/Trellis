/// Size caps (donor H16) and the mid-stream enforcement primitive.
///
/// The donor buffered a whole `arrayBuffer` and then checked its size for
/// text fetches; the streaming seam lets us enforce every cap mid-stream,
/// which the brief requires (native apps must not buffer 300 MB to discover
/// it is over a 25 MB cap).
library;

import 'dart:typed_data';

import 'exceptions.dart';

/// Article/page fetch ceiling (donor MAX_TEXT_FETCH_BYTES).
const int maxTextFetchBytes = 25 * 1024 * 1024;

/// Podcast episode ceiling (donor MAX_AUDIO_FETCH_BYTES).
const int maxAudioFetchBytes = 300 * 1024 * 1024;

/// Feed/OPML parse ceiling (donor MAX_XML_BYTES, M19 entity-expansion guard).
const int maxXmlBytes = 8 * 1024 * 1024;

/// Collects [body] into one buffer, throwing [SizeCapException] the moment
/// the running total exceeds [maxBytes] — the rest of the stream is never
/// pulled. [onBytes] fires after each chunk that survived the cap check
/// (donor ordering: cap check before progress).
Future<Uint8List> collectCapped(
  Stream<List<int>> body, {
  required int maxBytes,
  String? message,
  void Function(int got)? onBytes,
}) async {
  final builder = BytesBuilder(copy: false);
  var got = 0;
  await for (final chunk in body) {
    got += chunk.length;
    if (got > maxBytes) {
      throw SizeCapException(
          message ?? 'Response exceeds the $maxBytes-byte cap.');
    }
    builder.add(chunk);
    onBytes?.call(got);
  }
  return builder.takeBytes();
}

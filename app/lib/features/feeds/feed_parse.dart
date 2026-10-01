/// Feed bodies are parsed off the UI isolate (ADR-0017): a 25 MB back
/// catalogue is seconds of XML work on a mid-range phone, and on the UI
/// isolate those seconds are a frozen screen. Flutter's [compute] runs on
/// a fresh isolate natively and inline on the web, which has no isolates
/// to offer.
library;

import 'dart:convert';

import 'package:comms_core/comms_core.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

String feedBodyHash(String body) => sha256.convert(utf8.encode(body)).toString();

/// [feed] is null when the body's hash equals [unchangedHash]: the same
/// bytes as the last body that ingested, so there is nothing to parse.
typedef ParsedBody = ({String hash, ParsedFeed? feed});

/// Hashes and parses [body] together, off the UI isolate. Throws
/// [FeedParseException] as [parseRssFeed] does.
Future<ParsedBody> parseFeedBody(String body, String url,
    {String? unchangedHash}) async {
  final message = (body: body, url: url, unchangedHash: unchangedHash);
  if (!parsesOffThread(body)) return _parseFeedBody(message);
  return compute(_parseFeedBody, message);
}

/// A fresh isolate costs a few milliseconds and a copy of the body; a
/// small feed parses in less than that, so only a body big enough to
/// stall a frame pays for one.
bool parsesOffThread(String body) => body.length >= offThreadParseChars;

const offThreadParseChars = 256 * 1024;

/// [parseFeedBody] in the shape comms_core's archive walk takes.
Future<ParsedFeed> parseFeedOffThread(String body, String url) async =>
    (await parseFeedBody(body, url)).feed!;

// Top-level, so the isolate message carries only the strings and never
// a closure over a repository's database or HTTP client.
ParsedBody _parseFeedBody(
    ({String body, String url, String? unchangedHash}) m) {
  final hash = feedBodyHash(m.body);
  if (hash == m.unchangedHash) return (hash: hash, feed: null);
  return (hash: hash, feed: parseRssFeed(m.body, m.url));
}

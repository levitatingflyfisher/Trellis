/// Share from history and search: the platform sheet where there is one,
/// the clipboard where there isn't, or where the sheet fails.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'search_store.dart';

typedef ShareText = Future<void> Function(String text, {String? subject});

/// Hands one file at [path] to the platform share, with the words that go
/// with it.
typedef ShareFile = Future<void> Function(String path,
    {required String mimeType, required String subject, String? text});

Future<void> shareTextNative(String text, {String? subject}) async {
  await SharePlus.instance.share(ShareParams(text: text, subject: subject));
}

/// The web tier copies instead: the browser share sheet is missing on
/// most desktops, and a button that does nothing is worse than a copy.
ShareText? get defaultShareText => kIsWeb ? null : shareTextNative;

Future<void> shareFileNative(String path,
    {required String mimeType, required String subject, String? text}) async {
  await SharePlus.instance.share(ShareParams(
      files: [XFile(path, mimeType: mimeType)],
      text: text,
      subject: subject,
      title: subject));
}

/// The web tier has no files of its own to hand on.
ShareFile? get defaultShareFile => kIsWeb ? null : shareFileNative;

/// The title, where it came from, and the address someone else can open.
String shareTextFor(SearchItem item) {
  final show = item.showTitle;
  final title = show == null || show.isEmpty
      ? item.work.title
      : '${item.work.title}, from $show';
  final link = item.episode?.enclosureUrl ?? item.work.sourceUrl;
  return link == null ? title : '$title\n$link';
}

Future<void> shareItem(
        BuildContext context, SearchItem item, ShareText? share) =>
    shareWords(context, shareTextFor(item),
        subject: item.work.title, share: share);

/// Hands [text] to [share], or copies it where there is no share or it
/// fails, and says so.
Future<void> shareWords(BuildContext context, String text,
    {String? subject, required ShareText? share}) async {
  if (share != null) {
    try {
      await share(text, subject: subject);
      return;
    } catch (_) {
      // Falls through to the clipboard: the user asked to pass it on.
    }
  }
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: const Text('Copied to the clipboard'),
      persist: false,
    ));
}

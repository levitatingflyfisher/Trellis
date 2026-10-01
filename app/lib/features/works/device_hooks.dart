/// The two things the work page asks of the device itself: open a link
/// in the browser, and how fast this phone transcribes.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../transcribe/whisper_library.dart';

/// Hands [uri] to the browser (or the email app, for `mailto:`). Never an
/// in-app web view: the notes' links leave the app, and say so first.
Future<void> openExternalLink(Uri uri) async {
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// What transcribing costs on a phone running the dotprod whisper build:
/// about a twelfth of the episode's length, as measured on device. The
/// baseline build is several times slower and was never measured, so it
/// gets no number at all.
const dotprodTranscribeRate = 1 / 12;

double? _rate;
bool _probed = false;

/// [dotprodTranscribeRate] on an Android phone whose cores all report the
/// dotprod and fp16 features the fast build needs; null anywhere else,
/// where an estimate would be a guess.
double? deviceTranscribeRate() {
  if (_probed) return _rate;
  _probed = true;
  if (kIsWeb || !Platform.isAndroid) return null;
  try {
    final cpuinfo = File('/proc/cpuinfo').readAsStringSync();
    _rate = cpuHasDotprodFp16(cpuinfo) ? dotprodTranscribeRate : null;
  } catch (_) {
    _rate = null;
  }
  return _rate;
}

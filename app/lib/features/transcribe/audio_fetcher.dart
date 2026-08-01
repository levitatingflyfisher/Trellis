/// Fetching an episode's audio to a local file — the transcription
/// pipeline's first resumable step (proposal-2 §9), on the fleet's one
/// download engine. No pinned hash exists for arbitrary enclosures, so
/// promote is the atomic `.part` → final rename and nothing more; the
/// model-trust hash law belongs to the model store.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:domovoi/domovoi.dart' show TransferOutcome, resumableDownload;

abstract class AudioFetcher {
  /// Downloads [url] into [target] (resuming any `.part` beside it).
  /// Completes [TransferOutcome.completed] once [target] exists whole;
  /// a cancel keeps the partial and completes [TransferOutcome.cancelled].
  Future<TransferOutcome> fetch(String url, File target,
      {CancelToken? cancelToken, void Function(int received, int? total)? onProgress});
}

class DioAudioFetcher implements AudioFetcher {
  final Dio dio;
  DioAudioFetcher({Dio? dio}) : dio = dio ?? Dio();

  @override
  Future<TransferOutcome> fetch(String url, File target,
      {CancelToken? cancelToken,
      void Function(int received, int? total)? onProgress}) async {
    await target.parent.create(recursive: true);
    final part = File('${target.path}.part');
    return resumableDownload(
      dio: dio,
      url: url,
      partFile: part,
      cancelToken: cancelToken,
      onProgress: onProgress,
      promote: () => part.rename(target.path),
    );
  }
}

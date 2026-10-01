/// Fetching an episode's audio to a local file — the transcription
/// pipeline's first resumable step (proposal-2 §9), on the fleet's one
/// download engine. No pinned hash exists for arbitrary enclosures, so
/// promote is the atomic `.part` → final rename and nothing more; the
/// model-trust hash law belongs to the model store.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:domovoi/domovoi.dart' show TransferOutcome, resumableDownload;

import '../../net/guarded_http_client.dart';

abstract class AudioFetcher {
  /// Downloads [url] into [target] (resuming any `.part` beside it).
  /// Completes [TransferOutcome.completed] once [target] exists whole;
  /// a cancel keeps the partial and completes [TransferOutcome.cancelled].
  Future<TransferOutcome> fetch(String url, File target,
      {CancelToken? cancelToken, void Function(int received, int? total)? onProgress});
}

class DioAudioFetcher implements AudioFetcher {
  final Dio dio;

  /// [userAgent] is for native builds only: a browser refuses to let a
  /// page set the header, and the web build constructs this too.
  DioAudioFetcher({Dio? dio, String? userAgent})
      : dio = dio ??
            Dio(BaseOptions(headers: {
              'user-agent': ?userAgent,
            }));

  /// The native fetcher: enclosure and artwork URLs come from feeds, so
  /// they pass the same socket-level SSRF guard as feed fetches
  /// (guarded_http_client.dart). Dio follows redirects inside the
  /// [HttpClient], so every hop's connection is checked too.
  factory DioAudioFetcher.guarded(
      {String? userAgent,
      HostResolver? resolve,
      AddressPolicy allow = isPublicAddress}) {
    final fetcher = DioAudioFetcher(userAgent: userAgent);
    fetcher.dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => resolve == null
            ? guardedHttpClient(allow: allow)
            : guardedHttpClient(resolve: resolve, allow: allow));
    return fetcher;
  }

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

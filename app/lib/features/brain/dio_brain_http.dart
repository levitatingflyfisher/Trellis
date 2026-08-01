/// The app's implementation of brain_wiring's [BrainHttpClient] seam, over
/// dio (already the app's HTTP engine for audio; works on web too, so the
/// BYOK cloud Brain stays available in the PWA).
///
/// Seam contract, honoured here: non-2xx statuses come back as a
/// [BrainHttpResponse] (AnthropicBrain writes the calm sentence); only
/// transport-level failures throw. Consent is NEVER granted here — a call
/// must already have passed the one egress chokepoint (ADR-0003 law 6).
library;

import 'package:brain_wiring/brain_wiring.dart';
import 'package:dio/dio.dart';

class DioBrainHttpClient implements BrainHttpClient {
  DioBrainHttpClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  Future<BrainHttpResponse> post(
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) async {
    final response = await _dio.postUri<String>(
      url,
      data: body,
      options: Options(
        headers: headers,
        responseType: ResponseType.plain,
        // Per the seam contract the status is the caller's to judge —
        // dio must hand back a 429 or 500, not throw on it.
        validateStatus: (_) => true,
      ),
    );
    return BrainHttpResponse(
        statusCode: response.statusCode ?? 0, body: response.data ?? '');
  }
}

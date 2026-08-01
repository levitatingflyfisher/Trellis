/// The typed result of a conditional feed fetch (donor fetchFeedConditional
/// returned `{status, body?, etag?, lastModified?, retryAfter?, code?,
/// viaProxy?}`).
library;

enum FeedFetchStatus { fresh, notModified, throttled, notFound, error }

class FeedFetchResult {
  const FeedFetchResult.fresh({
    required String this.body,
    this.etag,
    this.lastModified,
    this.viaProxy = false,
  })  : status = FeedFetchStatus.fresh,
        retryAfterSeconds = null,
        errorCode = null,
        message = null;

  const FeedFetchResult.notModified()
      : status = FeedFetchStatus.notModified,
        body = null,
        etag = null,
        lastModified = null,
        retryAfterSeconds = null,
        errorCode = null,
        viaProxy = false,
        message = null;

  const FeedFetchResult.throttled(int this.retryAfterSeconds)
      : status = FeedFetchStatus.throttled,
        body = null,
        etag = null,
        lastModified = null,
        errorCode = null,
        viaProxy = false,
        message = null;

  const FeedFetchResult.notFound()
      : status = FeedFetchStatus.notFound,
        body = null,
        etag = null,
        lastModified = null,
        retryAfterSeconds = null,
        errorCode = null,
        viaProxy = false,
        message = null;

  const FeedFetchResult.error([this.errorCode, this.message])
      : status = FeedFetchStatus.error,
        body = null,
        etag = null,
        lastModified = null,
        retryAfterSeconds = null,
        viaProxy = false;

  final FeedFetchStatus status;

  /// Decoded feed text (fresh only).
  final String? body;

  /// Validators from the response (fresh via the direct path only — the
  /// donor deliberately nulls them for proxied bodies).
  final String? etag;
  final String? lastModified;

  /// Seconds to wait (throttled only; donor default 60).
  final int? retryAfterSeconds;

  /// HTTP status for 4xx-style errors; null for transport-level failures.
  final int? errorCode;

  /// A user-facing sentence from a typed transport refusal (error only).
  /// When the direct fetch throws a [CommsException] and no proxy may run,
  /// the sentence rides along instead of being destroyed — on the web tier
  /// that sentence is the honest "the browser blocked this fetch", which
  /// must not collapse into a generic "couldn't be reached".
  final String? message;

  final bool viaProxy;
}

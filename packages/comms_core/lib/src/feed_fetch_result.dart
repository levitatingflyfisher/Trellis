/// The typed result of a conditional feed fetch (donor fetchFeedConditional
/// returned `{status, body?, etag?, lastModified?, retryAfter?, code?,
/// viaProxy?}`).
library;

/// Why a feed failed, in words a listener can act on. They are stored as the
/// feed's last error and shown on its row, so they name the cause, not the
/// mechanism.
const feedGoneReason =
    'The feed’s server says this feed is gone. The show may have moved.';
const feedUnreachableReason = 'Couldn’t reach the feed’s server.';
const feedStalledReason = 'The feed’s server stopped sending.';
const feedBotWallReason = 'The feed’s web host is asking for a robot check, '
    'which Trellis can’t pass. Try again later, or ask the show for another '
    'feed address.';

/// The reason for an HTTP refusal that has no sentence of its own.
String feedRefusedReason(int code) =>
    'The feed’s server refused the request (error $code).';

enum FeedFetchStatus { fresh, notModified, throttled, notFound, error }

class FeedFetchResult {
  const FeedFetchResult.fresh({
    required String this.body,
    this.etag,
    this.lastModified,
    this.viaProxy = false,
    this.movedTo,
  })  : status = FeedFetchStatus.fresh,
        retryAfterSeconds = null,
        errorCode = null,
        message = null;

  const FeedFetchResult.notModified({this.movedTo})
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
        movedTo = null,
        body = null,
        etag = null,
        lastModified = null,
        errorCode = null,
        viaProxy = false,
        message = null;

  const FeedFetchResult.notFound()
      : status = FeedFetchStatus.notFound,
        movedTo = null,
        body = null,
        etag = null,
        lastModified = null,
        retryAfterSeconds = null,
        errorCode = null,
        viaProxy = false,
        message = null;

  const FeedFetchResult.error([this.errorCode, this.message])
      : status = FeedFetchStatus.error,
        movedTo = null,
        body = null,
        etag = null,
        lastModified = null,
        retryAfterSeconds = null,
        viaProxy = false;

  final FeedFetchStatus status;

  /// The feed's new permanent address, when the host moved it with
  /// 301/308 (fresh and notModified only). The caller adopts it.
  final String? movedTo;

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

/// Typed failures for the comms layer. The donor (ohPrimer) threw bare
/// `Error(message)`; the messages are preserved verbatim, the types are ours.
library;

/// Base class for every comms_core failure.
class CommsException implements Exception {
  const CommsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The SSRF guard rejected a URL (donor H15).
class UnsafeUrlException extends CommsException {
  const UnsafeUrlException(super.message);
}

/// A response exceeded a size cap (donor H16). Thrown mid-stream.
class SizeCapException extends CommsException {
  const SizeCapException(super.message);
}

/// A fetch failed after the direct/proxy ladder was exhausted, or was
/// refused because proxy consent is off (donor C5).
class FetchFailedException extends CommsException {
  const FetchFailedException(super.message);
}

/// A feed body could not be parsed (or was too large to parse safely, M19).
class FeedParseException extends CommsException {
  const FeedParseException(super.message);
}

/// An OPML document could not be parsed (or was too large).
class OpmlParseException extends CommsException {
  const OpmlParseException(super.message);
}

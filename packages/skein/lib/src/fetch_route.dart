/// `/api/fetch?url=<percent-encoded absolute URL>` — the proxy that lets
/// the app fetch on the browser's behalf, same-origin.
///
/// Laws 3, 4, 6 live here:
/// - [assertSafeFetchUrl] runs on the query's `url` AND on every redirect
///   hop the upstream server sends back — the classic "use the proxy to
///   read the router" attack (a public host bouncing the daemon into the
///   LAN via a 3xx) is refused at each hop, not just the first.
/// - **Resolve-time hardening (the DNS-rebinding half of law 3).**
///   `assertSafeFetchUrl` is lexical — it parses the host STRING and
///   cannot see DNS, so a public-looking hostname that RESOLVES to
///   127.0.0.1 or a LAN address sails straight past it. After the lexical
///   guard passes, the hostname is resolved ([HostResolver]) and every
///   returned address is classified ([isUnsafeResolvedAddress]); if any
///   is loopback/link-local/private/unique-local/unspecified, the fetch
///   is refused. To close the TOCTOU window between that check and the
///   actual connect — a second lookup could answer differently — the
///   outgoing socket is PINNED to the exact address just checked via
///   `HttpClient.connectionFactory`, which the family of tests here proves
///   for HTTP; the HTTPS half (`SecureSocket.secure(socket, host: ...)`,
///   preserving the original hostname for SNI and certificate
///   verification) was verified by hand against a real self-signed
///   certificate server, not by an automated test in this suite — see
///   ADR-0005's security section for what that leaves open. This whole
///   sequence — lexical guard, lookup, classify, pin — repeats on every
///   redirect hop, not just the first.
/// - The body is capped at [maxBytes]. Streaming a status code is a
///   one-way door — once 200 and headers reach the client, a later 502
///   cannot un-send them — so unlike the direct-fetch seam elsewhere in
///   this codebase (which streams to let mid-download caps abort a
///   transfer), this proxy BUFFERS the upstream body in memory up to the
///   cap before committing anything to the client. A cap trip becomes a
///   real 502, not a truncated 200. This is a deliberate deviation from
///   "stream the body" as literally written, spelled out here because it
///   changes an observable contract: 32 MiB is a small, bounded buffer for
///   a desktop daemon serving one household, never held across requests.
/// - Every failure this daemon originates (not proxied from upstream) is
///   marked with [skeinErrorHeader] — a same-origin response header the
///   app-side fetcher checks to decide "was that Skein refusing, or the
///   real site answering with its own 4xx/5xx?" without guessing from a
///   status code upstream could equally have sent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:comms_core/comms_core.dart'
    show UnsafeUrlException, assertSafeFetchUrl;

import 'host_guard.dart';
import 'limits.dart';
import 'version.dart';

/// Set (to `'1'`) on every response this daemon originates itself, as
/// opposed to one proxied byte-for-byte (status + whitelisted headers)
/// from the real upstream site.
const String skeinErrorHeader = 'x-skein-error';

/// Forwarded from the browser's request to the upstream fetch — nothing
/// else, so a page can't smuggle cookies or auth headers through the
/// daemon to a third party it was never meant to reach.
const List<String> forwardableRequestHeaders = [
  'accept',
  'if-none-match',
  'if-modified-since',
];

/// Forwarded from the upstream response back to the browser.
const List<String> forwardableResponseHeaders = [
  'content-type',
  'etag',
  'last-modified',
];

bool _isRedirect(int status) =>
    status == 301 ||
    status == 302 ||
    status == 303 ||
    status == 307 ||
    status == 308;

class _TooManyRedirects implements Exception {
  const _TooManyRedirects();
}

/// One hop's response, paired with the short-lived [HttpClient] that owns
/// its socket — closing that client too early (before the body is read)
/// would destroy the connection mid-stream, so the caller closes it only
/// after consuming the body.
class _HopResult {
  const _HopResult(this.response, this._client);
  final HttpClientResponse response;
  final HttpClient _client;
  void close() => _client.close(force: true);
}

/// Proxies one browser GET onto the real internet, same-origin.
class SkeinFetcher {
  SkeinFetcher({
    this.maxBytes = skeinMaxFetchBytes,
    Uri Function(String raw)? urlGuard,
    HostResolver? resolver,
    bool Function(InternetAddress)? isUnsafeAddress,
  })  : _urlGuard = urlGuard ?? assertSafeFetchUrl,
        _resolver = resolver ?? InternetAddress.lookup,
        _isUnsafeAddress = isUnsafeAddress ?? isUnsafeResolvedAddress;

  final int maxBytes;

  /// Re-run on the initial `url` AND on every redirect hop (law 3).
  /// Defaults to comms_core's real guard; tests inject a permissive one to
  /// exercise proxy mechanics against a loopback upstream (which the real
  /// guard correctly refuses in production).
  final Uri Function(String raw) _urlGuard;

  /// Looks up a hostname's addresses. Defaults to real DNS
  /// ([InternetAddress.lookup]); tests inject a fake so hostname-based
  /// rebinding scenarios need no real network.
  final HostResolver _resolver;

  /// Classifies a resolved address as unsafe to connect to. Defaults to
  /// the real [isUnsafeResolvedAddress]; tests inject a permissive
  /// stand-in to admit this file's own loopback fixtures for mechanics
  /// tests — the real function is proven directly in host_guard_test.dart
  /// and through this file's own resolve-time SSRF tests.
  final bool Function(InternetAddress) _isUnsafeAddress;

  static const int maxRedirects = 5;

  Future<void> proxy(HttpRequest request) async {
    final rawUrl = request.uri.queryParameters['url'];
    if (rawUrl == null || rawUrl.isEmpty) {
      await _skeinError(request.response, HttpStatus.badRequest,
          'That address is missing.');
      return;
    }

    final Uri target;
    try {
      target = _urlGuard(rawUrl);
    } on UnsafeUrlException catch (e) {
      await _skeinError(request.response, HttpStatus.badRequest, e.message);
      return;
    } on FormatException {
      await _skeinError(request.response, HttpStatus.badRequest,
          "That doesn't look like a valid web address.");
      return;
    }

    final forwarded = <String, String>{};
    for (final name in forwardableRequestHeaders) {
      final v = request.headers.value(name);
      if (v != null) forwarded[name] = v;
    }

    final _HopResult hop;
    try {
      hop = await _fetchFollowingRedirects(target, forwarded);
    } on UnsafeUrlException catch (e) {
      await _skeinError(request.response, HttpStatus.badRequest, e.message);
      return;
    } on _TooManyRedirects {
      await _skeinError(request.response, HttpStatus.badGateway,
          'That address redirected too many times.');
      return;
    } catch (_) {
      await _skeinError(request.response, HttpStatus.badGateway,
          "Your Skein couldn't reach that address.");
      return;
    }

    try {
      final upstream = hop.response;
      // Buffer up to the cap BEFORE committing status/headers — see the
      // library doc comment for why this can't stream-then-abort.
      final builder = BytesBuilder(copy: false);
      var over = false;
      try {
        await for (final chunk in upstream) {
          builder.add(chunk);
          if (builder.length > maxBytes) {
            over = true;
            break;
          }
        }
      } catch (_) {
        await _skeinError(request.response, HttpStatus.badGateway,
            'That address stopped answering before it finished.');
        return;
      }
      if (over) {
        await _skeinError(request.response, HttpStatus.badGateway,
            'That page is too large to bring in — over '
            '${maxBytes ~/ (1024 * 1024)} MB.');
        return;
      }

      request.response.statusCode = upstream.statusCode;
      for (final name in forwardableResponseHeaders) {
        final v = upstream.headers.value(name);
        if (v != null) request.response.headers.set(name, v);
      }
      request.response.add(builder.takeBytes());
      await request.response.close();
    } finally {
      hop.close();
    }
  }

  Future<_HopResult> _fetchFollowingRedirects(
      Uri url, Map<String, String> headers) async {
    var current = url;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      // Resolve-time hardening, repeated for THIS hop (law 3's DNS-
      // rebinding half): lookup (or literal-IP shortcut) → classify → the
      // client below is pinned to exactly this checked address.
      final vetted = await _resolveAndVet(current);

      final client = HttpClient()..autoUncompress = true;
      HttpClientResponse resp;
      try {
        client.connectionFactory = (uri, proxyHost, proxyPort) =>
            _pinnedConnect(vetted, uri);
        final req = await client.getUrl(current);
        req.followRedirects = false; // hops are ours, so the guard runs
        req.headers.set(
            HttpHeaders.userAgentHeader, 'trellis-skein/$skeinVersion');
        headers.forEach(req.headers.set);
        resp = await req.close();
      } catch (_) {
        client.close(force: true);
        rethrow;
      }

      if (_isRedirect(resp.statusCode)) {
        final location = resp.headers.value(HttpHeaders.locationHeader);
        await resp.drain<void>();
        client.close(force: true); // done with this hop's connection
        if (location == null || location.isEmpty) {
          throw const UnsafeUrlException(
              'That address redirected without saying where to.');
        }
        current = _urlGuard(current.resolve(location).toString());
        continue;
      }
      return _HopResult(resp, client); // caller closes after reading the body
    }
    throw const _TooManyRedirects();
  }

  /// Resolves [url]'s host (or classifies it directly when it's already a
  /// literal IP — no lookup to skip) and refuses if ANY candidate address
  /// is unsafe. Returns the address the connection will be pinned to.
  Future<InternetAddress> _resolveAndVet(Uri url) async {
    final literal = InternetAddress.tryParse(url.host);
    if (literal != null) {
      if (_isUnsafeAddress(literal)) {
        throw const UnsafeUrlException(
            "Local and private-network addresses can't be loaded.");
      }
      return literal;
    }

    final List<InternetAddress> addresses;
    try {
      addresses = await _resolver(url.host);
    } catch (_) {
      throw const UnsafeUrlException("That address couldn't be found.");
    }
    if (addresses.isEmpty) {
      throw const UnsafeUrlException("That address couldn't be found.");
    }
    for (final addr in addresses) {
      if (_isUnsafeAddress(addr)) {
        throw const UnsafeUrlException(
            "That address points at a local or private network.");
      }
    }
    return addresses.first;
  }

  /// Connects the TCP socket to [vetted] — NOT to whatever a fresh lookup
  /// of `uri.host` might answer, which closes the TOCTOU window between
  /// the check above and the connect. For https, the socket is then
  /// TLS-upgraded with the ORIGINAL hostname (`uri.host`) as the SNI/
  /// certificate-verification target, exactly as a normal HTTPS proxy
  /// tunnel does — so pinning the transport never weakens certificate
  /// validation.
  static Future<ConnectionTask<Socket>> _pinnedConnect(
      InternetAddress vetted, Uri uri) {
    final plainTask = Socket.startConnect(vetted, uri.port);
    if (!uri.isScheme('https')) return plainTask;
    return plainTask.then((task) async {
      final plain = await task.socket;
      final secureFuture = SecureSocket.secure(plain, host: uri.host);
      return ConnectionTask.fromSocket(secureFuture, plain.destroy);
    });
  }

  Future<void> _skeinError(
      HttpResponse response, int status, String message) async {
    response.statusCode = status;
    response.headers.set(skeinErrorHeader, '1');
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode({'error': message}));
    await response.close();
  }
}

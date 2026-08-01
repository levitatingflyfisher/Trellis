/// SSRF guard (donor H15: 00-utils.js `assertSafeFetchUrl`/`isLocalEndpoint`),
/// deliberately STRICTER than the donor:
///
/// - The browser's URL parser canonicalizes numeric hosts (`0x7f000001`,
///   `2130706433`, `0177.0.0.1`, `127.1` all become `127.0.0.1`) before the
///   donor's regexes ever ran. Dart's [Uri] does not, so this guard parses
///   IPv4 literals with inet_aton semantics itself.
/// - IPv4-mapped/-compatible and NAT64-embedded IPv6 addresses have their
///   embedded IPv4 checked against the full blocklist (the donor's regex only
///   caught mapped loopback).
/// - Extra blocked ranges for native apps on real LANs: CGNAT 100.64.0.0/10,
///   192.0.0.0/24, broadcast, IPv6 site-local fec0::/10, `.localhost` and
///   `.internal` hostname suffixes.
///
/// This is a lexical guard: it cannot see DNS. A hostname that *resolves* to
/// a private address still gets through here — [HttpFetcher] implementations
/// that resolve names should re-check the resolved address.
library;

import 'exceptions.dart';

/// Validates [raw] for fetching. Returns the parsed [Uri] on success,
/// throws [UnsafeUrlException] (with the donor's user-facing messages)
/// otherwise.
Uri assertSafeFetchUrl(String raw) {
  Uri u;
  try {
    u = Uri.parse(raw);
  } on FormatException {
    throw const UnsafeUrlException(
        "That doesn't look like a valid web address.");
  }
  if (!u.hasScheme) {
    throw const UnsafeUrlException(
        "That doesn't look like a valid web address.");
  }
  if (u.scheme != 'http' && u.scheme != 'https') {
    throw const UnsafeUrlException('Only http(s) addresses can be loaded.');
  }
  var host = u.host.toLowerCase();
  while (host.endsWith('.')) {
    host = host.substring(0, host.length - 1);
  }
  if (host.isEmpty || _isBlockedHost(host)) {
    throw const UnsafeUrlException(
        "Local and private-network addresses can't be loaded.");
  }
  return u;
}

bool _isBlockedHost(String host) {
  if (host == 'localhost' || host.endsWith('.localhost')) return true;
  if (host.endsWith('.local') || host.endsWith('.internal')) return true;
  if (host.contains(':')) {
    final groups = _parseIpv6(host);
    if (groups == null) return true; // unparseable IPv6-looking host: fail closed
    return _isBlockedIpv6(groups);
  }
  final v4 = _parseIpv4(host);
  if (v4 != null) return _isBlockedIpv4(v4);
  return false;
}

bool _isBlockedIpv4(int a) {
  final b0 = (a >> 24) & 0xFF;
  if (b0 == 0 || b0 == 10 || b0 == 127) return true; // "this", private, loopback
  final b1 = (a >> 16) & 0xFF;
  if (b0 == 172 && b1 >= 16 && b1 <= 31) return true; // 172.16.0.0/12
  if (b0 == 192 && b1 == 168) return true; // 192.168.0.0/16
  if (b0 == 169 && b1 == 254) return true; // link-local, incl. 169.254.169.254
  if (b0 == 100 && b1 >= 64 && b1 <= 127) return true; // CGNAT 100.64.0.0/10
  if (b0 == 192 && b1 == 0 && ((a >> 8) & 0xFF) == 0) return true; // 192.0.0.0/24
  if (a == 0xFFFFFFFF) return true; // broadcast
  return false;
}

/// inet_aton-style IPv4 literal parse: 1–4 dot-separated parts, each
/// decimal, hex (0x…) or octal (leading 0); the last part fills the
/// remaining bytes. Returns null when [host] is not an IPv4 literal.
int? _parseIpv4(String host) {
  if (host.isEmpty) return null;
  final parts = host.split('.');
  if (parts.length > 4) return null;
  final nums = <int>[];
  for (final p in parts) {
    final n = _parseIpv4Part(p);
    if (n == null) return null;
    nums.add(n);
  }
  final last = nums.removeLast();
  final lastBytes = 4 - nums.length;
  final lastMax = lastBytes == 4 ? 0xFFFFFFFF : (1 << (8 * lastBytes)) - 1;
  if (last < 0 || last > lastMax) return null;
  var addr = 0;
  for (final n in nums) {
    if (n < 0 || n > 255) return null;
    addr = (addr << 8) | n;
  }
  return (addr << (8 * lastBytes)) | last;
}

final _decimalDigits = RegExp(r'^\d+$');

int? _parseIpv4Part(String p) {
  if (p.isEmpty) return null;
  if (p.startsWith('0x')) {
    if (p.length == 2) return 0; // bare "0x" is 0 in inet_aton
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(p.substring(2))) return null;
    return int.tryParse(p.substring(2), radix: 16);
  }
  if (!_decimalDigits.hasMatch(p)) return null;
  if (p.length > 1 && p.startsWith('0')) {
    return int.tryParse(p, radix: 8); // octal (null on digits 8/9)
  }
  return int.tryParse(p);
}

bool _isBlockedIpv6(List<int> g) {
  if (g.every((x) => x == 0)) return true; // :: unspecified
  if (g.sublist(0, 7).every((x) => x == 0) && g[7] == 1) return true; // ::1
  if ((g[0] & 0xFFC0) == 0xFE80) return true; // fe80::/10 link-local
  if ((g[0] & 0xFFC0) == 0xFEC0) return true; // fec0::/10 site-local (deprecated)
  if ((g[0] & 0xFE00) == 0xFC00) return true; // fc00::/7 unique-local
  int? embedded;
  if (g.sublist(0, 5).every((x) => x == 0) && g[5] == 0xFFFF) {
    embedded = (g[6] << 16) | g[7]; // ::ffff:a.b.c.d IPv4-mapped
  } else if (g.sublist(0, 6).every((x) => x == 0)) {
    embedded = (g[6] << 16) | g[7]; // ::a.b.c.d IPv4-compatible (deprecated)
  } else if (g[0] == 0x0064 &&
      g[1] == 0xFF9B &&
      g.sublist(2, 6).every((x) => x == 0)) {
    embedded = (g[6] << 16) | g[7]; // 64:ff9b::/96 NAT64
  }
  return embedded != null && _isBlockedIpv4(embedded);
}

final _hexGroup = RegExp(r'^[0-9a-f]{1,4}$');

/// Expands an (unbracketed, lowercased) IPv6 literal to its 8 groups.
/// Returns null when it is not valid IPv6.
List<int>? _parseIpv6(String host) {
  var h = host;
  final zone = h.indexOf('%');
  if (zone >= 0) h = h.substring(0, zone); // strip zone id (fe80::1%eth0)
  if (h.contains('.')) {
    // Embedded dotted-quad tail (::ffff:127.0.0.1) → two hex groups.
    final i = h.lastIndexOf(':');
    if (i < 0) return null;
    final v4 = _parseDottedQuad(h.substring(i + 1));
    if (v4 == null) return null;
    h = '${h.substring(0, i + 1)}'
        '${((v4 >> 16) & 0xFFFF).toRadixString(16)}:'
        '${(v4 & 0xFFFF).toRadixString(16)}';
  }
  final dc = h.indexOf('::');
  if (dc >= 0 && dc != h.lastIndexOf('::')) return null; // one '::' at most
  List<String> left, right;
  if (dc >= 0) {
    left = dc == 0 ? const [] : h.substring(0, dc).split(':');
    final r = h.substring(dc + 2);
    right = r.isEmpty ? const [] : r.split(':');
  } else {
    left = h.split(':');
    right = const [];
  }
  final total = left.length + right.length;
  if (dc < 0 && total != 8) return null;
  if (dc >= 0 && total > 7) return null;
  final groups = <int>[];
  for (final s in left) {
    if (!_hexGroup.hasMatch(s)) return null;
    groups.add(int.parse(s, radix: 16));
  }
  groups.addAll(List.filled(8 - total, 0));
  for (final s in right) {
    if (!_hexGroup.hasMatch(s)) return null;
    groups.add(int.parse(s, radix: 16));
  }
  return groups.length == 8 ? groups : null;
}

int? _parseDottedQuad(String s) {
  final parts = s.split('.');
  if (parts.length != 4) return null;
  var v = 0;
  for (final p in parts) {
    if (p.isEmpty || p.length > 3 || !_decimalDigits.hasMatch(p)) return null;
    final n = int.parse(p);
    if (n > 255) return null;
    v = (v << 8) | n;
  }
  return v;
}

/// Resolve-time SSRF hardening (law 3, the DNS-rebinding half).
/// comms_core's `assertSafeFetchUrl` is a LEXICAL guard — it parses the
/// host string and cannot see DNS (its own doc comment says so). A
/// hostname a public site controls can resolve to `127.0.0.1` or a LAN
/// address and sail straight past it. This file is Skein-side hardening
/// only: it classifies the address a lookup ACTUALLY returned, and
/// `fetch_route.dart` pins the outgoing connection to exactly that
/// checked address so a second, different DNS answer can never be
/// substituted between the check and the connect (the classic TOCTOU
/// rebinding window). comms_core itself is unchanged.
library;

import 'dart:io';

/// Looks up [host]; Skein's default resolver is [InternetAddress.lookup],
/// injectable so tests never need real DNS.
typedef HostResolver = Future<List<InternetAddress>> Function(String host);

/// True when [addr] must never be connected to: loopback, link-local,
/// RFC1918 private, CGNAT, unique-local IPv6 (fc00::/7), unspecified, or
/// an IPv4-mapped IPv6 form of any of those. Mirrors (a resolve-time-only
/// subset of) comms_core's own blocklist by design — the categories the
/// resolve-time check is asked to cover, not a re-implementation of its
/// full lexical rule set (hostname suffixes like `.internal` have no
/// meaning for a resolved IP address).
bool isUnsafeResolvedAddress(InternetAddress addr) {
  if (addr.isLoopback || addr.isLinkLocal) return true;
  switch (addr.type) {
    case InternetAddressType.IPv4:
      return _blockedIpv4Bytes(addr.rawAddress);
    case InternetAddressType.IPv6:
      final b = addr.rawAddress;
      if (b.every((x) => x == 0)) return true; // :: unspecified
      if ((b[0] & 0xFE) == 0xFC) return true; // fc00::/7 unique-local
      // ::ffff:a.b.c.d — the standard IPv4-mapped form (RFC 4291 §2.5.5.2).
      if (b.take(10).every((x) => x == 0) && b[10] == 0xFF && b[11] == 0xFF) {
        return _blockedIpv4Bytes(b.sublist(12, 16));
      }
      return false;
    default:
      return true; // unix-socket or an address family we don't know: fail closed
  }
}

/// Checked directly for a top-level IPv4 address's raw bytes (where
/// [InternetAddress.isLoopback]/[isLinkLocal] already covered 127.0.0.0/8
/// and 169.254.0.0/16 before this runs — see [isUnsafeResolvedAddress])
/// AND for an IPv4 address extracted from an IPv4-mapped IPv6 wrapper
/// (where nothing upstream has classified it yet — those built-ins only
/// look at the OUTER IPv6 address). Repeats loopback/link-local itself so
/// both call sites get the full check.
bool _blockedIpv4Bytes(List<int> b) {
  final b0 = b[0], b1 = b[1];
  if (b0 == 0) return true; // 0.0.0.0/8 — unspecified/"this network"
  if (b0 == 127) return true; // 127.0.0.0/8 — loopback
  if (b0 == 169 && b1 == 254) return true; // 169.254.0.0/16 — link-local
  if (b0 == 10) return true; // RFC1918
  if (b0 == 172 && b1 >= 16 && b1 <= 31) return true; // RFC1918
  if (b0 == 192 && b1 == 168) return true; // RFC1918
  if (b0 == 100 && b1 >= 64 && b1 <= 127) return true; // CGNAT 100.64.0.0/10
  return false;
}

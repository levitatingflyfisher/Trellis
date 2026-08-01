/// The resolve-time half of law 3's SSRF guard. comms_core's
/// assertSafeFetchUrl is lexical — it cannot see DNS, so a public-looking
/// hostname that RESOLVES to a private/loopback/link-local address slips
/// past it (the classic DNS-rebinding attack against a server-side
/// fetcher). [isUnsafeResolvedAddress] classifies the ACTUAL resolved
/// address; it is Skein-side hardening only — comms_core is untouched.
import 'dart:io';

import 'package:skein/skein.dart';
import 'package:test/test.dart';

void main() {
  bool unsafe(String literal) =>
      isUnsafeResolvedAddress(InternetAddress(literal));

  group('IPv4', () {
    test('loopback (whole 127.0.0.0/8, not just 127.0.0.1)', () {
      expect(unsafe('127.0.0.1'), isTrue);
      expect(unsafe('127.5.5.5'), isTrue);
    });
    test('link-local 169.254.0.0/16', () => expect(unsafe('169.254.1.1'), isTrue));
    test('RFC1918 private ranges', () {
      expect(unsafe('10.0.0.1'), isTrue);
      expect(unsafe('172.16.0.1'), isTrue);
      expect(unsafe('172.31.255.255'), isTrue);
      expect(unsafe('192.168.1.1'), isTrue);
    });
    test('172.32.x.x is OUTSIDE the private range — not blocked',
        () => expect(unsafe('172.32.0.1'), isFalse));
    test('unspecified 0.0.0.0', () => expect(unsafe('0.0.0.0'), isTrue));
    test('CGNAT 100.64.0.0/10', () => expect(unsafe('100.64.0.1'), isTrue));
    test('a genuinely public address is not blocked',
        () => expect(unsafe('93.184.216.34'), isFalse));
  });

  group('IPv6', () {
    test('loopback ::1', () => expect(unsafe('::1'), isTrue));
    test('unspecified ::', () => expect(unsafe('::'), isTrue));
    test('link-local fe80::/10', () => expect(unsafe('fe80::1'), isTrue));
    test('unique-local fc00::/7 (both fc00:: and fd00::)', () {
      expect(unsafe('fc00::1'), isTrue);
      expect(unsafe('fd12:3456::1'), isTrue);
    });
    test('a globally-routed IPv6 address is not blocked',
        () => expect(unsafe('2606:2800:220:1:248:1893:25c8:1946'), isFalse));
  });

  group('IPv4-mapped IPv6 (::ffff:a.b.c.d)', () {
    test('a mapped loopback address is blocked',
        () => expect(unsafe('::ffff:127.0.0.1'), isTrue));
    test('a mapped private address is blocked',
        () => expect(unsafe('::ffff:10.0.0.1'), isTrue));
    test('a mapped public address is not blocked',
        () => expect(unsafe('::ffff:93.184.216.34'), isFalse));
  });
}

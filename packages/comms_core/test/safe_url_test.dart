/// SSRF guard (donor H15, 00-utils.js assertSafeFetchUrl) — deliberately
/// STRICTER than the donor: native apps reach real LANs, and Dart's Uri does
/// not canonicalize numeric IPv4 forms the way the browser URL parser does,
/// so the guard must parse them itself.
library;

import 'package:comms_core/comms_core.dart';
import 'package:test/test.dart';

void expectBlocked(String url, {String? messagePart}) {
  expect(
    () => assertSafeFetchUrl(url),
    throwsA(isA<UnsafeUrlException>().having(
      (e) => e.message,
      'message',
      messagePart == null ? anything : contains(messagePart),
    )),
    reason: 'expected $url to be blocked',
  );
}

void expectAllowed(String url) {
  expect(assertSafeFetchUrl(url), isA<Uri>(),
      reason: 'expected $url to be allowed');
}

void main() {
  group('scheme allowlist', () {
    test('http and https pass', () {
      expectAllowed('https://example.com/a');
      expectAllowed('http://example.com/a?b=c#d');
    });
    for (final url in [
      'file:///etc/passwd',
      'ftp://example.com/x',
      'javascript:alert(1)',
      'data:text/html,hi',
      'gopher://example.com/',
      'ws://example.com/',
    ]) {
      test('blocks $url', () {
        expectBlocked(url, messagePart: 'Only http(s)');
      });
    }
    test('garbage is not a web address', () {
      expectBlocked('not a url',
          messagePart: "doesn't look like a valid web address");
      expectBlocked('', messagePart: "doesn't look like a valid web address");
    });
  });

  group('donor H15 cases', () {
    test('blocks localhost', () => expectBlocked('http://localhost:9/x'));
    test('blocks metadata IP', () => expectBlocked('http://169.254.169.254/'));
    test('blocks all of 127.0.0.0/8, not just 127.0.0.1',
        () => expectBlocked('http://127.1.2.3/x'));
    test('blocks IPv4-mapped-IPv6 loopback',
        () => expectBlocked('http://[::ffff:7f00:1]/x'));
  });

  group('hostname blocks', () {
    for (final host in [
      'localhost',
      'LOCALHOST',
      'localhost.', // trailing dot
      'sub.localhost',
      'printer.local',
      'metadata.google.internal',
    ]) {
      test('blocks $host', () => expectBlocked('http://$host/x',
          messagePart: 'Local and private-network'));
    }
  });

  group('IPv4 blocks', () {
    for (final host in [
      '127.0.0.1',
      '10.0.0.1',
      '10.255.255.255',
      '192.168.1.1',
      '172.16.0.1',
      '172.31.255.255',
      '169.254.1.1',
      '0.0.0.0',
      '100.64.0.1', // CGNAT (stricter than donor)
      '255.255.255.255',
    ]) {
      test('blocks $host', () => expectBlocked('http://$host/x'));
    }

    test('blocks non-canonical numeric forms the browser would normalize', () {
      expectBlocked('http://2130706433/x'); // decimal 127.0.0.1
      expectBlocked('http://0x7f000001/x'); // hex 127.0.0.1
      expectBlocked('http://0177.0.0.1/x'); // octal first octet
      expectBlocked('http://127.1/x'); // inet_aton short form
      expectBlocked('http://192.168.1/x'); // a.b.c form
    });

    for (final host in [
      '8.8.8.8',
      '11.0.0.1',
      '172.32.0.1',
      '192.169.0.1',
      '100.128.0.1',
      '169.253.1.1',
    ]) {
      test('allows public $host', () => expectAllowed('http://$host/x'));
    }
  });

  group('IPv6 blocks', () {
    for (final host in [
      '[::1]',
      '[::]',
      '[fe80::1]', // link-local
      '[fec0::1]', // deprecated site-local (stricter)
      '[fc00::1]', // ULA
      '[fd12:3456::1]', // ULA
      '[::ffff:127.0.0.1]', // v4-mapped loopback, dotted
      '[::ffff:10.0.0.5]', // v4-mapped private (donor regex missed these)
      '[::ffff:a9fe:a9fe]', // v4-mapped 169.254.169.254
      '[::ffff:c0a8:101]', // v4-mapped 192.168.1.1
      '[::127.0.0.1]', // v4-compatible loopback (stricter)
      '[64:ff9b::7f00:1]', // NAT64-embedded loopback (stricter)
    ]) {
      test('blocks $host', () => expectBlocked('http://$host/x'));
    }
    test('allows public IPv6', () {
      expectAllowed('http://[2607:f8b0::1]/x');
      expectAllowed('http://[::ffff:8.8.8.8]/x'); // v4-mapped public
    });
  });

  test('returns the parsed Uri on success', () {
    final u = assertSafeFetchUrl('https://example.com:8080/x?y=1');
    expect(u.host, 'example.com');
    expect(u.port, 8080);
  });
}

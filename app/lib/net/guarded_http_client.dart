/// The SSRF guard at the socket (ADR-0017). comms_core's `assertSafeFetchUrl`
/// reads only a URL's text, so `http://feed.example/` that resolves to
/// 192.168.1.1 passed it. Here every connection the [HttpClient] opens,
/// first request and redirect hop alike, resolves the host once, refuses
/// if any answer is private, and connects to the very address it checked.
/// Checking one lookup and connecting after another would let a
/// rebinding DNS server answer public for the check and private for the
/// connect.
///
/// TLS still verifies the certificate against the hostname, and SNI still
/// names it: the socket is opened to the checked IP, then secured with
/// `host:` set to the URL's host.
library;

import 'dart:async';
import 'dart:io';

import 'package:comms_core/comms_core.dart';

typedef HostResolver = Future<List<InternetAddress>> Function(String host);
typedef AddressPolicy = bool Function(InternetAddress address);

Future<List<InternetAddress>> _lookup(String host) =>
    InternetAddress.lookup(host);

/// The default policy: anything comms_core's blocklist names is refused.
bool isPublicAddress(InternetAddress a) => !isBlockedIpAddress(a.rawAddress);

const _blockedMessage =
    'Local and private-network addresses can’t be loaded.';

/// An [HttpClient] whose every connection passes [allow]. [resolve] and
/// [allow] are injectable so tests can name hosts without DNS and reach a
/// loopback server on purpose.
HttpClient guardedHttpClient(
    {HostResolver resolve = _lookup,
    AddressPolicy allow = isPublicAddress,
    SecurityContext? context}) {
  final client = HttpClient(context: context);
  // A proxy would make the checked address the proxy's, not the
  // target's; this app sets none, and the factory relies on that.
  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    final host = uri.host;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    final literal = InternetAddress.tryParse(host);
    final addresses = literal != null ? [literal] : await resolve(host);
    if (addresses.isEmpty) {
      throw SocketException('No address for $host');
    }
    // One private answer among public ones is still a way in: a client
    // falling back to it after a failed connect would reach the LAN.
    if (!addresses.every(allow)) {
      throw const UnsafeUrlException(_blockedMessage);
    }
    final race = _race(_interleave(addresses), port);
    var cancelled = false;
    final socket = uri.scheme != 'https'
        ? race.socket
        : race.socket.then((s) async {
            final secure =
                await SecureSocket.secure(s, host: host, context: context);
            // Cancelled mid-handshake: nobody will read this socket.
            if (cancelled) {
              secure.destroy();
              throw const SocketException('Connection attempt cancelled');
            }
            return secure;
          });
    return ConnectionTask.fromSocket(socket, () {
      cancelled = true;
      race.cancel();
    });
  };
  return client;
}

/// Families alternated, first answer's family first (RFC 8305): a name
/// that lists two IPv6 addresses before its IPv4 ones, on a network with
/// no IPv6 route, must not wait out two dead connects.
List<InternetAddress> _interleave(List<InternetAddress> addresses) {
  final first = addresses.first.type;
  final a = [for (final x in addresses) if (x.type == first) x];
  final b = [for (final x in addresses) if (x.type != first) x];
  return [
    for (var i = 0; i < a.length || i < b.length; i++) ...[
      if (i < a.length) a[i],
      if (i < b.length) b[i],
    ],
  ];
}

/// Connects to the checked addresses the way the platform's own connect
/// would to a hostname: staggered by 250 ms, first to answer wins, the
/// rest are cancelled. Every candidate is an address already checked.
({Future<Socket> socket, void Function() cancel}) _race(
    List<InternetAddress> addresses, int port,
    {SocketConnector connect = Socket.startConnect}) {
  final done = Completer<Socket>();
  final tasks = <ConnectionTask<Socket>>[];
  final timers = <Timer>[];
  var cancelled = false;
  var failed = 0;

  void fail(Object e, StackTrace st) {
    if (++failed == addresses.length && !done.isCompleted) {
      done.completeError(e, st);
    }
  }

  // A cancel can land between a timer firing and its connect returning,
  // or while a handshake is in flight; anything that arrives after it is
  // closed, never handed on or left open.
  void cancelAll() {
    cancelled = true;
    for (final t in timers) {
      t.cancel();
    }
    for (final t in tasks) {
      t.cancel();
    }
    if (!done.isCompleted) {
      done.completeError(
          const SocketException('Connection attempt cancelled'));
    }
  }

  for (var i = 0; i < addresses.length; i++) {
    timers.add(Timer(Duration(milliseconds: 250 * i), () async {
      if (cancelled || done.isCompleted) {
        failed++;
        return;
      }
      final ConnectionTask<Socket> task;
      try {
        task = await connect(addresses[i], port);
      } catch (e, st) {
        fail(e, st);
        return;
      }
      if (cancelled || done.isCompleted) {
        task.cancel();
        task.socket.then((s) => s.destroy(), onError: (_) {});
        return;
      }
      tasks.add(task);
      task.socket.then((s) {
        if (cancelled || done.isCompleted) {
          s.destroy();
          return;
        }
        done.complete(s);
        for (final t in timers) {
          t.cancel();
        }
        for (final t in tasks) {
          if (!identical(t, task)) t.cancel();
        }
      }, onError: fail);
    }));
  }
  return (socket: done.future, cancel: cancelAll);
}

typedef SocketConnector = Future<ConnectionTask<Socket>> Function(
    InternetAddress address, int port);

/// Visible for tests: the race on its own, with a fake connector.
({Future<Socket> socket, void Function() cancel}) raceForTest(
        List<InternetAddress> addresses, int port,
        {required SocketConnector connect}) =>
    _race(addresses, port, connect: connect);

import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/feeds/background/feed_check_handoff.dart';
import 'package:trellis/features/feeds/background/feed_check_settings.dart';

class FakeDirectory implements PortDirectory {
  final Map<String, SendPort> names = {};
  @override
  SendPort? lookup(String name) => names[name];
  @override
  bool register(SendPort port, String name) {
    if (names.containsKey(name)) return false;
    names[name] = port;
    return true;
  }

  @override
  void remove(String name) => names.remove(name);
}

void main() {
  late FakeDirectory directory;
  setUp(() => directory = FakeDirectory());

  test('with no app running, the worker runs the check itself', () async {
    final ran = <FeedCheckTask>[];
    final worker = FeedCheckWorker(
        directory: directory,
        runHere: (task, _) async {
          ran.add(task);
          return true;
        });
    expect(await worker.run(FeedCheckTask.check), isTrue);
    expect(ran, [FeedCheckTask.check]);
    expect(directory.names, isEmpty, reason: 'its name goes when it ends');
  });

  test('with the app running, the worker hands the check over and runs '
      'nothing itself', () async {
    final appRan = <FeedCheckTask>[];
    final host = FeedCheckHost(
        directory: directory,
        runTask: (task, _) async {
          appRan.add(task);
          return true;
        });
    await host.open();
    addTearDown(host.close);

    final worker = FeedCheckWorker(
        directory: directory,
        runHere: (_, _) async => fail('ran a second owner'));
    expect(await worker.run(FeedCheckTask.autoDownload), isTrue);
    expect(appRan, [FeedCheckTask.autoDownload]);
  });

  test('an app name that doesn’t answer is passed over and the worker '
      'runs the check', () async {
    final dead = ReceivePort()..close();
    directory.names[feedCheckAppPortName] = dead.sendPort;
    var ran = false;
    final worker = FeedCheckWorker(
        directory: directory,
        pingTimeout: const Duration(milliseconds: 50),
        runHere: (_, _) async => ran = true);
    expect(await worker.run(FeedCheckTask.check), isTrue);
    expect(ran, isTrue);
  });

  test('a worker name left by a destroyed engine does not stop the next '
      'worker', () async {
    final dead = ReceivePort()..close();
    directory.names[feedCheckWorkerPortName] = dead.sendPort;
    var ran = false;
    final worker = FeedCheckWorker(
        directory: directory,
        pingTimeout: const Duration(milliseconds: 50),
        runHere: (_, _) async => ran = true);
    expect(await worker.run(FeedCheckTask.check), isTrue);
    expect(ran, isTrue);
  });

  test('a worker name left by a destroyed engine does not hold the app '
      'start for the long wait', () async {
    final dead = ReceivePort()..close();
    directory.names[feedCheckWorkerPortName] = dead.sendPort;
    final host = FeedCheckHost(
        directory: directory,
        pingTimeout: const Duration(milliseconds: 50),
        yieldTimeout: const Duration(seconds: 30),
        runTask: (_, _) async => true);
    addTearDown(host.close);
    await host.open().timeout(const Duration(seconds: 2));
    expect(directory.lookup(feedCheckWorkerPortName), isNull);
  });

  test('the system stopping a worker that handed over stops the app’s run',
      () async {
    final started = Completer<void>();
    final host = FeedCheckHost(
        directory: directory,
        runTask: (_, stop) async {
          started.complete();
          while (!stop.requested) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          return true;
        });
    await host.open();
    addTearDown(host.close);
    final worker = FeedCheckWorker(
        directory: directory,
        runHere: (_, _) async => fail('ran a second owner'));
    final running = worker.run(FeedCheckTask.autoDownload);
    await started.future;
    worker.stop();
    expect(await running.timeout(const Duration(seconds: 2)), isTrue);
  });

  test('an app opening mid-check waits until the worker has wound down',
      () async {
    final release = Completer<void>();
    final stopSeen = Completer<void>();
    final worker = FeedCheckWorker(
        directory: directory,
        runHere: (_, stop) async {
          while (!stop.requested) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          stopSeen.complete();
          await release.future;
          return true;
        });
    final running = worker.run(FeedCheckTask.check);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final host = FeedCheckHost(
        directory: directory, runTask: (_, _) async => true);
    addTearDown(host.close);
    var opened = false;
    final opening = host.open().then((_) => opened = true);
    await stopSeen.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(opened, isFalse, reason: 'the worker still holds its work');

    release.complete();
    await opening;
    expect(opened, isTrue);
    expect(await running, isTrue);
  });

  test('an app opening with no worker running opens at once', () async {
    final host = FeedCheckHost(
        directory: directory,
        yieldTimeout: const Duration(seconds: 30),
        runTask: (_, _) async => true);
    addTearDown(host.close);
    await host.open().timeout(const Duration(seconds: 1));
  });

  test('a second worker while one runs says try again later', () async {
    final release = Completer<bool>();
    final first = FeedCheckWorker(
        directory: directory, runHere: (_, _) => release.future);
    final running = first.run(FeedCheckTask.check);
    await Future<void>.delayed(Duration.zero);

    final second = FeedCheckWorker(
        directory: directory, runHere: (_, _) async => fail('ran twice'));
    expect(await second.run(FeedCheckTask.autoDownload), isFalse);
    release.complete(true);
    expect(await running, isTrue);
  });

  test('the app runs handed-over tasks one at a time', () async {
    var active = 0, maxActive = 0;
    final host = FeedCheckHost(
        directory: directory,
        runTask: (_, _) async {
          active++;
          maxActive = active > maxActive ? active : maxActive;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          active--;
          return true;
        });
    await host.open();
    addTearDown(host.close);
    final app = directory.lookup(feedCheckAppPortName)!;
    final replies = [ReceivePort(), ReceivePort()];
    app.send(['run', 'check', 'a', replies[0].sendPort]);
    app.send(['run', 'autoDownload', 'b', replies[1].sendPort]);
    expect(await replies[0].first, isTrue);
    expect(await replies[1].first, isTrue);
    expect(maxActive, 1);
  });

  test('a stop names its own hand-over; another worker’s task carries on',
      () async {
    final stops = <String, StopSignal>{};
    final host = FeedCheckHost(
        directory: directory,
        runTask: (task, stop) async {
          stops[task.name] = stop;
          return true;
        });
    await host.open();
    addTearDown(host.close);
    final app = directory.lookup(feedCheckAppPortName)!;
    final reply = ReceivePort();
    addTearDown(reply.close);
    app.send(['run', 'check', 'first', reply.sendPort]);
    await reply.first;
    // The first run has finished; a stop for another id touches nothing.
    app.send(['stop', 'someone-else']);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(stops['check']!.requested, isFalse);
  });
}

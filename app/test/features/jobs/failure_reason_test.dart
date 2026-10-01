import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/jobs/failure_reason.dart';
import 'package:trellis/features/models/model_store.dart';
import 'package:trellis/features/transcribe/decoder.dart';

/// A failed job tells the person what happened in words they can act on.
/// Offline and out-of-space must never read the same.
void main() {
  final req = RequestOptions(path: 'https://cast.test/1.mp3');

  test('no connection says so', () {
    expect(
      plainFailureReason(
          DioException(requestOptions: req, type: DioExceptionType.connectionError)),
      contains('connection'),
    );
    expect(plainFailureReason(const SocketException('down')),
        contains('connection'));
  });

  test('a vanished file says the address stopped working', () {
    final err = DioException(
      requestOptions: req,
      type: DioExceptionType.badResponse,
      response: Response(requestOptions: req, statusCode: 404),
    );
    expect(plainFailureReason(err), contains('isn’t there any more'));
  });

  test('a full disk says so', () {
    const err = FileSystemException(
        'write failed', '/x', OSError('No space left on device', 28));
    expect(plainFailureReason(err), contains('out of space'));
  });

  test('unreadable audio and a damaged model each get their own words', () {
    expect(plainFailureReason(DecodeException('bad')), contains('couldn’t be read'));
    expect(plainFailureReason(ModelIntegrityException('sha mismatch')),
        contains('damaged'));
  });

  test('anything else is calm and never a stack trace', () {
    final reason = plainFailureReason(StateError('internal detail'));
    expect(reason, isNot(contains('internal detail')));
    expect(reason, isNotEmpty);
  });
}

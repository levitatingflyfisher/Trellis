/// Turns whatever stopped a job into one sentence a person can act on.
/// Every failure screen shows the same line, so "you're offline" and
/// "the phone is full" never look alike.
library;

import 'dart:io';

import 'package:comms_core/comms_core.dart' show CommsException;
import 'package:dio/dio.dart';
import 'package:domovoi/domovoi.dart' show TruncatedTransfer;

import '../models/model_store.dart';
import '../transcribe/decoder.dart';

/// Thrown by a job that retried and still could not finish, carrying the
/// line to show.
class JobGaveUp implements Exception {
  final String reason;
  const JobGaveUp(this.reason);

  @override
  String toString() => reason;
}

/// What a failed job says when nothing more specific was recorded.
const genericFailureReason = 'Something went wrong. Trying again usually helps.';

const _offline =
    'Couldn’t reach the server. Check your connection, then try again.';

/// A lost connection is the commonest interruption there is; a job it
/// stops should carry on by itself next launch, not wait for a tap.
bool isTransientFailure(Object err) {
  if (err is SocketException) return true;
  if (err is DioException) {
    switch (err.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return true;
      default:
        return err.error is SocketException;
    }
  }
  return false;
}

String plainFailureReason(Object err) {
  if (err is JobGaveUp) return err.reason;
  if (err is SocketException) return _offline;
  if (err is DioException) {
    switch (err.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return _offline;
      case DioExceptionType.badResponse:
        final code = err.response?.statusCode;
        if (code == 404 || code == 410) {
          return 'The file isn’t there any more. The feed may have moved it.';
        }
        return 'The server turned the request down (error $code). '
            'Try again later.';
      default:
        if (err.error is SocketException) return _offline;
        if (err.error != null) return plainFailureReason(err.error!);
    }
  }
  if (err is FileSystemException && err.osError?.errorCode == 28) {
    return 'This phone is out of space. Free some up, then try again.';
  }
  if (err is DecodeException) {
    return 'This audio couldn’t be read. It may be damaged or an odd format.';
  }
  // comms_core's refusals (an address on the LAN, a size cap) already
  // carry a sentence written for the screen.
  if (err is CommsException) return err.message;
  if (err is TruncatedTransfer) {
    return 'The download stopped early. Try again.';
  }
  if (err is ModelIntegrityException) {
    return 'The model download was damaged. Trying again fetches it fresh.';
  }
  return genericFailureReason;
}

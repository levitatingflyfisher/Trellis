/// The web stub must offer every name the native side does.
///
/// `whisper_ffi.dart` swaps `bindings.dart` and `transcriber.dart` for
/// `unsupported.dart` under dart2js, so any public name the native files
/// gain and the stub lacks compiles on Android and breaks only the web
/// build (the October fold shipped `WhisperTranscriber.threads` that way).
/// Nothing in a VM test compiles the stub against the app's uses, so this
/// compares the two surfaces directly: top-level names, each class's
/// members and supertypes, and constructor parameters with defaults.
///
/// Exempt: anything whose signature needs dart:ffi (the shim's symbol
/// table can't exist without it), and the stub's test-only constructor.
@TestOn('vm')
library;

import 'dart:mirrors';

import 'package:test/test.dart';
import 'package:whisper_ffi/src/bindings.dart' as native_bindings;
import 'package:whisper_ffi/src/transcriber.dart' as native_transcriber;
import 'package:whisper_ffi/src/unsupported.dart' as stub;

/// The binding table for the per-window state set: every use of it goes
/// through raw pointers, and the app never names it.
const _ffiOnlyClasses = {'WhisperStateBindings'};

/// Stub-only members that exist so its own tests can reach the refusals.
const _stubOnly = {'WhisperBindings.WhisperBindings.any'};

LibraryMirror _lib(Type t) => reflectClass(t).owner as LibraryMirror;

String _n(Symbol s) => MirrorSystem.getName(s);

bool _mentionsFfi(TypeMirror t, [Set<TypeMirror>? seen]) {
  seen ??= {};
  if (!seen.add(t)) return false;
  final owner = t.owner;
  if (owner is LibraryMirror && owner.uri.toString() == 'dart:ffi') {
    return true;
  }
  if (_ffiOnlyClasses.contains(_n(t.simpleName))) return true;
  if (t is TypedefMirror) return _mentionsFfi(t.referent, seen);
  if (t is FunctionTypeMirror) {
    return _mentionsFfi(t.returnType, seen) ||
        t.parameters.any((p) => _mentionsFfi(p.type, seen));
  }
  if (t is ClassMirror && !t.isOriginalDeclaration) {
    return t.typeArguments.any((a) => _mentionsFfi(a, seen));
  }
  return false;
}

String _type(TypeMirror t) {
  if (t is ClassMirror && t.typeArguments.isNotEmpty) {
    return '${_n(t.simpleName)}<${t.typeArguments.map(_type).join(', ')}>';
  }
  return _n(t.simpleName);
}

String _param(ParameterMirror p) {
  final kind = p.isNamed ? 'named' : (p.isOptional ? 'optional' : 'positional');
  final def = p.hasDefaultValue ? ' = ${p.defaultValue?.reflectee}' : '';
  return '$kind ${_type(p.type)} ${_n(p.simpleName)}$def';
}

bool _ffiBound(DeclarationMirror d) => switch (d) {
      VariableMirror v => _mentionsFfi(v.type),
      MethodMirror m => _mentionsFfi(m.returnType) ||
          m.parameters.any((p) => _mentionsFfi(p.type)),
      TypeMirror t => _mentionsFfi(t),
      _ => false,
    };

/// One line per public, non-ffi member, phrased so a field and a getter
/// of the same type read the same (the stub may implement either way).
Set<String> _classSurface(ClassMirror c) {
  final out = <String>{
    for (final i in c.superinterfaces)
      '${_n(c.simpleName)} implements ${_type(i)}',
  };
  for (final d in c.declarations.values) {
    if (d.isPrivate || _ffiBound(d)) continue;
    final name = '${_n(c.simpleName)}.${_n(d.simpleName)}';
    if (_stubOnly.contains(name)) continue;
    if (d is VariableMirror) {
      final s = d.isStatic ? 'static ' : '';
      out.add('${s}get $name: ${_type(d.type)}');
      if (!d.isFinal && !d.isConst) out.add('${s}set $name');
    } else if (d is MethodMirror) {
      final s = d.isStatic ? 'static ' : '';
      final params = d.parameters.map(_param).join(', ');
      if (d.isConstructor) {
        out.add('new $name($params)');
      } else if (d.isGetter) {
        out.add('${s}get $name: ${_type(d.returnType)}');
      } else if (d.isSetter) {
        out.add('${s}set $name');
      } else {
        out.add('$s$name($params): ${_type(d.returnType)}');
      }
    }
  }
  return out;
}

Set<String> _surface(Iterable<LibraryMirror> libs) {
  final out = <String>{};
  for (final lib in libs) {
    for (final d in lib.declarations.values) {
      if (d.isPrivate || _ffiBound(d)) continue;
      if (d is ClassMirror) {
        out.add('class ${_n(d.simpleName)}');
        out.addAll(_classSurface(d));
      } else if (d is MethodMirror) {
        final params = d.parameters.map(_param).join(', ');
        out.add('${_n(d.simpleName)}($params): ${_type(d.returnType)}');
      } else if (d is VariableMirror) {
        out.add('top-level ${_n(d.simpleName)}: ${_type(d.type)}');
      }
    }
  }
  return out;
}

void main() {
  final native = _surface([
    _lib(native_bindings.WhisperBindings),
    _lib(native_transcriber.WhisperTranscriber),
  ]);
  final web = _surface([_lib(stub.WhisperTranscriber)]);

  test('the web stub has every public name the native files export', () {
    expect(native.difference(web), isEmpty,
        reason: 'add these to lib/src/unsupported.dart (refusing), or the '
            'web build breaks the first time the app uses them');
  });

  test('the web stub declares nothing the native side lacks', () {
    expect(web.difference(native), isEmpty);
  });

  test('the comparison actually sees the transcriber', () {
    // Guards the guard: a mirrors change that emptied both sides would
    // pass the two tests above vacuously.
    expect(native, contains('get WhisperTranscriber.threads: int'));
    expect(native, contains('new WhisperBindings.WhisperBindings.open('
        'positional String path)'));
  });
}

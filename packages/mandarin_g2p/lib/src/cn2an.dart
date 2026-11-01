/// Arabic numerals to Chinese numerals, a port of cn2an 0.5.24's
/// `Transform.transform(text, 'an2cn')` and the `An2Cn` class it calls
/// (github.com/Ailln/cn2an, MIT License, Copyright (c) 2019 Ailln).
///
/// Python's regex `\d` matches every Unicode decimal digit, so the
/// patterns here use [pyDigitClass] in its place. As in cn2an, a number
/// that cannot be converted (more than 16 digits, or digits from another
/// script) is left as it was.
library;

import 'py_text.dart';

const _measureWords = '斤|克|千克|公斤|吨|米|厘米|毫米|公里|升|毫升|元|角|分|个|只|条|张|块|瓶|杯|份|本|'
    '辆|台|匹|头|位|亩|小时|分钟|秒|天|半';

const _numberLow = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
const _unitLowOrder = [
  '', '十', '百', '千', '万', '十', '百', '千', //
  '亿', '十', '百', '千', '万', '十', '百', '千',
];

final String _d = '[$pyDigitClass]';
RegExp _re(String p) => RegExp(p, unicode: true);

final _rangeRe = _re('$_d+(\\.$_d+)?-$_d+(\\.$_d+)?(?=($_measureWords))');
final _dateRe = _re('($_d{2,4}年)?($_d{1,2}月)?($_d{1,2}日)?');
final _fractionRe = _re('$_d+/$_d+');
final _percentRe = _re('-?($_d+\\.)?$_d+%');
final _celsiusRe = _re('$_d+℃');
final _numberRe = _re('-?($_d+\\.)?$_d+');
final _yearDigitsRe = _re('$_d+(?=年)');
final _digitsRe = _re('$_d+');
final _wanYiRe = RegExp('([万亿])零([一二三四五六七八九壹贰叁肆伍陆柒捌玖][千仟])');

/// `cn2an.transform(text, 'an2cn')`.
String an2cnTransform(String inputs) {
  inputs = inputs.replaceAllMapped(_rangeRe, (m) => _sub(m[0]!, 'range'));
  inputs = inputs.replaceAllMapped(_dateRe, (m) => _sub(m[0]!, 'date'));
  inputs = inputs.replaceAllMapped(_fractionRe, (m) => _sub(m[0]!, 'fraction'));
  inputs = inputs.replaceAllMapped(_percentRe, (m) => _sub(m[0]!, 'percent'));
  inputs = inputs.replaceAllMapped(_celsiusRe, (m) => _sub(m[0]!, 'celsius'));
  return inputs.replaceAllMapped(_numberRe, (m) => _sub(m[0]!, 'number'));
}

String _sub(String inputs, String mode) {
  if (inputs.isEmpty) return inputs;
  try {
    switch (mode) {
      case 'date':
        final s = inputs.replaceAllMapped(
            _yearDigitsRe, (m) => an2cn(m[0]!, direct: true));
        return s.replaceAllMapped(_digitsRe, (m) => an2cn(m[0]!));
      case 'fraction':
        final f = inputs.replaceAllMapped(_digitsRe, (m) => an2cn(m[0]!));
        final parts = f.split('/');
        if (parts.length != 2) throw const FormatException('fraction');
        return '${parts[1]}分之${parts[0]}';
      case 'celsius':
        return '${an2cn(_dropLast(inputs))}摄氏度';
      case 'percent':
        return '百分之${an2cn(_dropLast(inputs))}';
      case 'range':
        final parts = inputs.split('-');
        if (parts.length != 2) throw const FormatException('range');
        return '${an2cn(parts[0])}到${an2cn(parts[1])}';
      default:
        return an2cn(inputs);
    }
  } on FormatException {
    // cn2an warns and keeps the text as it was.
    return inputs;
  }
}

String _dropLast(String s) {
  final r = s.runes.toList();
  return String.fromCharCodes(r, 0, r.length - 1);
}

/// `An2Cn().an2cn(inputs, 'low')`, or `'direct'` when [direct] is true.
/// Throws [FormatException] where cn2an raises.
String an2cn(String inputs, {bool direct = false}) {
  if (inputs.isEmpty) throw const FormatException('empty');
  // proces' full_angle_to_half_angle (traditional_to_simplified changes
  // no character that can reach here).
  final b = StringBuffer();
  for (var c in inputs.runes) {
    if (c == 12288) {
      c = 32;
    } else if (c >= 65281 && c <= 65374) {
      c -= 65248;
    }
    b.writeCharCode(c);
  }
  inputs = b.toString();
  for (final c in inputs.codeUnits) {
    if (!((c >= 0x30 && c <= 0x39) || c == 0x2E || c == 0x2D)) {
      throw const FormatException('not a number');
    }
  }
  var sign = '';
  if (inputs[0] == '-') {
    sign = '负';
    inputs = inputs.substring(1);
  }
  String output;
  if (direct) {
    final o = StringBuffer();
    for (final ch in inputs.split('')) {
      if (ch == '.') {
        o.write('点');
      } else {
        o.write(_numberLow[_int(ch)]);
      }
    }
    output = o.toString();
  } else {
    final split = inputs.split('.');
    if (split.length == 1) {
      output = _integer(split[0]);
    } else if (split.length == 2) {
      output = _integer(split[0]) + _decimal(split[1]);
    } else {
      throw const FormatException('format');
    }
  }
  return sign + output;
}

int _int(String s) {
  final v = int.tryParse(s);
  if (v == null || s.contains('-')) throw const FormatException('int');
  return v;
}

String _integer(String data) {
  if (data.isEmpty) throw const FormatException('int');
  // str(int(data)): drop leading zeros.
  var i = 0;
  while (i < data.length - 1 && data[i] == '0') {
    i++;
  }
  data = data.substring(i);
  if (data.length > _unitLowOrder.length) {
    throw const FormatException('too long');
  }
  final n = data.length;
  var out = '';
  for (var i = 0; i < n; i++) {
    final d = _int(data[i]);
    if (d != 0) {
      out += _numberLow[d] + _unitLowOrder[n - i - 1];
    } else {
      if ((n - i - 1) % 4 == 0) {
        out += _numberLow[d] + _unitLowOrder[n - i - 1];
      }
      if (i > 0 && !out.endsWith('零')) {
        out += _numberLow[d];
      }
    }
  }
  out = out
      .replaceAll('零零', '零')
      .replaceAll('零万', '万')
      .replaceAll('零亿', '亿')
      .replaceAll('亿万', '亿');
  out = _stripChar(out, '零');
  out = out.replaceAllMapped(_wanYiRe, (m) => '${m[1]}${m[2]}');
  if (out.startsWith('一十')) out = out.substring(1);
  if (out.isEmpty) out = '零';
  return out;
}

String _decimal(String data) {
  if (data.length > 16) data = data.substring(0, 16);
  final o = StringBuffer(data.isEmpty ? '' : '点');
  for (final ch in data.split('')) {
    o.write(_numberLow[_int(ch)]);
  }
  return o.toString();
}

String _stripChar(String s, String ch) {
  var a = 0;
  var b = s.length;
  while (a < b && s[a] == ch) {
    a++;
  }
  while (b > a && s[b - 1] == ch) {
    b--;
  }
  return s.substring(a, b);
}

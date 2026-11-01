/// Numbers written out in Hangul, as they are read: the Korean voice reads
/// only Hangul.
///
/// Korean counts two ways. Before the counters in [_nativeCounters] (시,
/// 개, 명, 살, 마리 ...) a number from 1 to 99 is native (세 시, 스무 살);
/// everything else is Sino-Korean (삼십 분, 이천이십육 년, 백 명). A one
/// before 십, 백, 천 and 만 is not said (십, 백, 천, 만); before 억 and 조 it
/// is (일억). A comma between digit groups is dropped, and a point inside
/// a number is 점.
library;

const _digits = ['영', '일', '이', '삼', '사', '오', '육', '칠', '팔', '구'];
const _places = ['', '십', '백', '천'];
const _groups = ['', '만', '억', '조', '경'];

const _nativeOnes = ['', '한', '두', '세', '네', '다섯', '여섯', '일곱', '여덟', '아홉'];
const _nativeTens = ['', '열', '스물', '서른', '마흔', '쉰', '예순', '일흔', '여든', '아흔'];

/// Counters a number up to 99 is counted with in native numbers.
const _nativeCounters = [
  '시간', '시', '개', '명', '살', '마리', '번', '잔', '권', '장', '사람', '달',
  '병', '그릇', '켤레', '송이', '군데', '가지', '곳',
];

/// [n] in Sino-Korean.
String sinoKorean(BigInt n) {
  if (n == BigInt.zero) return _digits[0];
  final out = StringBuffer();
  final groups = <int>[];
  var rest = n;
  final tenK = BigInt.from(10000);
  while (rest > BigInt.zero) {
    groups.add((rest % tenK).toInt());
    rest = rest ~/ tenK;
  }
  for (var g = groups.length - 1; g >= 0; g--) {
    final value = groups[g];
    if (value == 0) continue;
    if (value == 1 && g == 1) {
      out.write('만'); // 일만 is said 만
      continue;
    }
    final digits = value.toString().padLeft(4, '0');
    for (var i = 0; i < 4; i++) {
      final d = int.parse(digits[i]);
      final place = 3 - i;
      if (d == 0) continue;
      if (!(d == 1 && place > 0)) out.write(_digits[d]);
      out.write(_places[place]);
    }
    out.write(_groups[g]);
  }
  return out.toString();
}

/// [n], 1 to 99, in native numbers as said before a counter (스무, not
/// 스물, before a counter; 한, 두, 세, 네 for 1 to 4).
String nativeKorean(int n) {
  final tens = n ~/ 10, ones = n % 10;
  if (ones == 0 && tens == 2) return '스무';
  return '${_nativeTens[tens]}${_nativeOnes[ones]}';
}

final _number = RegExp(r'\d{1,3}(?:,\d{3})+(?!\d)|\d+(?:\.\d+)?');

/// [text] with every number written out in Hangul.
String spellNumbers(String text) => text.replaceAllMapped(_number, (m) {
      final raw = m.group(0)!.replaceAll(',', '');
      final after = text.substring(m.end).trimLeft();
      if (raw.contains('.')) {
        final [whole, fraction] = raw.split('.');
        return '${sinoKorean(BigInt.parse(whole))}점'
            '${fraction.split('').map((d) => _digits[int.parse(d)]).join()}';
      }
      final n = BigInt.parse(raw);
      if (n >= BigInt.one &&
          n < BigInt.from(100) &&
          _nativeCounters.any(after.startsWith)) {
        return nativeKorean(n.toInt());
      }
      return sinoKorean(n);
    });

// Numbers written out for the Korean voice, which reads only Hangul.
import 'package:korean_g2p/korean_g2p.dart';
import 'package:test/test.dart';

void main() {
  test('Sino-Korean numbers by place', () {
    expect(spellNumbers('0'), '영');
    expect(spellNumbers('10'), '십');
    expect(spellNumbers('11'), '십일');
    expect(spellNumbers('105'), '백오');
    expect(spellNumbers('2026년'), '이천이십육년');
    expect(spellNumbers('10000원'), '만원');
    expect(spellNumbers('35000원'), '삼만오천원');
    expect(spellNumbers('120000'), '십이만');
    expect(spellNumbers('100000000'), '일억');
    expect(spellNumbers('3월 17일'), '삼월 십칠일');
  });

  test('native numbers before the counters that take them', () {
    expect(spellNumbers('3시 30분'), '세시 삼십분');
    expect(spellNumbers('1개'), '한개');
    expect(spellNumbers('2명'), '두명');
    expect(spellNumbers('20살'), '스무살');
    expect(spellNumbers('21살'), '스물한살');
    expect(spellNumbers('45마리'), '마흔다섯마리');
    expect(spellNumbers('12시'), '열두시');
    // Past 99, counters take Sino-Korean numbers.
    expect(spellNumbers('100명'), '백명');
  });

  test('a decimal point and a thousands comma', () {
    expect(spellNumbers('3.5'), '삼점오');
    expect(spellNumbers('1,500원'), '천오백원');
  });

  test('text without digits is unchanged, and spelt numbers can be said',
      () {
    expect(spellNumbers('책을 읽어요.'), '책을 읽어요.');
    expect(phonemes(spellNumbers('2개')), ['t', 'u', 'ɡ', 'ɛ']);
  });
}

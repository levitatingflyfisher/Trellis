// Korean pronunciation for the tiny Korean voice (owner, 17 Nov 2026).
// The examples are those of the standard pronunciation rules
// (표준 발음법, the National Institute of Korean Language), article by
// article.
import 'package:korean_g2p/korean_g2p.dart';
import 'package:test/test.dart';

void main() {
  group('the sounds a word is said with, written in Hangul', () {
    void says(Map<String, String> cases) {
      for (final e in cases.entries) {
        expect(pronounce(e.key), e.value, reason: e.key);
      }
    }

    test('a final consonant is one of seven sounds (articles 9-11)', () {
      says({
        '닦다': '닥따', '키읔': '키윽', '옷': '옫', '웃다': '욷따',
        '있다': '읻따', '젖': '젇', '꽃': '꼳', '솥': '솓', '앞': '압',
        '넋': '넉', '앉다': '안따', '여덟': '여덜', '외곬': '외골',
        '핥다': '할따', '값': '갑', '닭': '닥', '삶': '삼',
      });
    });

    test('a final ㅎ joins the next consonant, or goes (article 12)', () {
      says({
        '놓고': '노코', '좋던': '조턴', '쌓지': '싸치', '많고': '만코',
        '않던': '안턴', '닳지': '달치', '각하': '가카', '먹히다': '머키다',
        '좁히다': '조피다', '넓히다': '널피다', '꽂히다': '꼬치다',
        '앉히다': '안치다', '놓는': '논는', '쌓네': '싼네', '놓아': '노아',
        '좋아': '조아', '않은': '아는', '싫어도': '시러도',
      });
    });

    test('a final consonant moves to an empty next syllable (articles 13-14)',
        () {
      says({
        '깎아': '까까', '옷이': '오시', '있어': '이써', '꽂아': '꼬자',
        '꽃을': '꼬츨', '밭에': '바테', '앞으로': '아프로', '덮이다': '더피다',
        '넋이': '넉씨', '앉아': '안자', '닭을': '달글', '젊어': '절머',
        '곬이': '골씨', '핥아': '할타', '읊어': '을퍼', '값을': '갑쓸',
      });
    });

    test('ㄷ and ㅌ before 이 are ㅈ and ㅊ (article 17)', () {
      says({'곧이듣다': '고지듣따', '굳이': '구지', '미닫이': '미다지',
            '땀받이': '땀바지', '밭이': '바치', '벼훑이': '벼훌치',
            '굳히다': '구치다', '닫히다': '다치다', '묻히다': '무치다'});
      // A ㅌ that was always there stays before 이.
      says({'티': '티', '느티나무': '느티나무'});
    });

    test('a stop before a nasal is a nasal (articles 18-19)', () {
      says({
        '먹는': '멍는', '국물': '궁물', '깎는': '깡는', '키읔만': '키응만',
        '몫몫이': '몽목씨', '긁는': '긍는', '닫는': '단는', '짓는': '진는',
        '옷맵시': '온맵씨', '있는': '인는', '맞는': '만는', '젖멍울': '전멍울',
        '쫓는': '쫀는', '꽃망울': '꼰망울', '붙는': '분는', '놓는': '논는',
        '잡는': '잠는', '밥물': '밤물', '앞마당': '암마당', '없는': '엄는',
        '담력': '담녁', '침략': '침냑', '강릉': '강능', '항로': '항노',
        '막론': '망논', '백리': '뱅니', '협력': '혐녁', '십리': '심니',
      });
    });

    test('ㄴ next to ㄹ is ㄹ (article 20)', () {
      says({'난로': '날로', '신라': '실라', '천리': '철리', '광한루': '광할루',
            '칼날': '칼랄', '물난리': '물랄리',
            '할는지': '할른지'});
    });

    test('a lenis consonant after a stop is tense (article 23)', () {
      says({
        '국밥': '국빱', '깎다': '깍따', '넋받이': '넉빠지', '삯돈': '삭똔',
        '닭장': '닥짱', '칡범': '칙뻠', '뻗대다': '뻗때다', '옷고름': '옫꼬름',
        '있던': '읻떤', '꽂고': '꼳꼬', '꽃다발': '꼳따발', '낯설다': '낟썰다',
        '밭갈이': '받까리', '솥전': '솓쩐', '곱돌': '곱똘', '덮개': '덥깨',
        '옆집': '엽찝', '읊조리다': '읍쪼리다',
        '값지다': '갑찌다',
      });
    });

    test('ㅢ after a consonant is ㅣ (article 5)', () {
      says({'희망': '히망', '띄어쓰기': '띠어쓰기', '유희': '유히'});
    });

    test('each word on its own: a final consonant does not move across a '
        'space', () {
      expect(pronounce('옷 안'), '옫 안');
    });

    test('anything that is not Hangul passes through', () {
      expect(pronounce('책, 그리고 펜!'), '책, 그리고 펜!');
    });
  });

  group('phonemes', () {
    test('Hangul to the aligner’s labels, with lenis stops voiced between '
        'voiced sounds and ㄹ a tap between vowels', () {
      expect(phonemes('가다'), ['k', 'a', 'd', 'a']);
      expect(phonemes('바보'), ['p', 'a', 'b', 'o']);
      expect(phonemes('나라'), ['n', 'a', 'ɾ', 'a']);
      expect(phonemes('달'), ['t', 'a', 'l']);
      expect(phonemes('물론'), ['m', 'u', 'l', 'l', 'o', 'n']);
    });

    test('aspirated and tense consonants keep their own labels', () {
      expect(phonemes('카타파차'), ['kʰ', 'a', 'tʰ', 'a', 'pʰ', 'a', 'tɕh', 'a']);
      expect(phonemes('까따빠짜'), ['kː', 'a', 'tː', 'a', 'pː', 'a', 'tʃː', 'a']);
    });

    test('vowels and glides', () {
      expect(phonemes('어으애에'), ['ʌ', 'ɯ', 'ɛ', 'e']);
      expect(phonemes('야여요유'), ['j', 'a', 'j', 'ʌ', 'j', 'o', 'j', 'u']);
      expect(phonemes('와워위의'), ['w', 'a', 'w', 'ʌ', 'w', 'i', 'ɯ', 'i']);
    });

    test('ㅅ before ㅣ is ɕ; ㅇ at the end is ŋ, at the start nothing', () {
      expect(phonemes('시'), ['ɕ', 'i']);
      expect(phonemes('강'), ['k', 'a', 'ŋ']);
      expect(phonemes('아이'), ['a', 'i']);
    });

    test('words are split by a space token, and punctuation stays', () {
      expect(phonemes('네, 좋아요.'),
          ['n', 'e', ',', ' ', 'tɕ', 'o', 'a', 'j', 'o', '.']);
    });

    test('the sound rules come first: 국물 is said 궁물', () {
      expect(phonemes('국물'), ['k', 'u', 'ŋ', 'm', 'u', 'l']);
    });
  });
}

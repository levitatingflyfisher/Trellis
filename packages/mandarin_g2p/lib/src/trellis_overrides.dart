/// Trellis's own word readings, loaded on top of pypinyin's phrase table
/// the way misaki loads its own `phrases_dict` (pypinyin's
/// `load_phrases_dict`). This list is Trellis's work (MIT); a word's
/// reading is a fact.
///
/// Why: Trellis does not ship pypinyin-dict's `large_pinyin` (its
/// CC-CEDICT data is CC-BY-SA). Without it, misaki reads a few common
/// words wrong. Each entry below fixes a word seen in a golden line
/// (r1615 `large_pinyin_diff.json`) and was checked twice: it equals the
/// reading misaki gives with `large_pinyin` loaded, and it equals the
/// Mandarin reading on English Wiktionary (en.wiktionary.org, the
/// traditional-character entry, read 13 Nov 2026). A word where the two
/// disagreed was left out:
///
///  * 学生, 心里, 军事力量 (力量): `large_pinyin` gives a neutral tone;
///    Wiktionary's standard reading is the full tone (xuéshēng, xīnlǐ,
///    lìliàng), which is what pypinyin already gives.
///  * 一场: `large_pinyin` gives chǎng; Wiktionary's 場 gives cháng for
///    events (一場戰爭) and chǎng for sports and shows, so the reading
///    depends on the noun, and the four golden lines are events.
///  * 说说笑笑: `large_pinyin` gives shuō shuo; Wiktionary gives
///    shuōshuōxiàoxiào.
///  * 肖恩 (Sean): Wiktionary has no entry; 肖 as a name is xiāo there,
///    `large_pinyin` gives xiāo, but no source covers the word itself.
///  * 跑上去: `large_pinyin` reads 上 as shǎng; no fix needed.
///
/// Each value is one list per character, its first item the reading, in
/// pypinyin's tone-mark style.
library;

const Map<String, List<List<String>>> trellisPhraseOverrides = {
  // Wiktionary 稱為 chēngwéi (为 "to be called"); ntrex-0037.
  '称之为': [
    ['chēng'],
    ['zhī'],
    ['wéi']
  ],
  // Wiktionary 最為 zuìwéi; ntrex-0085.
  '最为': [
    ['zuì'],
    ['wéi']
  ],
  // Wiktionary 直奔 zhíbèn; ntrex-0139.
  '直奔': [
    ['zhí'],
    ['bèn']
  ],
  // Wiktionary 男子 nánzǐ; ntrex-0151, 0193, 0865, 1693.
  '男子': [
    ['nán'],
    ['zǐ']
  ],
  // Wiktionary 朝鮮 Cháoxiǎn (standard in the Mainland); ntrex-0637,
  // 0745, 0751, 0763, 0769.
  '朝鲜': [
    ['cháo'],
    ['xiǎn']
  ],
  // Wiktionary 朝鮮半島 Cháoxiǎn Bàndǎo (Mainland); ntrex-0751.
  '朝鲜半岛': [
    ['cháo'],
    ['xiǎn'],
    ['bàn'],
    ['dǎo']
  ],
  // Wiktionary 丹佛 Dānfó (Denver); ntrex-0685.
  '丹佛': [
    ['dān'],
    ['fó']
  ],
  // Wiktionary 正當 zhèngdàng, "proper, legitimate" (standard); the word
  // 正当 alone also reads zhèngdāng ("just when"), so only the negated
  // form is fixed. ntrex-0901.
  '不正当': [
    ['bù'],
    ['zhèng'],
    ['dàng']
  ],
  // Wiktionary 性行為 xìngxíngwéi; ntrex-0901.
  '性行为': [
    ['xìng'],
    ['xíng'],
    ['wéi']
  ],
  // Wiktionary 應激 yìngjī; ntrex-1021.
  '应激': [
    ['yìng'],
    ['jī']
  ],
  // Wiktionary 危地馬拉 Wēidìmǎlā; ntrex-1033.
  '危地马拉': [
    ['wēi'],
    ['dì'],
    ['mǎ'],
    ['lā']
  ],
  // Wiktionary 營地 yíngdì; ntrex-1447.
  '营地': [
    ['yíng'],
    ['dì']
  ],
};

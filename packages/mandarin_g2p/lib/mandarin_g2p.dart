/// Mandarin text to Kokoro-82M v1.1-zh phonemes and token ids.
///
/// A pure-Dart port of the text front end Kokoro v1.1-zh was trained
/// with, so the model gets the same ids it saw in training:
///
///  * misaki `zh` v1.1 (github.com/hexgrad/misaki@fba1236, Apache-2.0,
///    Copyright hexgrad), whose `zh_frontend.py` and `tone_sandhi.py`
///    are adapted from PaddleSpeech (Apache-2.0, Copyright (c) 2021
///    PaddlePaddle Authors);
///  * jieba 0.42.1 (github.com/fxsjy/jieba, MIT, Copyright (c) 2013 Sun
///    Junyi): dictionary DAG and route, finalseg and posseg HMMs,
///    cut_for_search;
///  * pypinyin 0.55.0 (github.com/mozillazg/python-pinyin, MIT,
///    Copyright (c) 2016 mozillazg, 闲耘): lazy_pinyin with phrase
///    segmentation, strict initials and tone-3 finals, neutral tone 5;
///  * cn2an 0.5.24 (github.com/Ailln/cn2an, MIT, Copyright (c) 2019
///    Ailln): `transform(text, 'an2cn')`.
///
/// The data (jieba's dictionary and HMM tables, pypinyin's tables,
/// misaki's word lists) comes in as Strings the caller has read; this
/// package reads no files. pypinyin-dict's `large_pinyin` is not used
/// (its CC-CEDICT data is CC-BY-SA); a short list of Trellis's own word
/// readings fills the gaps that showed in the golden lines.
library;

import 'src/jieba.dart';
import 'src/jieba_dict.dart';
import 'src/jieba_hmm.dart';
import 'src/kokoro_zh.dart';
import 'src/pinyin.dart';
import 'src/trellis_overrides.dart';
import 'src/zh_frontend.dart';

export 'src/kokoro_zh.dart'
    show
        KokoroZhTokens,
        kokoroMaxPhonemes,
        kokoroZhIds,
        kokoroZhSpeed,
        kokoroZhVocab,
        splitKokoroPhonemes,
        styleRowFor;
export 'src/trellis_overrides.dart' show trellisPhraseOverrides;
export 'src/zh_frontend.dart'
    show ZhSegmentTrace, ZhToken, ZhTrace, ZhWordTrace;

class MandarinG2p {
  MandarinG2p._(this._frontend);

  /// Builds the front end from the data files' text (each file as
  /// published beside the model, `#` header line included):
  ///
  ///  * [jiebaDict]: `jieba_dict.txt`
  ///  * [finalsegHmm]: `jieba_finalseg_hmm.tsv`
  ///  * [possegHmm]: `jieba_posseg_hmm.tsv`
  ///  * [pinyinSingle]: `pypinyin_single.tsv`
  ///  * [pinyinPhrases]: `pypinyin_phrases.tsv`
  ///  * [pinyinAux]: `pypinyin_aux.json`
  ///  * [misakiTables]: `misaki_zh_tables.json`
  ///
  /// [trellisOverrides] loads Trellis's own word readings
  /// ([trellisPhraseOverrides]) after misaki's, so a few words read
  /// right without `large_pinyin`. Turn it off only to compare with plain
  /// misaki.
  factory MandarinG2p.fromData({
    required String jiebaDict,
    required String finalsegHmm,
    required String possegHmm,
    required String pinyinSingle,
    required String pinyinPhrases,
    required String pinyinAux,
    required String misakiTables,
    bool trellisOverrides = true,
  }) {
    final tables = MisakiTables.parse(misakiTables);
    final jieba = Jieba(
      JiebaDict.parse(jiebaDict),
      FinalsegHmm.parse(finalsegHmm),
      PossegHmm.parse(possegHmm),
    );
    final pinyin = PinyinTables.parse(
      single: pinyinSingle,
      phrases: pinyinPhrases,
      aux: pinyinAux,
      singleOverride: tables.singleOverride,
      phrasesOverride: {
        ...tables.phrasesOverride,
        if (trellisOverrides) ...trellisPhraseOverrides,
      },
    );
    return MandarinG2p._(ZhFrontend(jieba, pinyin, tables));
  }

  final ZhFrontend _frontend;

  /// misaki's phoneme string for [text] (`ZHG2P(version='1.1')(text)`),
  /// with its ids for Kokoro. When [trace] is given, every intermediate
  /// stage is recorded in it.
  ///
  /// Where misaki itself raises on a line (it can, on a few rare
  /// characters whose pinyin final is empty), this throws a [RangeError]
  /// or [ArgumentError] too.
  KokoroZhTokens g2p(String text, {ZhTrace? trace}) =>
      KokoroZhTokens(_frontend.call(text, trace: trace));

  /// [g2p], then split into pieces Kokoro can take in one call each
  /// ([splitKokoroPhonemes]). Each piece has its own length, style row
  /// and speed.
  List<KokoroZhTokens> g2pChunks(String text) => [
        for (final ps in splitKokoroPhonemes(_frontend.call(text)))
          KokoroZhTokens(ps),
      ];
}

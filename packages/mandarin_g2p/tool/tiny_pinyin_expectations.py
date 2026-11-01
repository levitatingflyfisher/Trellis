#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["pypinyin==0.55.0"]
# ///
"""Prints what real pypinyin 0.55.0 gives on the tiny unit-test tables in
test/fixtures/tiny/ (with misaki's overrides loaded the way misaki loads
them), so test/pinyin_test.dart can hold pypinyin's own answers.

Usage: tiny_pinyin_expectations.py test/fixtures/tiny
"""
import json
import os
import sys

import pypinyin.constants as C
from pypinyin import Style, lazy_pinyin, load_phrases_dict, load_single_dict
from pypinyin.seg import mmseg
from pypinyin.style._tone_convert import to_finals_tone3, to_initials


def rows(path):
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if line and not line.startswith('#'):
            yield line.split('\t')


def main():
    d = sys.argv[1]
    C.PINYIN_DICT.clear()
    C.PHRASES_DICT.clear()
    for cp, r in rows(os.path.join(d, 'pypinyin_single.tsv')):
        C.PINYIN_DICT[int(cp, 16)] = r
    for w, s in rows(os.path.join(d, 'pypinyin_phrases.tsv')):
        C.PHRASES_DICT[w] = [x.split(',') for x in s.split(' ')]
    mmseg.seg._prefix_set = mmseg.PrefixSet()
    mmseg.retrain(mmseg.seg)
    # misaki's own overrides (zh_frontend.py)
    load_phrases_dict({'不': [['bu4']], '嗲': [['dia3']]})
    load_single_dict({ord('地'): 'de,di4'})

    raws = ['ka1i', 'lüè', 'm̄', 'ê̄', 'ń', 'yuán', 'wǔ', 'jū', 'xiù', 'guǐ',
            'lùn', 'zhī', 'bei5', 'de', 'ér', 'yī', 'wén', 'yǔ', 'nǚ', 'hu4',
            'we2i', 'ng', 'ńg', 'yo', 'wēng', 'yīn', 'yìng', 'qióng', 'r', '一']
    texts = ['你好', '大学生们', '不好', '地', '大学', 'a大学b你', '嗯', '呣欸',
             '居秀鬼论之', '女儿', '纪律', '〇', '你好吗', '大不', '㐀你']
    out = {
        'initials': {r: to_initials(r, strict=True) for r in raws},
        'finalsTone3': {r: to_finals_tone3(r, strict=True) for r in raws},
        'lazyInitials': {t: lazy_pinyin(t, neutral_tone_with_five=True, style=Style.INITIALS)
                         for t in texts},
        'lazyFinals': {t: lazy_pinyin(t, neutral_tone_with_five=True, style=Style.FINALS_TONE3)
                       for t in texts},
    }
    print(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()

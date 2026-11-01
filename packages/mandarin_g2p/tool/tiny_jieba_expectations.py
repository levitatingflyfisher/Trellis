#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["jieba==0.42.1"]
# ///
"""Prints what real jieba 0.42.1 gives on the tiny unit-test tables in
test/fixtures/tiny/, so test/jieba_test.dart can hold jieba's own answers.

Usage: tiny_jieba_expectations.py test/fixtures/tiny
"""
import json
import os
import sys
import tempfile

import jieba
import jieba.finalseg as fs
import jieba.posseg as ps


def rows(path):
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if line and not line.startswith('#'):
            yield line.split('\t')


def hmm(path, tuple_states):
    key = (lambda s: tuple(s.split(','))) if tuple_states else (lambda s: s)
    start, trans, emit, cst = {}, {}, {}, {}
    for f in rows(path):
        if f[0] == 'S':
            start[key(f[1])] = float(f[2])
            trans.setdefault(key(f[1]), {})
            emit.setdefault(key(f[1]), {})
        elif f[0] == 'T':
            trans.setdefault(key(f[1]), {})[key(f[2])] = float(f[3])
        elif f[0] == 'E':
            emit.setdefault(key(f[1]), {})[f[2]] = float(f[3])
        elif f[0] == 'C':
            cst[f[1]] = tuple(key(s) for s in f[2].split(' '))
    return start, trans, emit, cst


def main():
    d = sys.argv[1]
    lines = [l for l in open(os.path.join(d, 'jieba_dict.txt'), encoding='utf-8')
             if not l.startswith('#')]
    tmp = tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False, encoding='utf-8')
    tmp.write(''.join(lines))
    tmp.close()
    tk = jieba.Tokenizer(dictionary=tmp.name)
    tk.tmp_dir = tempfile.gettempdir()
    fs.start_P, fs.trans_P, fs.emit_P, _ = hmm(os.path.join(d, 'jieba_finalseg_hmm.tsv'), False)
    ps.start_P, ps.trans_P, ps.emit_P, ps.char_state_tab_P = hmm(
        os.path.join(d, 'jieba_posseg_hmm.tsv'), True)
    pt = ps.POSTokenizer(tk)
    texts = ['我来到北京大学', '清华大学', '小明来到了清华', 'B超了abc12.5%不',
             '北京 大学\r\n了', '一天看看', '小红华']
    out = {
        'cut': {t: tk.lcut(t) for t in texts},
        'posCut': {t: [[w, f] for w, f in pt.lcut(t)] for t in texts},
        'cutForSearch': {t: tk.lcut_for_search(t) for t in texts},
    }
    os.unlink(tmp.name)
    print(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()

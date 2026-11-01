#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#   "misaki[zh] @ git+https://github.com/hexgrad/misaki@fba1236595f2d2bf21d414ba6e57d25256afada3",
#   "jieba==0.42.1",
#   "pypinyin==0.55.0",
#   "pypinyin-dict==0.9.0",
#   "cn2an==0.5.24",
#   "proces==0.1.7",
# ]
# ///
"""Runs real misaki zh v1.1 on a data folder (the seven files, in the
formats the Trellis data helper wrote) and prints, for each input line,
every stage in the shape of zh_g2p.json, plus direct calls of the tone
sandhi and erhua steps. pypinyin-dict's large_pinyin is not loaded.

Usage: tiny_misaki_expectations.py DATA_DIR LINES_TXT EXTRA_JSON
  LINES_TXT: one input per line. EXTRA_JSON: {"modified_tone": [[word,
  pos, finals], ...], "erhua": [[initials, finals, word, pos], ...],
  "pre_merge": [[[word, pos], ...], ...]}.
"""
import json
import os
import re
import sys
import tempfile
import types


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
    data, lines_path, extra_path = sys.argv[1:4]
    import jieba
    import jieba.finalseg as fs
    import jieba.posseg as ps
    import pypinyin.constants as C
    from pypinyin.seg import mmseg

    lines = [l for l in open(os.path.join(data, 'jieba_dict.txt'), encoding='utf-8')
             if not l.startswith('#')]
    tmp = tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False, encoding='utf-8')
    tmp.write(''.join(lines))
    tmp.close()
    tk = jieba.Tokenizer(dictionary=tmp.name)
    jieba.dt = tk
    jieba.cut_for_search = tk.cut_for_search
    fs.start_P, fs.trans_P, fs.emit_P, _ = hmm(os.path.join(data, 'jieba_finalseg_hmm.tsv'), False)
    ps.start_P, ps.trans_P, ps.emit_P, ps.char_state_tab_P = hmm(
        os.path.join(data, 'jieba_posseg_hmm.tsv'), True)
    ps.dt = ps.POSTokenizer(tk)

    C.PINYIN_DICT.clear()
    C.PHRASES_DICT.clear()
    for cp, r in rows(os.path.join(data, 'pypinyin_single.tsv')):
        C.PINYIN_DICT[int(cp, 16)] = r
    for w, s in rows(os.path.join(data, 'pypinyin_phrases.tsv')):
        C.PHRASES_DICT[w] = [x.split(',') for x in s.split(' ')]
    mmseg.seg._prefix_set = mmseg.PrefixSet()
    mmseg.retrain(mmseg.seg)

    import misaki.zh_frontend as zf
    zf.large_pinyin = types.SimpleNamespace(load=lambda: None)
    from misaki import zh
    import cn2an
    import contextlib
    with contextlib.redirect_stdout(sys.stderr):  # misaki prints a warning
        g2p = zh.ZHG2P(version='1.1')
    fe = g2p.frontend
    tm = fe.tone_modifier
    cfg = json.load(open(os.path.join(os.path.dirname(__file__), 'kokoro_v1_1_zh_vocab.json'), encoding='utf-8'))
    vocab = cfg['vocab']

    extra = json.load(open(extra_path, encoding='utf-8'))
    direct = {
        'modified_tone': [[w, p, f, tm.modified_tone(w, p, list(f))]
                          for w, p, f in extra.get('modified_tone', [])],
        'erhua': [[i, f, w, p, [list(x) for x in fe._merge_erhua(list(i), list(f), w, p)]]
                  for i, f, w, p in extra.get('erhua', [])],
        'pre_merge': [[seg, [list(x) for x in tm.pre_merge_for_modify([tuple(s) for s in seg])]]
                      for seg in extra.get('pre_merge', [])],
        'split_word': [[w, tm._split_word(w)] for w in extra.get('split_word', [])],
    }

    rec = {}
    orig_lcut = zf.psg.lcut

    def lcut(text, *a, **k):
        out = orig_lcut(text, *a, **k)
        rec['segments'][-1]['posseg'] = [[w, t] for w, t in out]
        return out
    zf.psg.lcut = lcut
    for name in ('_merge_bu', '_merge_yi', '_merge_reduplication',
                 '_merge_continuous_three_tones', '_merge_continuous_three_tones_2',
                 '_merge_er'):
        orig = getattr(tm, name)

        def wrap(seg, _orig=orig, _name=name):
            out = _orig(seg)
            rec['segments'][-1].setdefault('pre_merge_steps', []).append(
                [_name, [[w, t] for w, t in out]])
            return out
        setattr(tm, name, wrap)
    orig_gif, orig_mod, orig_er = fe._get_initials_finals, tm.modified_tone, fe._merge_erhua

    def gif(word):
        i, f = orig_gif(word)
        rec['segments'][-1]['words'].append({'word': word, 'initials': list(i), 'finals': list(f)})
        return i, f

    def mod(word, pos, finals):
        out = orig_mod(word, pos, finals)
        w = rec['segments'][-1]['words'][-1]
        w['tag'] = pos
        w['finals_sandhi'] = list(out)
        return out

    def er(initials, finals, word, pos):
        i, f = orig_er(initials, finals, word, pos)
        w = rec['segments'][-1]['words'][-1]
        w['initials_erhua'] = list(i)
        w['finals_erhua'] = list(f)
        return i, f
    fe._get_initials_finals, tm.modified_tone, fe._merge_erhua = gif, mod, er
    orig_call = zf.ZHFrontend.__call__

    def fe_call(self, text, *a, **k):
        rec['segments'].append({'zh': text, 'words': []})
        result, tokens = orig_call(self, text, *a, **k)
        rec['segments'][-1]['phonemes'] = result
        return result, tokens
    zf.ZHFrontend.__call__ = fe_call

    items = []
    for n, text in enumerate(open(lines_path, encoding='utf-8').read().splitlines()):
        if not text or text.startswith('#'):
            continue
        rec['segments'] = []
        try:
            out, _ = g2p(text)
        except Exception as e:  # misaki itself fails on this line
            items.append({'id': f'line-{n + 1}', 'text': text, 'error': type(e).__name__})
            continue
        a = cn2an.transform(text, 'an2cn') if text.strip() else text
        p = zh.ZHG2P.map_punctuation(a)
        split = [[e.strip(), z.strip()] for e, z in
                 re.findall(r"([A-Za-z \'-]*[A-Za-z][A-Za-z \'-]*)|([^A-Za-z]+)", p)]
        items.append({'id': f'line-{n + 1}', 'text': text, 'cn2an': a, 'punct_mapped': p,
                      'en_zh_split': split, 'segments': rec['segments'], 'phonemes': out,
                      'len_ps': len(out), 'style_row': len(out) - 1,
                      'input_ids': [0] + [vocab[c] for c in out if c in vocab] + [0]})
    os.unlink(tmp.name)
    print(json.dumps({'items': items, 'direct': direct}, ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()

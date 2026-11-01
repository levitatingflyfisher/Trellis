#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["jieba==0.42.1"]
# ///
"""Writes test/fixtures/targeted/: the golden lines written for Trellis
(the "target-*" items of zh_g2p.json, made by misaki zh v1.1 on the full
data) and the smallest slice of the seven data files that gives the same
answers on exactly those lines.

Why the slice is exact: every lookup the front end makes is for a
substring of a Chinese segment (jieba's DAG and cut_for_search, pypinyin's
phrase and character tables, the HMM emissions). So the slice keeps:
  - jieba_dict.txt: the words that are such substrings, plus one line
    "§rest <n> x" carrying the other words' frequency so the total (and
    so every log probability) is unchanged; '§' is outside every range
    jieba looks words up in, so the line is never matched.
  - both HMM tables: every start and transition line, and the emission
    (and posseg char-state) lines of the characters that reach each HMM
    (found by running jieba itself on the segments and words).
  - pypinyin: the characters that occur; the phrases that are substrings,
    plus, for each substring that is a proper prefix of some phrase, one
    such phrase, so the greedy phrase match walks the same way.
  - pypinyin_aux.json and misaki_zh_tables.json whole.

Usage: make_targeted_fixture.py DATA_DIR ZH_G2P_JSON OUT_DIR
"""
import json
import os
import shutil
import sys


def hmm_inputs(segs, words):
    """The characters each HMM's Viterbi sees: posseg's while tagging the
    segments, finalseg's while misaki's _split_word cuts the words."""
    import jieba
    import jieba.finalseg as fs
    import jieba.posseg as ps
    seen = {'jieba_finalseg_hmm.tsv': set(), 'jieba_posseg_hmm.tsv': set()}
    fv, pv = fs.viterbi, ps.viterbi

    def f_rec(obs, *a):
        seen['jieba_finalseg_hmm.tsv'].update(obs)
        return fv(obs, *a)

    def p_rec(obs, *a):
        seen['jieba_posseg_hmm.tsv'].update(obs)
        return pv(obs, *a)
    fs.viterbi, ps.viterbi = f_rec, p_rec
    for s in segs:
        ps.lcut(s)
    for w in words:
        jieba.lcut_for_search(w)
    return seen


def main():
    data, golden, out = sys.argv[1:4]
    os.makedirs(out, exist_ok=True)
    items = [it for it in json.load(open(golden, encoding='utf-8'))['items']
             if it['id'].startswith('target-')]
    segs = [s['zh'] for it in items for s in it['segments']]
    subs = set()
    for s in segs:
        for i in range(len(s)):
            for j in range(i + 1, min(len(s), i + 12) + 1):
                subs.add(s[i:j])
    chars = {c for s in segs for c in s}
    words = [w['word'] for it in items for s in it['segments'] for w in s['words']]
    hmm_chars = hmm_inputs(segs, words)

    def header_and_rows(name):
        lines = open(os.path.join(data, name), encoding='utf-8').read().split('\n')
        return lines[0], [l for l in lines[1:] if l]

    # jieba dictionary
    head, rows = header_and_rows('jieba_dict.txt')
    total = sum(int(r.split(' ')[1]) for r in rows)
    keep = [r for r in rows if r.split(' ')[0] in subs]
    kept = sum(int(r.split(' ')[1]) for r in keep)
    with open(os.path.join(out, 'jieba_dict.txt'), 'w', encoding='utf-8') as f:
        f.write(head + ' Slice for the targeted golden lines; "§rest" carries the other words\' frequency.\n')
        f.write('\n'.join(keep + [f'§rest {total - kept} x']) + '\n')

    # HMM tables
    for name in ('jieba_finalseg_hmm.tsv', 'jieba_posseg_hmm.tsv'):
        head, rows = header_and_rows(name)
        keep = []
        for r in rows:
            f = r.split('\t')
            seen = hmm_chars[name]
            if f[0] in ('S', 'T') or (f[0] == 'E' and f[2] in seen) or (f[0] == 'C' and f[1] in seen):
                keep.append(r)
        with open(os.path.join(out, name), 'w', encoding='utf-8') as fh:
            fh.write(head + ' Slice for the targeted golden lines.\n' + '\n'.join(keep) + '\n')

    # pypinyin
    head, rows = header_and_rows('pypinyin_single.tsv')
    keep = [r for r in rows if chr(int(r.split('\t')[0], 16)) in chars]
    with open(os.path.join(out, 'pypinyin_single.tsv'), 'w', encoding='utf-8') as fh:
        fh.write(head + ' Slice for the targeted golden lines.\n' + '\n'.join(keep) + '\n')
    head, rows = header_and_rows('pypinyin_phrases.tsv')
    words = {r.split('\t')[0]: r for r in rows}
    keep = {w for w in words if w in subs}
    for s in subs:
        for w in words:
            if len(w) > len(s) and w.startswith(s):
                keep.add(w)
                break
    with open(os.path.join(out, 'pypinyin_phrases.tsv'), 'w', encoding='utf-8') as fh:
        fh.write(head + ' Slice for the targeted golden lines.\n'
                 + '\n'.join(words[w] for w in sorted(keep)) + '\n')

    for name in ('pypinyin_aux.json', 'misaki_zh_tables.json'):
        shutil.copy(os.path.join(data, name), os.path.join(out, name))

    with open(os.path.join(out, 'targeted_golden.json'), 'w', encoding='utf-8') as fh:
        json.dump({
            'about': 'The golden lines written for Trellis (MIT), as misaki zh v1.1 '
                     'reads them on the full data (large_pinyin not loaded).',
            'items': [{k: it[k] for k in ('id', 'category', 'text', 'phonemes',
                                          'len_ps', 'input_ids')} for it in items],
        }, fh, ensure_ascii=False, indent=0)


if __name__ == '__main__':
    main()

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
#   "ordered-set==4.1.0",
#   "regex==2026.11.9",
#   "addict==2.4.0",
# ]
# ///
"""Makes zh_g2p_v2.json: the data helper's golden script (misaki_golden.py,
large_pinyin off) with Trellis's word readings loaded right after
misaki's own, by the same pypinyin.load_phrases_dict call misaki uses.

Usage: golden_v2.py MISAKI_GOLDEN_PY OVERRIDES_JSON VOCAB_CONFIG NTREX TARGETED_TSV OUT_JSON
  OVERRIDES_JSON: `dart run tool/print_trellis_overrides.dart` output.
"""
import importlib.util
import json
import sys


def main():
    script, overrides_path, *rest = sys.argv[1:]
    overrides = json.load(open(overrides_path, encoding='utf-8'))
    import pypinyin
    import misaki.zh as zh
    orig_init = zh.ZHG2P.__init__

    def init(self, *a, **k):
        orig_init(self, *a, **k)
        pypinyin.load_phrases_dict(overrides)
    zh.ZHG2P.__init__ = init

    spec = importlib.util.spec_from_file_location('misaki_golden', script)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    sys.argv = [script] + rest
    mod.main()


if __name__ == '__main__':
    main()

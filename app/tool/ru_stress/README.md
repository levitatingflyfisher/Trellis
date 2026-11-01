# Russian stress: building our own data

Russian speech needs the stressed vowel of each word, and no stress
dictionary with a clean licence exists. These tools build one from
public-domain dictionaries of 1847–1911, whose headwords carry printed
stress marks, and from Hunspell ru_RU (BSD-style) for modern forms.

Rules:
- Only public-domain scans, read by our own OCR, and clean modern word
  lists. Nothing from Zaliznyak, Wiktionary, Wikisource, OpenCorpora,
  espeak-ng or the Russian National Corpus.
- An AI may check a stress mark against the scan. An AI-checked entry
  goes into the lookup table only. Nothing a model learns from contains
  an AI's answer: the unknown-word guesser learns only from entries the
  scans agree on, and from rules.

Tools:
- `orthography.py`: pre-reform spelling to modern (ѣ, і, ѳ, ѵ, the final
  ъ, -аго, -ыя, з/с in prefixes), keeping the stress mark on its vowel.
  Ambiguous words get candidates, and a modern word list picks one.
- `extract.py`: every marked word from the accent finder's page output,
  with words split at a line end joined and OCR junk dropped.
- `upright.py`: keeps upright words only; italic examples carry no marks.
- `vote.py`: modern spelling, Hunspell's word list, and a vote across
  dictionaries: `agree` (two or more sightings on one vowel), `single`,
  or `disputed` (no vowel named).
- `provenance.py`: each entry says where it came from (`scan-agree`,
  `scan-single`, `rule`, `ai-checked`); the training export refuses any
  `ai-checked` row.
- `classify.py`: the tiny stress model for words the table lacks. It
  scores each vowel from the letters around it and its place in the word,
  learns only from printed marks, and saves a plain table of weights
  (about 3 MB) the app can read.
- `guess.py`: an earlier guesser by word endings alone, kept as the
  baseline; on held-out pages it is right on 50–64% of the words the
  table lacks, against about 70% for `classify.py`.

Tests: `uv run --with pytest --with numpy --with scikit-learn pytest app/tool/ru_stress`

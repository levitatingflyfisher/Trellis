# How to convert a translation model

Most translation pairs come as ONNX files someone else exported
(onnx-community, Xenova). When no trusted export exists, Trellis converts
the upstream model itself. ADR-0014's amendment of 2026-11-11 allows that
only on four conditions:

1. This recipe and its pinned versions are in the repo
   (`app/tool/convert_marian_onnx.py`).
2. The upstream model is named by its full commit, never a branch.
3. The two converted files are pinned in the catalog by sha256 and size,
   like every other file.
4. The Models screen credits the pair as “converted by Trellis from
   <upstream>”, with its licence.

## What the recipe does

`app/tool/convert_marian_onnx.py <model id> <upstream commit> <out dir>`:

1. Downloads the model at that commit.
2. Exports it with optimum's `main_export`, task
   `text2text-generation-with-past`, opset 14. This gives an encoder and a
   merged decoder (one graph with a first-step branch and a cached branch,
   the shape `marian_generation_loop.dart` drives).
3. Quantizes both graphs to int8 with ONNX Runtime's `quantize_dynamic`
   (`QInt8`, one scale per tensor). The merged decoder needs
   `EnableSubgraph`, or the weights inside its two branches stay 32-bit
   and the file stays about four times as big.
4. Prints the size and sha256 of the six files a catalog entry pins, in
   the catalog's order: the two converted graphs, then `source.spm`,
   `vocab.json`, `config.json` and `tokenizer_config.json` straight from
   the upstream commit. Only the two graphs are hosted by Trellis; the
   catalog fetches the four small files from upstream.

The script carries its own pinned dependencies (PEP 723), so
`uv run` sets them up: Python 3.12, optimum 1.23.3, transformers 4.46.3,
torch 2.5.1 (CPU build), onnx 1.17.0, onnxruntime 1.20.1, numpy 1.26.4,
sentencepiece 0.2.3, tokenizers 0.20.3, huggingface-hub 0.36.2. Newer
optimum (2.x) and torch (2.9 and later) failed to export these models in
November 2026.

## A re-run makes the same model, not the same bytes

The encoder comes out byte for byte the same. The merged decoder comes out
with the same weights and the same operations in the same order, but the
exporter numbers its internal names differently on each run, so its
sha256 differs. Check a re-run with
`app/tool/compare_onnx_weights.py <pinned file> <new file>`: it exits 0
when weights and operations match.

So the pinned hash is the hash of the file that was uploaded. Upload the
files the recipe made, as they are, and pin those. Never pin a hash from
one run and upload the files of another.

## Hosting and checking

The converted files go on a permanent GitHub release of the Trellis
repo, one release per conversion (English to Japanese: tag
`models-enja-1`, files at
`https://github.com/levitatingflyfisher/Trellis/releases/download/models-enja-1/<file name>`).
The release keeps the two converted files, the upstream licence text, a
note of what was changed (exported to ONNX, quantized to int8, nothing
else) and the export recipe (`convert_marian_onnx.py`). It is never
deleted: phones pin its files by hash and must always be able to fetch
them. Before a catalog entry that points at the release can merge:
download each file back from its release address and check its sha256
and size against the catalog. A mismatch means the upload changed and the
entry waits.

## English to Japanese: ElanMT-BT

| | |
|---|---|
| Upstream | `Mitsua/elan-mt-bt-en-ja` on Hugging Face |
| Commit | `02c48e7031386cd2d41974b0ff1aaf52f010c5fa` |
| Upstream weights | `model.safetensors`, 121,138,826 bytes, sha256 `d36a6549863d02a42ad0085ed7eb58d3a81c537e455173bb1e6ce434ecb2eeb8` (matches Hugging Face's own record) |
| Licence | CC BY-SA 4.0 (weights). The training data is all openly licensed (CC0, CC BY, CC BY-SA, MIT), with no web-crawled or machine-translated text, per the model card. |
| Credit | ElanMT-BT by ELAN MITSUA Project / Abstract Engine |

The converted files, as they were made on 2026-11-11:

| File | Bytes | sha256 |
|---|---|---|
| `encoder_model_quantized.onnx` | 35,890,766 | `b8698e3dee264d0e71d4bdd7469933c33a0ca4e08fb377a10dee70e528d3a7cc` |
| `decoder_model_merged_quantized.onnx` | 59,457,806 | `5ae7b58e2bfb69f67f0183fbb612a2145f902b5bc47567d844738c99c75b2463` |
| `source.spm` (upstream) | 792,751 | `a6824c2996a4877cae8a0240f11a112ab0e4ea1f22e54cd42179376fe558f4ff` |
| `vocab.json` (upstream) | 881,911 | `f508b75734ee21cf16b3816b7b29dea400f1f5998f47b7695cef1979ca49e106` |
| `config.json` (upstream) | 1,075 | `78298efb7b70a119900886b41de089e2543c1234bb7d767defa09ea494cb7ab7` |
| `tokenizer_config.json` (upstream) | 854 | `3c4a72a28f4db53dbf21d87b35d0ebee03ea76304f95940a809f9e18ab5220aa` |

Total 97,025,163 bytes. A re-run of the recipe the same day gave the same
encoder bytes and a decoder with the same weights and operations (decoder
sha256 `e0ade628…`, which is why only the first run's files are pinned).

Quality on the first 300 lines of NTREX-128 (BLEU with ja-mecab, chrF),
decoded one sentence at a time with the app's own greedy steps: the two
int8 files scored 23.56 and 32.72; the int8 encoder with the 32-bit
merged decoder scored 23.53 and 32.70; the original PyTorch model,
greedy, 23.36 and 32.76. Quantizing loses nothing measurable. (An earlier
figure of 24.2 and 33.1 came from optimum's runner, which loaded the
32-bit decoder and decoded in padded batches of 16; it does not describe
the int8 pair.)

The model is a plain Marian base model of the shape the app already runs
(6 encoder and 6 decoder layers, d_model 512, one shared 32k vocabulary,
`source.spm` and `target.spm` byte-identical), so it needs no code change:
`config.json` gives pad and decoder start 32000, end of sentence 0, and
`bad_words_ids` `[[32000]]`, which `MarianModelConfig` already reads.
`app/test/reader/translation/marian_real_pair_test.dart` runs the
converted files through the app's own generation loop.

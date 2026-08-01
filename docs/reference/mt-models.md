# Translation models — the licensing record (ADR-0008)

A downloadable translation pair is a data entry in `ml_runtime`'s
`ModelRegistry` (`packages/ml_runtime/lib/src/registry.dart`,
`ModelRegistry.starter()`), not code — adding a pair never touches the
Marian engine. This file is the verbatim license record for the pair
shipped, so the choice can be checked rather than trusted, following
`tts-voices.md`'s own convention for exactly this situation.

## Starter pair: `opus-mt-en-es`

**Chosen (ADR-0008).** `onnx-community/opus-mt-en-es` on Hugging Face —
Xenova/onnx-community's ONNX conversion of `Helsinki-NLP/opus-mt-en-es`
(a Marian transformer, trained on OPUS/Tatoeba-Challenge data), int8
quantized.

- Registry id: `opus-mt-en-es`
- Source: `https://huggingface.co/onnx-community/opus-mt-en-es`
  (verified 2026-08-14/15 — the file list and `config.json` were read
  directly rather than assumed; see below)
- Direction: English -> Spanish only. The registry's `langs` field names
  the TARGET language (`{'es'}`).
- Total size: 248,686,982 bytes (~248.7 MB) across four files, all
  downloaded directly and hashed locally 2026-08-14/15:

| File | Bytes | sha256 |
|---|---|---|
| `onnx/encoder_model_quantized.onnx` | 52,875,078 | `13ec84a3afebfe97cae004a5f39881ea38541308514ec26c18a0b807476d6fba` |
| `onnx/decoder_model_merged_quantized.onnx` | 193,290,224 | `832c4e0c1630a401f3115f0fcb08922f473b7f4996a5371d02ff880dc55f9399` |
| `source.spm` | 801,636 | `4dd547c24816a335e7b0b2e63376a8f1b3cbfc671eda5ab808dd44fdadaa8791` |
| `vocab.json` | 1,720,044 | `b074b4cca0036ade5a39ea97faabd534e1015482c480fc2cb02c6481983eb163` |

No archive to extract — every file above ships loose and is downloaded,
sha256-verified, and promoted independently, the same per-file law
Supertonic's voice files and whisper's single model file already follow;
`MarianModelLayout` names which file plays which role.

**Deliberately not registered:** `target.spm` (825,924 bytes, present in
the same upstream repo). It tokenizes text for the OTHER direction
(es->en decode input) — this engine only ever encodes English and decodes
by reversing the joint `vocab.json`, so nothing in the shipped code ever
opens it.

### Repo file list, as actually found (2026-08-14)

The campaign spec that started this work said "VERIFY the repo's actual
file list... do not assume." What was found by listing the repo directly
(`huggingface_hub.HfApi().model_info(..., files_metadata=True)`): the
`onnx/` subfolder ships nine quantization variants of the encoder
(`_fp16`, `_int8`, `_uint8`, `_q4`, `_q4f16`, `_bnb4`, plus the plain
`_quantized` alias used here) and eleven of the decoder, plus a separate
`decoder_with_past_model*` family (the pre-merge two-graph export this
campaign does NOT use). `encoder_model_quantized.onnx` and
`decoder_model_merged_quantized.onnx` are the exact filenames the spec
named; only their byte sizes were a guess (see ADR-0008 for the ~113MB
vs ~246MB gap).

### `config.json` facts load-bearing for the engine

Read directly from the repo (2026-08-14), not assumed:

```
"bos_token_id": 0, "eos_token_id": 0, "pad_token_id": 65000,
"decoder_start_token_id": 65000, "vocab_size": 65001, "d_model": 512,
"encoder_layers": 6, "decoder_layers": 6
```

`tokenizer_config.json` confirms `"separate_vocabs": false` — a single
joint `vocab.json` covers both languages' pieces, exactly as the spec
anticipated.

### LICENSE — the spec's assumption was backwards, corrected here

The originating spec expected "License: Apache-2.0 (HF card) / weights
CC-BY-4.0 upstream." Reading both cards directly (2026-08-15) found the
opposite pairing:

**`onnx-community/opus-mt-en-es`'s own model card** (the repo these
exact files are downloaded from) — YAML frontmatter, fetched
2026-08-15 from
`https://huggingface.co/onnx-community/opus-mt-en-es/raw/main/README.md`:

```
license: cc-by-4.0
```

**`Helsinki-NLP/opus-mt-en-es`'s own model card** (the ORIGINAL model
this ONNX export was converted from) — YAML frontmatter, fetched
2026-08-15 from
`https://huggingface.co/Helsinki-NLP/opus-mt-en-es/raw/main/README.md`:

```
license: apache-2.0
```

Neither repo carries a separate `LICENSE` file (`onnx-community/opus-mt-
en-es/resolve/main/LICENSE` returns 404). The registry entry's
`licenses` field names `CC-BY-4.0` — the license the repo actually
hosting the downloaded bytes declares for them. The upstream
Apache-2.0 claim is recorded here, verbatim, for completeness and in
case a future maintainer needs to reason about the original weights
rather than this specific ONNX conversion.

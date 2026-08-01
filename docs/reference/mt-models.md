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

---

## Campaign 8 "Babel widens" — Phase 0 verification (2026-08-15)

The founding-tweet flow (English episode -> whisper transcript -> en->X
translation -> SPOKEN in X) makes the target language a parameter. This
section is the verbatim license/size/hash record for every pair
evaluated, per the spec's priority order (es shipped, de, pt, ru, ja,
zh) — including the pairs NOT shipped, and why, since a gap that isn't
recorded is a gap that gets rediscovered the hard way.

### Verification method: a validated zero-download pinning path

Downloading and hashing a ~250MB ONNX pair per candidate (six pairs,
twelve files, ~1.5GB) to VERIFY a hash before deciding whether to ship
it is wasteful when Hugging Face's own tree API already carries the
answer. Before trusting it, it was checked against the already-shipped
`opus-mt-en-es` entry's own ground truth (real local download, real
local sha256, from the original ADR-0008 pass):

```
GET https://huggingface.co/api/models/onnx-community/opus-mt-en-es/tree/main/onnx?recursive=1
```

For `onnx/encoder_model_quantized.onnx`, the API returned `size:
52875078` and `lfs.oid: 13ec84a3afebfe97cae004a5f39881ea38541308514ec26c18a0b807476d6fba` —
an EXACT match, digit for digit, to the pinned registry entry's
independently-downloaded-and-hashed values. Re-confirmed a second and
third time by downloading the actual `de`, `ru`, `zh`, and `jap`/`jap-en`
encoder+decoder pairs later in this pass (for the decoder-trap re-probe
and the real-translation quality checks below) and diffing their local
`sha256sum` against the tree API's `lfs.oid` — three-for-three exact
matches. `size`/`lfs.oid` from this endpoint is therefore a trustworthy
substitute for a full download when the goal is pinning a hash, not
running the model. Small files that don't cross Hugging Face's LFS
threshold (`source.spm`, `vocab.json` — under ~2.7MB in every pair
checked) carry no `lfs` block at all and were downloaded directly and
hashed locally, same as the original es pass.

### Shipped pairs

All four below share the exact architecture family as `opus-mt-en-es`
(`config.json`: `architectures: ["MarianMTModel"]`, 6 encoder + 6
decoder layers, `d_model: 512`, `separate_vocabs: false`) and the exact
merged-decoder ONNX export shape (`onnx/decoder_model_merged_quantized.onnx`
with the same 24 `past_key_values.*`/`present.*` input/output names and
one `optimum::if` node keyed on `use_cache_branch`) — verified by
downloading the `de` pair's own encoder+decoder graphs and inspecting
them with `onnx.load` (not assumed from the config match alone).

#### `opus-mt-en-de` / `opus-mt-de-en`

Source: `https://huggingface.co/onnx-community/opus-mt-en-de` (forward)
and `https://huggingface.co/onnx-community/opus-mt-de-en` (reverse).
License: `cc-by-4.0` (both repos' own README frontmatter, fetched
2026-08-15) — upstream `Helsinki-NLP/opus-mt-en-de` also declares
`cc-by-4.0`; `Helsinki-NLP/opus-mt-de-en` declares `apache-2.0` (the two
directions' upstream originals carry DIFFERENT licenses from each
other — recorded verbatim, not reconciled, following the es entry's own
precedent of naming the bytes-hosting repo's license as the one that
governs).

| Pair | File | Bytes | sha256 |
|---|---|---|---|
| en-de | `onnx/encoder_model_quantized.onnx` | 49,342,278 | `94ae6a9149aca29ef31a58bb8ccc1c3df3720840caef890ccc6cde73c94cb0f4` |
| en-de | `onnx/decoder_model_merged_quantized.onnx` | 175,598,624 | `492004d70327f4552fbddba033f8d8ce946edb87b66cbf8f9a7b41d14fe683cc` |
| en-de | `source.spm` | 768,489 | `678f2a1177d8389f67b66299762dcc4fc567e89b07e212ba91b0c56daecf47ce` |
| en-de | `vocab.json` | 1,389,436 | `d5acea957b265a78554999144459c5e391e0df525864edc8287bc090290baa44` |
| de-en | `onnx/encoder_model_quantized.onnx` | 49,342,278 | `3e7b95246cf1885b5c6c123a36818a417c3ef6f500d4c17e030fef427fff7a74` |
| de-en | `onnx/decoder_model_merged_quantized.onnx` | 175,598,624 | `d789d6a132d540fa40d6fa5901c3ba1e6209c69bf201ffef54f73833fa9b5a6c` |
| de-en | `source.spm` | 796,845 | `bbd1f495eea99c8e21ae086d9146e0fa7b096c3dfdd9ba07ab8b631889df5c9b` |
| de-en | `vocab.json` | 1,389,436 | `d5acea957b265a78554999144459c5e391e0df525864edc8287bc090290baa44` |

(`en-de`'s own `target.spm` and `de-en`'s own `source.spm` are the same
German tokenizer, byte-for-byte — hashes cross-check exactly, confirming
the two repos are genuinely a matched forward/reverse pair. Neither
`target.spm` is registered, same reasoning as the es entry: this engine
only ever encodes the source side and decodes by reversing the joint
`vocab.json`.)

**Quality, verified with real inference** (Python, real ONNX Runtime,
the frozen-cross-attention-KV loop below): fluent, idiomatic German out
for all four standard test sentences — `"Hello, world!"` ->
`"Hallo, Welt!"`; `"I would pay for a podcast player that automatically
translates episodes into other languages."` -> `"Ich würde für einen
Podcast-Player bezahlen, der automatisch Episoden in andere Sprachen
übersetzt."` On par with the shipped es pair. One general Marian
base-model quirk observed on a *two-sentence* input fed as one string
(`"Good morning. How are you today?"` -> `"Wie geht es dir heute?"`,
dropping the greeting): this is very likely a probe artifact, not a
model defect — the probe script fed both sentences through one
`encode()` call, but the shipped app always calls `translate()` once per
`core.splitSentences`-split sentence, so a multi-sentence string never
reaches the real decode loop this way in production. Recorded rather
than asserted as a genuine defect, since it wasn't isolated further.

#### `opus-mt-en-ru` / `opus-mt-ru-en`

Source: `https://huggingface.co/onnx-community/opus-mt-en-ru` /
`.../opus-mt-ru-en`. License: `cc-by-4.0` on both onnx-community repos;
upstream `Helsinki-NLP/opus-mt-en-ru` is `apache-2.0`,
`Helsinki-NLP/opus-mt-ru-en` is `cc-by-4.0`.

| Pair | File | Bytes | sha256 |
|---|---|---|---|
| en-ru | `onnx/encoder_model_quantized.onnx` | 51,603,782 | `b8b4f72528c0da92e579af8a739f97fa2f792d73527ba2fee786fa7286c4055b` |
| en-ru | `onnx/decoder_model_merged_quantized.onnx` | 186,923,812 | `5d15c48566e60dcaa5af7422bcceca24ccc8f3eaa8f1b3aedc5d6170e6c232f3` |
| en-ru | `source.spm` | 802,781 | `16bebef1389a0b8ab452772c4e35b9e605e5713f8ac7baa71ca701394eaa086d` |
| en-ru | `vocab.json` | 2,726,796 | `5cf0d95d930d8d3e783c9e2f46a72f08b43a18060dab4ddefbcb66a733efedcb` |
| ru-en | `onnx/encoder_model_quantized.onnx` | 51,603,782 | `fdd4d1de9cb02feaae8bc892e0e21b1bfd1741fa43a2895d471ee5f53ae260c4` |
| ru-en | `onnx/decoder_model_merged_quantized.onnx` | 186,923,812 | `0fef11505dc0564d0d6d54e37529d7ba949826fe19fd7193052610989fccbf28` |
| ru-en | `source.spm` | 1,080,169 | `745998e51ba5b058e38b7ac7765c25c43ed5c1c39cc92b27163b9b2e323c9d7c` |
| ru-en | `vocab.json` | 2,726,796 | `5cf0d95d930d8d3e783c9e2f46a72f08b43a18060dab4ddefbcb66a733efedcb` |

**Quality, verified with real inference:** fluent Cyrillic out —
`"Hello, world!"` -> `"Привет, мир!"`; `"The quick brown fox..."` ->
`"Быстрый коричневый лис прыгает через ленивую собаку."` One coined
compound (`"подкастист"` for "podcast player" in the founding-tweet
sentence) — an acceptable MT neologism, not a decode failure. On par
with es/de.

#### `opus-mt-en-zh` / `opus-mt-zh-en`

**Update, Phase 3 (2026-08-15): `opus-mt-en-zh` (English -> Chinese) is
NOT registered — evaluated, translation quality is real, but demoted for
a rendering reason found downstream of this section, not a quality one.**
`opus-mt-zh-en` (Chinese -> English) ships unaffected; its output is
Latin text, so the finding below does not touch it. See "Phase 3:
en-zh demoted — a display gap, not a translation gap" further down this
file for the full account; this section is kept as the unmodified
Phase 0 verification record (pins, quality samples) for both directions,
since both were real, checked findings even though only one shipped.

Source: `https://huggingface.co/onnx-community/opus-mt-en-zh` /
`.../opus-mt-zh-en`. License: `cc-by-4.0` on both onnx-community repos;
upstream `Helsinki-NLP/opus-mt-en-zh` is `apache-2.0`,
`Helsinki-NLP/opus-mt-zh-en` is `cc-by-4.0`. **No `tc-big` variant
exists for this pair** — `Helsinki-NLP/opus-mt-tc-big-en-zh` and
`.../opus-mt-tc-big-zh-en` both 401 (Hugging Face's unauthenticated
"does not exist" response, confirmed against a known-nonexistent repo
and a known-gated repo to disambiguate from an auth wall) — so the base
model checked here IS the best clean-licensed option, not a fallback
from a stronger one that was skipped.

| Pair | File | Bytes | sha256 |
|---|---|---|---|
| en-zh | `onnx/encoder_model_quantized.onnx` | 52,875,078 | `cb02c542d2ab3010766031f3ce04e9041ffb6bd2df15caa7c41f3aead7cfe6dc` |
| en-zh | `onnx/decoder_model_merged_quantized.onnx` | 193,290,224 | `c6fe901b5bae6235237f07ac0dfb421bf2a14aaaa02d4024bd1965be5b1d215e` |
| en-zh | `source.spm` | 806,435 | `5775ddc9e3ff2fae91554da56468ad35ff56edaba870fea74447bc7234bfdaa8` |
| en-zh | `vocab.json` | 1,747,795 | `22c957348eed495ee925afc40a36da3e387c8a34a734c8486967c2dca271613e` |
| zh-en | `onnx/encoder_model_quantized.onnx` | 52,875,078 | `86b0dc5a1d5d8062583800654864aae1311fce2172bba80910d02020d3693577` |
| zh-en | `onnx/decoder_model_merged_quantized.onnx` | 193,290,224 | `714881fafd326c8cb56bc6e3e542d1d106a5acf90e6abb71e20423ebf1b47875` |
| zh-en | `source.spm` | 804,677 | `e27a3a1b539f4959ec72ea60e453f49156289f95d4e6000b29332efc45616203` |
| zh-en | `vocab.json` | 1,747,906 | `08a119a1defd522fa047cb5e3bfe3e89633e96caa38ced0dc9cee7ef1021a011` |

**Quality, verified with real inference — asymmetric, recorded
honestly:**
- **zh-en (Chinese -> English): excellent, on par with es/de/ru.**
  `"你好，世界！"` -> `"Hello, world!"`; `"早上好，你今天怎么样？"` ->
  `"Good morning. How are you today?"` — fully fluent and accurate on
  every test sentence.
- **en-zh (English -> Chinese): usable but noticeably less fluent —
  ships LABELED, not silently.** `"I would pay for a podcast player
  that automatically translates episodes into other languages."` ->
  `"我会支付一个播客播放器的费用 自动将片段翻译成其他语言"` — correct
  in substance (a native reader gets the meaning) but missing a
  connective between the two clauses where natural Chinese wants one;
  `"Hello, world!"` -> `"你好,世界! !"` doubles the terminal exclamation
  mark. This matches the base (non-tc-big) OPUS-MT en-zh model's general
  reputation as one of the weaker directions in the catalog absent a
  `tc-big` alternative, which — confirmed above — doesn't exist for this
  pair. Shipped anyway per the spec's own law ("a weaker pair ships
  LABELED, it doesn't ship silently and it doesn't get hidden"): the
  output is genuinely usable, just rougher than its siblings.

### Phase 3: `en-zh` demoted — a display gap, not a translation gap

Unlike `en-jap`/`jap-en` and `en-pt`/`pt-en` below, `en-zh`'s translation
was never in question — Phase 0's own samples above are fluent enough to
ship. What changed in Phase 3: the spec called for verifying CJK font
rendering on the reader's own surfaces rather than assuming it, and that
verification (`app/test/visual/cjk_font_golden_test.dart`, the same
self-guarded `VISUAL_TOUR=1` golden convention `tour_golden_test.dart`
uses) rendered the scroll-mode dual display showing a real Chinese
translation, then the PNG was read directly.

**The glyphs render as tofu boxes (□).** The app bundles only Lora and
Nunito — Latin/Cyrillic Google Fonts with zero CJK coverage, which was
expected. The actionable finding: this app has a real, established
conformance law for exactly this situation. `fleet_conformance_test.dart`
runs `FleetCheck.c7Fonts` for Trellis — every glyph the app's own UI
prints must exist in its BUNDLED fonts' cmaps, precisely so rendering
never depends on whatever font happens to be installed on a given
device (`reader_prefs.dart`'s own comment: "never a system/unbundled
face"). Two follow-up checks confirmed this isn't a false alarm:

1. **`fontFamilyFallback` naming an installed system font made no
   difference.** This development box has `google-noto-sans-cjk-vf-fonts`
   installed (`fc-list` confirms it), and declaring it in
   `fontFamilyFallback` on the reader's translated-line style still
   rendered tofu, identically. Root cause, confirmed rather than
   guessed: `flutter test`'s golden-render pipeline loads only
   asset-bundled fonts — it never consults fontconfig/`fc-list`, so a
   system-family name in `fontFamilyFallback` is a no-op there by
   construction. The experiment doesn't prove a real device would also
   show tofu; it proves this app's own C7 doctrine (verify from what the
   app bundles, not what might be installed) is the only question this
   harness — or, per the doctrine, this app — can actually answer.
2. **Bundling a CJK font to close the gap the honest way was costed,
   not assumed.** Downloaded `notofonts/noto-cjk`'s `Sans2.004` release
   and measured its single-weight, single-region subset OTF directly:
   `SubsetOTF/SC/NotoSansSC-Regular.otf` is 8,331,336 bytes (OFL-1.1,
   verified from the archive's own `LICENSE` file — the same license
   family as the bundled Lora/Nunito). `app/budgets.json`'s C3 ratchet
   has 71,888,630 bytes of APK headroom against 68,465,362 measured —
   3,423,268 bytes (~3.3MB) of remaining room. An 8.3MB single-region,
   single-weight font does not fit; the full multi-region family this
   project would eventually want is far larger. Not a rounding error —
   demoted on a real number, not a guess.

**Decision: `opus-mt-en-zh` is not registered.** `opus-mt-zh-en` (Chinese
source, English output) is unaffected and ships — Latin text carries no
glyph risk. A user who wants to READ Chinese output, not just hear it
spoken, is the gap; Speak-in-Chinese itself was never blocked by this
finding (the system voice speaks the stored text regardless of whether
it renders legibly on screen), but shipping a "Show Chinese" toggle
whose own display is unverified — after just proving it fails in the one
environment that can be checked — repeats exactly the kind of "ships a
control that doesn't really work" mistake this campaign's own Phase 1
regression fixes (`reader_screen.dart`'s dead-toggle fix) exist to
prevent. The library doc comment on `cjk_font_golden_test.dart` keeps
the finding as a live regression guard, not just a one-time note: if a
future pass bundles a CJK font and re-runs this golden clean, that's the
signal `en-zh` (and Japanese import display, the second golden's case)
can be reconsidered.

### Evaluated, NOT shipped: `en-jap` / `jap-en` (Japanese)

**Verdict: Japanese does not clear the bar for the Marian offline
floor.** Per the spec's own pre-authorized fallback for exactly this
outcome, the honest label is: **Japanese needs the household Brain
(Phase 5); the on-device floor is not yet available.**

What was checked, in order:

1. **No `tc-big` export exists.** `Helsinki-NLP/opus-mt-tc-big-en-ja`
   and `.../opus-mt-tc-big-ja-en` both 401 (don't exist). The only
   direct bilingual pair on Hugging Face uses the legacy three-letter
   code `jap`, not `ja`: `Helsinki-NLP/opus-mt-en-jap` /
   `.../opus-mt-jap-en` — both `license: apache-2.0`. **No ONNX
   conversion exists on the trusted `onnx-community` org at all** (its
   49-repo `opus-mt` catalog, listed directly via the Hub API, has no
   `en-jap`/`jap-en`/`en-ja`/`ja-en` entry). The one trusted-org ONNX
   conversion found is on `Xenova` (the predecessor org to
   `onnx-community`, same maintainer lineage, a "known quantizer" per
   the fleet's trust ladder): `Xenova/opus-mt-en-jap` /
   `.../opus-mt-jap-en`. Its own README carries no `license:`
   frontmatter of its own (unlike every onnx-community repo above,
   which self-declares `cc-by-4.0`) — it only names
   `base_model: Helsinki-NLP/opus-mt-en-jap`, so the license recorded
   here (`apache-2.0`) is INHERITED from the named upstream, a weaker
   attestation than onnx-community's explicit self-declaration,
   flagged honestly rather than silently treated as equivalent.

   | Pair | File | Bytes | sha256 |
   |---|---|---|---|
   | en-jap | `onnx/encoder_model_quantized.onnx` | 43,312,542 | `4062a86cbec1d388e779294f07b784179d87a648c90771e94879b3a28cd96be7` |
   | en-jap | `onnx/decoder_model_merged_quantized.onnx` | 50,550,704 | `084c7544b640eeea722b4858328f479d804236b916a2bec761442ff062726619` |
   | en-jap | `source.spm` | 508,602 | `375cbed8885a6d369e0493acfc69a066010a86f98f9bac02430cbeb1726934a6` |
   | en-jap | `vocab.json` | 1,734,978 | `62f7857585e3cd6150bb420830076edede27caac6304778d8d81be41164e469d` |
   | jap-en | `onnx/encoder_model_quantized.onnx` | 43,312,542 | `cd2b38cf4665f1ebad54dc3628cf0e9186ee951171a988644fcc25ef2d74822c` |
   | jap-en | `onnx/decoder_model_merged_quantized.onnx` | 50,550,704 | `65895b7f5576bc71ddab2fb64b97c42ac21999d19c38a9b2dfa33317df701720` |
   | jap-en | `source.spm` | 1,021,944 | `7d5ec21daca7dccb7a9df371b699def40ddd9d0c24cef855e44e31a39b96af55` |
   | jap-en | `vocab.json` | 1,734,978 | `62f7857585e3cd6150bb420830076edede27caac6304778d8d81be41164e469d` |

2. **Real inference, greedy decode, the same frozen-cross-attention-KV
   loop that produces fluent es/de/ru/zh: pure `<pad>` output for 3 of
   4 test sentences.** `config.json` for both repos names
   `"bad_words_ids": [[46275]]` (46275 IS the model's own
   `pad_token_id`/`decoder_start_token_id`) — a field NONE of the
   shipped pairs' configs carry. Step-1 logits confirmed why: the pad
   token's logit was exactly `0.0` while every other candidate scored
   -5 to -7, so unmasked greedy argmax always picks it and the decode
   collapses immediately. This is upstream's OWN documented awareness
   that the export is fragile without logit masking, not a bug in this
   campaign's probe.
3. **Masking the pad token out of the argmax candidate set (matching
   `bad_words_ids`) fixes the collapse but not the translation.** Both
   directions then produce grammatical-LOOKING but semantically
   incoherent output: `"The quick brown fox jumps over the lazy dog."`
   -> `"猛禽は,いの犬のようだ."` (word salad: "raptor... dog-like
   thing"); Japanese->English produced Bible-register hallucinations
   unrelated to the input (`"The salutation of into do do Gaius been
   the mercy of Gaius."`) — a strong signal of a small, old,
   religious-corpus-heavy training set (Tatoeba/JW300-era OPUS data),
   consistent with the archaic `jap` ISO code marking this as one of
   the earliest, least-revisited pairs in the Helsinki-NLP catalog.
4. **`、` (U+3001, the ordinary Japanese comma) is not even in
   `jap-en`'s `vocab.json`** — falls back to `<unk>` on real running
   text, a second independent sign of a small/stale training
   vocabulary.

Both directions were tested with real ONNX Runtime inference, not
inferred from reputation alone — the incoherence is observed, not
assumed. Ship-strategy consequence: Japanese is the Phase 5 Brain-lane
QUALITY path, per the spec's own design; Marian is not the floor for
this language, and the app must say so rather than silently offering a
translator that produces gibberish.

### Evaluated, NOT shipped: `en-pt` / `pt-en` (Portuguese)

No bilingual Marian pair — `tc-big` or base — has a **trusted-org**
ONNX conversion. What exists, checked directly rather than assumed:

- `Helsinki-NLP/opus-mt-tc-big-en-pt` exists upstream (200) with no
  reverse `tc-big-pt-en`, and no ONNX conversion of it on
  `onnx-community` or `Xenova` (neither org's catalog lists it).
- `Helsinki-NLP/opus-mt-en-pt` / `.../opus-mt-pt-en` (the plain,
  non-tc-big bilingual pair) do not exist at all (401 on both).
- The only ONNX artifacts found on Hugging Face search
  (`opus-mt-en-pt`, `tc-big-en-pt`) are individual-account repos
  (`R4kSo1997/opus-mt-en-pt-onnx-int8`, `TigreGotico/opus-mt-en-pt-onnx`,
  and similar) — fail the fleet's trust ladder (official orgs > known
  quantizers > curated catalogs > avoid mirrors) outright; not
  evaluated further.
- **`onnx-community/opus-mt-en-ROMANCE` and `.../opus-mt-ROMANCE-en`
  DO exist at a trusted org** and DO cover Portuguese — but as a
  multi-target model selected by a language-directive token
  (`>>pt<<`) prepended to the source text, not a dedicated bilingual
  pair. Checked concretely, not assumed: `en-ROMANCE`'s `vocab.json`
  carries 47 `>>xx<<`-style directive tokens including `>>pt<<`
  (id present) — but real `sentencepiece` encoding of its own
  `source.spm` (`sp.get_piece_size() == 32000`, no `>>`-prefixed piece
  anywhere in that table) shreds a literal `">>pt<< Hello world"` into
  `['▁>', '>', 'pt', '<', '<', '▁Hello', '▁world']` — meaningless
  sub-word fragments, not the single directive token the model needs.
  The real behavior (confirmed against how `MarianTokenizer` is
  documented to work upstream) is a REGEX extraction of the `>>xx<<`
  prefix BEFORE SentencePiece ever sees the rest of the text, with the
  directive's id looked up directly in the 65,001-entry joint
  `vocab.json` and prepended to the SentencePiece-encoded ids — a
  second, separate mechanism this campaign's tokenizer/generation loop
  (`packages/ml_runtime`, `marian_generation_loop.dart`) does not
  implement. `MarianUnigramTokenizer`'s own constructor only indexes
  `SpmPieceType.normal` pieces into `_scoreByPiece` — `userDefined`/
  reserved pieces are deliberately excluded — so even a future
  encoder-only fix would need a genuinely separate directive-token
  path, not a vocabulary tweak. Also has no int8-quantized ONNX export
  at all (only fp32/fp16, ~210-236MB per graph vs the ~50-190MB
  quantized pairs above) — a second, independent reason this isn't a
  drop-in swap.

Recorded as a deferred gap, not a silent one: Portuguese has no Marian
floor this pass. Phase 5's Brain lane is the honest path for it, same
as Japanese, until either a trusted-org bilingual ONNX conversion
appears or the multi-target directive-token mechanism gets built as its
own feature.

### The decoder-trap re-probe (ADR-0008's frozen-cross-attention-KV fix)

Re-proven end to end with real ONNX Runtime inference on the `de` pair
(chosen as the smallest fully-shipped pair after es) before writing any
Dart: the exact same failure ADR-0008 documented for es reproduces
byte-for-byte — `present.0.encoder.key` shape `(1, 8, 5, 64)` (real) on
step 0, collapsing to `(0, 8, 1, 64)` (degenerate) on every cached step
thereafter — and the same fix (freeze step 1's real
`present.*.encoder.*` tensors, re-feed those exact values on every later
step instead of the current step's own cached-branch output) produces
fluent German on every test sentence. Graph structure inspected directly
(`onnx.load`, not assumed): the `de` decoder graph carries the identical
24 `past_key_values.*`/`present.*` input/output names and the same
single `optimum::if` node keyed on `use_cache_branch` as the es graph.
`ru`, `zh`, `en-jap`/`jap-en` were confirmed to share the SAME
architecture signature via `config.json` (`MarianMTModel`, 6+6 layers,
`separate_vocabs: false`) but were not independently graph-inspected —
their real-inference translations above (fluent for ru/zh, incoherent
for jap for unrelated reasons already explained) are themselves
evidence the same fix applies, since a still-present frozen-KV bug would
produce garbage regardless of translation-quality reputation. No
`tc-big` ONNX export exists for either CJK pair (recorded above), so the
spec's "and on one tc-big export" re-probe target has no artifact to
test against — recorded as the reason, not skipped silently.

### SentencePiece / CJK tokenizer coverage

Real golden vectors were generated against the real `zh-en` and
`jap-en` `source.spm` files (Chinese and Japanese SOURCE-side
tokenization — the direction that actually needs whitespace-free
segmentation, since the reverse `en-*` pairs tokenize English) using
the real Python `sentencepiece` library, the same process as the
original 25 es vectors. Result: **zero divergence** once one narrow,
verified fix landed — the pure-Dart `MarianUnigramTokenizer`'s Viterbi
encoder had no whitespace assumption baked into its design (confirmed:
`normalize()` only collapses whitespace RUNS, never assumes one
exists), but real CJK text exposed that the model's own normalizer
folds Halfwidth-and-Fullwidth-Forms punctuation (U+FF01-U+FF5E — the
fullwidth `！`/`？` every CJK IME emits) to plain ASCII before
tokenizing, which the Dart encoder didn't do. This is a fixed
arithmetic offset (`codepoint - 0xFEE0`), not the general 237KB NFKC
charsmap ADR-0008 already declined to port — narrow enough to
implement exactly, and load-bearing for CJK specifically since
fullwidth ASCII punctuation is common in ordinary Japanese/Chinese
text, unlike the rare decomposed-Latin-accent case the es fixture
documents. Landed in `packages/ml_runtime/lib/src/marian_tokenizer.dart`
(`_foldFullwidthAscii`), golden fixtures at
`packages/ml_runtime/test/fixtures/marian_tokenizer_goldens_{zh,ja}.json`.
The `ja` fixture is kept even though the `jap`/`ja` Marian pair does not
ship (above) — it's the evidence that the tokenizer itself generalizes
to CJK correctly; the `zh` fixture is the same evidence for the pair
that DOES ship.

### Registry design: `sourceLang` (Phase 1)

`ModelSpec.langs` means the TARGET language a model produces (ADR-0008)
— correct for `pickModel`'s generic `(task, tier, langHint)` selection,
which ASR and TTS also use and which this campaign does not touch. It
breaks for translation the moment more than one pair produces the SAME
target: `de-en`, `ru-en`, and `zh-en` all carry `langs: {'en'}`, so
`pickModel(translation, tier, langHint: 'en')` could not tell them
apart and would silently fall through to the largest-`sizeBytes`
tiebreak regardless of which language a work actually needs translated.
Fix: a new `ModelSpec.sourceLang` field (the es entry gets
`sourceLang: 'en'` added too, so the field is never half-populated) and
a new `ModelRegistry.pickTranslationPair(tier, {sourceLang, targetLang})`
that matches BOTH fields — `pickModel` itself is untouched, so every
existing ASR/TTS caller (and the existing es translation call sites,
migrated to the new method in the same pass) keeps its exact prior
behavior.

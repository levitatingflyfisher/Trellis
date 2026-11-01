# ADR-0020: Translation runs on device, verified

- Status: Accepted. Shipped in 1.5.9. A release build translated en→ru on
  an x86_64 emulator (2026-11-07, see Consequences); the same check on an
  arm64 phone, and the “Update available” path over real 1.5.8 data, are
  release checks still to run.
- Date: 2026-11-07
- Builds on: [ADR-0008](0008-babel-the-translation-organ.md) (the engine)
  and [ADR-0014](0014-babel-widens.md) (the pairs). The 1.5.9 plan called
  this “ADR-0008”; that number is Babel’s, so this takes the next free one.

## Context

ADR-0008 built the Marian engine and ADR-0014 widened it. Both proved it
against faked ONNX sessions and, for the decoding logic, against the real
models in Python. ADR-0008’s 1.5.5 section ended with “No pair has run on
a phone.”

Three things happened since:

- **1.5.6 crashed on the first translation.** It worked in debug builds
  and in every test, and aborted the app on a phone.
- **1.5.6 hid every pair.** The Translate sheet said there was no
  offline translator on a phone that had one downloaded, because the
  pairs were registered above the tier the app runs at.
- **The downloads were too big.** The six oldest pairs (en-es, en-de,
  de-en, en-ru, ru-en, zh-en) came from onnx-community at about 230 to
  250 MB each, most of it a 175 to 193 MB decoder. Xenova publishes a
  merged decoder for the same models at about 60 MB.

This ADR records what makes translation on the device trustworthy now,
and what each claim rests on.

## Decision

### 1. OPUS-MT, as ONNX, through ONNX Runtime

The models are Helsinki-NLP’s OPUS-MT Marian models (CC-BY 4.0; the
licensing record is [mt-models.md](../reference/mt-models.md)). Each pair
is an ONNX export of six pinned files: `encoder_model_quantized.onnx`,
`decoder_model_merged_quantized.onnx`, `source.spm`, `vocab.json`,
`config.json` and `tokenizer_config.json`. Each file carries a sha256 and
a byte count (`packages/ml_runtime/lib/src/translation_catalog.dart`), is
downloaded from Hugging Face on the listener’s tap and is never re-hosted.

The graphs run through `flutter_onnxruntime` (MIT), which wraps Microsoft’s
ONNX Runtime (MIT). It is the same runtime the Supertonic voice uses
(ADR-0007), so the app carries one native payload for both. The engine is
`app/lib/features/reader/translation/src/marian_translator.dart`; the
decoding loop, with the frozen cross-attention fix from ADR-0008, is
`marian_generation_loop.dart` (`marian_generation_loop_test.dart`).

### 2. The R8 keep rule, and why it must stay

`app/android/app/proguard-rules.pro`:

```
-keep class ai.onnxruntime.** { *; }
```

ONNX Runtime’s native library finds its Java classes (`OnnxTensor`,
`OrtSession` and the rest) by name, through JNI `FindClass`. Release
builds run R8, which renames classes. In 1.5.6 R8 renamed them,
`FindClass` returned null, and the app aborted on the first translation
run on a phone. Debug builds and the test suite don’t run R8, so nothing
caught it before release. 1.5.7 added the rule.

Guard: `app/test/android_keep_classes_test.dart` (“R8 keeps ONNX Runtime
classes by name”) fails if the rule is missing or if
`app/android/app/build.gradle.kts` stops loading `proguard-rules.pro`. The
release recipe also checks the built APK itself:
`strings classes.dex | grep "Lai/onnxruntime/OnnxTensor;"`. If the plugin
ever moves ONNX Runtime to another Java package, change the rule and the
test together.

### 3. Every pair registers at tier t1

Every pair in `translationCatalog()` has `minTier: DeviceTier.t1`. The app
has no tier probe and runs every device at T1 (`DeviceServices`’ default
tier). At T2, the 1.5.6 registration, the Translate sheet could never see
a pair the Models screen had just downloaded. An int8 pair of about
110 MB is a phone-sized download, so T1 is also the honest tier.

Guard: `app/test/services/device_services_real_tier_test.dart` (“the real
wiring can route translations out of English”) goes through
`DeviceServices.real`, not a test double with a hand-picked tier. The
voice moved to T1 in 1.5.8 for the same reason (ADR-0007, last section).

### 4. The six oldest pairs take Xenova’s int8 decoder, after a parity check

Since 1.5.9 the six onnx-community pairs keep their encoder, tokenizer
and configs, and take Xenova’s `onnx/decoder_model_merged_quantized.onnx`
at a pinned commit. A pair drops from about 249 MB to about 116 MB.

The swap was accepted only after a parity check. Its record
(`decoder-parity.md`, with the script `decoder_parity.py`) lives in the
maintainer’s working notes outside this repo, so the method and the table
are copied here.

**Method.** For each pair, onnx-community’s encoder (the file phones
already have) ran once per sentence. Greedy decoding then ran twice:
(a) with the current onnx-community decoder and (b) with Xenova’s decoder.
The loop mirrored `marian_generation_loop.dart`: an empty past on step 1,
the step-1 cross-attention values frozen, pad and the single-token
`bad_words_ids` suppressed, at most 3n+16 tokens. Tokenizing used
onnx-community’s `source.spm` pieces mapped through `vocab.json`, as the
app does. The input was 50 sentences written for the check (10 news, 10
dialogue, 10 podcast-transcript style, 10 with names, 10 with numbers; no
personal data). zh-en used the same 50 written in Chinese; de-en and
ru-en used the English set as rendered by the en-de and en-ru pairs.
“Identical” means the same token ids. chrF is sacrebleu’s corpus chrF of
(b) against (a). The plan’s rule: accept a pair only if at least 90% of
outputs are identical AND chrF is at least 95; a pair that fails keeps its
old decoder. Before any number was trusted, the two repos were checked to
be compatible: the same `config.json` dimensions and special ids, a
byte-identical `vocab.json` and `source.spm`, and the same decoder input
and output names, types and logits width. Every downloaded file matched
the Hugging Face tree API’s sha256 and size. onnxruntime 1.20.1 (CPU).

**Result (run 2026-11-06):**

| Pair | Identical | chrF (b vs a) | Verdict | Old decoder | New decoder | Pair total |
|---|---|---|---|---|---|---|
| en-es | 45/50 (90%) | 98.61 | accept, at the threshold | 193.3 MB | 60.2 MB | 248.7 → 115.6 MB |
| en-de | 49/50 (98%) | 99.43 | accept | 175.6 MB | 56.7 MB | 227.1 → 108.2 MB |
| de-en | 49/50 (98%) | 99.93 | accept | 175.6 MB | 56.7 MB | 227.1 → 108.2 MB |
| en-ru | 47/50 (94%) | 99.14 | accept | 186.9 MB | 58.9 MB | 242.1 → 114.1 MB |
| ru-en | 48/50 (96%) | 99.52 | accept | 186.9 MB | 58.9 MB | 242.3 → 114.3 MB |
| zh-en | 48/50 (96%) | 99.20 | accept | 193.3 MB | 60.2 MB | 248.7 → 115.6 MB |

Every output that differed was a fluent paraphrase of the other (“Las
fuertes lluvias provocaron” against “La fuerte lluvia causó”; “Хотите”
against “Хочешь”; “Officials expect” against “The officials expect”). No
difference brought in a mistranslation, a dropped clause, or a broken
name or number. One en-ru grammar slip (“ближайший аптека”) appears with
both decoders, so it is the model’s, not the export’s.

A first run printed the same numbers with every pair rejected, because
its compatibility check counted Xenova’s explicit `bad_words_ids=[[pad]]`
as a difference. The app bans pad either way, so the check was corrected
to compare the effective banned set and re-run. Phones keep
onnx-community’s config.

**Pins** (url, sha256, bytes) are in `translation_catalog.dart`, at these
Xenova commits: en-es `4b002a4c`, en-de `1ca130c4`, de-en `399dfd68`,
en-ru `e050376e`, ru-en `afe8c6c7`, zh-en `39d480d5`.

Tests, `packages/ml_runtime/test/translation_catalog_test.dart`: “takes
Xenova’s int8 decoder at a pinned commit”, “keeps onnx-community’s
encoder, tokenizer and configs”, “the whole pair is under 130 MB”.

### 5. A phone that has the old decoder updates once, and the old file goes

Each pair keeps its spec id and the decoder keeps its file name, so a
1.5.8 phone sees its pair as present but one file short. The Models
screen and the Translate sheet word that as a download size, “Update
available: 60.2 MB”, not as an error (`app/test/models/models_screen_test.dart`
and `app/test/features/reader_translate_test.dart`, “a downloaded pair
whose decoder was re-pinned reads as an update”). The listener fetches it
from either screen, never at start-up.

`DiskModelStore.pruneUnreferenced` deletes model files no registered spec
still lists: the old decoder, and the Qwen files 1.5.9 removed. It keeps a
download in flight, a paused `.part` that can still resume, extracted
voice and dictionary directories, and anything outside the models
directory (`app/test/models/model_store_prune_test.dart`, including
“swapped decoder prunes old file”, “prune keeps in-flight .part files”
and “a models directory given with a trailing slash keeps installed
files”). Start-up runs the prune and nothing else: it makes no network
request, per ADR-0003 law 6 (`app/test/bootstrap_io_test.dart`, “start-up
tidies the model store”).

A translation interrupted under 1.5.8 can’t resume until its pair is
updated; after the update the language has to be picked again.

### 6. Stale files are judged by size alone

`DiskModelStore.isDownloaded` and the prune judge a plain installed file
by its name and its length against the pin. The sha256 is checked once,
at download, before the file is promoted. The 1.5.9 swap works because
the old and new decoders share a name and differ in size (193 MB against
60 MB).

**A future re-pin to a file of the same name and the same byte count
would read as installed, and the old weights would stay.** Such a re-pin
must change the file name (the store names a file after the last segment
of its URL), or the store must first gain a hash marker: a record of each
promoted file’s sha256, compared against the pin. Archives (voices,
dictionaries) are judged only by their extracted directory existing, not
by size.

## Consequences

- **What has been seen running.** A release build of 3444ab8 on an x86_64
  emulator (2026-11-07) listed en→ru at 114.1 MB in the Translate sheet,
  downloaded it fresh and translated “We walked home along the old road.”
  as “Мы пошли домой по старой дороге.” One weaker sentence in that run is
  within the base model’s quality, as the parity check found. Still
  unchecked on a device: the “Update available” fetch over a real 1.5.8
  install (it needs 1.5.8 data under the same signing key), and an arm64
  phone. Both are on the release checklist.
- en-es passed at exactly 90% identical. Its differences are paraphrases,
  but it has no margin; a later re-pin of that pair should be checked
  again rather than assumed.
- A listener offline at upgrade loses the six older pairs until the 60 MB
  update can be fetched. That is inherent to a re-pin under the same id.
- The translation job still runs on the UI isolate, with inference on the
  native side (ADR-0008, 1.5.5).

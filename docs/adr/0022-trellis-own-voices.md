# ADR-0022: Trellis's own voices, one per language

- Status: Accepted
- Date: 2026-11-13

## Context

The owner's ruling of 13 November 2026 (board-0203, board-0211): Trellis
gets its own voices, downloaded inside the app, one per language,
whatever the phone has. Phone voices stay an extra, never the only way.
Nobody should have to add a voice in Android's settings. The owner then
said yes to two engines from the survey: Kyutai's Pocket TTS and hexgrad's
Kokoro. On the owner's phone the only languages Trellis could speak were
Spanish, French and Portuguese, all through Supertonic 2, whose weights are
OpenRAIL-M and whose maker is reported dissolved.

A clean licence here means the code, the weights and the training data
are MIT, Apache-2.0, BSD, CC-BY or CC0, and nothing at run time needs
espeak-ng (GPL-3).

Correction (13 November, after 1.6.14 shipped): the training data of
both engines was not checked before the release, and neither meets that
bar as written.
- **Pocket TTS.** Kyutai does not state the training data of its
  released models. The paper its model card cites (arXiv 2509.06926,
  appendix D) trained its TTS models on AMI, Earnings-22 (CC-BY-SA),
  GigaSpeech and SPGISpeech (non-commercial or research terms),
  TED-LIUM, VoxPopuli, LibriHeavy and Emilia (CC-BY-NC).
- **Kokoro v1.1-zh.** Its Chinese data was "freely and permissively
  granted" by LongMaoData, a dataset company, with no licence named.
  Synthetic English made with closed TTS services is also mixed in.
- The weights themselves are CC-BY-4.0 and Apache-2.0, and every voice
  clip is CC0 or CC-BY-4.0. Whether the shipped voices stay is the
  owner's call (board, 13 November).

## Decision

### One rule for every voice

A language has a downloaded voice when the model registry has a `tts`
entry whose `langs` names it (`ModelRegistry.voiceFor`, `voiceLangs`); a
test holds that no two entries claim one language. Every voice downloaded
on the device sits behind one engine (`DownloadedVoices`) that hands each
sentence to the voice for its language, so one Read aloud run or one
episode can use several. Read aloud, its voice settings, the one tap and
the language picker all read this one rule. Adding a voice is a registry
entry.

### Pocket TTS: German, Spanish, French, Italian, Portuguese, Dutch, English

- Weights only from Kyutai's ungated repository
  `kyutai/pocket-tts-without-voice-cloning` (CC-BY-4.0), at a pinned
  revision. Nobody on Trellis's side accepts Kyutai's gate, and the voice
  cloning encoder is not part of Trellis. Trellis clones no voice.
- Trellis converts the weights to ONNX itself (ADR-0014's rule: a model
  runs only from an export Trellis trusts) and keeps the files on the
  permanent release `models-voices-1`. The export matches Kyutai's own
  PyTorch on the same noise in all seven languages (70 of 70 sentences,
  the same tokens and frame count, audio correlation at least 0.997).
  The flow transformer and flow net ship as int8 (dynamic, per channel,
  MatMul only); the Mimi decoder ships in fp32 and is one file shared by
  every language (`ModelFile.shared`, stored once, deleted with the last
  voice that uses it).
- Voices are Kyutai's ready voice states, one per language, each from a
  source with a clean licence; each voice's speaker and licence is shown
  with it: German caro_davy, English bill_boerst, Spanish lola, French
  estelle, Italian giovanni (CC0); Dutch daan, Portuguese mary
  (CC-BY-4.0). Where several clean voices passed equally, the one
  Whisper was most sure of was picked. The record of each is
  docs/reference/tts-voices.md. Excluded: Kyutai's Expresso and EARS voices (CC-BY-NC), and two
  whose source does not state a licence (`rafael`, `juergen`).
- Text is prepared exactly as Kyutai prepares it (`pocket_text.dart`,
  `pocket_chunks.dart`), tokenized by a Dart reader of Hugging Face's
  `tokenizer.json` (equal ids on 1,400 lines in seven languages), and the
  generation loop is a Dart port of the reference loop (`pocket_loop.dart`),
  which ends on the same frame as Kyutai's on the real graphs.
- Kyutai's defaults: temperature 0.3, one flow step. A careful pace gives
  four steps. The model has no speed input, so a slower pace leaves a pause
  after each sentence instead.

### Kokoro-82M v1.1-zh: Chinese

- The fp16 ONNX export from `thewh1teagle/kokoro-onnx` (Apache-2.0), kept
  on `models-voices-1`. The onnx-community fp16 file returns NaN audio for
  every line past 30 phonemes on ONNX Runtime 1.32, and int8 drifts in
  Chinese. The engine refuses audio with a NaN in it rather than play it.
- Voice `zf_001`, the maker's own sample voice.
- The text front end is a Dart port of misaki's Chinese G2P
  (`packages/mandarin_g2p`: cn2an, jieba with its HMM and part-of-speech
  tags, pypinyin, misaki's tone sandhi and erhua). It equals misaki token
  for token on 418 of 418 lines. pypinyin-dict's `large_pinyin` is not
  used, because part of it is CC-BY-SA; twelve word readings it gets right
  and pypinyin alone does not are kept in Trellis's own list, each checked
  against a second source.
- The style row and speed follow the maker's code: row = phonemes - 1, and
  speed falls from 1.1 to 0.88 between 83 and 183 phonemes.

### Supertonic

Supertonic 2 would have stayed for a language where Pocket TTS failed
the gate below. Pocket TTS passed in all four of its languages (en, es,
fr, pt), so Supertonic retires in the release that ships these voices,
engine and all.

### The gate

Before a voice ships: the app's own engine speaks test sentences on an
Android emulator through the phone's ONNX Runtime plugin; the audio goes
back to the desktop, Whisper transcribes it, and the word error must be
within 1.5 times that of Kyutai's PyTorch on the same sentences. No
audio may contain a NaN. Nobody has heard these voices on the owner's
phone before the release; the owner hears them after.

## Not done here

- Korean and Russian: no clean, phone-sized voice yet. The best clean
  candidates went to the owner (board-0211).
- Kokoro's Japanese voices need a Japanese word splitter with readings
  ported to Dart; that is a separate job.
- Kokoro's English needs its own front end; Pocket TTS covers English.

## Consequences

- Every downloaded voice is labelled machine-made, as before.
- About 108 MB per Pocket TTS language, plus 41 MB once for the shared
  decoder; about 175 MB for Chinese.
- Pocket TTS has no speed input: a slower pace leaves a pause after each
  sentence, and a careful step gives four flow steps.
- The gate's numbers: 10 sentences per language through whisper
  large-v3. Int8 word error was 0% in en, de and es, about 1% in fr, it
  and nl, and 4.2% against PyTorch's 3.1% in pt. The device files scored
  the same as desktop. One word is about 1% of the set, so the gate
  catches a broken export but cannot rank close voices.
- The CC-BY licence asks for credit, a licence link and a note of
  changes: the Models screen's Voices section and the release's NOTICE
  carry them.

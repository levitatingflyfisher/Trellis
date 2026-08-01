# TTS voices — the licensing record (ADR-0007, retired: ADR-0006)

A downloadable voice is a data entry in `ml_runtime`'s `ModelRegistry`
(`packages/ml_runtime/lib/src/registry.dart`, `ModelRegistry.starter()`), not
code — adding a voice never touches the Supertonic engine. This file is the
verbatim license record for every candidate considered, so the choice can be
checked rather than trusted.

## Starter voice: `supertonic-en-m1`

**Chosen (ADR-0007).** Supertonic v2 (`Supertone/supertonic-2` on Hugging
Face), fp32 ONNX, voice style M1 — the official Flutter example's own
default. Needs no phonemizer: the model consumes raw character indices, so
there is no espeak-ng-shaped second license to carry.

- Registry id: `supertonic-en-m1`
- Source: `https://huggingface.co/Supertone/supertonic-2` (verified
  2026-08-14 — NOT `Supertone/supertonic`, which is a same-size-class v1,
  English-only sibling repo; the URL was confirmed by downloading and
  checking `cardData.language` and file sizes against ADR-0007's own
  research verdict, not assumed from the repo name)
- Sample rate: 44,100 Hz · languages the MODEL covers: en/ko/es/pt/fr (this
  entry claims only `en` — one voice embedding, reviewed for one language;
  see ADR-0007's language-honesty section)
- Total size: 263,520,679 bytes (~263.5 MB) across seven files, all
  downloaded directly and hashed locally 2026-08-14:

| File | Bytes | sha256 |
|---|---|---|
| `onnx/duration_predictor.onnx` | 1,521,526 | `6d556b3691165c364be91dc0bd894656b5949f5acd2750d8ec2f954010845011` |
| `onnx/text_encoder.onnx` | 27,431,318 | `dd5f535ed629f7df86071043e15f541ce1b2ab7f1bdbce4c7892b307bca79fa3` |
| `onnx/vector_estimator.onnx` | 132,471,364 | `105e9d66fd8756876b210a6b4aa03fc393b1eaca3a8dadcc8d9a3bc785c86a35` |
| `onnx/vocoder.onnx` | 101,405,066 | `19bd51f47a186069c752403518a40f7ea4c647455056d2511f7249691ecddf7c` |
| `onnx/unicode_indexer.json` | 262,196 | `b7662a73a0703f43b97c0f2e089f8e8325e26f5d841aca393b5a54c509c92df1` |
| `onnx/tts.json` | 8,699 | `ee531d9af9b80438a2ed703e22155ee6c83b12595ab22fd3bb6de94c7502fe96` |
| `voice_styles/M1.json` | 420,510 | `a04c823cbda6dd1c7de131ec68fea83bbb70d7f29d61623304eb871e3b83b5a1` |

No archive to extract — every file above ships loose and is downloaded,
sha256-verified, and promoted independently (the same per-file law
whisper's single model file already follows); `SupertonicVoiceLayout` names
which file plays which role.

### LICENSE, verbatim (fetched 2026-08-14 from
`https://huggingface.co/Supertone/supertonic-2/resolve/main/LICENSE`)

```
BigScience Open RAIL-M License
dated August 18, 2022

Section I: PREAMBLE

This Open RAIL-M License was created by BigScience, a collaborative open innovation project aimed at
the responsible development and use of large multilingual datasets and Large Language Models
(“LLMs”). While a similar license was originally designed for the BLOOM model, we decided to adapt it
and create this license in order to propose a general open and responsible license applicable to other
machine learning based AI models (e.g. multimodal generative models).
In short, this license strives for both the open and responsible downstream use of the accompanying
model. When it comes to the open character, we took inspiration from open source permissive licenses
regarding the grant of IP rights. Referring to the downstream responsible use, we added use-based
restrictions not permitting the use of the Model in very specific scenarios, in order for the licensor to be
able to enforce the license in case potential misuses of the Model may occur. Even though downstream
derivative versions of the model could be released under different licensing terms, the latter will always
have to include - at minimum - the same use-based restrictions as the ones in the original license (this
license).
The development and use of artificial intelligence (“AI”), does not come without concerns. The world has
witnessed how AI techniques may, in some instances, become risky for the public in general. These risks
come in many forms, from racial discrimination to the misuse of sensitive information.
BigScience believes in the intersection between open and responsible AI development; thus, this License
aims to strike a balance between both in order to enable responsible open-science in the field of AI.
This License governs the use of the model (and its derivatives) and is informed by the model card
associated with the model.

NOW THEREFORE, You and Licensor agree as follows:

1. Definitions
(a) "License" means the terms and conditions for use, reproduction, and Distribution as defined in
this document.
(b) “Data” means a collection of information and/or content extracted from the dataset used with the
Model, including to train, pretrain, or otherwise evaluate the Model. The Data is not licensed under
this License.
(c)“Output” means the results of operating a Model as embodied in informational content resulting
therefrom.
(d)“Model” means any accompanying machine-learning based assemblies (including checkpoints),
consisting of learnt weights, parameters (including optimizer states), corresponding to the model
architecture as embodied in the Complementary Material, that have been trained or tuned, in whole or
in part on the Data, using the Complementary Material.
(e) “Derivatives of the Model” means all modifications to the Model, works based on the Model, or any
other model which is created or initialized by transfer of patterns of the weights, parameters,
activations or output of the Model, to the other model, in order to cause the other model to perform
similarly to the Model, including - but not limited to - distillation methods entailing the use of
intermediate data representations or methods based on the generation of synthetic data by the Model
for training the other model.
(f)“Complementary Material” means the accompanying source code and scripts used to define,
run, load, benchmark or evaluate the Model, and used to prepare data for training or evaluation, if
any. This includes any accompanying documentation, tutorials, examples, etc, if any.
(g) “Distribution” means any transmission, reproduction, publication or other sharing of the Model or
Derivatives of the Model to a third party, including providing the Model as a hosted service made
available by electronic or other remote means - e.g. API-based or web access.
(h) “Licensor” means the copyright owner or entity authorized by the copyright owner that is
granting the License, including the persons or entities that may have rights in the Model and/or
distributing the Model.
(i) "You" (or "Your") means an individual or Legal Entity exercising permissions granted by this
License and/or making use of the Model for whichever purpose and in any field of use, including
usage of the Model in an end-use application - e.g. chatbot, translator, image generator.
(j) “Third Parties” means individuals or legal entities that are not under common control with
Licensor or You.
(k) "Contribution" means any work of authorship, including the original version of the Model and
any modifications or additions to that Model or Derivatives of the Model thereof, that is
intentionally submitted to Licensor for inclusion in the Model by the copyright owner or by an
individual or Legal Entity authorized to submit on behalf of the copyright owner. For the
purposes of this definition,
“submitted” means any form of electronic, verbal, or written
communication sent to the Licensor or its representatives, including but not limited to
communication on electronic mailing lists, source code control systems, and issue tracking
systems that are managed by, or on behalf of, the Licensor for the purpose of discussing and
improving the Model, but excluding communication that is conspicuously marked or otherwise
designated in writing by the copyright owner as "Not a Contribution."
(l) "Contributor" means Licensor and any individual or Legal Entity on behalf of whom a
Contribution has been received by Licensor and subsequently incorporated within the Model.


Section II: INTELLECTUAL PROPERTY RIGHTS

Both copyright and patent grants apply to the Model, Derivatives of the Model and Complementary
Material. The Model and Derivatives of the Model are subject to additional terms as described in Section III.

2. Grant of Copyright License. Subject to the terms and conditions of this License, each Contributor
hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable copyright license to reproduce, prepare, publicly display, publicly perform, sublicense, and distribute the
Complementary Material, the Model, and Derivatives of the Model.

3. Grant of Patent License. Subject to the terms and conditions of this License and where and as
applicable, each Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge,
royalty-free, irrevocable (except as stated in this paragraph) patent license to make, have made, use, offer
to sell, sell, import, and otherwise transfer the Model and the Complementary Material, where such
license applies only to those patent claims licensable by such Contributor that are necessarily infringed by
their Contribution(s) alone or by combination of their Contribution(s) with the Model to which such
Contribution(s) was submitted. If You institute patent litigation against any entity (including a cross-claim
or counterclaim in a lawsuit) alleging that the Model and/or Complementary Material or a Contribution
incorporated within the Model and/or Complementary Material constitutes direct or contributory patent
infringement, then any patent licenses granted to You under this License for the Model and/or Work shall
terminate as of the date such litigation is asserted or filed.
Section III: CONDITIONS OF USAGE, DISTRIBUTION AND REDISTRIBUTION

4. Distribution and Redistribution. You may host for Third Party remote access purposes (e.g.
software-as-a-service), reproduce and distribute copies of the Model or Derivatives of the Model thereof
in any medium, with or without modifications, provided that You meet the following conditions:

a. Use-based restrictions as referenced in paragraph 5 MUST be included as an enforceable provision
by You in any type of legal agreement (e.g. a license) governing the use and/or distribution of the
Model or Derivatives of the Model, and You shall give notice to subsequent users You Distribute to,
that the Model or Derivatives of the Model are subject to paragraph 5. This provision does not apply
to the use of Complementary Material.

b. You must give any Third Party recipients of the Model or Derivatives of the Model a copy of this
License;

c. You must cause any modified files to carry prominent notices stating that You changed the files;

d. You must retain all copyright, patent, trademark, and attribution notices excluding those notices
that do not pertain to any part of the Model, Derivatives of the Model.
You may add Your own copyright statement to Your modifications and may provide additional or
different license terms and conditions - respecting paragraph 4.a.
- for use, reproduction, or Distribution
of Your modifications, or for any such Derivatives of the Model as a whole, provided Your use,
reproduction, and Distribution of the Model otherwise complies with the conditions stated in this License.

5. Use-based restrictions. The restrictions set forth in Attachment A are considered Use-based restrictions.
Therefore You cannot use the Model and the Derivatives of the Model for the specified restricted uses. You
may use the Model subject to this License, including only for lawful purposes and in accordance with the
License. Use may include creating any content with, finetuning, updating, running, training, evaluating and/or
reparametrizing the Model. You shall require all of Your users who use the Model or a Derivative of the Model
to comply with the terms of this paragraph (paragraph 5).

6. The Output You Generate. Except as set forth herein, Licensor claims no rights in the Output You
generate using the Model. You are accountable for the Output you generate and its subsequent uses. No
use of the output can contravene any provision as stated in the License.

Section IV: OTHER PROVISIONS

7. Updates and Runtime Restrictions. To the maximum extent permitted by law, Licensor reserves the
right to restrict (remotely or otherwise) usage of the Model in violation of this License, update the Model
through electronic means, or modify the Output of the Model based on updates. You shall undertake
reasonable efforts to use the latest version of the Model.

8. Trademarks and related. Nothing in this License permits You to make use of Licensors’ trademarks,
trade names, logos or to otherwise suggest endorsement or misrepresent the relationship between the
parties; and any rights not expressly granted herein are reserved by the Licensors.

9. Disclaimer of Warranty. Unless required by applicable law or agreed to in writing, Licensor provides
the Model and the Complementary Material (and each Contributor provides its Contributions) on an "AS
IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied,
including, without limitation, any warranties or conditions of TITLE, NON-INFRINGEMENT,
MERCHANTABILITY , or FITNESS FOR A PARTICULAR PURPOSE. You are solely responsible for
determining the appropriateness of using or redistributing the Model, Derivatives of the Model, and the
Complementary Material and assume any risks associated with Your exercise of permissions under this
License.

10. Limitation of Liability. In no event and under no legal theory, whether in tort (including negligence),
contract, or otherwise, unless required by applicable law (such as deliberate and grossly negligent acts) or
agreed to in writing, shall any Contributor be liable to You for damages, including any direct, indirect,
special, incidental, or consequential damages of any character arising as a result of this License or out of
the use or inability to use the Model and the Complementary Material (including but not limited to
damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other
commercial damages or losses), even if such Contributor has been advised of the possibility of such
damages.

11. Accepting Warranty or Additional Liability. While redistributing the Model, Derivatives of the
Model and the Complementary Material thereof, You may choose to offer, and charge a fee for, acceptance
of support, warranty, indemnity, or other liability obligations and/or rights consistent with this License.
However, in accepting such obligations, You may act only on Your own behalf and on Your sole
responsibility, not on behalf of any other Contributor, and only if You agree to indemnify, defend, and
hold each Contributor harmless for any liability incurred by, or claims asserted against, such Contributor
by reason of your accepting any such warranty or additional liability.

12. If any provision of this License is held to be invalid, illegal or unenforceable, the remaining
provisions shall be unaffected thereby and remain valid as if such provision had not been set forth herein.

END OF TERMS AND CONDITIONS

Attachment A

Use Restrictions

You agree not to use the Model or Derivatives of the Model:
(a) In any way that violates any applicable national, federal, state, local or international law
or regulation;
(b) For the purpose of exploiting, harming or attempting to exploit or harm minors in any
way;
(c) To generate or disseminate verifiably false information and/or content with the purpose of
harming others;
(d) To generate or disseminate personal identifiable information that can be used to harm an
individual;
(e) To generate or disseminate information and/or content (e.g. images, code, posts, articles),
and place the information and/or content in any context (e.g. bot generating tweets)
without expressly and intelligibly disclaiming that the information and/or content is
machine generated;
(f) To defame, disparage or otherwise harass others;
(g) To impersonate or attempt to impersonate (e.g. deepfakes) others without their consent;
(h) For fully automated decision making that adversely impacts an individual’s legal rights or
otherwise creates or modifies a binding, enforceable obligation;
(i) For any use intended to or which has the effect of discriminating against or harming
individuals or groups based on online or offline social behavior or known or predicted
personal or personality characteristics;
(j) To exploit any of the vulnerabilities of a specific group of persons based on their age,
social, physical or mental characteristics, in order to materially distort the behavior of a
person pertaining to that group in a manner that causes or is likely to cause that person or
another person physical or psychological harm;
(k) For any use intended to or which has the effect of discriminating against individuals or
groups based on legally protected characteristics or categories;
(l) To provide medical advice and medical results interpretation;
(m) To generate or disseminate information for the purpose to be used for administration of
justice, law enforcement, immigration or asylum processes, such as predicting an
individual will commit fraud/crime commitment (e.g. by text profiling, drawing causal
relationships between assertions made in documents, indiscriminate and
arbitrarily-targeted use).
```

**Finding:** BigScience Open RAIL-M — commercial use and redistribution
permitted, WITH the use-based restrictions in Attachment A binding on every
downstream user (§5), and a requirement that anyone receiving the model gets
a copy of this license (§4.b). Trellis never redistributes these weights
itself — the models screen's download pulls directly from
`Supertone/supertonic-2` on Hugging Face, where `LICENSE` sits alongside
every weight file, so the user's copy of the license comes from Supertone
(the licensor) directly. See ADR-0007's Weights licensing section for the
full accounting, including why the app's own code stays MIT regardless.

## Considered and rejected: the csukuangfj2 int8 repack

`csukuangfj2/sherpa-onnx-supertonic-tts-int8-2026-03-06` on Hugging Face —
considered as the size-reduction option in ADR-0007's Phase 0 ranking (option
2 of 3). Rejected on two independent grounds:

1. **No license.** The repo's own metadata reports `license: None`. This
   alone disqualifies unlicensed weights from a license-hygiene campaign,
   regardless of anything below.
2. **Its support files aren't in the format this engine's ported inference
   code reads.** `unicode_indexer.bin` (262,144 bytes) is a raw binary,
   where the ported `UnicodeProcessor`-equivalent (adapted from the official
   Flutter example) `jsonDecode`s a JSON array. `voice.bin` (517,168 bytes)
   is likewise a packed binary, where the ported voice-style loader expects
   a per-voice JSON file with `style_ttl`/`style_dp` keys. Both formats are
   shaped for sherpa-onnx's own C++ loader — using them here would mean
   reverse-engineering two undocumented binary formats.

**Worth recording anyway:** `duration_predictor.int8.onnx` and
`text_encoder.int8.onnx` in that repack are byte-identical (same sha256) to
the fp32 originals — never actually quantized despite the filename. Only
`vector_estimator.int8.onnx` (40,686,657 bytes) and `vocoder.int8.onnx`
(25,977,132 bytes) are genuinely smaller than their fp32 counterparts. A
hybrid pairing those two graphs with Supertone's own JSON support files was
considered and set aside — still no license on the quantized files, and a
clean fully-licensed fp32 option already exists. See ADR-0007 for the full
reasoning.

## Retired voices

Superseded by `supertonic-en-m1` (ADR-0007). Kept below, not deleted — the
license verification work is a record worth keeping even after the voice
itself is gone from the registry.

### `piper-en-libritts-r-medium` (ADR-0006, removed)

**Was chosen, now retired.** Piper `en_US-libritts_r-medium`,
int8-quantized, via sherpa-onnx's release bundle.

- Registry id: `piper-en-libritts-r-medium`
- Download: `https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-libritts_r-medium-int8.tar.bz2`
- sha256: `7e4552e239988f4896872822b56e99e0e9e00958164e3f6bdf5ee14391fbe829`
- Size: 23,398,348 bytes (23.4 MB)
- Sample rate: 22,050 Hz · 904 speakers (multi-speaker VITS; the engine
  defaults to speaker id 0 — a real, stable voice in that set, not a
  placeholder; a speaker picker is future work)
- Archive layout (verified by downloading, hashing, and extracting the file
  above): top-level dir `vits-piper-en_US-libritts_r-medium-int8/`, containing
  `en_US-libritts_r-medium.onnx`, `en_US-libritts_r-medium.onnx.json`,
  `tokens.txt`, `MODEL_CARD`, and `espeak-ng-data/` (355 files).

#### MODEL_CARD, verbatim (fetched 2026-08-14 from
`https://huggingface.co/rhasspy/piper-voices/raw/main/en/en_US/libritts_r/medium/MODEL_CARD`,
and confirmed identical inside the downloaded archive's own copy)

```
# Model card for libritts_r (medium)

* Language: en_US (English, United States)
* Speakers: 904
* Quality: medium
* Samplerate: 22,050Hz

## Dataset

* URL: http://www.openslr.org/141/
* License: CC BY 4.0

## Training

Fine-tuned from English lessac medium on train-clean-360.
```

**Finding:** CC BY 4.0 (Creative Commons Attribution 4.0) over the LibriTTS-R
corpus (OpenSLR 141) — freely redistributable, commercial use permitted, with
attribution. Clean pick — retired for the engine-side espeak-ng obligation
below, not for anything wrong with the voice's own weights.

### Rejected candidate: `en_US-lessac-medium`

Considered because its size class and quality tier are comparable to
libritts_r. Rejected on license grounds.

#### MODEL_CARD, verbatim (fetched 2026-08-14 from
`https://huggingface.co/rhasspy/piper-voices/raw/main/en/en_US/lessac/medium/MODEL_CARD`)

```
# Model card for lessac (medium)

* Language: en_US (English, United States)
* Speakers: 1
* Quality: medium
* Samplerate: 22,050Hz

## Dataset

* URL: https://www.cstr.ed.ac.uk/projects/blizzard/2013/lessac_blizzard2013/
* License: https://www.cstr.ed.ac.uk/projects/blizzard/2013/lessac_blizzard2013/license.html
```

The MODEL_CARD's own license field is a link, not a name — followed it
(fetched 2026-08-14) rather than assuming. The linked page is a "RESEARCH
LICENCE AGREEMENT" between Voice Factory International, Inc. and Lessac
Technologies, Inc., naming the audio book recordings and associated data as
their property. It requires a named licensee (person or organization),
complete postal address, and a manually-verified email exchange before a
download password is issued — "Each license is manually verified before a
download password is issued." This is a gated, per-user research license,
not a freely redistributable one.

**Finding:** rejected. A voice built on this corpus cannot be redistributed
inside an app's downloadable asset catalog without violating the license's
own acceptance terms (the app's users would never individually accept the
agreement or receive their own password).

### Licensing note carried into ADR-0006 (why Piper was retired)

The voice's own weights (CC BY 4.0) were clean. The sherpa-onnx TTS *engine
path* bundled espeak-ng's phoneme data inside the SAME release archive
(`espeak-ng-data/`, 355 files) — espeak-ng is GPL-3.0. An APK shipping that
rung would have distributed GPL-3.0 code alongside the app's own MIT code;
see ADR-0006's Licensing section (now pointing to ADR-0007) for the full
accounting that led to Supertonic replacing this rung entirely rather than
taking the recorded espeak-free escape hatch (piper-plus, MIT) in place.

### Quantization (Piper, retired)

int8 was picked on **size** (23.4 MB vs. 43.1 MB fp16 vs. 82.0 MB fp32/full),
following the fleet's whisper-tiny q8 precedent. Nobody verified this by ear
in this pass — TTS quantization artifacts are audible in a way ASR's aren't.
Kept here for the record even though the voice is retired; the sibling
release assets:

- `vits-piper-en_US-libritts_r-medium-int8.tar.bz2` — 23,398,348 bytes (was chosen)
- `vits-piper-en_US-libritts_r-medium-fp16.tar.bz2` — 43,071,574 bytes
- `vits-piper-en_US-libritts_r-medium.tar.bz2` (fp32/full) — 82,038,311 bytes

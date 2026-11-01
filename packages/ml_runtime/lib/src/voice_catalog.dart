/// Trellis's own voices, one per language (owner, 13 Nov, board-0211).
/// Each entry is pinned by sha256 and byte length, and comes either from
/// Trellis's own models release (`models-voices-1`, files Trellis
/// converted or keeps a copy of) or from its maker at a fixed revision.
/// Provenance and licences: docs/reference/tts-voices.md.
library;

import 'registry.dart';

const _release =
    'https://github.com/levitatingflyfisher/Trellis/releases/download/models-voices-1/';

/// Kyutai's ungated repository (CC-BY-4.0) at the revision pocket-tts
/// 4.0.1 pins: nobody accepts a gate, and the voice-cloning encoder is
/// not in it.
const _kyutaiRevision = 'a7056f505a4a8ca72d8b5fb1440071d6f1a35739';
const _kyutai =
    'https://huggingface.co/kyutai/pocket-tts-without-voice-cloning/resolve/$_kyutaiRevision/languages/';

/// Pocket TTS's Mimi decoder, fp32, the same graph for every language:
/// stored once on the phone and deleted with the last voice that uses it.
final _mimi = ModelFile(
  url: '${_release}pocket-mimi_decoder.onnx',
  sha256: '6d011922afe90bd200d81865acab176b1bc10ef2d7a4235fc4dd3aef64e82976',
  bytes: 41275933,
  shared: true,
);

/// A Pocket TTS voice for one language. Trellis's own ONNX export of
/// Kyutai's weights (the text conditioner, and the flow transformer and
/// flow net in int8: ADR-0022) comes from the Trellis release; the
/// tokenizer and the ready voice state come from Kyutai at the pinned
/// revision. Each voice is one of Kyutai's defaults whose recording has a
/// clean licence (CC0 or CC-BY-4.0), checked against Kyutai's voice
/// list (pocket_tts/utils/utils.py) and the kyutai/tts-voices README.
ModelSpec _pocket({
  required String tag,
  required String language,
  required (String, int) conditioner,
  required (String, int) main,
  required (String, int) flow,
  required (String, int) tokenizer,
  required String voice,
  required (String, int) voiceFile,
  required String credit,
}) {
  ModelFile own(String name, (String, int) pin) => ModelFile(
      url: '${_release}pocket-$language-$name', sha256: pin.$1, bytes: pin.$2);
  return ModelSpec(
    id: 'pocket-$tag',
    task: ModelTask.tts,
    files: [
      own('text_conditioner.onnx', conditioner),
      own('flow_lm_main_int8.onnx', main),
      own('flow_lm_flow_int8.onnx', flow),
      _mimi,
      ModelFile(
          url: '$_kyutai$language/tokenizer.json',
          sha256: tokenizer.$1,
          bytes: tokenizer.$2),
      ModelFile(
          url: '$_kyutai$language/embeddings/$voice.safetensors',
          sha256: voiceFile.$1,
          bytes: voiceFile.$2),
    ],
    licenses: [
      'CC-BY-4.0',
      if (credit.contains('CC0')) 'CC0-1.0',
    ],
    minTier: DeviceTier.t1,
    langs: {tag},
    pocketLayout: PocketVoiceLayout(
      language: language,
      textConditionerFileName: 'pocket-$language-text_conditioner.onnx',
      mainFileName: 'pocket-$language-flow_lm_main_int8.onnx',
      flowFileName: 'pocket-$language-flow_lm_flow_int8.onnx',
      mimiFileName: 'pocket-mimi_decoder.onnx',
      tokenizerFileName: 'tokenizer.json',
      voiceFileName: '$voice.safetensors',
      voiceCredit: credit,
    ),
  );
}

List<ModelSpec> voiceCatalog() => [
      // German, English, Spanish, French, Italian, Dutch, Portuguese:
      // Pocket TTS (Kyutai, CC-BY-4.0). Voices picked by the speech-
      // recognition gate (ADR-0022): every one at or under 1.5 times
      // Kyutai's own PyTorch word error, and the most certain transcript
      // among the clean voices where several tied.
      _pocket(
        tag: 'de',
        language: 'german',
        conditioner: (
          '39b8e77f10db5c8a06f72b7750408b4eb08df20df6506c68cbae7e6285eb061a',
          16388650,
        ),
        main: (
          '0812eebc08640c76c14f647d00329b71854c4e853f5bdb1c39ca776422833923',
          76096610,
        ),
        flow: (
          '7676096b5562ef1789995aef6ff8f9b1b280e8aa96c782f39f584ab2ba0d19fb',
          10050520,
        ),
        tokenizer: (
          '2d77849811e3d1b6ae80e5b11b203f57e1847901104d8a0573b34f46f8dddb53',
          245966,
        ),
        voice: 'caro_davy',
        voiceFile: (
          '1f19753a2d06366db2dc261bf9026f582836cde579fea9857a21e9f28c474362',
          5064504,
        ),
        credit: 'caro_davy (a LibriVox reader, CC0)',
      ),
      _pocket(
        tag: 'en',
        language: 'english',
        conditioner: (
          'd44e296f1d751d9f8ad371d4cbc25fe645d965b85a2296341221189b59cdc4df',
          16388650,
        ),
        main: (
          '29ab0cac4f553f255eae55f59152537a17d101d11d1b19bc38e752397b953051',
          76096610,
        ),
        flow: (
          '9d2efd253adb8b9f088f6ff57f3c406894f529055922a504062b1a14edd6e80f',
          10050520,
        ),
        tokenizer: (
          'f498428e1eafee50492f7be13dc9bfafcfc12e508cd0eb1b01c92ecd5d8c6687',
          245020,
        ),
        voice: 'bill_boerst',
        voiceFile: (
          'a4510681c5ca6ac978b9fee83fc8a0d6569f7627b380caab0c5d23c53e4c0607',
          6539064,
        ),
        credit: 'bill_boerst (a LibriVox reader, CC0)',
      ),
      _pocket(
        tag: 'es',
        language: 'spanish',
        conditioner: (
          'b44230e610a000df395e19e14aa96899b773c7f6bc74ea1fb20579c1bda46738',
          16388650,
        ),
        main: (
          'd2f5f9e6a1c5cabd1445f5676107dbdeee07690cb1069ab5e57e53bc8aa0e814',
          76096610,
        ),
        flow: (
          '51cd9e050ad5fed75dba1f725a8123b8425ee4ab505be86fdab31a04d7118a9b',
          10050520,
        ),
        tokenizer: (
          '9ade09bbdc64ab2b59952b90773fa0890b780ece4fd5aef0d36a00c6ad5f0531',
          246610,
        ),
        voice: 'lola',
        voiceFile: (
          '967b8f08639345ff5ad1a912a5542fe421518c3f80b87d52078c6726348ab1e7',
          5457720,
        ),
        credit: 'lola (a Common Voice speaker, CC0)',
      ),
      _pocket(
        tag: 'fr',
        language: 'french',
        conditioner: (
          '37be848ebd7558b925eb498a9b7e2b3797630d6f4a885d43f0dc8d1b1bf6dfc6',
          16388650,
        ),
        main: (
          '1e634e012091ad0e61a49ec0c1ee7624a13880c463a53ed4037b75932fe7ca80',
          76096610,
        ),
        flow: (
          'b9512691d2812bb4ae59ae5e91c1fe7c75ede924f291d722f5c116e3877af03b',
          10050520,
        ),
        tokenizer: (
          '6211acffe9cb95172f71f0051f18e26ea305b2b32ea00b331ee976551c70887f',
          246403,
        ),
        voice: 'estelle',
        voiceFile: (
          'd9efd55657f74ba9483caec23f9fd1d155e121b058feef86af3760d54ea8aa15',
          7571256,
        ),
        credit: 'estelle (recorded by Kyutai, CC0)',
      ),
      _pocket(
        tag: 'it',
        language: 'italian',
        conditioner: (
          '16b310264df7e2d05c3d33c3c70df03d93892fe837c58c476d8d65316c38304b',
          16388650,
        ),
        main: (
          '4125783ac47fb59c1dd06ddb3232e0abcf3e3606fd49e281ddc096e91d9fa358',
          76096610,
        ),
        flow: (
          'e63432f35e1df7da701b1e7b18e493243774674662c52251354d635a0794611f',
          10050520,
        ),
        tokenizer: (
          '4bc1c0d4d54f9480183e94c94cfabf74fd89b0912537d4ef607d1982c4a381ec',
          246586,
        ),
        voice: 'giovanni',
        voiceFile: (
          '5cede7852c7076f611750e4a8d3c95d19c6386852abc55940b3279f775fc5f9b',
          4130608,
        ),
        credit: 'giovanni (a Common Voice speaker, CC0)',
      ),
      _pocket(
        tag: 'nl',
        language: 'dutch',
        conditioner: (
          '0e0c74c34433541e0bdfe1dc32c35f8756ed854c300bbf5d14dc20abc5d18d82',
          16388650,
        ),
        main: (
          '8bb5f2e062bbf61399dc98303b6007972e50e5de9ce46f296f4d26bdf5dacbf5',
          76096610,
        ),
        flow: (
          'c2637e7429c6f0097acf84d96c775dca0b7305d70d4a0e875d92fa2ad0101216',
          10050520,
        ),
        tokenizer: (
          'e6f610b98c427641b4ab0e1024dca7843e3d6b620871a14b204932e42c5a1736',
          245206,
        ),
        voice: 'daan',
        voiceFile: (
          'be6b053e504c8345a9832c1e3676f539304a2921c416b7140ec5ebb5f95016c4',
          3884848,
        ),
        credit: 'daan (a CML-TTS speaker, CC-BY-4.0)',
      ),
      _pocket(
        tag: 'pt',
        language: 'portuguese',
        conditioner: (
          '248cf930ef7e488254a38dab991bcecb644f4dcfb5733efd0047162b987e7469',
          16388650,
        ),
        main: (
          '3ee8ef1dea4bfde2bae90c6eef12973f0628c7ad2a53d655f263b5a6e069b0f9',
          76096610,
        ),
        flow: (
          '2c4531526e228da816e95ac40a43ec315f8c51bfc0acb0c32d3146f8ce983d8e',
          10050520,
        ),
        tokenizer: (
          'b33e269f7f042a763080d71ba087d74d2f6759674b238a723c028e436b1a25ab',
          247014,
        ),
        voice: 'mary',
        voiceFile: (
          '148e07e6297293af34ea09bcbe2039eb703060c6650122f7de1dd116d4a94226',
          5949240,
        ),
        credit: 'mary (VCTK speaker p333, University of Edinburgh, CC-BY-4.0)',
      ),
      // Chinese: Kokoro-82M v1.1-zh (hexgrad, Apache-2.0). The model is
      // thewh1teagle/kokoro-onnx's fp16 export (release model-files-v1.1,
      // re-uploaded 2026-08-18 with a float speed input), kept on the
      // Trellis release: onnx-community's fp16 file returned NaN audio
      // for every line past 30 phonemes on ONNX Runtime 1.32, and int8
      // drifts in Chinese. The voice is zf_001, the maker's own sample
      // voice. The front-end data is jieba 0.42.1 (MIT), pypinyin 0.55.0
      // (MIT; its own dictionaries, not pypinyin-dict's large_pinyin,
      // which is partly CC-BY-SA) and misaki's tables (Apache-2.0), each
      // converted once to plain text with a header naming its source.
      ModelSpec(
        id: 'kokoro-zh-zf001',
        task: ModelTask.tts,
        files: [
          ModelFile(
            url: '${_release}kokoro-v1.1-zh.fp16.onnx',
            sha256:
                'a628ea5d6fbde96d1a85f691a6a00847829937f9e488021ba2c5359bc6ea08b5',
            bytes: 163528759,
          ),
          ModelFile(
            url:
                'https://huggingface.co/onnx-community/Kokoro-82M-v1.1-zh-ONNX/resolve/6cc0f0d2ebe369a68b0df87c2b65c1af8c0ac3e3/voices/zf_001.bin',
            sha256:
                '0a89ec12bb93fb9c74077924daf02568baad64e1f869389f5aaee01a386035f8',
            bytes: 522240,
          ),
          ModelFile(
            url: '${_release}zh-jieba_dict.txt',
            sha256:
                '9224855d0da4a967d478627976978d337b98e6764d66662f660b1b0a74cc86c7',
            bytes: 5071954,
          ),
          ModelFile(
            url: '${_release}zh-jieba_finalseg_hmm.tsv',
            sha256:
                'dbb6c3a0d83022b7ebff86ce503fc37d89f33a58e63c64dda3f650bf3c1df3e8',
            bytes: 969916,
          ),
          ModelFile(
            url: '${_release}zh-jieba_posseg_hmm.tsv',
            sha256:
                '3a246f26e859ac58dec8ad62e5700fbdfe45e674e49ea7fdef1ae4cca5a6cf27',
            bytes: 3142066,
          ),
          ModelFile(
            url: '${_release}zh-pypinyin_single.tsv',
            sha256:
                'a1f5a740d02e971292bec5e6d8efe6eb6482f889ab670dddd5c5c9ec3ae4039e',
            bytes: 495480,
          ),
          ModelFile(
            url: '${_release}zh-pypinyin_phrases.tsv',
            sha256:
                '8bba3573cf544f466cd64004d5a6abe47b190261332a18c6f050295c31c035b0',
            bytes: 1208972,
          ),
          ModelFile(
            url: '${_release}zh-pypinyin_aux.json',
            sha256:
                '508a4097e97e93d15a4eb69a54e540c642c997eca640e5540c93890e9166f3c4',
            bytes: 955,
          ),
          ModelFile(
            url: '${_release}zh-misaki_zh_tables.json',
            sha256:
                'f5eac0762eb186d4eff51814624b7c75233f31960be05d98aa4e5dd4f6b0a807',
            bytes: 6811,
          ),
        ],
        licenses: const ['Apache-2.0', 'MIT'],
        minTier: DeviceTier.t1,
        langs: const {'zh'},
        kokoroLayout: const KokoroVoiceLayout(
          modelFileName: 'kokoro-v1.1-zh.fp16.onnx',
          voiceFileName: 'zf_001.bin',
          frontEndFileNames: {
            'jiebaDict': 'zh-jieba_dict.txt',
            'finalsegHmm': 'zh-jieba_finalseg_hmm.tsv',
            'possegHmm': 'zh-jieba_posseg_hmm.tsv',
            'pinyinSingle': 'zh-pypinyin_single.tsv',
            'pinyinPhrases': 'zh-pypinyin_phrases.tsv',
            'pinyinAux': 'zh-pypinyin_aux.json',
            'misakiTables': 'zh-misaki_zh_tables.json',
          },
        ),
      ),
    ];

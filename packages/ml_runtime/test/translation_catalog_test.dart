import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';

/// The 1.5.9 decoder swap: the six pairs shipped before 1.5.5 kept
/// onnx-community's 175-193 MB merged decoder. Xenova's int8 export of the
/// same graph is about 60 MB, and decoder_parity.py (outside the repo, see
/// ADR) found the outputs match. Each accepted pair keeps its
/// onnx-community encoder, tokenizer and configs (phones already have
/// them) and takes only Xenova's decoder, pinned to a commit.
void main() {
  final starter = ModelRegistry.starter();

  // (spec id, Xenova commit, sha256 (lfs.oid at that commit), bytes).
  const swapped = [
    (
      'opus-mt-en-es',
      '4b002a4c7edd54a7ced58877258b87f7efd3f892',
      '58ee5ddd6e22d1693d8722b90c1486afb93700a4376cf28fd74175052ad530ae',
      60212804,
    ),
    (
      'opus-mt-en-de',
      '1ca130c44c4c5441ef16d48aae521a424ab644f7',
      '8b46a825964cdd182fe47cc780f0fb87d357eae1f47cf20aa63c1c09be5b510c',
      56652404,
    ),
    (
      'opus-mt-de-en',
      '399dfd68706739fffd503f876093e455ae268a06',
      '4712800584b2d77c2f9e620bf29523e2b20b62f65ade5011ee01780e2b0ea5d3',
      56652404,
    ),
    (
      'opus-mt-en-ru',
      'e050376e960175e8ddc5cff85025dc8436cddd68',
      '7efefcd793a5663bc204224a92a123524f3dfe2ffad59e5f73d6734d1b11ad04',
      58931576,
    ),
    (
      'opus-mt-ru-en',
      'afe8c6c738ec81b6d033fd8f44f9678a639a7c67',
      '25e7ff97b201bce64ab9c39749761d657b70b8602bcbc1ce01c67f713e90ffdf',
      58931576,
    ),
    (
      'opus-mt-zh-en',
      '39d480d52a9ea3065a1f117adfe4dbc55de10e6f',
      'c6b7f04ff1ba0fbd1bf6852599b4c0cad6fe512d57cd887f44ef36cf705424cb',
      60212804,
    ),
  ];

  for (final (id, commit, sha256, bytes) in swapped) {
    group(id, () {
      final spec = starter.byId(id)!;

      test('takes Xenova\'s int8 decoder at a pinned commit', () {
        final decoder = spec.files[1];
        final pair = id.substring('opus-mt-'.length);
        expect(
            decoder.url,
            'https://huggingface.co/Xenova/opus-mt-$pair/resolve/$commit/'
            'onnx/decoder_model_merged_quantized.onnx');
        expect(decoder.sha256, sha256);
        expect(decoder.bytes, bytes);
      });

      test('keeps onnx-community\'s encoder, tokenizer and configs', () {
        for (final f in [spec.files[0], ...spec.files.skip(2)]) {
          expect(f.url, startsWith('https://huggingface.co/onnx-community/'));
        }
      });

      test('the whole pair is under 130 MB', () {
        expect(spec.sizeBytes, lessThan(130 * 1000 * 1000));
      });
    });
  }
}

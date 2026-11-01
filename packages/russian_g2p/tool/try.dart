import 'package:russian_g2p/russian_g2p.dart';

void main(List<String> args) {
  for (final w in args) {
    print('$w\t${sentencePhonemes(w)}');
  }
}

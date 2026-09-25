import 'package:mfm_parser/src/internal/core/core.dart';
import 'package:mfm_parser/src/internal/language.dart';
import 'package:mfm_parser/src/internal/utils.dart';
import 'package:mfm_parser/src/node.dart';

/// MFM Parser class
class MfmParser {
  const MfmParser();

  /// parse full syntax.
  /// if you want to limit elements nest, input [nestLimit]
  List<MfmNode> parse(String input, {int? nestLimit}) {
    final result = Language().fullParser.handler(
        input,
        0,
        FullParserOpts(
            nestLimit: nestLimit ?? 20,
            depth: 0,
            linkLabel: false,
            trace: false)) as Success;

    final res = mergeText(result.value);
    return res;
  }

  /// parse limited syntax.
  /// it will parse text or emoji.
  List<MfmNode> parseSimple(String input) {
    final result = Language().simpleParser.handler(
        input,
        0,
        FullParserOpts(
            nestLimit: 20,
            depth: 0,
            linkLabel: false,
            trace: false)) as Success;
    return mergeText(result.value);
  }
}

class FullParserOpts {
  int nestLimit;
  int depth;
  bool linkLabel;
  bool trace;

  /// [Parser.manyMemo] のメモ表。キーは `(要素パーサ, depth, linkLabel)`、値は開始位置ごとの結果。
  /// 1 つの入力文字列に対してだけ有効なので、別の文字列をパースするときは差し替える。
  Map<ManyMemoKey, Map<int, ManyMemoEntry>> manyMemo = {};

  FullParserOpts(
      {required this.nestLimit,
      required this.depth,
      required this.linkLabel,
      required this.trace});
}

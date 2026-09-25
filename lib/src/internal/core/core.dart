import 'dart:collection';

import 'package:mfm_parser/src/mfm_parser.dart';

class Success<T> extends Result<T> {
  const Success(
      {required super.value, required super.index, super.success = true});
}

class Failure<T> extends Result<T> {
  const Failure({super.success = false});
}

abstract class Result<T> {
  final bool success;
  final T? value;
  final int? index;

  const Result({required this.success, this.value, this.index});
}

typedef ParserHandler<T> = Result<T> Function(
    String input, int index, FullParserOpts state);

Success<T> success<T>(int index, T value) =>
    Success<T>(value: value, index: index);
Failure<T> failure<T>() => Failure<T>();

class Parser<T> {
  String? name;
  late ParserHandler<T> handler;

  Parser({required ParserHandler<T> handler, this.name}) {
    this.handler = (input, index, state) {
      if (state.trace && name != null) {
        final pos = "$index";
        print("${pos.padRight(6)}enter $name");
        final result = handler(input, index, state);
        if (result.success) {
          final pos = "$index:${result.index}";
          print("${pos.padRight(6)}match $name");
        } else {
          final pos = "$index";
          print("${pos.padRight(6)}fail $name");
        }
        return result;
      }
      return handler(input, index, state);
    };
  }

  Parser<U> map<U>(U Function(T value) fn) {
    return Parser<U>(handler: (input, index, state) {
      final result = handler(input, index, state);
      if (!result.success) {
        if (result is! Failure<U>) {
          return failure<U>();
        }

        return result as Result<U>;
      }
      return success(result.index!, fn(result.value as T));
    });
  }

  Parser<String> text() {
    return Parser(handler: (input, index, state) {
      final result = handler(input, index, state);
      if (!result.success) {
        if (result is! Result<String>) {
          return failure();
        }
        return result as Result<String>;
      }
      final succeed = result as Success;
      final text = input.substring(index, result.index);
      return success(succeed.index!, text);
    });
  }

  Parser<List<T2>> many<T2>(int min) {
    return Parser(handler: (input, index, state) {
      Result result;
      var latestIndex = index;
      final List<T2> accum = [];
      while (latestIndex < input.length) {
        result = handler(input, latestIndex, state);
        if (!result.success) {
          break;
        }
        latestIndex = result.index!;
        accum.add(result.value);
      }
      if (accum.length < min) {
        return failure<List<T2>>();
      }
      return success(latestIndex, accum);
    });
  }

  /// [many] と同じ結果を返すが、開始位置ごとに結果をメモする。
  ///
  /// 閉じ記号が見つかるまで先へ走査するループ（`seq([open, X.many(1), close])`）は、
  /// 閉じが無いと失敗し、外側のループが 1 文字進めて同じ走査をやり直すため O(n²) になる。
  /// 位置 k からの結果は「k の要素」+「その要素の終わりからの結果」なので、
  /// 一度走査すれば通過した全位置の結果が分かる。それをメモして以降の走査を O(1) にする。
  ///
  /// 要素の結果は `(input, index, state.depth, state.linkLabel)` だけで決まる前提。
  Parser<List<T2>> manyMemo<T2>(int min) {
    return Parser(handler: (input, index, state) {
      final table = state.manyMemo.putIfAbsent(
          ManyMemoKey(this, state.depth, state.linkLabel), () => {});

      final visited = <int>[];
      final values = <Object?>[];
      var latestIndex = index;
      ManyMemoEntry? tail = table[latestIndex];
      while (tail == null && latestIndex < input.length) {
        final result = handler(input, latestIndex, state);
        if (!result.success) {
          break;
        }
        visited.add(latestIndex);
        values.add(result.value);
        latestIndex = result.index!;
        tail = table[latestIndex];
      }

      var entry =
          tail ?? (table[latestIndex] = ManyMemoEntry._(latestIndex, 0, null));
      for (var i = visited.length - 1; i >= 0; i--) {
        entry = table[visited[i]] = ManyMemoEntry._(
            entry.end, entry.count + 1, _Cons(values[i], entry._values));
      }

      if (entry.count < min) {
        return failure<List<T2>>();
      }
      return success(entry.end, _ConsList<T2>(entry._values));
    });
  }

  Parser<List<T>> sep(Parser<dynamic> separator, int min) {
    if (min < 1) {
      throw Exception('"min" must be a value greater than or equal to 1.');
    }

    return seq([
      this,
      seq([
        separator,
        this,
      ], select: 1)
          .many(min - 1),
    ]).map((result) => <T>[result[0], for (final elem in result[1]) elem]);
  }

  Parser option<T2>() {
    return alt([
      this,
      succeeded(null),
    ]);
  }
}

/// [Parser.manyMemo] のメモ表のキー。要素の結果を左右するのはパーサと depth・linkLabel だけ。
class ManyMemoKey {
  final Parser parser;
  final int depth;
  final bool linkLabel;

  const ManyMemoKey(this.parser, this.depth, this.linkLabel);

  @override
  bool operator ==(Object other) =>
      other is ManyMemoKey &&
      identical(parser, other.parser) &&
      depth == other.depth &&
      linkLabel == other.linkLabel;

  @override
  int get hashCode => Object.hash(identityHashCode(parser), depth, linkLabel);
}

/// [Parser.manyMemo] のメモ 1 件。その位置から始めたときの終了位置・要素数・要素。
class ManyMemoEntry {
  final int end;
  final int count;
  final _Cons? _values;

  const ManyMemoEntry._(this.end, this.count, this._values);
}

class _Cons {
  final Object? head;
  final _Cons? tail;

  const _Cons(this.head, this.tail);
}

/// [_Cons] を包む List。
/// 走査結果は外側の seq が失敗すると捨てられるので、中身は最初に触られたときに作る。
class _ConsList<E> extends ListBase<E> {
  _Cons? _cons;
  List<E>? _list;

  _ConsList(this._cons);

  List<E> get _materialized {
    final list = _list;
    if (list != null) return list;
    final built = <E>[];
    for (var c = _cons; c != null; c = c.tail) {
      built.add(c.head as E);
    }
    _cons = null;
    return _list = built;
  }

  @override
  int get length => _materialized.length;

  @override
  set length(int newLength) => _materialized.length = newLength;

  @override
  E operator [](int index) => _materialized[index];

  @override
  void operator []=(int index, E value) => _materialized[index] = value;

  @override
  void add(E element) => _materialized.add(element);
}

Parser<T> str<T extends String>(T value) {
  return Parser(handler: (input, index, _) {
    if (!input.startsWith(value, index)) {
      return failure();
    }

    return success(index + value.length, value);
  });
}

Parser<String> regexp<T extends RegExp>(T pattern) {
  return Parser(handler: (input, index, _) {
    final result = pattern.matchAsPrefix(input, index);

    if (result == null) {
      return failure();
    }
    return success(index + result.group(0)!.length, result.group(0)!);
  });
}

Parser seq(List<Parser> parsers, {int? select}) {
  return Parser(handler: (input, index, state) {
    Result result;
    var latestIndex = index;
    final accum = [];

    for (var i = 0; i < parsers.length; i++) {
      result = parsers[i].handler(input, latestIndex, state);
      if (!result.success) {
        return result;
      }
      latestIndex = result.index!;
      accum.add(result.value);
    }
    return success(latestIndex, (select != null ? accum[select] : accum));
  });
}

Parser alt(List<Parser> parsers) {
  return Parser(handler: (input, index, state) {
    Result result;
    for (var i = 0; i < parsers.length; i++) {
      result = parsers[i].handler(input, index, state);
      if (result.success) {
        return result;
      }
    }
    return failure();
  });
}

Parser<T> succeeded<T>(T value) {
  return Parser(handler: (_, index, __) {
    return success(index, value);
  });
}

Parser notMatch(Parser parser) {
  return Parser(handler: (input, index, state) {
    final result = parser.handler(input, index, state);
    return !result.success ? success(index, null) : failure();
  });
}

final Parser cr = str("\r");
final Parser lf = str("\n");
final Parser crlf = str("\r\n");
final Parser newline = alt([crlf, cr, lf]);
final Parser char = Parser(handler: (input, index, _) {
  if ((input.length - index) < 1) {
    return failure();
  }
  final value = input[index];
  return success(index + 1, value);
});

final Parser lineBegin = Parser(handler: (input, index, state) {
  if (index == 0) {
    return success(index, null);
  }
  if (cr.handler(input, index - 1, state).success) {
    return success(index, null);
  }
  if (lf.handler(input, index - 1, state).success) {
    return success(index, null);
  }
  return failure();
});

Parser lineEnd = Parser(handler: (input, index, state) {
  if (index == input.length) {
    return success(index, null);
  }
  if (cr.handler(input, index, state).success) {
    return success(index, null);
  }
  if (lf.handler(input, index, state).success) {
    return success(index, null);
  }
  return failure();
});

Parser lazy<T>(Parser<T> Function() fn) {
  Parser? parser;
  parser = Parser(handler: (input, index, state) {
    parser!.handler = fn().handler;
    return parser.handler(input, index, state);
  });
  return parser;
}

Map<String, Parser> createLanguage<T>(Map<String, Parser Function()> syntaxes) {
  final Map<String, Parser> rules = {};

  for (final entry in syntaxes.entries) {
    rules[entry.key] = lazy(() {
      final parser = syntaxes[entry.key]!();
      parser.name = entry.key;
      return parser;
    });
  }
  return rules;
}

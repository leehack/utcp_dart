import 'data/tool.dart';
import 'json.dart';
import 'tool_repository.dart';

abstract interface class ToolSearchStrategy {
  Future<List<Tool>> searchTools(
    ToolRepository repository,
    String query, {
    int limit = 10,
    List<String>? anyOfTagsRequired,
  });
}

/// Ranks tools by matches against their name, tags, and description.
///
/// Scoring follows the reference `tag_and_description_word_match` strategy
/// so results are consistent with the Python and TypeScript SDKs.
class TagSearchStrategy implements ToolSearchStrategy {
  const TagSearchStrategy({this.descriptionWeight = 1, this.tagWeight = 3});

  factory TagSearchStrategy.fromJson(JsonMap json) {
    final type = json.optString('tool_search_strategy_type') ?? strategyType;
    if (type != strategyType) {
      throw FormatException("Unsupported tool_search_strategy_type '$type'.");
    }
    return TagSearchStrategy(
      descriptionWeight: json.optNum('description_weight')?.toDouble() ?? 1,
      tagWeight: json.optNum('tag_weight')?.toDouble() ?? 3,
    );
  }

  static const strategyType = 'tag_and_description_word_match';

  final double descriptionWeight;
  final double tagWeight;

  static final _word = RegExp(r'\w+');

  static Set<String> _words(String text) =>
      _word.allMatches(text).map((m) => m[0]!).toSet();

  static bool _partial(String a, String b) =>
      b.length > 2 && (b.contains(a) || a.contains(b));

  /// A non-positive [limit] returns every tool.
  @override
  Future<List<Tool>> searchTools(
    ToolRepository repository,
    String query, {
    int limit = 10,
    List<String>? anyOfTagsRequired,
  }) async {
    final queryLower = query.toLowerCase();
    final queryWords = _words(queryLower);
    final longQueryWords = queryWords.where((w) => w.length > 2);

    var tools = await repository.getTools();
    if (anyOfTagsRequired != null && anyOfTagsRequired.isNotEmpty) {
      final required = anyOfTagsRequired.map((t) => t.toLowerCase()).toSet();
      tools = tools
          .where(
            (t) => t.tags.any((tag) => required.contains(tag.toLowerCase())),
          )
          .toList();
    }

    double score(Tool tool) {
      var score = 0.0;
      final nameLower = tool.name.toLowerCase();
      final nameOnly = nameLower.split('.').last;
      if (queryLower.contains(nameOnly) || nameOnly.contains(queryLower)) {
        score += tagWeight * 2;
      }
      score += _words(nameOnly).where(queryWords.contains).length * tagWeight;

      for (final tag in tool.tags) {
        final tagLower = tag.toLowerCase();
        if (queryLower.contains(tagLower) || tagLower.contains(queryLower)) {
          score += tagWeight;
        }
        final tagWords = _words(tagLower);
        score += tagWords.where(queryWords.contains).length * tagWeight * 0.5;
        for (final queryWord in longQueryWords) {
          if (tagWords.any((w) => _partial(queryWord, w))) {
            score += tagWeight * 0.3;
          }
        }
      }

      if (tool.description.isNotEmpty) {
        final descWords = _words(tool.description.toLowerCase());
        score +=
            descWords
                .where((w) => w.length > 2 && queryWords.contains(w))
                .length *
            descriptionWeight;
        for (final queryWord in longQueryWords) {
          if (descWords.any((w) => _partial(queryWord, w))) {
            score += descriptionWeight * 0.5;
          }
        }
      }
      return score;
    }

    final ranked =
        [for (final (i, tool) in tools.indexed) (i, tool, score(tool))]
          ..sort((a, b) {
            final byScore = b.$3.compareTo(a.$3);
            return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
          });
    final sorted = [for (final r in ranked) r.$2];
    return limit > 0 ? sorted.take(limit).toList() : sorted;
  }
}

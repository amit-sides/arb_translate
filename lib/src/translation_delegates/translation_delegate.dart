import 'dart:convert';

import 'package:arb_translate/src/flutter_tools/fakes/fake_app_resource_bundle.dart';
import 'package:arb_translate/src/flutter_tools/fakes/fake_app_resource_bundle_collection.dart';
import 'package:arb_translate/src/flutter_tools/gen_l10n_types.dart';
import 'package:arb_translate/src/flutter_tools/localizations_utils.dart';
import 'package:arb_translate/src/translation_delegates/translate_exception.dart';
import 'package:icu_parser/icu_parser.dart';
import 'package:icu_parser/intl_message.dart' as icu_msg;
import 'package:meta/meta.dart';
import 'package:petitparser/petitparser.dart';

abstract class TranslationDelegate {
  const TranslationDelegate({
    required this.batchSize,
    required this.maxParallelQueries,
    required this.cooldownBetweenBatches,
    required this.context,
    required this.useEscaping,
    required this.relaxSyntax,
  });

  final int batchSize;
  final int maxParallelQueries;
  final int cooldownBetweenBatches;
  final String? context;
  final bool useEscaping;
  final bool relaxSyntax;

  int get maxRetryCount;
  Duration get queryBackoff => Duration(seconds: cooldownBetweenBatches);

  Future<Map<String, String>> translate(
    Map<String, Object?> resources,
    LocaleInfo locale,
  ) async {
    final batches = prepareBatches(resources);

    final results = <String, String>{};

    for (var i = 0; i < batches.length; i += maxParallelQueries) {
      final batchResults = await Future.wait([
        for (var j = i; j < i + maxParallelQueries && j < batches.length; j++)
          _translateBatch(
            resources: batches[j],
            locale: locale,
            batchName: '${j + 1}/${batches.length}',
          ),
      ]);

      results.addAll({for (final results in batchResults) ...results});

      // Add cooldown between batch groups if not the last group
      if (i + maxParallelQueries < batches.length && cooldownBetweenBatches > 0) {
        print('Cooldown for ${cooldownBetweenBatches}s before next batch group...');
        await Future.delayed(Duration(seconds: cooldownBetweenBatches));
      }
    }

    return results;
  }

  List<Map<String, Object?>> prepareBatches(Map<String, Object?> resources) {
    final batches = [<String, Object?>{}];

    var lastBatchSize = 0;

    for (final key in resources.keys.where((key) => !key.startsWith('@'))) {
      final resourceWithMetadata = {
        key: resources[key],
        if (resources.containsKey('@$key')) '@$key': resources['@$key'],
      };
      final resourceSize = json.encode(resourceWithMetadata).length;

      if (lastBatchSize == 0 || lastBatchSize + resourceSize <= batchSize) {
        batches.last.addAll(resourceWithMetadata);

        lastBatchSize += resourceSize;
      } else {
        batches.add(resourceWithMetadata);

        lastBatchSize = resourceSize;
      }
    }

    return batches;
  }

  Future<Map<String, String>> _translateBatch({
    required Map<String, Object?> resources,
    required LocaleInfo locale,
    required String batchName,
  }) async {
    var retryCount = 0;

    while (true) {
      String response;

      try {
        response = await getModelResponse(resources, locale);
      } on QuotaExceededException {
        print(
          'Quota exceeded for batch $batchName, retrying in '
          '${queryBackoff.inSeconds}s...',
        );

        await Future.delayed(queryBackoff);
        continue;
      } on NoResponseException catch (_) {
        retryCount++;

        print(
          'Placeholder validation failed for batch $batchName, retrying '
          '$retryCount/$maxRetryCount...',
        );

        if (retryCount > maxRetryCount) {
          rethrow;
        }

        continue;
      }

      final result = _tryParseResponse(resources, response);

      if (result == null) {
        retryCount++;

        if (retryCount > maxRetryCount) {
          throw ResponseParsingException();
        }

        print(
          'Failed to parse response for $batchName, retrying '
          '$retryCount/$maxRetryCount...',
        );

        continue;
      }

      if (!validateResults(resources, result)) {
        retryCount++;

        print(
          'Placeholder validation failed for batch $batchName, retrying '
          '$retryCount/$maxRetryCount...',
        );

        if (retryCount > maxRetryCount) {
          throw PlaceholderValidationException();
        }

        continue;
      }

      print('Translated batch $batchName');

      return result;
    }
  }

  Future<String> getModelResponse(
    Map<String, Object?> resources,
    LocaleInfo locale,
  );

  Map<String, String>? _tryParseResponse(
    Map<String, Object?> resources,
    String? response,
  ) {
    if (response == null) {
      return null;
    }

    // Check if response contains JSON braces
    if (!response.contains('{') || !response.contains('}')) {
      print('Warning: Response does not contain valid JSON structure');
      print('Response preview: ${response.substring(0, response.length > 200 ? 200 : response.length)}');
      return null;
    }

    String trimmedResponse;
    try {
      trimmedResponse = response.substring(
        response.indexOf('{'),
        response.lastIndexOf('}') + 1,
      );
    } catch (e) {
      print('Warning: Failed to extract JSON from response: $e');
      print('Response preview: ${response.substring(0, response.length > 200 ? 200 : response.length)}');
      return null;
    }

    Map<String, Object?> responseJson;

    try {
      responseJson = json.decode(trimmedResponse);
    } catch (e) {
      print('Warning: Failed to decode JSON: $e');
      print('JSON preview: ${trimmedResponse.substring(0, trimmedResponse.length > 500 ? 500 : trimmedResponse.length)}');
      return null;
    }

    final messageResources = resources.keys.where(
      (key) => !key.startsWith('@'),
    );

    // Check if all expected keys are present
    final missingKeys = messageResources.where((key) => !responseJson.containsKey(key)).toList();
    if (missingKeys.isNotEmpty) {
      print('Warning: Response is missing keys: ${missingKeys.take(5).join(", ")}${missingKeys.length > 5 ? "..." : ""}');
      return null;
    }

    if (messageResources.any((key) => responseJson[key] is! String)) {
      final invalidKeys = messageResources.where((key) => responseJson[key] is! String).toList();
      print('Warning: Some keys do not have string values: ${invalidKeys.take(3).join(", ")}${invalidKeys.length > 3 ? "..." : ""}');
      return null;
    }

    return {
      for (final key in messageResources) key: responseJson[key] as String,
    };
  }

  @protected
  @visibleForTesting
  bool validateResults(
    Map<String, Object?> resources,
    Map<String, String> results,
  ) {
    final messageResources = resources.keys.where(
      (key) => !key.startsWith('@'),
    );

    // First, validate placeholder count matches
    for (final key in messageResources) {
      final originalMessage = resources[key] as String;
      final translatedMessage = results[key]!;

      final originalPlaceholders = extractPlaceholders(originalMessage);
      final translatedPlaceholders = extractPlaceholders(translatedMessage);

      if (originalPlaceholders.length != translatedPlaceholders.length) {
        print(
          'Warning: Placeholder count mismatch for "$key". '
          'Original has ${originalPlaceholders.length} placeholder(s): [${originalPlaceholders.join(", ")}], '
          'Translation has ${translatedPlaceholders.length} placeholder(s): [${translatedPlaceholders.join(", ")}]',
        );
        return false;
      }
    }

    // Then validate with Message parser for syntax errors
    final templateBundle = FakeAppResourcesBundle(resources, true);
    final otherBundle = FakeAppResourcesBundle(results, false);

    for (final key in messageResources) {
      try {
        final message = Message(
          templateBundle,
          FakeAppResourceBundleCollection(
            templateBundle: templateBundle,
            otherBundle: otherBundle,
          ),
          key,
          false,
          useEscaping: useEscaping,
          useRelaxedSyntax: relaxSyntax,
        );

        if (message.hadErrors) {
          return false;
        }
      } catch (e) {
        return false;
      }
    }

    return true;
  }
  /// Extracts all unique placeholder names from an ICU message string using the official icu_parser API.
  List<String> extractPlaceholders(String icuMessage) {
    final placeholders = <String>{};
    if (icuMessage.isEmpty) {
      return [];
    }

    IcuParser parser = IcuParser();

    try {
      // 1. Initialize the internal message parser instance and parse the string
      // This returns a MainMessage or a CompositeMessage containing the structural nodes.
      final Result result = parser.contents.plus().parse(icuMessage);


      // 2. Traversal helper to walk the parsed message components
      void extractFromMessage(icu_msg.Message m) {
        if (m is icu_msg.VariableSubstitution) {
          // Simple variables (e.g. {name} or {count})
          placeholders.add(m.variableNameFromParser);
          return;
        } else if (m is icu_msg.Plural) {
          // Plurals use a selector variable
          placeholders.add(m.mainArgument!);
          if (m.zero != null) extractFromMessage(m.zero!);
          if (m.one != null) extractFromMessage(m.one!);
          if (m.two != null) extractFromMessage(m.two!);
          if (m.few != null) extractFromMessage(m.few!);
          if (m.many != null) extractFromMessage(m.many!);
          if (m.other != null) extractFromMessage(m.other!);
          return;
        } else if (m is icu_msg.Select) {
          placeholders.add(m.mainArgument!);
          // Select layout behaves identically to plurals
          for (final subMessage in m.cases.values) {
            extractFromMessage(subMessage);
            return;
          }
        } else if (m is icu_msg.CompositeMessage) {
          // A composite message contains a list of sub-messages (pieces of text and variables combined)
          for (final piece in m.pieces!) {
            extractFromMessage(piece);
          }
          return;
        } else if (m is icu_msg.Gender) {
          placeholders.add(m.mainArgument!);
          if (m.male != null) extractFromMessage(m.male!);
          if (m.female != null) extractFromMessage(m.female!);
          if (m.other != null) extractFromMessage(m.other!);
          return;
        } else if (m is icu_msg.LiteralString) {
          // Literal strings contain no placeholders
          return;
        }

        print('Unhandled message type: ${m.runtimeType}');
      }

      // 3. Process the top-level object hierarchy
      for (dynamic message in result.value) {
        if (message is icu_msg.Message) {
          extractFromMessage(message);
        }
      }
    } catch (e) {
      print('Error parsing ICU message: $e');
    }

    return placeholders.toList();
  }

  // Extract placeholders like {name}, {count}, etc. from a message string
  // Uses icu_parser to properly parse ICU MessageFormat syntax
  List<String> extractPlaceholders2(String message) {
    final placeholders = <String>{};
    
    try {
      final parser = IcuParser();

      final parseResult = parser.message.parse(message);
      if (parseResult is Success && parseResult.value != null) {
        final msg = parseResult.value as icu_msg.Message;
        _extractPlaceholdersFromMessage(msg, placeholders);
      }
    } catch (e) {
      // If parsing fails, fallback to simple regex extraction
      final simplePlaceholderRegex = RegExp(r'\{([a-zA-Z_][a-zA-Z0-9_]*)\}');
      for (final match in simplePlaceholderRegex.allMatches(message)) {
        placeholders.add(match.group(1)!);
      }
    }
    
    return placeholders.toList();
  }
  
  // Extract placeholders from an ICU Message object
  void _extractPlaceholdersFromMessage(icu_msg.Message msg, Set<String> placeholders) {
    // Handle MainMessage - has messagePieces property
    if (msg is icu_msg.MainMessage) {
      for (final piece in msg.messagePieces) {
        _extractPlaceholdersFromMessage(piece, placeholders);
      }
    }
    // Handle CompositeMessage - has pieces property
    else if (msg is icu_msg.CompositeMessage && msg.pieces != null) {
      for (final piece in msg.pieces!) {
        _extractPlaceholdersFromMessage(piece, placeholders);
      }
    }
    // Handle VariableSubstitution - this is a simple placeholder like {name}
    else if (msg is icu_msg.VariableSubstitution) {
      if (msg.variableName != null) {
        placeholders.add(msg.variableName!);
      }
    }
    // Handle Plural - has zero, one, two, few, many, other properties
    else if (msg is icu_msg.Plural) {
      // The main argument name (e.g., "count" in {count, plural, ...})
      if (msg.mainArgument != null) {
        placeholders.add(msg.mainArgument!);
      }
      // Recursively process all plural form options
      if (msg.zero != null) _extractPlaceholdersFromMessage(msg.zero!, placeholders);
      if (msg.one != null) _extractPlaceholdersFromMessage(msg.one!, placeholders);
      if (msg.two != null) _extractPlaceholdersFromMessage(msg.two!, placeholders);
      if (msg.few != null) _extractPlaceholdersFromMessage(msg.few!, placeholders);
      if (msg.many != null) _extractPlaceholdersFromMessage(msg.many!, placeholders);
      if (msg.other != null) _extractPlaceholdersFromMessage(msg.other!, placeholders);
    }
    // Handle Gender (Select) - has female, male, other properties
    else if (msg is icu_msg.Gender) {
      // The main argument name (e.g., "gender" in {gender, select, ...})
      if (msg.mainArgument != null) {
        placeholders.add(msg.mainArgument!);
      }
      // Recursively process all gender options
      if (msg.female != null) _extractPlaceholdersFromMessage(msg.female!, placeholders);
      if (msg.male != null) _extractPlaceholdersFromMessage(msg.male!, placeholders);
      if (msg.other != null) _extractPlaceholdersFromMessage(msg.other!, placeholders);
    }
    // Handle Select - has cases map
    else if (msg is icu_msg.Select) {
      // The main argument name
      if (msg.mainArgument != null) {
        placeholders.add(msg.mainArgument!);
      }
      // Recursively process all select cases
      for (final case_ in msg.cases.values) {
        _extractPlaceholdersFromMessage(case_, placeholders);
      }
    }
  }
}

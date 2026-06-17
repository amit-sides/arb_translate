import 'dart:convert';

import 'package:arb_translate/src/flutter_tools/fakes/fake_app_resource_bundle.dart';
import 'package:arb_translate/src/flutter_tools/fakes/fake_app_resource_bundle_collection.dart';
import 'package:arb_translate/src/flutter_tools/gen_l10n_types.dart';
import 'package:arb_translate/src/flutter_tools/localizations_utils.dart';
import 'package:arb_translate/src/translation_delegates/translate_exception.dart';
import 'package:meta/meta.dart';

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
    final templateBundle = FakeAppResourcesBundle(resources, true);
    final otherBundle = FakeAppResourcesBundle(results, false);

    for (final key in resources.keys.where((key) => !key.startsWith('@'))) {
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
}

import 'package:arb_translate/src/flutter_tools/localizations_utils.dart';
import 'package:arb_translate/src/translation_delegates/translation_delegate.dart';
import 'package:test/test.dart';

/// Test subclass for testing
class TestableTranslationDelegate extends TranslationDelegate {
  const TestableTranslationDelegate()
      : super(
          batchSize: 4096,
          maxParallelQueries: 5,
          cooldownBetweenBatches: 0,
          context: null,
          useEscaping: false,
          relaxSyntax: false,
        );

  @override
  int get batchSize => throw UnimplementedError();

  @override
  int get maxRetryCount => throw UnimplementedError();

  @override
  Future<String> getModelResponse(
      Map<String, Object?> resources, LocaleInfo locale) {
    throw UnimplementedError();
  }
}

void main() {
  group('extractPlaceholders', () {
    final delegate = TestableTranslationDelegate();

    group('Simple placeholders', () {
      test('extracts single placeholder', () {
        expect(
          delegate.extractPlaceholders('{count} Status'),
          equals(['count']),
        );
      });

      test('extracts multiple placeholders', () {
        expect(
          delegate.extractPlaceholders('Hello {name}, you have {count} messages'),
          equals(['name', 'count']),
        );
      });

      test('extracts placeholder at the beginning', () {
        expect(
          delegate.extractPlaceholders('{name} said hello'),
          equals(['name']),
        );
      });

      test('extracts placeholder at the end', () {
        expect(
          delegate.extractPlaceholders('Hello to {name}'),
          equals(['name']),
        );
      });

      test('extracts placeholder in the middle', () {
        expect(
          delegate.extractPlaceholders('Hello {name}, welcome!'),
          equals(['name']),
        );
      });

      test('extracts same placeholder only once', () {
        expect(
          delegate.extractPlaceholders('{name} told {name} hello'),
          equals(['name']),
        );
      });

      test('extracts multiple different placeholders', () {
        expect(
          delegate.extractPlaceholders('{firstName} {lastName}'),
          equals(['firstName', 'lastName']),
        );
      });

      test('handles placeholders with underscores', () {
        expect(
          delegate.extractPlaceholders('Hello {user_name}'),
          equals(['user_name']),
        );
      });

      test('handles placeholders with numbers', () {
        expect(
          delegate.extractPlaceholders('Item {item1} and {item2}'),
          equals(['item1', 'item2']),
        );
      });

      test('returns empty list for text without placeholders', () {
        expect(
          delegate.extractPlaceholders('Just plain text'),
          equals([]),
        );
      });

      test('returns empty list for empty string', () {
        expect(
          delegate.extractPlaceholders(''),
          equals([]),
        );
      });
    });

    group('ICU plural messages', () {
      test('extracts placeholder from simple plural', () {
        expect(
          delegate.extractPlaceholders(
            '{count, plural, one{1 item} other{{count} items}}',
          ),
          equals(['count']),
        );
      });

      test('extracts placeholder from plural with multiple forms', () {
        expect(
          delegate.extractPlaceholders(
            '{count, plural, =0{No items} one{1 item} other{{count} items}}',
          ),
          equals(['count']),
        );
      });

      test('extracts placeholder from plural with text before', () {
        expect(
          delegate.extractPlaceholders(
            'You have {count, plural, one{1 item} other{{count} items}}',
          ),
          equals(['count']),
        );
      });

      test('extracts placeholder from plural with text after', () {
        expect(
          delegate.extractPlaceholders(
            '{count, plural, one{1 file} other{{count} files}} selected',
          ),
          equals(['count']),
        );
      });

      test('extracts placeholder from plural with text before and after', () {
        expect(
          delegate.extractPlaceholders(
            'Found {count, plural, one{1 result} other{{count} results}} total',
          ),
          equals(['count']),
        );
      });

      test('extracts placeholders from nested plural', () {
        // Plural with another placeholder inside
        expect(
          delegate.extractPlaceholders(
            '{count, plural, one{1 item for {user}} other{{count} items for {user}}}',
          ),
          unorderedEquals(['count', 'user']),
        );
      });

      test('extracts from complex plural with multiple placeholders', () {
        expect(
          delegate.extractPlaceholders(
            '{count, plural, one{{user} has 1 item} other{{user} has {count} items}}',
          ),
          unorderedEquals(['count', 'user']),
        );
      });
    });

    group('ICU gender messages', () {
      test('extracts placeholder from gender select', () {
        expect(
          delegate.extractPlaceholders(
            '{gender, select, male{He} female{She} other{They}}',
          ),
          equals(['gender']),
        );
      });

      test('extracts placeholder from gender with text before', () {
        expect(
          delegate.extractPlaceholders(
            '{gender, select, male{Mr.} female{Ms.} other{Mx.}} {name}',
          ),
          unorderedEquals(['gender', 'name']),
        );
      });

      test('extracts placeholders from nested gender', () {
        expect(
          delegate.extractPlaceholders(
            '{gender, select, male{He invited {user}} female{She invited {user}} other{They invited {user}}}',
          ),
          unorderedEquals(['gender', 'user']),
        );
      });
    });

    group('ICU select messages', () {
      test('extracts placeholder from select', () {
        expect(
          delegate.extractPlaceholders(
            '{status, select, active{Active} inactive{Inactive} other{Unknown}}',
          ),
          equals(['status']),
        );
      });

      test('extracts placeholder from select with text', () {
        expect(
          delegate.extractPlaceholders(
            'Status: {status, select, on{Enabled} off{Disabled} other{Unknown}}',
          ),
          unorderedEquals(['status']),
        );
      });

      test('extracts placeholders from nested select', () {
        expect(
          delegate.extractPlaceholders(
            '{type, select, user{User {name}} admin{Admin {name}} other{Unknown {name}}}',
          ),
          unorderedEquals(['type', 'name']),
        );
      });
    });

    group('Mixed placeholders and ICU', () {
      test('extracts from simple placeholder with plural', () {
        expect(
          delegate.extractPlaceholders(
            '{name} has {count, plural, one{1 message} other{{count} messages}}',
          ),
          unorderedEquals(['name', 'count']),
        );
      });

      test('extracts from complex mixed message', () {
        expect(
          delegate.extractPlaceholders(
            '{user} updated {count, plural, one{1 file} other{{count} files}} in {folder}',
          ),
          unorderedEquals(['user', 'count', 'folder']),
        );
      });

      test('extracts from multiple ICU constructs', () {
        expect(
          delegate.extractPlaceholders(
            '{count, plural, one{1 item} other{{count} items}} for {user} with status {status, select, active{Active} other{Inactive}}',
          ),
          unorderedEquals(['count', 'user', 'status']),
        );
      });
    });

    group('Edge cases', () {
      test('handles escaped braces', () {
        // Escaped braces in ICU syntax: '{' and '}'
        expect(
          delegate.extractPlaceholders("Text with '{' and '}'"),
          equals([]),
        );
      });

      test('handles escaped single quotes', () {
        expect(
          delegate.extractPlaceholders("It''s {name}'s item"),
          equals(['name']),
        );
      });

      test('handles numeric placeholder values in plural', () {
        expect(
          delegate.extractPlaceholders(
            '{count, plural, =0{No items} =1{One item} other{{count} items}}',
          ),
          equals(['count']),
        );
      });

      test('handles all plural forms', () {
        expect(
          delegate.extractPlaceholders(
            '{count, plural, zero{No items} one{1 item} two{2 items} few{A few items} many{Many items} other{{count} items}}',
          ),
          equals(['count']),
        );
      });
    });

    group('Real-world examples', () {
      test('handles couponFilter_statusCount', () {
        expect(
          delegate.extractPlaceholders('{count} Status'),
          equals(['count']),
        );
      });

      test('handles dateFormat patterns', () {
        expect(
          delegate.extractPlaceholders('{year}-{month}-{day}'),
          equals(['year', 'month', 'day']),
        );
      });

      test('handles unregisteredPopup_deleteSelectedConfirmation', () {
        expect(
          delegate.extractPlaceholders(
            '{count,plural, =1{Are you sure you want to delete this coupon?}other{Are you sure you want to delete {count} coupons?}}',
          ),
          equals(['count']),
        );
      });

      test('handles remindersSettings plural forms', () {
        expect(
          delegate.extractPlaceholders(
            '{count, plural, one{hour} other{hours}}',
          ),
          equals(['count']),
        );
      });

      test('handles common_inX pattern', () {
        expect(
          delegate.extractPlaceholders(
            'in {count, plural, one{# day} other{# days}}',
          ),
          equals(['count']),
        );
      });
    });
  });
}

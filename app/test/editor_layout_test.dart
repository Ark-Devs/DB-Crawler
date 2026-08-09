import 'package:db_crawler/ui/editor_view.dart';
import 'package:flutter_test/flutter_test.dart';

/// The editor's height arithmetic.
///
/// Two shipped builds got this wrong in opposite directions — one overflowed
/// off the bottom of a landscape screen, one squeezed the text field to a few
/// pixels under the keyboard — and neither was caught, because the only way to
/// see it was to hold a phone. These are the properties that were violated.
void main() {
  // Chrome the layout has to leave room for, mirroring the widget: a divider,
  // plus a toolbar, plus the tab strip and suggestion bar when they are shown.
  double chromeOf(EditorLayout layout, {required bool hasSuggestions}) {
    return (layout.showTabStrip ? 42.0 : 0.0) +
        (layout.showSuggestions ? 42.0 : 0.0) +
        (layout.compact ? 44.0 : 52.0) +
        1;
  }

  group('EditorLayout', () {
    test('the editor is typable under a keyboard', () {
      // A short phone in portrait with the keyboard up: what the workspace has
      // left over is a few hundred points. The old formula handed the editor
      // 42% of that and no floor, which came to about one clipped line.
      for (final hasSuggestions in [false, true]) {
        final layout = EditorLayout.forHeight(
          height: 300,
          typing: true,
          hasSuggestions: hasSuggestions,
        );
        expect(
          layout.editorHeight,
          greaterThanOrEqualTo(EditorLayout.minEditorHeight),
          reason: 'suggestions: $hasSuggestions',
        );
      }
    });

    test('landscape under a keyboard still leaves room to type', () {
      // Landscape leaves roughly a third of what portrait does. The tab strip
      // and the full-size toolbar have to give way for anything to be left.
      final layout = EditorLayout.forHeight(
        height: 180,
        typing: true,
        hasSuggestions: false,
      );
      expect(layout.compact, isTrue);
      expect(layout.showTabStrip, isFalse);
      expect(layout.editorHeight, greaterThan(100));
    });

    test('nothing is laid out taller than the box it was given', () {
      for (var height = EditorLayout.minLayoutHeight;
          height <= 1000.0;
          height += 7) {
        for (final typing in [false, true]) {
          for (final hasSuggestions in [false, true]) {
            final layout = EditorLayout.forHeight(
              height: height,
              typing: typing,
              hasSuggestions: hasSuggestions,
            );
            final used = chromeOf(layout, hasSuggestions: hasSuggestions) +
                layout.editorHeight +
                (layout.showResults ? layout.resultsHeight : 0.0);
            expect(
              used,
              lessThanOrEqualTo(height + 0.001),
              reason: 'overflow at height $height, typing $typing, '
                  'suggestions $hasSuggestions',
            );
            expect(layout.editorHeight, greaterThanOrEqualTo(0));
            expect(layout.resultsHeight, greaterThanOrEqualTo(-0.001));
          }
        }
      }
    });

    test('the editor gets its floor, or everything there is', () {
      for (var height = EditorLayout.minLayoutHeight;
          height <= 1000.0;
          height += 7) {
        for (final typing in [false, true]) {
          for (final hasSuggestions in [false, true]) {
            final layout = EditorLayout.forHeight(
              height: height,
              typing: typing,
              hasSuggestions: hasSuggestions,
            );
            final free = layout.editorHeight + layout.resultsHeight;
            final want =
                free < EditorLayout.minEditorHeight ? free : EditorLayout.minEditorHeight;
            expect(
              layout.editorHeight,
              greaterThanOrEqualTo(want - 0.001),
              reason: 'starved at height $height, typing $typing, '
                  'suggestions $hasSuggestions',
            );
          }
        }
      }
    });

    test('the completion strip gives way before the editor does', () {
      // A strip of chips is help; a strip of chips over a text field you can
      // no longer read is not.
      final cramped = EditorLayout.forHeight(
        height: 120,
        typing: true,
        hasSuggestions: true,
      );
      expect(cramped.showSuggestions, isFalse);

      final roomy = EditorLayout.forHeight(
        height: 400,
        typing: true,
        hasSuggestions: true,
      );
      expect(roomy.showSuggestions, isTrue);
    });

    test('a roomy screen shows results alongside the editor', () {
      final layout = EditorLayout.forHeight(
        height: 700,
        typing: false,
        hasSuggestions: false,
      );
      expect(layout.showTabStrip, isTrue);
      expect(layout.compact, isFalse);
      expect(layout.showResults, isTrue);
      // Results are the point of running a query; idle, they get the larger
      // half.
      expect(layout.resultsHeight, greaterThan(layout.editorHeight));
    });

    test('typing hands space back from the results to the editor', () {
      final idle = EditorLayout.forHeight(
        height: 700,
        typing: false,
        hasSuggestions: false,
      );
      final active = EditorLayout.forHeight(
        height: 700,
        typing: true,
        hasSuggestions: false,
      );
      expect(active.editorHeight, greaterThan(idle.editorHeight));
      expect(active.resultsHeight, lessThan(idle.resultsHeight));
    });
  });
}

import 'package:flutter/material.dart';

import '../core/models.dart';

/// The app is dark by default.
///
/// It is used one-handed, often late, often in a dim room, and the screen is
/// mostly dense monospaced data. A light theme is available for daylight, but
/// dark is the case to optimise for.
ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3D7EFF),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
    ),
    listTileTheme: const ListTileThemeData(
      visualDensity: VisualDensity.compact,
    ),
  );
}

/// The monospaced stack used for SQL and for result cells.
///
/// Names it by family rather than bundling a font: every column of digits has
/// to line up, and the platform's own monospace does that without adding a
/// megabyte to the download.
const monoFont = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Menlo', 'Consolas', 'Roboto Mono', 'Courier New'],
  fontFeatures: [FontFeature.tabularFigures()],
);

/// The colours a user can tag a connection with.
///
/// Production and staging looking identical is the mistake this app makes
/// easiest and the most expensive one to make, so the tag is shown on the
/// connection card, in the app bar, and behind the run button.
const connectionColors = <int>[
  0xFFE5484D, // red — production
  0xFFF76B15, // orange
  0xFFFFB224, // amber — staging
  0xFF30A46C, // green — local
  0xFF3D7EFF, // blue
  0xFF8E4EC6, // purple
];

/// How a value is rendered in the grid, by column kind.
///
/// NULL gets its own treatment — italic, dimmed, and spelled out — because
/// showing it as an empty cell makes it indistinguishable from an empty
/// string, and those two mean very different things in a WHERE clause.
TextStyle cellStyle(ThemeData theme, ValueKind kind, {required bool isNull}) {
  final base = monoFont.copyWith(
    fontSize: 13,
    color: theme.colorScheme.onSurface,
  );
  if (isNull) {
    return base.copyWith(
      fontStyle: FontStyle.italic,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
    );
  }
  return switch (kind) {
    ValueKind.number => base.copyWith(color: theme.colorScheme.primary),
    ValueKind.boolean => base.copyWith(color: theme.colorScheme.tertiary),
    ValueKind.datetime ||
    ValueKind.date ||
    ValueKind.time =>
      base.copyWith(color: theme.colorScheme.secondary),
    ValueKind.bytes => base.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
      ),
    _ => base,
  };
}

/// The icon for a table, view, or column, so the tree reads at a glance.
IconData iconForTable(TableInfo table) =>
    table.isView ? Icons.visibility_outlined : Icons.table_chart_outlined;

IconData iconForKind(ValueKind kind) => switch (kind) {
      ValueKind.number => Icons.tag,
      ValueKind.boolean => Icons.toggle_on_outlined,
      ValueKind.datetime || ValueKind.date => Icons.event_outlined,
      ValueKind.time => Icons.schedule_outlined,
      ValueKind.bytes => Icons.data_object_outlined,
      ValueKind.json => Icons.data_object,
      ValueKind.uuid => Icons.fingerprint,
      _ => Icons.text_fields,
    };

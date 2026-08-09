import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'results_grid.dart';
import 'theme.dart';

// The fixed pieces of the editor column. They are named rather than inlined
// because the layout has to subtract exactly what it is about to draw — a
// constant that disagrees with the widget is how a Column overflows.
const _tabStripHeight = 42.0;
const _suggestionHeight = 42.0;
const _toolbarHeight = 52.0;
const _toolbarCompactHeight = 44.0;

/// How the editor column divides the height it was handed.
///
/// This lives outside the widget so it can be checked without a device.
/// Getting it wrong has shipped twice now — once as a Column that overflowed
/// off the bottom of a landscape screen, and once as a text field squeezed to
/// a few pixels by a keyboard — and both times the mistake was plain in the
/// numbers alone, well before anything was rendered.
@immutable
class EditorLayout {
  const EditorLayout._({
    required this.compact,
    required this.showSuggestions,
    required this.editorHeight,
    required this.resultsHeight,
  });

  /// Roughly six lines of the mono face plus its padding. Below this the
  /// editor stops being something anyone can write a query in, so it is a
  /// floor and not a target — the share below may exceed it, never undercut
  /// it while there is height to spare.
  static const minEditorHeight = 132.0;

  /// True when the box is short enough that the tab strip and a full-size
  /// toolbar are worth more as editor space than as controls.
  ///
  /// The smallest box this can lay out without overflowing is a compact
  /// toolbar and its divider. Below that there is no arrangement to pick, and
  /// no device that asks for one.
  static const minLayoutHeight = _toolbarCompactHeight + 1;

  final bool compact;

  /// False when there are suggestions but nowhere to put them without taking
  /// the editor below a couple of lines. A completion strip that costs you
  /// sight of what you are completing is not help.
  final bool showSuggestions;

  final double editorHeight;
  final double resultsHeight;

  bool get showTabStrip => !compact;

  /// Below about a line and a half the results pane shows nothing but a
  /// clipped header, so it is dropped rather than teased.
  bool get showResults => resultsHeight >= 48;

  factory EditorLayout.forHeight({
    required double height,
    required bool typing,
    required bool hasSuggestions,
  }) {
    // Two lines of text is the least worth showing a completion strip over.
    const leastUsefulEditor = 60.0;
    final showSuggestions = hasSuggestions &&
        height - minLayoutHeight - _suggestionHeight >= leastUsefulEditor;

    final suggestions = showSuggestions ? _suggestionHeight : 0.0;
    final roomy = _tabStripHeight + suggestions + _toolbarHeight + 1;

    // Compact is decided by what is left, not by whether the keyboard is up.
    // Keying it on typing meant a short landscape pane still laid out 95
    // points of chrome inside a 60-point box, and a Column that does not fit
    // has nothing to give — it just runs off the bottom.
    final compact = height - roomy < minEditorHeight;
    final chrome = compact ? suggestions + _toolbarCompactHeight + 1 : roomy;
    final free = (height - chrome).clamp(0.0, double.infinity);

    // A share of what is left, with a floor under it. The floor is what was
    // missing before: 42% of a keyboard-sized remainder is a text field too
    // short to show the line being typed. The share rises while the keyboard
    // is up too — results you cannot see are worth less than room to write
    // the query that produces them.
    final floor = free < minEditorHeight ? free : minEditorHeight;
    final share =
        (free * (typing ? 0.62 : 0.42)).clamp(0.0, typing ? 340.0 : 260.0);
    final editor = share < floor ? floor : share;

    return EditorLayout._(
      compact: compact,
      showSuggestions: showSuggestions,
      editorHeight: editor,
      resultsHeight: free - editor,
    );
  }
}

/// The SQL editor and its results.
class EditorView extends StatefulWidget {
  const EditorView({super.key});

  /// True while the text field has focus, which is as near as Flutter gets to
  /// "the keyboard is up" without asking the platform.
  ///
  /// The workspace watches it to fold its header away. On a phone in landscape
  /// the header, the tab strip, the toolbar and the keyboard together left the
  /// text field about one line — the editor was on screen and impossible to
  /// type into. Anything that is not the text being edited gives way while it
  /// is being edited.
  static final ValueNotifier<bool> typing = ValueNotifier<bool>(false);

  /// Loads SQL into the editor from elsewhere in the app.
  ///
  /// A static hook rather than a key or a controller passed down: the explorer
  /// and the history list both need to push text into an editor that lives
  /// inside a TabBarView and may not be built yet, and threading a controller
  /// through both would be more plumbing than the one live editor justifies.
  static void Function(String sql)? _loader;
  static void loadSql(String sql) => _loader?.call(sql);

  @override
  State<EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<EditorView> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  Timer? _completionDebounce;
  String _completionPrefix = '';
  List<Suggestion> _suggestions = const [];

  /// True when the user has highlighted part of the buffer, which changes what
  /// the run button does.
  bool get _hasSelection {
    final sel = _controller.selection;
    return sel.isValid && !sel.isCollapsed;
  }

  String get _selectedText {
    final sel = _controller.selection;
    if (!_hasSelection) return '';
    return sel.textInside(_controller.text);
  }

  @override
  void initState() {
    super.initState();
    // The run button and the suggestion bar both depend on where the cursor
    // is, and moving the caret fires no onChanged.
    _controller.addListener(_onEditorChanged);
    _focus.addListener(_onFocusChanged);
    EditorView._loader = (sql) {
      _controller.text = sql;
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
      context.read<AppState>().setSql(sql);
      if (mounted) setState(() {});
    };
    _shownTabId = context.read<AppState>().tab.id;
    final existing = context.read<AppState>().sql;
    if (existing.isNotEmpty) _controller.text = existing;
  }

  /// Which tab's text the controller currently holds. Switching tabs has to
  /// swap the buffer, and there is no notification for "the tab changed" other
  /// than noticing it during a rebuild.
  String _shownTabId = '';

  void _syncTab(AppState state) {
    if (state.tab.id == _shownTabId) return;
    _shownTabId = state.tab.id;
    _controller.value = TextEditingValue(
      text: state.tab.sql,
      selection: TextSelection.collapsed(offset: state.tab.sql.length),
    );
    _suggestions = const [];
  }

  void _onFocusChanged() {
    EditorView.typing.value = _focus.hasFocus;
    if (mounted) setState(() {});
  }

  /// Recomputes suggestions a beat after typing stops.
  ///
  /// Completion is a round trip through the core and, on a first use, a
  /// catalog query. Firing on every keystroke would put that on the critical
  /// path of typing; a short pause is imperceptible and costs one call
  /// instead of thirty.
  void _onEditorChanged() {
    if (mounted) setState(() {});
    _completionDebounce?.cancel();
    _completionDebounce = Timer(const Duration(milliseconds: 180), () async {
      final selection = _controller.selection;
      if (!selection.isValid || !selection.isCollapsed || !_focus.hasFocus) {
        if (mounted) setState(() => _suggestions = const []);
        return;
      }
      final result = await context
          .read<AppState>()
          .complete(_controller.text, selection.baseOffset);
      if (!mounted) return;
      setState(() {
        _completionPrefix = result.prefix;
        _suggestions = result.suggestions;
      });
    });
  }

  /// Replaces the partial word under the cursor with the chosen suggestion.
  void _applySuggestion(Suggestion suggestion) {
    final selection = _controller.selection;
    if (!selection.isValid) return;
    final cursor = selection.baseOffset;
    final start = cursor - _completionPrefix.length;
    if (start < 0) return;

    final text = _controller.text;
    final replaced = text.replaceRange(start, cursor, suggestion.text);
    _controller.value = TextEditingValue(
      text: replaced,
      selection:
          TextSelection.collapsed(offset: start + suggestion.text.length),
    );
    context.read<AppState>().setSql(replaced);
    setState(() => _suggestions = const []);
  }

  @override
  void dispose() {
    EditorView._loader = null;
    _completionDebounce?.cancel();
    _controller.removeListener(_onEditorChanged);
    // Detached before the node is disposed: disposing unfocuses, and a
    // listener firing then would rebuild an ancestor mid-teardown.
    _focus.removeListener(_onFocusChanged);
    EditorView.typing.value = false;
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _syncTab(state);

    // Every height below is derived from the box we were actually given.
    // Fixed heights plus a minimum-height editor overflowed the moment the
    // keyboard opened in landscape, and an overflowing Column has nothing to
    // shrink and no scrollbar — the content simply went off the bottom.
    //
    // The opposite mistake is just as easy: a purely proportional share has no
    // floor under it, so a keyboard that takes most of the screen leaves the
    // editor a few pixels tall. Everything here has both a share and a floor.
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final width = constraints.maxWidth;

        final typing = _focus.hasFocus;
        final layout = EditorLayout.forHeight(
          height: height,
          typing: typing,
          hasSuggestions: _suggestions.isNotEmpty,
        );

        final toolbar = _Toolbar(
          compact: layout.compact,
          canRun: _controller.text.trim().isNotEmpty && !state.running,
          running: state.running,
          hasSelection: _hasSelection,
          onRun: () {
            // A selection means "run exactly this". Highlighting one statement
            // out of a script and running the lot instead is the kind of
            // mistake that is only noticed afterwards.
            final selected = _selectedText.trim();
            _focus.unfocus();
            state.run(statement: selected.isEmpty ? null : selected);
          },
          onCancel: state.cancel,
          onFormat: () {
            final formatted = _tidy(_controller.text);
            _controller.text = formatted;
            state.setSql(formatted);
            setState(() {});
          },
        );

        final suggestionBar = layout.showSuggestions
            ? _SuggestionBar(
                suggestions: _suggestions,
                onPick: _applySuggestion,
              )
            : null;

        final results = state.running
            ? const _RunningIndicator()
            : ResultsPanel(results: state.results, error: state.runError);

        // Wider than tall means landscape, where the keyboard leaves a short,
        // wide strip. Stacking the editor above the results in that shape
        // leaves neither of them usable, so they sit side by side instead and
        // each gets the full remaining height.
        if (width > height) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: (width * 0.46).clamp(260.0, width - 200),
                child: Column(
                  children: [
                    if (layout.showTabStrip)
                      SizedBox(
                          height: _tabStripHeight,
                          child: _TabStrip(state: state)),
                    // Expanded, so whatever the keyboard leaves goes here
                    // rather than to a pane nobody is reading.
                    Expanded(
                      child: _EditorField(
                        controller: _controller,
                        focus: _focus,
                        compact: layout.compact,
                        onChanged: state.setSql,
                      ),
                    ),
                    if (suggestionBar != null) suggestionBar,
                    toolbar,
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: results),
            ],
          );
        }

        return Column(
          children: [
            if (layout.showTabStrip)
              SizedBox(height: _tabStripHeight, child: _TabStrip(state: state)),
            SizedBox(
              height: layout.editorHeight,
              child: _EditorField(
                controller: _controller,
                focus: _focus,
                compact: layout.compact,
                onChanged: state.setSql,
              ),
            ),
            if (suggestionBar != null) suggestionBar,
            toolbar,
            const Divider(height: 1),
            if (layout.showResults)
              SizedBox(height: layout.resultsHeight, child: results),
          ],
        );
      },
    );
  }

  /// A light tidy-up, not a formatter.
  ///
  /// It puts the major clauses on their own lines and collapses runs of
  /// whitespace, which is most of the readability win on a narrow screen.
  /// Anything more ambitious needs a real parser, and getting that subtly
  /// wrong would rewrite the user's query into something else.
  static String _tidy(String sql) {
    const clauses = [
      'SELECT', 'FROM', 'WHERE', 'GROUP BY', 'HAVING', 'ORDER BY',
      'LIMIT', 'INNER JOIN', 'LEFT JOIN', 'RIGHT JOIN', 'FULL JOIN',
      'CROSS JOIN', 'JOIN', 'UNION ALL', 'UNION', 'VALUES', 'SET',
    ];
    var out = sql.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
    for (final clause in clauses) {
      out = out.replaceAllMapped(
        RegExp('(?<![\\w])$clause(?![\\w])', caseSensitive: false),
        (match) => '\n${match.group(0)!.toUpperCase()}',
      );
    }
    return out
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }
}

class _EditorField extends StatelessWidget {
  const _EditorField({
    required this.controller,
    required this.focus,
    required this.compact,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focus;

  /// Trims the padding when the box is short. Twelve points top and bottom is
  /// most of a line of text, and a line of text is what is scarce here.
  final bool compact;

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    // No constraints of its own: the parent has already measured what it can
    // spare, and a minimum height here is exactly what overflowed before.
    return SizedBox.expand(
      child: Container(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: TextField(
          controller: controller,
          focusNode: focus,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          // Every one of these would otherwise fight the user: autocorrect
          // rewrites table names, capitalisation breaks case-sensitive
          // identifiers, and smart quotes turn a valid literal into a syntax
          // error that is invisible on a small screen.
          autocorrect: false,
          enableSuggestions: false,
          smartQuotesType: SmartQuotesType.disabled,
          smartDashesType: SmartDashesType.disabled,
          textCapitalization: TextCapitalization.none,
          style: monoFont.copyWith(fontSize: 14, height: 1.4),
          decoration: InputDecoration(
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: compact ? 6 : 12,
            ),
            hintText: 'SELECT * FROM …',
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.compact,
    required this.canRun,
    required this.running,
    required this.hasSelection,
    required this.onRun,
    required this.onCancel,
    required this.onFormat,
  });

  /// Squeezes the run button down while the keyboard is up. The toolbar is the
  /// only thing that has to stay reachable then, not the only thing that
  /// matters.
  final bool compact;

  final bool canRun;
  final bool running;
  final bool hasSelection;
  final VoidCallback onRun;
  final VoidCallback onCancel;
  final VoidCallback onFormat;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tag = state.active?.profile.colorTag;
    final density =
        compact ? VisualDensity.compact : VisualDensity.standard;

    return SizedBox(
      height: compact ? _toolbarCompactHeight : _toolbarHeight,
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, compact ? 2 : 6, 8, compact ? 2 : 6),
        child: Row(
          children: [
            if (running)
              OutlinedButton.icon(
                onPressed: onCancel,
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('Stop'),
                style: OutlinedButton.styleFrom(visualDensity: density),
              )
            else
              FilledButton.icon(
                onPressed: canRun ? onRun : null,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(hasSelection ? 'Run selection' : 'Run'),
                style: FilledButton.styleFrom(
                  visualDensity: density,
                  // Tinting the run button with the connection's colour is the
                  // last thing a user sees before a statement executes, which
                  // makes it the right place to say "this is production".
                  backgroundColor: tag == null ? null : Color(tag),
                ),
              ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Tidy up',
              visualDensity: density,
              icon: const Icon(Icons.format_align_left, size: 20),
              onPressed: onFormat,
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

class _RunningIndicator extends StatelessWidget {
  const _RunningIndicator();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          SizedBox(height: 14),
          Text('Running…'),
          SizedBox(height: 4),
          Text(
            'Stop is above if it takes too long.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}


/// Suggestions, as a horizontal strip directly above the toolbar.
///
/// A dropdown overlay is the desktop answer and the wrong one here: it would
/// cover the very text being edited on a screen where the keyboard already
/// takes half the height. A strip stays out of the way and is reachable with
/// the thumb already on the screen.
class _SuggestionBar extends StatelessWidget {
  const _SuggestionBar({required this.suggestions, required this.onPick});

  final List<Suggestion> suggestions;
  final void Function(Suggestion) onPick;

  static IconData _icon(String kind) => switch (kind) {
        'column' => Icons.view_column_outlined,
        'table' => Icons.table_chart_outlined,
        'view' => Icons.visibility_outlined,
        'function' || 'procedure' => Icons.functions,
        _ => Icons.abc,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 42,
      color: theme.colorScheme.surfaceContainerHighest,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        itemCount: suggestions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final s = suggestions[i];
          return ActionChip(
            visualDensity: VisualDensity.compact,
            avatar: Icon(_icon(s.kind), size: 14),
            label: Text(s.text, style: monoFont.copyWith(fontSize: 12.5)),
            tooltip: s.detail.isEmpty ? null : '${s.text} · ${s.detail}',
            onPressed: () => onPick(s),
          );
        },
      ),
    );
  }
}


/// The row of editor tabs.
///
/// Several buffers matter on a phone more than on a desktop: there is no
/// second window to keep a reference query in, so without tabs you overwrite
/// the thing you were about to need.
class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 42,
      color: theme.colorScheme.surfaceContainerLow,
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: state.tabs.length,
              itemBuilder: (context, i) {
                final tab = state.tabs[i];
                final active = i == state.activeTabIndex;
                return InkWell(
                  onTap: () => state.selectTab(i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          width: 2,
                          color: active
                              ? theme.colorScheme.primary
                              : Colors.transparent,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        if (tab.running)
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: SizedBox(
                              width: 11,
                              height: 11,
                              child:
                                  CircularProgressIndicator(strokeWidth: 1.6),
                            ),
                          ),
                        Text(
                          tab.title,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: active
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (state.tabs.length > 1)
                          IconButton(
                            iconSize: 14,
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.only(left: 4),
                            constraints: const BoxConstraints(),
                            icon: const Icon(Icons.close),
                            onPressed: () => state.closeTab(tab.id),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: 'New tab',
            icon: const Icon(Icons.add, size: 20),
            onPressed: () => state.openTab(),
          ),
        ],
      ),
    );
  }
}

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// Creates or edits a saved connection.
class ConnectionEditor extends StatefulWidget {
  const ConnectionEditor({super.key, this.existing});

  final ConnectionProfile? existing;

  @override
  State<ConnectionEditor> createState() => _ConnectionEditorState();
}

class _ConnectionEditorState extends State<ConnectionEditor> {
  final _formKey = GlobalKey<FormState>();

  late Engine _engine;
  late AuthMethod _auth;
  late TlsMode _tls;
  late bool _readOnly;
  int? _colorTag;

  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _database = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _file = TextEditingController();

  bool _obscurePassword = true;
  bool _passwordTouched = false;
  bool _hasStoredPassword = false;
  bool _loadingDatabases = false;
  bool _testing = false;
  String _testResult = '';
  bool _testOk = false;

  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _engine = existing?.engine ?? Engine.sqlserver;
    _auth = existing?.auth ?? AuthMethod.sql;
    _tls = existing?.tls ?? TlsMode.require;
    _readOnly = existing?.readOnly ?? false;
    _colorTag = existing?.colorTag;

    if (existing != null) {
      _name.text = existing.name;
      _host.text = existing.host;
      _port.text = existing.port?.toString() ?? '';
      _database.text = existing.database;
      _user.text = existing.user;
      _file.text = existing.file;
      _loadPasswordFlag(existing.id);
    }
  }

  Future<void> _loadPasswordFlag(String id) async {
    final stored = await context.read<AppState>().connections.hasPassword(id);
    if (mounted) setState(() => _hasStoredPassword = stored);
  }

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _database, _user, _password, _file]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New connection' : 'Edit connection'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            _EngineSelector(
              selected: _engine,
              onChanged: (engine) => setState(() {
                _engine = engine;
                if (_port.text.isEmpty && engine.defaultPort > 0) {
                  _port.text = engine.defaultPort.toString();
                }
              }),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              textCapitalization: TextCapitalization.sentences,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Give it a name' : null,
            ),
            const SizedBox(height: 16),
            if (_engine.usesFile) ..._fileFields() else ..._networkFields(),
            const SizedBox(height: 24),
            _ColorTagPicker(
              selected: _colorTag,
              onChanged: (value) => setState(() => _colorTag = value),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              value: _readOnly,
              onChanged: (value) => setState(() => _readOnly = value),
              contentPadding: EdgeInsets.zero,
              title: const Text('Read-only'),
              subtitle: const Text(
                'Refuse anything that is not a read. Worth leaving on for '
                'production — it is the difference between checking a number '
                'and changing one.',
              ),
            ),
            const SizedBox(height: 16),
            if (_testResult.isNotEmpty) _TestBanner(ok: _testOk, message: _testResult),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering),
              label: Text(_testing ? 'Connecting…' : 'Test connection'),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _fileFields() => [
        TextFormField(
          controller: _file,
          readOnly: true,
          style: monoFont.copyWith(fontSize: 13),
          decoration: InputDecoration(
            labelText: 'Database file',
            hintText: 'Choose a .db or .sqlite file',
            suffixIcon: IconButton(
              icon: const Icon(Icons.folder_open),
              onPressed: _pickFile,
            ),
          ),
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? 'Choose a file' : null,
        ),
        const SizedBox(height: 8),
        Text(
          'The file is opened where it sits. Pick one from this device or from '
          'a cloud folder your file manager has synced locally.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ];

  List<Widget> _networkFields() => [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: _host,
                decoration: const InputDecoration(labelText: 'Host'),
                keyboardType: TextInputType.url,
                autocorrect: false,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Host is required' : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _port,
                decoration: InputDecoration(
                  labelText: 'Port',
                  hintText: '${_engine.defaultPort}',
                ),
                keyboardType: TextInputType.number,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null;
                  final port = int.tryParse(v.trim());
                  if (port == null || port < 1 || port > 65535) {
                    return '1–65535';
                  }
                  return null;
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _database,
          decoration: InputDecoration(
            labelText: 'Database',
            // Typing stays available: listing databases needs permission the
            // login may not have, and being unable to enumerate should never
            // mean being unable to connect.
            suffixIcon: IconButton(
              tooltip: 'Choose from the server',
              icon: _loadingDatabases
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more),
              onPressed: _loadingDatabases ? null : _pickDatabase,
            ),
          ),
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          validator: (v) {
            if (_engine == Engine.postgres && (v == null || v.trim().isEmpty)) {
              return 'PostgreSQL needs a database';
            }
            return null;
          },
        ),
        if (_engine != Engine.postgres) ...[
          const SizedBox(height: 6),
          Text(
            _database.text.trim().isEmpty
                ? 'Tap the arrow to list what is on the server. Left empty, you '
                    'get whatever this login opens by default — usually master, '
                    'not yours.'
                : 'Tap the arrow to pick a different one.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (_engine == Engine.sqlserver) ...[
          const SizedBox(height: 20),
          Text('Authentication', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<AuthMethod>(
            segments: [
              for (final method in AuthMethod.values)
                ButtonSegment(value: method, label: Text(method.label)),
            ],
            selected: {_auth},
            onSelectionChanged: (values) =>
                setState(() => _auth = values.first),
            showSelectedIcon: false,
          ),
          const SizedBox(height: 6),
          Text(_auth.description,
              style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 16),
        TextFormField(
          controller: _user,
          decoration: InputDecoration(
            labelText: 'Username',
            // NTLM has nowhere else to learn the domain from.
            hintText: _engine == Engine.sqlserver && _auth == AuthMethod.windows
                ? r'DOMAIN\username'
                : null,
          ),
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          validator: (v) {
            if (v == null || v.trim().isEmpty) return 'Username is required';
            if (_engine == Engine.sqlserver &&
                _auth == AuthMethod.windows &&
                !v.contains(r'\')) {
              return r'Windows authentication needs DOMAIN\username';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _password,
          obscureText: _obscurePassword,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => _passwordTouched = true,
          decoration: InputDecoration(
            labelText: 'Password',
            // Editing a saved connection must not require retyping the
            // password, and must not display it either.
            hintText: _hasStoredPassword && !_passwordTouched
                ? 'Saved in the keystore — leave blank to keep it'
                : null,
            suffixIcon: IconButton(
              icon: Icon(_obscurePassword
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text('Encryption', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        SegmentedButton<TlsMode>(
          segments: [
            for (final mode in TlsMode.values)
              ButtonSegment(value: mode, label: Text(mode.label)),
          ],
          selected: {_tls},
          onSelectionChanged: (values) =>
              setState(() => _tls = values.first),
          showSelectedIcon: false,
        ),
        const SizedBox(height: 6),
        Text(_tls.description, style: Theme.of(context).textTheme.bodySmall),
        if (_tls == TlsMode.disable) ...[
          const SizedBox(height: 6),
          Text(
            'Your password crosses the network in the clear. Do not use this '
            'over mobile data or public Wi-Fi.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
          ),
        ],
      ];

  /// Shows a message where the user is actually looking. The Test-connection
  /// banner lives at the bottom of a scrolling form, which is the wrong place
  /// for a failure they triggered from a field near the top.
  void _report(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 6),
    ));
  }

  /// Fetches the databases on the server and lets the user pick one.
  ///
  /// The fetch needs a reachable host and working credentials, so it doubles
  /// as a connection test — and when it fails, the reason is shown here rather
  /// than left for the user to discover after saving.
  Future<void> _pickDatabase() async {
    final host = _host.text.trim();
    final user = _user.text.trim();
    if (host.isEmpty || user.isEmpty) {
      _report('Fill in the host and username first.');
      return;
    }

    setState(() {
      _loadingDatabases = true;
      _testResult = '';
    });

    final state = context.read<AppState>();
    final profile = _buildProfile();
    final password = _password.text.isNotEmpty
        ? _password.text
        : await state.connections.password(profile.id);

    final result = await state.fetchDatabases(profile, password);
    if (!mounted) return;
    setState(() => _loadingDatabases = false);

    if (!result.ok) {
      _report(result.message);
      return;
    }
    if (result.databases.isEmpty) {
      _report('Connected, but this login cannot see any databases.');
      return;
    }

    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _DatabaseList(
        databases: result.databases,
        selected: _database.text.trim(),
        // PostgreSQL cannot connect without naming a database, so there is no
        // meaningful "let the server decide" for it.
        allowServerDefault: _engine != Engine.postgres,
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => _database.text = chosen);
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(withReadStream: false);
    final path = result?.files.single.path;
    if (path != null && mounted) {
      setState(() => _file.text = path);
    }
  }

  ConnectionProfile _buildProfile() {
    final existing = widget.existing;
    return ConnectionProfile(
      id: existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: _name.text.trim(),
      engine: _engine,
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()),
      database: _database.text.trim(),
      user: _user.text.trim(),
      file: _file.text.trim(),
      auth: _auth,
      tls: _tls,
      readOnly: _readOnly,
      colorTag: _colorTag,
      rawDsn: existing?.rawDsn ?? '',
      params: existing?.params ?? const {},
      lastUsed: existing?.lastUsed,
    );
  }

  Future<void> _test() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _testing = true;
      _testResult = '';
    });

    final state = context.read<AppState>();
    final profile = _buildProfile();
    // Use the typed password if there is one, otherwise the stored one, so
    // testing an existing connection works without retyping.
    final password = _password.text.isNotEmpty
        ? _password.text
        : await state.connections.password(profile.id);

    final result = await state.testConnection(profile, password);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = result.ok;
      _testResult = result.message;
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final state = context.read<AppState>();
    final navigator = Navigator.of(context);

    // A blank password field on an existing connection means "keep what is
    // stored", not "clear it". Passing null is how the store is told to leave
    // the keystore alone.
    final password = _passwordTouched ? _password.text : null;

    await state.connections.save(_buildProfile(), password: password);
    state.refresh();
    navigator.pop();
  }
}

class _EngineSelector extends StatelessWidget {
  const _EngineSelector({required this.selected, required this.onChanged});

  final Engine selected;
  final ValueChanged<Engine> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final engine in Engine.values)
          ChoiceChip(
            selected: engine == selected,
            label: Text(engine.label),
            onSelected: (_) => onChanged(engine),
          ),
      ],
    );
  }
}

class _ColorTagPicker extends StatelessWidget {
  const _ColorTagPicker({required this.selected, required this.onChanged});

  final int? selected;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Colour', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(
          'Shown behind the run button. Make production look different from '
          'everything else.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final color in connectionColors)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: GestureDetector(
                  onTap: () => onChanged(selected == color ? null : color),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Color(color),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected == color
                            ? Theme.of(context).colorScheme.onSurface
                            : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _TestBanner extends StatelessWidget {
  const _TestBanner({required this.ok, required this.message});

  final bool ok;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = ok ? scheme.primary : scheme.error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              message,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}


/// The list of databases fetched from the server.
///
/// A filter appears once the list is long enough to be worth scrolling — a
/// server with two hundred databases is common and unusable on a phone
/// otherwise.
class _DatabaseList extends StatefulWidget {
  const _DatabaseList({
    required this.databases,
    required this.selected,
    required this.allowServerDefault,
  });

  final List<String> databases;
  final String selected;
  final bool allowServerDefault;

  @override
  State<_DatabaseList> createState() => _DatabaseListState();
}

class _DatabaseListState extends State<_DatabaseList> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needle = _filter.trim().toLowerCase();
    final matches = needle.isEmpty
        ? widget.databases
        : widget.databases
            .where((d) => d.toLowerCase().contains(needle))
            .toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Text('Databases', style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text('${widget.databases.length}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
          ),
          if (widget.databases.length > 8)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                autofocus: false,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Filter',
                ),
                onChanged: (v) => setState(() => _filter = v),
              ),
            ),
          Expanded(
            child: ListView(
              controller: controller,
              children: [
                if (widget.allowServerDefault && needle.isEmpty) ...[
                  ListTile(
                    leading: const Icon(Icons.star_outline, size: 20),
                    title: const Text('Server default'),
                    subtitle: const Text(
                        'Whatever this login opens by default, usually master'),
                    selected: widget.selected.isEmpty,
                    onTap: () => Navigator.of(context).pop(''),
                  ),
                  const Divider(height: 1),
                ],
                for (final name in matches)
                  ListTile(
                    leading: const Icon(Icons.storage_outlined, size: 20),
                    title: Text(name, style: monoFont.copyWith(fontSize: 14)),
                    selected: name == widget.selected,
                    trailing: name == widget.selected
                        ? const Icon(Icons.check, size: 18)
                        : null,
                    onTap: () => Navigator.of(context).pop(name),
                  ),
                if (matches.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('Nothing matches.')),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

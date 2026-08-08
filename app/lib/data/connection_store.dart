import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';

/// Persists saved connections.
///
/// The split is the important part. Everything that is not a secret — name,
/// host, port, database, user — goes into a JSON file in the app's private
/// directory, where it is easy to read, easy to back up, and easy to debug.
/// The password goes into the platform keystore, and nowhere else.
///
/// Rolling our own encryption over a single blob was the alternative, and it
/// is worse: it means inventing key derivation, key storage, and a migration
/// path, to end up with something weaker than the Keystore and Keychain the OS
/// already provides and already backs with hardware where it exists.
class ConnectionStore {
  ConnectionStore({FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                // Without this the password is readable while the phone is
                // locked, and is copied into an iCloud backup.
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _secure;

  static const _fileName = 'connections.json';
  static const _passwordPrefix = 'db_crawler_password_';

  List<ConnectionProfile> _profiles = const [];
  bool _loaded = false;

  List<ConnectionProfile> get profiles => List.unmodifiable(_profiles);
  bool get isLoaded => _loaded;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) {
        _profiles = const [];
        _loaded = true;
        return;
      }
      final decoded = jsonDecode(await file.readAsString());
      final list = (decoded is Map<String, dynamic>)
          ? (decoded['connections'] as List<dynamic>? ?? const [])
          : (decoded as List<dynamic>);
      _profiles = list
          .map((e) => ConnectionProfile.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // A corrupt file must not brick the app on launch. Starting empty is
      // recoverable — the user re-enters a connection. Crashing on every
      // start is not, and the file is kept so nothing is thrown away.
      _profiles = const [];
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    final file = await _file();
    final payload = jsonEncode({
      'version': 1,
      'connections': _profiles.map((p) => p.toJson()).toList(),
    });
    // Write to a temporary file and rename over the original. A rename is
    // atomic, so a crash or a battery death mid-write cannot leave a
    // half-written file where the connection list used to be.
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(payload, flush: true);
    await temp.rename(file.path);
  }

  Future<void> save(ConnectionProfile profile, {String? password}) async {
    final index = _profiles.indexWhere((p) => p.id == profile.id);
    final updated = List.of(_profiles);
    if (index >= 0) {
      updated[index] = profile;
    } else {
      updated.add(profile);
    }
    _profiles = updated;
    await _persist();

    // A null password means "leave whatever is stored alone", which is what
    // lets the editor be reopened and resaved without the user retyping it.
    // An empty string means "forget it".
    if (password != null) {
      if (password.isEmpty) {
        await _secure.delete(key: _passwordKey(profile.id));
      } else {
        await _secure.write(key: _passwordKey(profile.id), value: password);
      }
    }
  }

  Future<void> delete(String id) async {
    _profiles = _profiles.where((p) => p.id != id).toList();
    await _persist();
    // Deleting the credential matters as much as deleting the profile —
    // otherwise the keystore accumulates passwords for connections that no
    // longer exist and nobody can see.
    await _secure.delete(key: _passwordKey(id));
  }

  Future<String> password(String id) async {
    try {
      return await _secure.read(key: _passwordKey(id)) ?? '';
    } catch (_) {
      // A keystore read can fail on a device whose secure hardware was reset,
      // typically after a factory restore. Treating it as "no password" lets
      // the user retype it instead of hitting an error they cannot act on.
      return '';
    }
  }

  Future<bool> hasPassword(String id) async {
    final value = await password(id);
    return value.isNotEmpty;
  }

  Future<void> touch(String id) async {
    final index = _profiles.indexWhere((p) => p.id == id);
    if (index < 0) return;
    final updated = List.of(_profiles);
    updated[index] = updated[index].copyWith(lastUsed: DateTime.now());
    _profiles = updated;
    await _persist();
  }

  static String _passwordKey(String id) => '$_passwordPrefix$id';
}

/// Keeps the last N statements the user ran, per device.
///
/// This is the feature that turns the app from a query box into something
/// usable on a phone: nobody wants to retype a join on a touchscreen, and the
/// thing you need at 11pm is almost always something you already ran once.
class QueryHistoryStore {
  static const _fileName = 'history.json';
  static const _limit = 200;

  List<HistoryEntry> _entries = const [];

  List<HistoryEntry> get entries => List.unmodifiable(_entries);

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final list = jsonDecode(await file.readAsString()) as List<dynamic>;
      _entries = list
          .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      _entries = const [];
    }
  }

  Future<void> add(HistoryEntry entry) async {
    // Running the same statement twice in a row should not fill the list with
    // copies of it; the second run just moves the entry to the top.
    final withoutDuplicate =
        _entries.where((e) => e.sql.trim() != entry.sql.trim()).toList();
    _entries = [entry, ...withoutDuplicate].take(_limit).toList();
    await _persist();
  }

  Future<void> clear() async {
    _entries = const [];
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final file = await _file();
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode(_entries.map((e) => e.toJson()).toList()),
        flush: true,
      );
      await temp.rename(file.path);
    } catch (_) {
      // History is a convenience. Failing to write it must never interrupt
      // the query the user actually cares about.
    }
  }
}

# DB Crawler

[![CI](https://github.com/Ark-Devs/DB-Crawler/actions/workflows/ci.yml/badge.svg)](https://github.com/Ark-Devs/DB-Crawler/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A SQL client for phones. Browse schemas and run queries against **SQL Server /
Azure SQL, PostgreSQL, MySQL / MariaDB, and SQLite** — from an Android or iOS
device, with no laptop, no VPN appliance, and no server in the middle.

Connections are saved on the device. Passwords go into the platform keystore,
never into a file.

## Install

Builds are attached to each [release](https://github.com/Ark-Devs/DB-Crawler/releases).

**Android.** Take `db-crawler-<version>-arm64-v8a.apk` unless you know your
phone is something else — that covers essentially every device from the last
several years. `universal` runs anywhere and is roughly three times the size,
because it carries a copy of the core for each architecture. Android will ask
you to permit installing from your browser or file manager the first time.

The beta APKs are signed with a **debug key**. Fine for sideloading, not
acceptable to the Play Store — a real signing key comes before any store
submission.

**iOS.** The attached IPA is unsigned, and Apple provides no way to install an
unsigned app by tapping it. You need either an Apple Developer certificate to
re-sign it, or a sideloading tool such as AltStore or Sideloadly.

## Why it is built this way

The app is Flutter for the interface and **Go for everything that touches a
database**, linked in as a native library and called over `dart:ffi`.

That split is driven by SQL Server. Dart has no mature TDS driver, so a
pure-Dart client would mean hand-writing the wire protocol — weeks of work on
the engine that matters most here, to end up with something less tested than
what already exists. Go has battle-tested drivers for all four engines.

It pays off twice. The risky parts — protocol handling, type conversion,
catalog queries — are plain Go, so they run and are tested on a laptop, in CI,
against a real database. No phone required to find a bug.

```
core/          Go: connections, queries, introspection, the JSON protocol
  dbcore/      the engine — no UI, no platform, fully testable
  ffi/         the three C symbols the app links against
  cmd/         a terminal harness that speaks the identical protocol
app/           Flutter: the interface
tool/          cross-compiles the core for Android and iOS
```

## What it does

**Connections.** Four engines, saved on the device, with a colour tag so
production does not look like staging. Test before saving. A read-only switch
that refuses anything that is not a read.

**Explorer.** Schemas, tables, views, functions and procedures, filtered by
kind and by name, with row estimates. Tap a table to open `SELECT TOP 200` on
it; tap its icon for columns, indexes, foreign keys, and a reconstructed
`CREATE TABLE`. Tap a column to scaffold a `WHERE` clause.

**Editor.** Several query tabs, each holding its own results, so a slow query
in one cannot overwrite what another is showing. Multi-statement batches, a
stop button that actually cancels the query on the server, and context-aware
completion for tables and columns. Select part of the buffer and only that
part runs. Autocorrect, smart quotes, and auto-capitalisation are all off —
each one silently breaks SQL.

**One thing on screen at a time.** Navigation is a drawer, not a permanent tab
bar: on a phone in landscape the chrome and the keyboard together left the
editor about one line to type into. The only thing kept on screen is the name
of the database the next statement will run against, and even that folds away
while you are typing. Tap it to switch database.

**Results.** A grid that scrolls both ways with a pinned header, lazy rows, and
columns sized to their contents. Numbers right-aligned. `NULL` rendered
distinctly from an empty string. Tap a row to read it full-screen. Export to
CSV or JSON.

**History.** Every statement you have run, searchable. Nobody wants to retype a
join on a touchscreen.

## Running it

```bash
# 1. Build the native core (needs the Android NDK)
export ANDROID_NDK_HOME=~/Android/Sdk/ndk/27.0.12077973
./tool/build-core.sh android

# 2. Run the app
cd app && flutter run
```

For iOS, `./tool/build-core.sh ios` on a Mac, then `cd app && flutter run`.
No Xcode step: the Podfile declares the core as a pod and the podspec carries
the linker flags.

## Working on the core without a phone

`cmd/dbcrawler` speaks the same JSON protocol the app sends, over stdin:

```bash
cd core
go run ./cmd/dbcrawler -sqlite /tmp/shop.db -tables
go run ./cmd/dbcrawler -sqlite /tmp/shop.db -read-only -sql "SELECT * FROM products"

# Or drive the protocol directly, one request per line
echo '{"op":"ping"}' | go run ./cmd/dbcrawler
```

Against a real server:

```bash
go run ./cmd/dbcrawler -engine sqlserver \
  -dsn 'sqlserver://user:pass@host:1433?database=SQ_Inventory&encrypt=true' \
  -sql 'SELECT TOP 5 * FROM dbo.orders'
```

## Tests

```bash
cd core && go test -race ./...   # runs against a real SQLite database
cd app  && flutter test && flutter analyze
```

The Go suite is not mocked. A mock would only prove the code agrees with
itself; the bugs worth catching — a driver returning bytes where a string was
expected, a catalog reporting columns out of order, a row cap that silently
drops data — only show up against a real engine.

## Three decisions worth knowing about

**Values cross the FFI boundary as strings, never as JSON numbers.** A
`DECIMAL(19,4)` routed through a float64 loses its last digits silently, and
that type is where every price and every ledger balance lives. Each value
arrives as an exact string plus its column's kind, which still tells the grid
to right-align it and an export to write it unquoted. The export re-types to a
real number only when the round-trip is provably lossless; anything wider stays
an exact string.

**Statement splitting is a scanner, not a split on semicolons.** A semicolon
inside a string literal, a comment, a PostgreSQL dollar-quoted body, or a
bracketed identifier is not a separator. Treating it as one truncates a
statement into something that either fails or — worse — succeeds while meaning
something else.

**The read-only guard is an allowlist over a full-depth keyword scan.** A
blocklist fails open, and failing open on production from a phone is the exact
accident the switch exists to prevent. It also has to look inside CTE bodies:
`WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x` presents `SELECT` as
its outermost keyword while deleting every row.

## If a connection fails

The app tries to say which layer failed, because the raw driver message
usually blames the wrong one.

**"operation not permitted"** means the device refused to open the socket at
all — nothing reached the network. On Android that is the missing `INTERNET`
permission. Flutter's template puts it only in the debug and profile
manifests, which are not merged into a release build, so a release APK has no
network access unless `android/app/src/main/AndroidManifest.xml` declares it.
Beta 1 shipped without it and could not connect to anything.

**"no reply from the host"** is a network path problem: firewall, security
group, or a database not listening on a public address.

**"login failed"** means the server was reached and answered — credentials,
not connectivity.

**"negative serial number"** was a real failure against SQL Server and is
fixed. Its default self-signed certificate usually has a serial whose leading
bit is set, which DER reads as negative, and Go 1.23 began rejecting those
while parsing — before certificate verification is reached, so
`TrustServerCertificate` could not rescue it and the connection was impossible
at any Encryption setting except Off. The main packages now carry
`//go:debug x509negativeserial=1`, restoring the older parsing behaviour. That
relaxes a strictness check, not a trust check; whether the certificate is
trusted is still decided by the Encryption setting.

**"certificate could not be verified"** is Verify doing its job against a
self-signed certificate. Use Require — still encrypted, just not checking who
issued the certificate.

### Authentication

SQL Server connections pick a method explicitly: **SQL Server** (a login the
server itself holds — the usual choice) or **Windows** (a domain account over
NTLM, which needs the username as `DOMAIN\username`).

It is a visible choice because the driver otherwise infers it from the shape of
the username, and an inferred choice cannot be debugged: a rejected login never
says which method was even tried. Azure SQL works over SQL Server
authentication; Entra ID / Azure AD accounts are not supported yet.

### The database field

For SQL Server the database is optional, and leaving it empty is not the same
as picking one: you land in whatever the login's default database is, usually
`master`. The explorer will then show `master`'s tables and none of yours,
which looks like the app is broken when it is doing exactly what it was told.

That is why the header names the database you are actually in, asked of the
server rather than read back off the profile — it is the difference between
"no tables" and "no tables *here*". Tap it to move to another database; the
list is what your login can open, and switching reconnects rather than issuing
`USE`, because PostgreSQL cannot change database on a live connection at all.

## Security

- Passwords live in the Android Keystore / iOS Keychain, keyed by connection
  id. The saved-connections file holds no credential and never has.
- The keychain entry is `first_unlock_this_device`: not readable while the
  phone is locked, and not copied into an iCloud backup.
- TLS defaults to **require** for every networked engine. Turning it off is a
  deliberate act and the editor says what it costs.
- The read-only switch is a client-side guard, and a useful one. It is not a
  substitute for a read-only login on the server — if you have the option, use
  both.
- Exports are written to the cache directory, because a share is in transit,
  not something to leave sitting in app storage.

## Cutting a release

Tag it and push. The workflow in `.github/workflows/release.yml` builds the
core for all three Android ABIs, builds the APKs, builds an unsigned IPA on a
macOS runner, and attaches everything to a GitHub Release.

```bash
git tag -a v0.0.2-beta -m "Beta 2"
git push origin v0.0.2-beta
```

It runs there rather than locally because GitHub's runners carry the Android
SDK, the NDK, and Xcode. The iOS job is `continue-on-error`, so a problem
needing a Mac to diagnose does not hold up a working Android build.

## Status

Working, and honest about what is not here yet:

- Editing rows from the grid — the app queries and browses; it does not yet
  offer an in-place cell editor.
- No syntax highlighting. Completion is there, but it is name completion —
  tables, columns, keywords — not a parser that understands your query.
- Results are capped at 1000 rows. The grid says when a result was cut short,
  but there is no paging to the next page.
- The reconstructed DDL is a readable summary, not a runnable script. Storage
  clauses, computed columns, and check constraints are not in the metadata it
  is built from, and the table screen says so.
- Only one connection is open at a time.

The iOS path is the least exercised part of this repo. The Android core is
cross-compiled and symbol-checked in CI on every push; the iOS archive,
podspec, and linker flags have not yet been run on real hardware.

## Licence

[MIT](LICENSE). © 2026 Ark Devs.

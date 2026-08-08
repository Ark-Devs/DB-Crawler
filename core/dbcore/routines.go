package dbcore

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
)

// Object kinds the explorer groups by. These are the values TableInfo.Type
// carries, so the app can filter on them without a second vocabulary.
const (
	ObjTable     = "table"
	ObjView      = "view"
	ObjMatView   = "materialized view"
	ObjFunction  = "function"
	ObjProcedure = "procedure"
)

// IsRoutine reports whether a kind is executable code rather than storage.
// Routines have a definition to read; tables have columns to browse.
func IsRoutine(kind string) bool {
	return kind == ObjFunction || kind == ObjProcedure
}

// Objects lists everything in a schema worth showing: tables, views, and
// stored routines.
//
// A failure to read routines does not fail the whole listing. Permission to
// see tables and permission to see procedure metadata are separate grants in
// every one of these engines, and losing the table list because a routine
// query was refused would be a poor trade.
func (s *Session) Objects(ctx context.Context, schema string) ([]TableInfo, error) {
	tables, err := s.Tables(ctx, schema)
	if err != nil {
		return nil, err
	}
	routines, routineErr := s.routines(ctx, schema)
	if routineErr == nil {
		tables = append(tables, routines...)
	}
	sortTables(tables)
	return tables, nil
}

func (s *Session) routines(ctx context.Context, schema string) ([]TableInfo, error) {
	switch s.Engine {
	case SQLServer:
		return s.queryRoutines(ctx, `
SELECT sch.name,
       o.name,
       CASE WHEN o.type = 'P' THEN 'procedure' ELSE 'function' END
FROM sys.objects o
JOIN sys.schemas sch ON sch.schema_id = o.schema_id
WHERE o.type IN ('P', 'FN', 'IF', 'TF')
  AND (@p1 = '' OR sch.name = @p1)
ORDER BY sch.name, o.name`, schema)

	case PostgreSQL:
		// prokind arrived in PostgreSQL 11. On anything older this query
		// fails, routines are skipped, and the table list is unaffected.
		return s.queryRoutines(ctx, `
SELECT n.nspname,
       p.proname,
       CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE ($1 = '' OR n.nspname = $1)
  AND n.nspname NOT LIKE 'pg\_%'
  AND n.nspname <> 'information_schema'
  AND p.prokind IN ('f', 'p')
ORDER BY n.nspname, p.proname`, schema)

	case MySQL:
		return s.queryRoutines(ctx, `
SELECT routine_schema, routine_name, LOWER(routine_type)
FROM information_schema.routines
WHERE routine_schema = COALESCE(NULLIF(?, ''), DATABASE())
ORDER BY routine_name`, schema)

	case SQLite:
		// SQLite has no stored routines at all.
		return nil, nil
	}
	return nil, fmt.Errorf("unsupported engine %q", s.Engine)
}

func (s *Session) queryRoutines(ctx context.Context, query string, schema string) ([]TableInfo, error) {
	rows, err := s.db.QueryContext(ctx, query, schema)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []TableInfo
	for rows.Next() {
		var t TableInfo
		if err := rows.Scan(&t.Schema, &t.Name, &t.Type); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// RoutineDefinition returns the source of a stored function or procedure.
//
// Unlike the reconstructed CREATE TABLE the table screen shows, this is the
// real text the server holds, so it can be read and trusted.
func (s *Session) RoutineDefinition(ctx context.Context, schema, name, kind string) (string, error) {
	switch s.Engine {
	case SQLServer:
		qualified := name
		if schema != "" {
			qualified = schema + "." + name
		}
		return s.queryString(ctx,
			`SELECT OBJECT_DEFINITION(OBJECT_ID(@p1))`, qualified)

	case PostgreSQL:
		// The regprocedure cast needs an unambiguous name; where a function is
		// overloaded this returns the first match, which is the common case.
		return s.queryString(ctx, `
SELECT pg_get_functiondef(p.oid)
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.proname = $1 AND ($2 = '' OR n.nspname = $2)
LIMIT 1`, name, schema)

	case MySQL:
		return s.queryString(ctx, `
SELECT routine_definition
FROM information_schema.routines
WHERE routine_name = ?
  AND routine_schema = COALESCE(NULLIF(?, ''), DATABASE())
LIMIT 1`, name, schema)

	case SQLite:
		return "", fmt.Errorf("SQLite has no stored routines")
	}
	return "", fmt.Errorf("unsupported engine %q", s.Engine)
}

func (s *Session) queryString(ctx context.Context, query string, args ...any) (string, error) {
	var v sql.NullString
	if err := s.db.QueryRowContext(ctx, query, args...).Scan(&v); err != nil {
		return "", err
	}
	if !v.Valid || strings.TrimSpace(v.String) == "" {
		// Encrypted or natively-compiled routines have no readable text, and
		// saying so beats showing an empty page.
		return "", fmt.Errorf("no definition available — the routine may be encrypted")
	}
	return v.String, nil
}

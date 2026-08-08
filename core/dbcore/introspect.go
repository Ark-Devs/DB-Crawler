package dbcore

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"strings"
)

// TableInfo is one table or view in the explorer tree.
type TableInfo struct {
	Schema string `json:"schema,omitempty"`
	Name   string `json:"name"`
	Type   string `json:"type"` // "table" | "view" | "materialized view"
	// RowEstimate comes from the planner's statistics, not from COUNT(*).
	// It is absent rather than zero when the engine cannot cheaply say, because
	// counting every table in a schema to populate a tree is how a browser
	// hangs for a minute on a database of any size.
	RowEstimate *int64 `json:"rowEstimate,omitempty"`
	Comment     string `json:"comment,omitempty"`
}

// ColumnInfo describes one column, in the detail a column list needs.
type ColumnInfo struct {
	Name         string  `json:"name"`
	DataType     string  `json:"dataType"`
	Nullable     bool    `json:"nullable"`
	Default      *string `json:"default,omitempty"`
	IsPrimaryKey bool    `json:"isPrimaryKey"`
	IsAutoIncr   bool    `json:"isAutoIncrement,omitempty"`
	Position     int     `json:"position"`
	Comment      string  `json:"comment,omitempty"`
}

// IndexInfo describes one index.
type IndexInfo struct {
	Name    string   `json:"name"`
	Columns []string `json:"columns"`
	Unique  bool     `json:"unique"`
	Primary bool     `json:"primary"`
}

// ForeignKeyInfo describes one outbound foreign key, which is what makes the
// explorer navigable: tapping a value can jump to the row it references.
type ForeignKeyInfo struct {
	Name       string   `json:"name"`
	Columns    []string `json:"columns"`
	RefSchema  string   `json:"refSchema,omitempty"`
	RefTable   string   `json:"refTable"`
	RefColumns []string `json:"refColumns"`
	OnDelete   string   `json:"onDelete,omitempty"`
	OnUpdate   string   `json:"onUpdate,omitempty"`
}

// TableDetail is everything the table screen shows, fetched in one round trip
// so opening a table is one wait rather than four.
type TableDetail struct {
	Schema      string           `json:"schema,omitempty"`
	Name        string           `json:"name"`
	Columns     []ColumnInfo     `json:"columns"`
	Indexes     []IndexInfo      `json:"indexes"`
	ForeignKeys []ForeignKeyInfo `json:"foreignKeys"`
	DDL         string           `json:"ddl,omitempty"`
}

// Databases lists the databases reachable on this connection.
func (s *Session) Databases(ctx context.Context) ([]string, error) {
	switch s.Engine {
	case SQLServer:
		// HAS_DBACCESS filters to what this login can actually open, so the
		// tree does not offer databases that error the moment they are tapped.
		return s.queryStrings(ctx, `
			SELECT name FROM sys.databases
			WHERE state = 0 AND HAS_DBACCESS(name) = 1
			ORDER BY name`)
	case PostgreSQL:
		return s.queryStrings(ctx, `
			SELECT datname FROM pg_database
			WHERE datallowconn AND NOT datistemplate
			  AND has_database_privilege(datname, 'CONNECT')
			ORDER BY datname`)
	case MySQL:
		return s.queryStrings(ctx, `
			SELECT schema_name FROM information_schema.schemata
			WHERE schema_name NOT IN ('information_schema','performance_schema','mysql','sys')
			ORDER BY schema_name`)
	case SQLite:
		// SQLite's "databases" are the main file plus anything ATTACHed.
		return s.queryStrings(ctx, `SELECT name FROM pragma_database_list ORDER BY seq`)
	}
	return nil, fmt.Errorf("unsupported engine %q", s.Engine)
}

// Schemas lists the schemas inside the current database. Engines without a
// schema layer return nothing, and the explorer skips the level entirely.
func (s *Session) Schemas(ctx context.Context) ([]string, error) {
	switch s.Engine {
	case SQLServer:
		return s.queryStrings(ctx, `
			SELECT name FROM sys.schemas
			WHERE name NOT IN ('sys','INFORMATION_SCHEMA','guest','db_owner',
			                   'db_accessadmin','db_securityadmin','db_ddladmin',
			                   'db_backupoperator','db_datareader','db_datawriter',
			                   'db_denydatareader','db_denydatawriter')
			ORDER BY name`)
	case PostgreSQL:
		return s.queryStrings(ctx, `
			SELECT nspname FROM pg_namespace
			WHERE nspname NOT LIKE 'pg\_%' AND nspname <> 'information_schema'
			  AND has_schema_privilege(nspname, 'USAGE')
			ORDER BY nspname`)
	}
	return nil, nil
}

// Tables lists tables and views in a schema. An empty schema means whatever
// the connection considers current.
func (s *Session) Tables(ctx context.Context, schema string) ([]TableInfo, error) {
	switch s.Engine {
	case SQLServer:
		return s.sqlServerTables(ctx, schema)
	case PostgreSQL:
		return s.postgresTables(ctx, schema)
	case MySQL:
		return s.mysqlTables(ctx, schema)
	case SQLite:
		return s.sqliteTables(ctx)
	}
	return nil, fmt.Errorf("unsupported engine %q", s.Engine)
}

// Table fetches columns, indexes, and foreign keys for one table.
func (s *Session) Table(ctx context.Context, schema, name string) (*TableDetail, error) {
	detail := &TableDetail{Schema: schema, Name: name}
	var err error
	if detail.Columns, err = s.columns(ctx, schema, name); err != nil {
		return nil, err
	}
	if len(detail.Columns) == 0 {
		return nil, fmt.Errorf("table %s not found", s.Engine.Qualify(schema, name))
	}
	// Indexes and keys are supporting detail. A permission gap that hides them
	// should not stop the column list — which is the part the user came for —
	// from rendering.
	detail.Indexes, _ = s.indexes(ctx, schema, name)
	detail.ForeignKeys, _ = s.foreignKeys(ctx, schema, name)
	detail.DDL = s.renderDDL(detail)
	return detail, nil
}

func (s *Session) columns(ctx context.Context, schema, name string) ([]ColumnInfo, error) {
	switch s.Engine {
	case SQLServer:
		return s.sqlServerColumns(ctx, schema, name)
	case PostgreSQL:
		return s.postgresColumns(ctx, schema, name)
	case MySQL:
		return s.mysqlColumns(ctx, schema, name)
	case SQLite:
		return s.sqliteColumns(ctx, name)
	}
	return nil, fmt.Errorf("unsupported engine %q", s.Engine)
}

func (s *Session) indexes(ctx context.Context, schema, name string) ([]IndexInfo, error) {
	switch s.Engine {
	case SQLServer:
		return s.sqlServerIndexes(ctx, schema, name)
	case PostgreSQL:
		return s.postgresIndexes(ctx, schema, name)
	case MySQL:
		return s.mysqlIndexes(ctx, schema, name)
	case SQLite:
		return s.sqliteIndexes(ctx, name)
	}
	return nil, nil
}

func (s *Session) foreignKeys(ctx context.Context, schema, name string) ([]ForeignKeyInfo, error) {
	switch s.Engine {
	case SQLServer:
		return s.sqlServerForeignKeys(ctx, schema, name)
	case PostgreSQL:
		return s.postgresForeignKeys(ctx, schema, name)
	case MySQL:
		return s.mysqlForeignKeys(ctx, schema, name)
	case SQLite:
		return s.sqliteForeignKeys(ctx, name)
	}
	return nil, nil
}

// renderDDL reconstructs a CREATE TABLE from the metadata already fetched.
//
// It is a readable summary, not something to run: engine-specific storage
// clauses, partitioning, computed columns, and check constraints are not in
// the metadata gathered here. The app labels it as such rather than implying a
// faithful script.
func (s *Session) renderDDL(d *TableDetail) string {
	var b strings.Builder
	fmt.Fprintf(&b, "CREATE TABLE %s (\n", s.Engine.Qualify(d.Schema, d.Name))

	parts := make([]string, 0, len(d.Columns)+len(d.ForeignKeys)+1)
	for _, c := range d.Columns {
		line := "    " + s.Engine.QuoteIdentifier(c.Name) + " " + c.DataType
		if !c.Nullable {
			line += " NOT NULL"
		}
		if c.Default != nil && *c.Default != "" {
			line += " DEFAULT " + *c.Default
		}
		parts = append(parts, line)
	}

	var pk []string
	for _, c := range d.Columns {
		if c.IsPrimaryKey {
			pk = append(pk, s.Engine.QuoteIdentifier(c.Name))
		}
	}
	if len(pk) > 0 {
		parts = append(parts, "    PRIMARY KEY ("+strings.Join(pk, ", ")+")")
	}

	for _, fk := range d.ForeignKeys {
		parts = append(parts, fmt.Sprintf("    CONSTRAINT %s FOREIGN KEY (%s) REFERENCES %s (%s)",
			s.Engine.QuoteIdentifier(fk.Name),
			s.quoteAll(fk.Columns),
			s.Engine.Qualify(fk.RefSchema, fk.RefTable),
			s.quoteAll(fk.RefColumns)))
	}

	b.WriteString(strings.Join(parts, ",\n"))
	b.WriteString("\n);\n")

	for _, ix := range d.Indexes {
		if ix.Primary {
			continue
		}
		unique := ""
		if ix.Unique {
			unique = "UNIQUE "
		}
		fmt.Fprintf(&b, "\nCREATE %sINDEX %s ON %s (%s);\n",
			unique,
			s.Engine.QuoteIdentifier(ix.Name),
			s.Engine.Qualify(d.Schema, d.Name),
			s.quoteAll(ix.Columns))
	}
	return b.String()
}

func (s *Session) quoteAll(names []string) string {
	out := make([]string, len(names))
	for i, n := range names {
		out[i] = s.Engine.QuoteIdentifier(n)
	}
	return strings.Join(out, ", ")
}

// PreviewSQL builds the statement the app runs when a table is tapped.
// Keeping it here rather than in the UI means the quoting rules live in one
// place and the app can show the user exactly what it is about to run.
func (s *Session) PreviewSQL(schema, table string, limit int) string {
	if limit <= 0 {
		limit = defaultMaxRows
	}
	ref := s.Engine.Qualify(schema, table)
	if s.Engine == SQLServer {
		return fmt.Sprintf("SELECT TOP %d * FROM %s", limit, ref)
	}
	return fmt.Sprintf("SELECT * FROM %s LIMIT %d", ref, limit)
}

// CountSQL builds an exact row count, which the table screen runs only when
// the user asks for it.
func (s *Session) CountSQL(schema, table string) string {
	return "SELECT COUNT(*) AS row_count FROM " + s.Engine.Qualify(schema, table)
}

// --- small query helpers -------------------------------------------------

func (s *Session) queryStrings(ctx context.Context, query string, args ...any) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var v sql.NullString
		if err := rows.Scan(&v); err != nil {
			return nil, err
		}
		if v.Valid {
			out = append(out, v.String)
		}
	}
	return out, rows.Err()
}

// groupIndexRows folds the one-row-per-index-column shape that every catalog
// returns into one entry per index, preserving column order.
type indexRow struct {
	name    string
	column  string
	unique  bool
	primary bool
}

func groupIndexRows(rows []indexRow) []IndexInfo {
	order := make([]string, 0, len(rows))
	byName := make(map[string]*IndexInfo, len(rows))
	for _, r := range rows {
		ix, ok := byName[r.name]
		if !ok {
			ix = &IndexInfo{Name: r.name, Unique: r.unique, Primary: r.primary}
			byName[r.name] = ix
			order = append(order, r.name)
		}
		if r.column != "" {
			ix.Columns = append(ix.Columns, r.column)
		}
	}
	out := make([]IndexInfo, 0, len(order))
	for _, name := range order {
		out = append(out, *byName[name])
	}
	return out
}

type fkRow struct {
	name       string
	column     string
	refSchema  string
	refTable   string
	refColumn  string
	onDelete   string
	onUpdate   string
	ordinalKey int
}

func groupForeignKeyRows(rows []fkRow) []ForeignKeyInfo {
	order := make([]string, 0, len(rows))
	byName := make(map[string]*ForeignKeyInfo, len(rows))
	for _, r := range rows {
		fk, ok := byName[r.name]
		if !ok {
			fk = &ForeignKeyInfo{
				Name:      r.name,
				RefSchema: r.refSchema,
				RefTable:  r.refTable,
				OnDelete:  r.onDelete,
				OnUpdate:  r.onUpdate,
			}
			byName[r.name] = fk
			order = append(order, r.name)
		}
		fk.Columns = append(fk.Columns, r.column)
		fk.RefColumns = append(fk.RefColumns, r.refColumn)
	}
	out := make([]ForeignKeyInfo, 0, len(order))
	for _, name := range order {
		out = append(out, *byName[name])
	}
	return out
}

func sortTables(t []TableInfo) {
	sort.Slice(t, func(i, j int) bool {
		if t[i].Schema != t[j].Schema {
			return t[i].Schema < t[j].Schema
		}
		return t[i].Name < t[j].Name
	})
}

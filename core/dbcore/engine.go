// Package dbcore is the database engine behind the mobile SQL client.
//
// It is deliberately free of any UI or platform concern: everything here runs
// as plain Go on a laptop, which is what makes the protocol handling, the type
// conversion, and the introspection queries testable without a phone in hand.
package dbcore

import (
	"fmt"
	"strconv"
	"strings"
)

// Engine is one supported database product.
type Engine string

const (
	SQLServer  Engine = "sqlserver"
	PostgreSQL Engine = "postgres"
	MySQL      Engine = "mysql"
	SQLite     Engine = "sqlite"
)

// ParseEngine maps the names a user might reasonably type onto an Engine.
// The aliases matter because a connection profile is often typed on a phone
// keyboard, and "mariadb" or "mssql" are what people actually reach for.
func ParseEngine(s string) (Engine, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "sqlserver", "mssql", "sql server", "azuresql", "azure":
		return SQLServer, nil
	case "postgres", "postgresql", "pg":
		return PostgreSQL, nil
	case "mysql", "mariadb":
		return MySQL, nil
	case "sqlite", "sqlite3":
		return SQLite, nil
	default:
		return "", fmt.Errorf("unknown database engine %q", s)
	}
}

// driverName is the database/sql driver each engine registers itself under.
func (e Engine) driverName() string {
	switch e {
	case SQLServer:
		return "sqlserver"
	case PostgreSQL:
		return "pgx"
	case MySQL:
		return "mysql"
	case SQLite:
		return "sqlite"
	}
	return string(e)
}

// DefaultPort is what the connection editor pre-fills so a user only has to
// type a host. SQLite is a file, so it has none.
func (e Engine) DefaultPort() int {
	switch e {
	case SQLServer:
		return 1433
	case PostgreSQL:
		return 5432
	case MySQL:
		return 3306
	}
	return 0
}

// Placeholder renders the bind marker for the nth parameter, counting from 1.
// Every engine spells this differently and getting it wrong is the single most
// common way a cross-engine client corrupts a query.
func (e Engine) Placeholder(n int) string {
	switch e {
	case SQLServer:
		return "@p" + strconv.Itoa(n)
	case PostgreSQL:
		return "$" + strconv.Itoa(n)
	default:
		return "?"
	}
}

// QuoteIdentifier wraps a table or column name so that reserved words, spaces,
// and mixed case survive. The closing delimiter is doubled inside the name,
// which is the escape every one of these dialects uses.
func (e Engine) QuoteIdentifier(name string) string {
	switch e {
	case SQLServer:
		return "[" + strings.ReplaceAll(name, "]", "]]") + "]"
	case MySQL:
		return "`" + strings.ReplaceAll(name, "`", "``") + "`"
	default:
		return `"` + strings.ReplaceAll(name, `"`, `""`) + `"`
	}
}

// Qualify builds a qualified table reference, skipping an empty schema so
// SQLite and MySQL — which have no schema layer in the way the others do —
// do not end up with a leading dot.
func (e Engine) Qualify(schema, table string) string {
	if schema == "" {
		return e.QuoteIdentifier(table)
	}
	return e.QuoteIdentifier(schema) + "." + e.QuoteIdentifier(table)
}

// SupportsSchemas reports whether the explorer should show a schema level
// between the database and its tables.
func (e Engine) SupportsSchemas() bool {
	return e == SQLServer || e == PostgreSQL
}

// itoa is a local shorthand; the catalog code builds a lot of small strings.
func itoa(n int) string { return strconv.Itoa(n) }

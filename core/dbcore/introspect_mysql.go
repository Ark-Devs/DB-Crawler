package dbcore

import (
	"context"
	"database/sql"
	"strings"
)

// MySQL has no schema layer distinct from the database, so the "schema"
// argument is treated as a database name and an empty value means DATABASE().

func (s *Session) mysqlTables(ctx context.Context, schema string) ([]TableInfo, error) {
	const q = `
SELECT table_schema, table_name,
       CASE table_type WHEN 'VIEW' THEN 'view' ELSE 'table' END,
       table_rows,
       COALESCE(table_comment, '')
FROM information_schema.tables
WHERE table_schema = COALESCE(NULLIF(?, ''), DATABASE())
ORDER BY table_name`

	rows, err := s.db.QueryContext(ctx, q, schema)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []TableInfo
	for rows.Next() {
		var t TableInfo
		var estimate sql.NullInt64
		if err := rows.Scan(&t.Schema, &t.Name, &t.Type, &estimate, &t.Comment); err != nil {
			return nil, err
		}
		// InnoDB's table_rows is a sampled estimate and is NULL for a view.
		if estimate.Valid && t.Type == "table" {
			e := estimate.Int64
			t.RowEstimate = &e
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (s *Session) mysqlColumns(ctx context.Context, schema, table string) ([]ColumnInfo, error) {
	const q = `
SELECT column_name,
       column_type,
       is_nullable,
       column_default,
       ordinal_position,
       COALESCE(column_comment, ''),
       column_key,
       extra
FROM information_schema.columns
WHERE table_name = ?
  AND table_schema = COALESCE(NULLIF(?, ''), DATABASE())
ORDER BY ordinal_position`

	rows, err := s.db.QueryContext(ctx, q, table, schema)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []ColumnInfo
	for rows.Next() {
		var (
			c        ColumnInfo
			nullable string
			def      sql.NullString
			key      string
			extra    string
		)
		if err := rows.Scan(&c.Name, &c.DataType, &nullable, &def,
			&c.Position, &c.Comment, &key, &extra); err != nil {
			return nil, err
		}
		c.Nullable = strings.EqualFold(nullable, "YES")
		c.IsPrimaryKey = key == "PRI"
		c.IsAutoIncr = strings.Contains(strings.ToLower(extra), "auto_increment")
		if def.Valid {
			c.Default = &def.String
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Session) mysqlIndexes(ctx context.Context, schema, table string) ([]IndexInfo, error) {
	const q = `
SELECT index_name, non_unique, column_name, seq_in_index
FROM information_schema.statistics
WHERE table_name = ?
  AND table_schema = COALESCE(NULLIF(?, ''), DATABASE())
ORDER BY index_name, seq_in_index`

	rows, err := s.db.QueryContext(ctx, q, table, schema)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var collected []indexRow
	for rows.Next() {
		var (
			r         indexRow
			nonUnique int
			seq       int
		)
		if err := rows.Scan(&r.name, &nonUnique, &r.column, &seq); err != nil {
			return nil, err
		}
		r.unique = nonUnique == 0
		// MySQL names the primary key index PRIMARY, always and only.
		r.primary = r.name == "PRIMARY"
		collected = append(collected, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return groupIndexRows(collected), nil
}

func (s *Session) mysqlForeignKeys(ctx context.Context, schema, table string) ([]ForeignKeyInfo, error) {
	const q = `
SELECT k.constraint_name,
       k.column_name,
       k.referenced_table_schema,
       k.referenced_table_name,
       k.referenced_column_name,
       COALESCE(r.delete_rule, ''),
       COALESCE(r.update_rule, '')
FROM information_schema.key_column_usage k
LEFT JOIN information_schema.referential_constraints r
       ON r.constraint_schema = k.constraint_schema
      AND r.constraint_name = k.constraint_name
WHERE k.table_name = ?
  AND k.table_schema = COALESCE(NULLIF(?, ''), DATABASE())
  AND k.referenced_table_name IS NOT NULL
ORDER BY k.constraint_name, k.ordinal_position`

	rows, err := s.db.QueryContext(ctx, q, table, schema)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var collected []fkRow
	for rows.Next() {
		var r fkRow
		if err := rows.Scan(&r.name, &r.column, &r.refSchema, &r.refTable,
			&r.refColumn, &r.onDelete, &r.onUpdate); err != nil {
			return nil, err
		}
		// The referenced schema is only worth showing when it differs.
		if r.refSchema == schema {
			r.refSchema = ""
		}
		collected = append(collected, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return groupForeignKeyRows(collected), nil
}

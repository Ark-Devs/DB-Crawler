package dbcore

import (
	"context"
	"database/sql"
	"strings"
)

// SQLite exposes its catalog through PRAGMA functions rather than an
// information schema. They take the table name as an argument, which means
// they can be parameterised properly instead of being string-concatenated —
// worth insisting on, because a table name arriving from a tapped tree node is
// still untrusted input.

func (s *Session) sqliteTables(ctx context.Context) ([]TableInfo, error) {
	const q = `
SELECT name, type
FROM sqlite_master
WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'
ORDER BY type, name`

	rows, err := s.db.QueryContext(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []TableInfo
	for rows.Next() {
		var t TableInfo
		if err := rows.Scan(&t.Name, &t.Type); err != nil {
			return nil, err
		}
		// SQLite keeps no row statistics, so there is no estimate to give.
		// The table screen offers an exact count on demand instead; on a file
		// that is local to the device, COUNT(*) is cheap enough to be honest.
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sortTables(out)
	return out, nil
}

func (s *Session) sqliteColumns(ctx context.Context, table string) ([]ColumnInfo, error) {
	// table_xinfo rather than table_info so that generated and hidden columns
	// appear; a column list that omits them does not match the table.
	const q = `SELECT cid, name, type, "notnull", dflt_value, pk FROM pragma_table_xinfo(?) ORDER BY cid`

	rows, err := s.db.QueryContext(ctx, q, table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []ColumnInfo
	var pkCount int
	for rows.Next() {
		var (
			c       ColumnInfo
			cid     int
			notNull int
			pk      int
			def     sql.NullString
		)
		if err := rows.Scan(&cid, &c.Name, &c.DataType, &notNull, &def, &pk); err != nil {
			return nil, err
		}
		c.Position = cid + 1
		c.Nullable = notNull == 0
		c.IsPrimaryKey = pk > 0
		if pk > 0 {
			pkCount++
		}
		if def.Valid {
			c.Default = &def.String
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// A single INTEGER PRIMARY KEY is an alias for the implicit rowid and
	// therefore auto-assigns, whether or not AUTOINCREMENT was written.
	if pkCount == 1 {
		for i := range out {
			if out[i].IsPrimaryKey && strings.EqualFold(strings.TrimSpace(out[i].DataType), "INTEGER") {
				out[i].IsAutoIncr = true
			}
		}
	}
	return out, nil
}

func (s *Session) sqliteIndexes(ctx context.Context, table string) ([]IndexInfo, error) {
	const q = `
SELECT il.name, il.origin = 'pk' AS is_pk, il."unique", ii.name
FROM pragma_index_list(?) AS il
JOIN pragma_index_info(il.name) AS ii
ORDER BY il.seq, ii.seqno`

	rows, err := s.db.QueryContext(ctx, q, table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var collected []indexRow
	for rows.Next() {
		var (
			r      indexRow
			isPK   int
			unique int
			column sql.NullString
		)
		if err := rows.Scan(&r.name, &isPK, &unique, &column); err != nil {
			return nil, err
		}
		r.primary = isPK == 1
		r.unique = unique == 1
		// An index over an expression reports a NULL column name.
		if column.Valid {
			r.column = column.String
		}
		collected = append(collected, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return groupIndexRows(collected), nil
}

func (s *Session) sqliteForeignKeys(ctx context.Context, table string) ([]ForeignKeyInfo, error) {
	const q = `SELECT id, seq, "table", "from", "to", on_delete, on_update FROM pragma_foreign_key_list(?) ORDER BY id, seq`

	rows, err := s.db.QueryContext(ctx, q, table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// SQLite identifies a foreign key by an integer id, not a name, so the
	// constraint gets a synthetic name built from the table it points at.
	var collected []fkRow
	for rows.Next() {
		var (
			r       fkRow
			id, seq int
			to      sql.NullString
		)
		if err := rows.Scan(&id, &seq, &r.refTable, &r.column, &to, &r.onDelete, &r.onUpdate); err != nil {
			return nil, err
		}
		r.name = "fk_" + table + "_" + itoa(id)
		// A NULL "to" means the key targets the referenced table's primary key
		// without naming it.
		if to.Valid {
			r.refColumn = to.String
		} else {
			r.refColumn = "rowid"
		}
		collected = append(collected, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return groupForeignKeyRows(collected), nil
}

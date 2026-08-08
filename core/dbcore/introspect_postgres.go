package dbcore

import (
	"context"
	"database/sql"
)

func (s *Session) postgresTables(ctx context.Context, schema string) ([]TableInfo, error) {
	// reltuples is the planner's estimate and is -1 on a table that has never
	// been analysed, which is reported as "unknown" rather than as zero rows.
	const q = `
SELECT n.nspname AS schema_name,
       c.relname AS table_name,
       CASE c.relkind
            WHEN 'r' THEN 'table'
            WHEN 'p' THEN 'table'
            WHEN 'v' THEN 'view'
            WHEN 'm' THEN 'materialized view'
            WHEN 'f' THEN 'foreign table'
            ELSE 'table'
       END AS object_type,
       CASE WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END AS row_estimate,
       COALESCE(obj_description(c.oid, 'pg_class'), '') AS comment
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p','v','m','f')
  AND ($1 = '' OR n.nspname = $1)
  AND n.nspname NOT LIKE 'pg\_%'
  AND n.nspname <> 'information_schema'
  AND has_table_privilege(c.oid, 'SELECT')
ORDER BY n.nspname, c.relname`

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
		if estimate.Valid {
			e := estimate.Int64
			t.RowEstimate = &e
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (s *Session) postgresColumns(ctx context.Context, schema, table string) ([]ColumnInfo, error) {
	// format_type renders the declared type exactly as psql \d would, including
	// precision and array notation, which beats reassembling it from
	// information_schema's separate length and precision columns.
	const q = `
SELECT a.attname,
       format_type(a.atttypid, a.atttypmod) AS data_type,
       NOT a.attnotnull AS nullable,
       pg_get_expr(d.adbin, d.adrelid) AS default_expr,
       a.attnum,
       COALESCE(col_description(a.attrelid, a.attnum), '') AS comment,
       COALESCE(pk.is_pk, false) AS is_pk,
       (a.attidentity <> '' OR pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval(%') AS is_auto
FROM pg_attribute a
JOIN pg_class c      ON c.oid = a.attrelid
JOIN pg_namespace n  ON n.oid = c.relnamespace
LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
LEFT JOIN LATERAL (
    SELECT true AS is_pk
    FROM pg_index i
    WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY (i.indkey)
    LIMIT 1
) pk ON true
WHERE c.relname = $1
  AND ($2 = '' OR n.nspname = $2)
  AND a.attnum > 0
  AND NOT a.attisdropped
ORDER BY a.attnum`

	rows, err := s.db.QueryContext(ctx, q, table, schema)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []ColumnInfo
	for rows.Next() {
		var c ColumnInfo
		var def sql.NullString
		if err := rows.Scan(&c.Name, &c.DataType, &c.Nullable, &def,
			&c.Position, &c.Comment, &c.IsPrimaryKey, &c.IsAutoIncr); err != nil {
			return nil, err
		}
		if def.Valid {
			c.Default = &def.String
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Session) postgresIndexes(ctx context.Context, schema, table string) ([]IndexInfo, error) {
	// The join on generate_subscripts walks indkey in declared order, which is
	// what keeps a composite index's columns in the order that determines
	// whether a query can use it.
	const q = `
SELECT ci.relname AS index_name,
       i.indisunique,
       i.indisprimary,
       a.attname
FROM pg_index i
JOIN pg_class c       ON c.oid = i.indrelid
JOIN pg_namespace n   ON n.oid = c.relnamespace
JOIN pg_class ci      ON ci.oid = i.indexrelid
JOIN generate_subscripts(i.indkey, 1) AS k(ord) ON true
JOIN pg_attribute a   ON a.attrelid = c.oid AND a.attnum = i.indkey[k.ord]
WHERE c.relname = $1 AND ($2 = '' OR n.nspname = $2)
ORDER BY ci.relname, k.ord`

	rows, err := s.db.QueryContext(ctx, q, table, schema)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var collected []indexRow
	for rows.Next() {
		var r indexRow
		if err := rows.Scan(&r.name, &r.unique, &r.primary, &r.column); err != nil {
			return nil, err
		}
		collected = append(collected, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return groupIndexRows(collected), nil
}

func (s *Session) postgresForeignKeys(ctx context.Context, schema, table string) ([]ForeignKeyInfo, error) {
	const q = `
SELECT con.conname,
       att.attname        AS column_name,
       rn.nspname         AS ref_schema,
       rc.relname         AS ref_table,
       ratt.attname       AS ref_column,
       CASE con.confdeltype WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT'
            WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' END,
       CASE con.confupdtype WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT'
            WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' END
FROM pg_constraint con
JOIN pg_class c      ON c.oid = con.conrelid
JOIN pg_namespace n  ON n.oid = c.relnamespace
JOIN pg_class rc     ON rc.oid = con.confrelid
JOIN pg_namespace rn ON rn.oid = rc.relnamespace
JOIN generate_subscripts(con.conkey, 1) AS k(ord) ON true
JOIN pg_attribute att  ON att.attrelid = con.conrelid  AND att.attnum = con.conkey[k.ord]
JOIN pg_attribute ratt ON ratt.attrelid = con.confrelid AND ratt.attnum = con.confkey[k.ord]
WHERE con.contype = 'f'
  AND c.relname = $1 AND ($2 = '' OR n.nspname = $2)
ORDER BY con.conname, k.ord`

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
		collected = append(collected, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return groupForeignKeyRows(collected), nil
}

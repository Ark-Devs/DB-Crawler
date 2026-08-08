package dbcore

import (
	"context"
	"database/sql"
)

// SQL Server introspection reads sys.* rather than INFORMATION_SCHEMA.
//
// INFORMATION_SCHEMA is portable but lossy here: it cannot report row
// estimates, it does not distinguish a clustered index from a heap, and it
// silently omits objects the login cannot see in a way that looks like the
// objects do not exist. sys.* answers all three honestly.

func (s *Session) sqlServerTables(ctx context.Context, schema string) ([]TableInfo, error) {
	const q = `
SELECT sch.name AS [schema],
       o.name    AS [name],
       CASE o.type WHEN 'U' THEN 'table' ELSE 'view' END AS [type],
       CAST(ISNULL(p.rows, -1) AS BIGINT) AS row_estimate,
       CAST(ISNULL(ep.value, '') AS NVARCHAR(MAX)) AS comment
FROM sys.objects o
JOIN sys.schemas sch ON sch.schema_id = o.schema_id
OUTER APPLY (
    SELECT TOP 1 pt.rows
    FROM sys.partitions pt
    WHERE pt.object_id = o.object_id AND pt.index_id IN (0, 1)
    ORDER BY pt.rows DESC
) p
OUTER APPLY (
    SELECT TOP 1 x.value
    FROM sys.extended_properties x
    WHERE x.major_id = o.object_id AND x.minor_id = 0 AND x.name = 'MS_Description'
) ep
WHERE o.type IN ('U', 'V')
  AND (@p1 = '' OR sch.name = @p1)
ORDER BY sch.name, o.name`

	rows, err := s.db.QueryContext(ctx, q, schema)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []TableInfo
	for rows.Next() {
		var t TableInfo
		var estimate int64
		if err := rows.Scan(&t.Schema, &t.Name, &t.Type, &estimate, &t.Comment); err != nil {
			return nil, err
		}
		if estimate >= 0 {
			e := estimate
			t.RowEstimate = &e
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (s *Session) sqlServerColumns(ctx context.Context, schema, table string) ([]ColumnInfo, error) {
	const q = `
SELECT c.name,
       ty.name AS type_name,
       c.max_length, c.precision, c.scale,
       c.is_nullable,
       c.is_identity,
       dc.definition,
       c.column_id,
       CAST(ISNULL(ep.value, '') AS NVARCHAR(MAX)) AS comment,
       CAST(CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END AS BIT) AS is_pk
FROM sys.columns c
JOIN sys.objects o  ON o.object_id = c.object_id
JOIN sys.schemas sch ON sch.schema_id = o.schema_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id
OUTER APPLY (
    SELECT TOP 1 x.value
    FROM sys.extended_properties x
    WHERE x.major_id = c.object_id AND x.minor_id = c.column_id AND x.name = 'MS_Description'
) ep
LEFT JOIN (
    SELECT ic.object_id, ic.column_id
    FROM sys.index_columns ic
    JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
    WHERE i.is_primary_key = 1
) pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
WHERE o.name = @p1 AND (@p2 = '' OR sch.name = @p2)
ORDER BY c.column_id`

	rows, err := s.db.QueryContext(ctx, q, table, schema)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []ColumnInfo
	for rows.Next() {
		var (
			c         ColumnInfo
			typeName  string
			maxLen    int
			precision int
			scale     int
			def       sql.NullString
		)
		if err := rows.Scan(&c.Name, &typeName, &maxLen, &precision, &scale,
			&c.Nullable, &c.IsAutoIncr, &def, &c.Position, &c.Comment, &c.IsPrimaryKey); err != nil {
			return nil, err
		}
		c.DataType = sqlServerTypeName(typeName, maxLen, precision, scale)
		if def.Valid {
			c.Default = &def.String
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// sqlServerTypeName reassembles the declared type from the catalog's parts.
//
// max_length is in bytes, so the character count for an N-type is half of it,
// and -1 is how the catalog spells MAX. Showing "nvarchar(-1)" or "nvarchar(400)"
// for what the user declared as nvarchar(200) would make the column list wrong
// in exactly the way that erodes trust in the rest of the screen.
func sqlServerTypeName(name string, maxLen, precision, scale int) string {
	switch name {
	case "nvarchar", "nchar":
		if maxLen == -1 {
			return name + "(max)"
		}
		return name + "(" + itoa(maxLen/2) + ")"
	case "varchar", "char", "varbinary", "binary":
		if maxLen == -1 {
			return name + "(max)"
		}
		return name + "(" + itoa(maxLen) + ")"
	case "decimal", "numeric":
		return name + "(" + itoa(precision) + "," + itoa(scale) + ")"
	case "datetime2", "datetimeoffset", "time":
		if scale != 7 {
			return name + "(" + itoa(scale) + ")"
		}
	case "float":
		if precision != 53 {
			return name + "(" + itoa(precision) + ")"
		}
	}
	return name
}

func (s *Session) sqlServerIndexes(ctx context.Context, schema, table string) ([]IndexInfo, error) {
	const q = `
SELECT i.name, i.is_unique, i.is_primary_key, c.name AS column_name
FROM sys.indexes i
JOIN sys.objects o   ON o.object_id = i.object_id
JOIN sys.schemas sch ON sch.schema_id = o.schema_id
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE o.name = @p1 AND (@p2 = '' OR sch.name = @p2)
  AND i.type > 0 AND i.name IS NOT NULL
  AND ic.is_included_column = 0
ORDER BY i.name, ic.key_ordinal`

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

func (s *Session) sqlServerForeignKeys(ctx context.Context, schema, table string) ([]ForeignKeyInfo, error) {
	const q = `
SELECT fk.name,
       pc.name  AS column_name,
       rsch.name AS ref_schema,
       ro.name   AS ref_table,
       rc.name   AS ref_column,
       fk.delete_referential_action_desc,
       fk.update_referential_action_desc
FROM sys.foreign_keys fk
JOIN sys.objects o    ON o.object_id = fk.parent_object_id
JOIN sys.schemas sch  ON sch.schema_id = o.schema_id
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN sys.columns pc   ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
JOIN sys.objects ro   ON ro.object_id = fk.referenced_object_id
JOIN sys.schemas rsch ON rsch.schema_id = ro.schema_id
JOIN sys.columns rc   ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
WHERE o.name = @p1 AND (@p2 = '' OR sch.name = @p2)
ORDER BY fk.name, fkc.constraint_column_id`

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

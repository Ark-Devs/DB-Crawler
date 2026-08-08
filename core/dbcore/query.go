package dbcore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Column describes one column of a result set.
type Column struct {
	Name     string    `json:"name"`
	Kind     ValueKind `json:"kind"`
	DBType   string    `json:"dbType,omitempty"`
	Nullable *bool     `json:"nullable,omitempty"`
}

// Result is what one statement produced. A statement yields either a grid of
// rows or a count of rows affected, never both, and Kind says which.
type Result struct {
	Kind      string        `json:"kind"` // "rows" | "affected"
	Statement string        `json:"statement"`
	Class     StatementKind `json:"class"`

	Columns []Column `json:"columns,omitempty"`
	Rows    [][]Cell `json:"rows,omitempty"`

	// Truncated says the row cap was hit and there is more behind it. Without
	// this the user cannot tell a query that returned exactly the cap from one
	// that returned a million rows, which is the difference between a complete
	// answer and a misleading one.
	Truncated bool `json:"truncated"`

	RowsAffected *int64 `json:"rowsAffected,omitempty"`
	LastInsertID *int64 `json:"lastInsertId,omitempty"`

	ElapsedMs int64 `json:"elapsedMs"`

	// Error is set when this statement failed. Earlier statements in the same
	// batch keep their results: telling the user statements 1 and 2 succeeded
	// before 3 failed is the difference between a recoverable mistake and a
	// mystery about what state the database is now in.
	Error string `json:"error,omitempty"`
}

// QueryOptions bounds one execution.
type QueryOptions struct {
	// MaxRows caps how many rows are read back. Zero means the default cap;
	// a negative value means no cap, which the app only ever passes for an
	// export the user explicitly asked for.
	MaxRows int

	TimeoutSeconds int

	// OpID lets the app cancel this execution while it is running.
	OpID string

	// StopOnError halts a multi-statement batch at the first failure. It
	// defaults on, because running the rest of a migration after step two
	// failed is rarely what anyone wants.
	StopOnError bool
}

const defaultMaxRows = 500

func (o QueryOptions) maxRows() int {
	if o.MaxRows == 0 {
		return defaultMaxRows
	}
	return o.MaxRows
}

func (o QueryOptions) timeout() time.Duration {
	if o.TimeoutSeconds <= 0 {
		return 60 * time.Second
	}
	return time.Duration(o.TimeoutSeconds) * time.Second
}

// Execute runs every statement in the buffer and returns one Result each.
func (s *Session) Execute(ctx context.Context, sqlText string, args []any, opts QueryOptions) ([]Result, error) {
	statements := SplitStatements(s.Engine, sqlText)
	if len(statements) == 0 {
		return nil, errors.New("nothing to run")
	}

	// Parameters only make sense for a single statement — there is no sane way
	// to distribute one argument list across a batch, and guessing would bind
	// the wrong value to the wrong statement.
	if len(args) > 0 && len(statements) > 1 {
		return nil, errors.New("parameters can only be used with a single statement")
	}

	for _, st := range statements {
		if err := s.guard(st.Text); err != nil {
			return nil, err
		}
	}

	opCtx, cancel := context.WithTimeout(ctx, opts.timeout())
	defer cancel()
	if opts.OpID != "" {
		s.track(opts.OpID, cancel)
		defer s.untrack(opts.OpID)
	}

	results := make([]Result, 0, len(statements))
	for _, st := range statements {
		res := s.runOne(opCtx, st.Text, args, opts)
		results = append(results, res)
		if res.Error != "" && opts.StopOnError {
			break
		}
	}
	return results, nil
}

// runOne executes a single statement, never returning an error: a statement
// failure is data the app renders next to the statement that caused it.
func (s *Session) runOne(ctx context.Context, statement string, args []any, opts QueryOptions) Result {
	start := time.Now()
	class := Classify(statement)
	res := Result{Statement: statement, Class: class}

	// Anything that can return rows goes through Query. Deciding by keyword
	// rather than by trying both matters because `INSERT … RETURNING` and
	// `UPDATE … OUTPUT` do return rows, and Exec would silently discard them.
	if class == KindSelect || returnsRows(statement) {
		rows, err := s.db.QueryContext(ctx, statement, args...)
		if err != nil {
			res.Kind = "rows"
			res.Error = describeError(err, ctx)
			res.ElapsedMs = time.Since(start).Milliseconds()
			return res
		}
		defer rows.Close()

		cols, data, truncated, err := readRows(rows, opts.maxRows())
		res.Kind = "rows"
		res.Columns = cols
		res.Rows = data
		res.Truncated = truncated
		if err != nil {
			res.Error = describeError(err, ctx)
		}
		res.ElapsedMs = time.Since(start).Milliseconds()
		return res
	}

	out, err := s.db.ExecContext(ctx, statement, args...)
	res.Kind = "affected"
	if err != nil {
		res.Error = describeError(err, ctx)
		res.ElapsedMs = time.Since(start).Milliseconds()
		return res
	}
	// Not every driver supports these, and an unsupported one returns an
	// error rather than a zero. Reporting "0 rows affected" when the driver
	// simply declined to say would be a lie, so the field is left absent.
	if n, err := out.RowsAffected(); err == nil {
		res.RowsAffected = &n
	}
	if id, err := out.LastInsertId(); err == nil && id != 0 {
		res.LastInsertID = &id
	}
	res.ElapsedMs = time.Since(start).Milliseconds()
	return res
}

// returnsRows spots the write statements that also produce a result set.
func returnsRows(statement string) bool {
	upper := upperFold(statement)
	switch firstKeyword(statement) {
	case "INSERT", "UPDATE", "DELETE", "MERGE":
		return containsWord(upper, "RETURNING") || containsWord(upper, "OUTPUT")
	case "WITH":
		return Classify(statement) == KindSelect ||
			containsWord(upper, "RETURNING") || containsWord(upper, "OUTPUT")
	case "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "PRAGMA", "CALL", "EXEC", "EXECUTE":
		return true
	}
	return false
}

// readRows drains a result set up to the cap, reporting whether more remained.
//
// It reads one row past the cap to distinguish "exactly cap rows" from "more
// than cap rows", then stops. Closing the cursor early is what tells the
// driver to stop pulling rows across the network.
func readRows(rows *sql.Rows, maxRows int) ([]Column, [][]Cell, bool, error) {
	names, err := rows.Columns()
	if err != nil {
		return nil, nil, false, err
	}
	types, _ := rows.ColumnTypes()

	cols := make([]Column, len(names))
	for i, name := range names {
		cols[i] = Column{Name: name, Kind: KindUnknown}
		if i < len(types) && types[i] != nil {
			dbType := types[i].DatabaseTypeName()
			cols[i].DBType = dbType
			cols[i].Kind = kindForDatabaseType(dbType)
			if nullable, ok := types[i].Nullable(); ok {
				cols[i].Nullable = &nullable
			}
		}
	}

	// Duplicate column names are legal in SQL and common in a join written in
	// a hurry. Left as-is they collide in any map-shaped consumer, so they are
	// disambiguated here where the original order is still known.
	deduplicateNames(cols)

	var out [][]Cell
	truncated := false
	scan := make([]any, len(names))
	ptrs := make([]any, len(names))
	for i := range scan {
		ptrs[i] = &scan[i]
	}

	for rows.Next() {
		if maxRows >= 0 && len(out) >= maxRows {
			truncated = true
			break
		}
		if err := rows.Scan(ptrs...); err != nil {
			return cols, out, truncated, err
		}
		row := make([]Cell, len(names))
		for i, v := range scan {
			value, kind := convertValue(v, cols[i].Kind)
			row[i] = value
			// A column the driver could not name a type for is classified from
			// the first non-NULL value that arrives.
			if cols[i].Kind == KindUnknown && value != nil {
				cols[i].Kind = kind
			}
		}
		out = append(out, row)
	}
	if err := rows.Err(); err != nil {
		return cols, out, truncated, err
	}
	return cols, out, truncated, nil
}

func deduplicateNames(cols []Column) {
	seen := make(map[string]int, len(cols))
	for i := range cols {
		name := cols[i].Name
		if name == "" {
			name = fmt.Sprintf("column%d", i+1)
			cols[i].Name = name
		}
		if n, ok := seen[name]; ok {
			seen[name] = n + 1
			cols[i].Name = fmt.Sprintf("%s (%d)", name, n+1)
		} else {
			seen[name] = 1
		}
	}
}

// describeError turns a driver error into something worth showing on a phone.
//
// A cancelled context surfaces from the driver as a generic failure, which
// would tell the user their query broke when in fact they stopped it. The
// distinction matters most on mobile, where the app is also cancelling queries
// on its own when the OS suspends it.
func describeError(err error, ctx context.Context) string {
	switch {
	case errors.Is(err, context.Canceled) || errors.Is(ctx.Err(), context.Canceled):
		return "cancelled"
	case errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded):
		return "timed out"
	}
	return err.Error()
}

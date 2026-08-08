package dbcore

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// These tests run against a real SQLite database rather than a mock.
//
// A mock would only prove the code agrees with itself. The bugs worth catching
// here — a driver returning bytes where a string was expected, a PRAGMA that
// reports columns in the wrong order, a row cap that silently drops data —
// only appear against a real engine. SQLite is the one that needs no server,
// so it is the one that can run in CI on every commit.

func newTestDB(t *testing.T) (*Manager, *Session) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	m := NewManager()
	t.Cleanup(m.CloseAll)

	s, err := m.Open(context.Background(), Config{Engine: SQLite, File: path})
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	seed := `
CREATE TABLE customers (
    id    INTEGER PRIMARY KEY,
    name  TEXT NOT NULL,
    email TEXT UNIQUE
);
CREATE TABLE orders (
    id          INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    reference   TEXT NOT NULL,
    total       NUMERIC(19,4) NOT NULL DEFAULT 0,
    -- SQLite gives a NUMERIC column REAL affinity, so it rounds a wide decimal
    -- on the way in, before any client sees it. SQL Server and MySQL do not:
    -- they store DECIMAL exactly and hand it back as text bytes. This column
    -- reproduces that shape so the read path can be tested on SQLite.
    total_exact TEXT,
    placed_at   TEXT,
    notes       TEXT
);
CREATE INDEX ix_orders_customer ON orders(customer_id, reference);
INSERT INTO customers (id, name, email) VALUES
    (1, 'Nimal Perera', 'nimal@example.lk'),
    (2, 'Kumari Silva', NULL);
INSERT INTO orders (id, customer_id, reference, total, total_exact, placed_at, notes) VALUES
    (1, 1, 'SC-ABCDEF', 1250.75, '12345678901234.5678', '2026-08-01T10:00:00Z', NULL),
    (2, 1, 'SC-GHIJKL', 250.50, '250.5000', '2026-08-02T11:30:00Z', ''),
    (3, 2, 'SC-MNOPQR', 0, '0.0000', NULL, 'rush');
`
	if _, err := s.Execute(context.Background(), seed, nil, QueryOptions{StopOnError: true}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	return m, s
}

func TestExecuteSelect(t *testing.T) {
	_, s := newTestDB(t)
	results, err := s.Execute(context.Background(),
		"SELECT id, name, email FROM customers ORDER BY id", nil, QueryOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 1 {
		t.Fatalf("expected 1 result, got %d", len(results))
	}
	r := results[0]
	if r.Error != "" {
		t.Fatalf("query failed: %s", r.Error)
	}
	if r.Kind != "rows" {
		t.Errorf("kind = %q, want rows", r.Kind)
	}
	if len(r.Rows) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(r.Rows))
	}
	if got := deref(r.Rows[0][1]); got != "Nimal Perera" {
		t.Errorf("first name = %q", got)
	}
	// The customer with no email must come back as NULL, not "".
	if r.Rows[1][2] != nil {
		t.Errorf("missing email = %q, want NULL", deref(r.Rows[1][2]))
	}
	if len(r.Columns) != 3 || r.Columns[0].Name != "id" {
		t.Errorf("columns = %+v", r.Columns)
	}
}

func TestExecutePreservesDecimalPrecision(t *testing.T) {
	_, s := newTestDB(t)
	// The bug this guards against is a price losing its last digits between
	// the database and the screen. It is silent, it looks plausible, and it is
	// wrong. Passing a wide decimal through a float64 is how it happens.
	results, err := s.Execute(context.Background(),
		"SELECT total_exact FROM orders WHERE id = 1", nil, QueryOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if got := deref(results[0].Rows[0][0]); got != "12345678901234.5678" {
		t.Errorf("total = %q, want 12345678901234.5678 exactly", got)
	}
}

func TestExecuteFloatsAreReadable(t *testing.T) {
	_, s := newTestDB(t)
	results, err := s.Execute(context.Background(),
		"SELECT total FROM orders ORDER BY id", nil, QueryOptions{})
	if err != nil {
		t.Fatal(err)
	}
	// A money column must not arrive in scientific notation, and a whole
	// number must not grow a decimal tail.
	want := []string{"1250.75", "250.5", "0"}
	for i, w := range want {
		if got := deref(results[0].Rows[i][0]); got != w {
			t.Errorf("row %d total = %q, want %q", i, got, w)
		}
	}
}

func TestExecuteRowCapReportsTruncation(t *testing.T) {
	_, s := newTestDB(t)
	results, err := s.Execute(context.Background(),
		"SELECT id FROM orders ORDER BY id", nil, QueryOptions{MaxRows: 2})
	if err != nil {
		t.Fatal(err)
	}
	r := results[0]
	if len(r.Rows) != 2 {
		t.Fatalf("expected the cap to hold at 2 rows, got %d", len(r.Rows))
	}
	if !r.Truncated {
		t.Error("Truncated = false; the user cannot tell this answer is partial")
	}

	// A result that exactly fills the cap with nothing behind it must not be
	// flagged as truncated, or every complete answer looks incomplete.
	exact, err := s.Execute(context.Background(),
		"SELECT id FROM orders ORDER BY id", nil, QueryOptions{MaxRows: 3})
	if err != nil {
		t.Fatal(err)
	}
	if exact[0].Truncated {
		t.Error("Truncated = true for a complete result set")
	}
}

func TestExecuteMultipleStatements(t *testing.T) {
	_, s := newTestDB(t)
	results, err := s.Execute(context.Background(),
		"SELECT 1 AS a; SELECT 2 AS b; SELECT 3 AS c", nil, QueryOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 3 {
		t.Fatalf("expected 3 results, got %d", len(results))
	}
	for i, want := range []string{"1", "2", "3"} {
		if got := deref(results[i].Rows[0][0]); got != want {
			t.Errorf("statement %d returned %q, want %q", i+1, got, want)
		}
	}
}

func TestExecuteStopsOnErrorButKeepsEarlierResults(t *testing.T) {
	_, s := newTestDB(t)
	results, err := s.Execute(context.Background(),
		"SELECT 1; SELECT * FROM no_such_table; SELECT 3", nil,
		QueryOptions{StopOnError: true})
	if err != nil {
		t.Fatal(err)
	}
	// Knowing statement 1 ran and statement 3 did not is the difference
	// between a recoverable mistake and a mystery about database state.
	if len(results) != 2 {
		t.Fatalf("expected 2 results (one good, one failed), got %d", len(results))
	}
	if results[0].Error != "" {
		t.Errorf("first statement should have succeeded, got %q", results[0].Error)
	}
	if results[1].Error == "" {
		t.Error("second statement should have failed")
	}
}

func TestExecuteAffectedRows(t *testing.T) {
	_, s := newTestDB(t)
	results, err := s.Execute(context.Background(),
		"UPDATE orders SET notes = 'seen' WHERE customer_id = 1", nil, QueryOptions{})
	if err != nil {
		t.Fatal(err)
	}
	r := results[0]
	if r.Kind != "affected" {
		t.Errorf("kind = %q, want affected", r.Kind)
	}
	if r.RowsAffected == nil || *r.RowsAffected != 2 {
		t.Errorf("rowsAffected = %v, want 2", r.RowsAffected)
	}
}

func TestExecuteWithParameters(t *testing.T) {
	_, s := newTestDB(t)
	results, err := s.Execute(context.Background(),
		"SELECT reference FROM orders WHERE customer_id = ?", []any{2}, QueryOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if len(results[0].Rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(results[0].Rows))
	}
	if got := deref(results[0].Rows[0][0]); got != "SC-MNOPQR" {
		t.Errorf("reference = %q", got)
	}
}

func TestReadOnlyGuard(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ro.db")
	m := NewManager()
	t.Cleanup(m.CloseAll)

	// Seed with a writable session, then reopen read-only.
	writable, err := m.Open(context.Background(), Config{Engine: SQLite, File: path})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writable.Execute(context.Background(),
		"CREATE TABLE t (id INTEGER); INSERT INTO t VALUES (1)", nil, QueryOptions{}); err != nil {
		t.Fatal(err)
	}
	m.Close(writable.ID)

	s, err := m.Open(context.Background(), Config{Engine: SQLite, File: path, ReadOnly: true})
	if err != nil {
		t.Fatal(err)
	}

	if _, err := s.Execute(context.Background(), "SELECT * FROM t", nil, QueryOptions{}); err != nil {
		t.Errorf("read-only connection refused a SELECT: %v", err)
	}

	for _, sql := range []string{
		"DELETE FROM t",
		"UPDATE t SET id = 2",
		"DROP TABLE t",
		"WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x",
	} {
		if _, err := s.Execute(context.Background(), sql, nil, QueryOptions{}); err == nil {
			t.Errorf("read-only connection allowed %q", sql)
		}
	}

	// A batch is refused whole if any statement in it writes, rather than
	// running the reads and stopping at the write.
	if _, err := s.Execute(context.Background(), "SELECT 1; DELETE FROM t", nil, QueryOptions{}); err == nil {
		t.Error("read-only connection allowed a batch containing a write")
	}
	var count int
	if err := s.db.QueryRow("SELECT COUNT(*) FROM t").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Errorf("row count = %d, want 1 — the read-only connection wrote", count)
	}
}

func TestIntrospection(t *testing.T) {
	_, s := newTestDB(t)
	ctx := context.Background()

	tables, err := s.Tables(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	found := map[string]bool{}
	for _, tbl := range tables {
		found[tbl.Name] = true
	}
	if !found["customers"] || !found["orders"] {
		t.Fatalf("tables = %+v, want customers and orders", tables)
	}

	detail, err := s.Table(ctx, "", "orders")
	if err != nil {
		t.Fatal(err)
	}

	if len(detail.Columns) != 7 {
		t.Errorf("expected 7 columns, got %d", len(detail.Columns))
	}
	// Column order is the declared order; a browser that shuffles it is
	// showing a different table than the one the user wrote.
	wantOrder := []string{"id", "customer_id", "reference", "total", "total_exact", "placed_at", "notes"}
	for i, want := range wantOrder {
		if i >= len(detail.Columns) || detail.Columns[i].Name != want {
			t.Errorf("column %d = %q, want %q", i, detail.Columns[i].Name, want)
		}
	}

	byName := map[string]ColumnInfo{}
	for _, c := range detail.Columns {
		byName[c.Name] = c
	}
	if !byName["id"].IsPrimaryKey {
		t.Error("id should be the primary key")
	}
	if !byName["id"].IsAutoIncr {
		t.Error("a lone INTEGER PRIMARY KEY auto-assigns and should say so")
	}
	if byName["customer_id"].Nullable {
		t.Error("customer_id is NOT NULL")
	}
	if !byName["notes"].Nullable {
		t.Error("notes is nullable")
	}
	if byName["total"].Default == nil || !strings.Contains(*byName["total"].Default, "0") {
		t.Errorf("total default = %v, want 0", byName["total"].Default)
	}

	var composite *IndexInfo
	for i := range detail.Indexes {
		if detail.Indexes[i].Name == "ix_orders_customer" {
			composite = &detail.Indexes[i]
		}
	}
	if composite == nil {
		t.Fatalf("index ix_orders_customer missing from %+v", detail.Indexes)
	}
	// Composite index column order decides whether a query can use the index,
	// so reporting it out of order is worse than not reporting it.
	if len(composite.Columns) != 2 || composite.Columns[0] != "customer_id" || composite.Columns[1] != "reference" {
		t.Errorf("index columns = %v, want [customer_id reference]", composite.Columns)
	}

	if len(detail.ForeignKeys) != 1 {
		t.Fatalf("expected 1 foreign key, got %+v", detail.ForeignKeys)
	}
	fk := detail.ForeignKeys[0]
	if fk.RefTable != "customers" || len(fk.Columns) != 1 || fk.Columns[0] != "customer_id" {
		t.Errorf("foreign key = %+v", fk)
	}

	if !strings.Contains(detail.DDL, "CREATE TABLE") || !strings.Contains(detail.DDL, `"reference"`) {
		t.Errorf("DDL looks wrong:\n%s", detail.DDL)
	}
}

func TestPreviewSQL(t *testing.T) {
	_, s := newTestDB(t)
	got := s.PreviewSQL("", "orders", 10)
	if got != `SELECT * FROM "orders" LIMIT 10` {
		t.Errorf("preview = %q", got)
	}
	// The preview must be runnable as-is — that is the whole point of the app
	// generating it rather than the user typing it.
	if _, err := s.Execute(context.Background(), got, nil, QueryOptions{}); err != nil {
		t.Errorf("generated preview did not run: %v", err)
	}
	count := s.CountSQL("", "orders")
	results, err := s.Execute(context.Background(), count, nil, QueryOptions{})
	if err != nil {
		t.Fatalf("generated count did not run: %v", err)
	}
	if got := deref(results[0].Rows[0][0]); got != "3" {
		t.Errorf("count = %q, want 3", got)
	}
}

func TestCancel(t *testing.T) {
	_, s := newTestDB(t)
	// A recursive CTE that never terminates is the portable way to make a
	// query that has to be cancelled rather than waited out.
	const runaway = `
WITH RECURSIVE forever(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM forever
)
SELECT COUNT(*) FROM forever`

	done := make(chan []Result, 1)
	go func() {
		results, _ := s.Execute(context.Background(), runaway, nil,
			QueryOptions{OpID: "op-1", TimeoutSeconds: 30})
		done <- results
	}()

	// Wait for the query to actually be registered before cancelling it,
	// otherwise the test races the goroutine and cancels nothing.
	waitFor(t, func() bool { return s.runningCount() > 0 })

	if !s.Cancel("op-1") {
		t.Fatal("Cancel reported no such operation")
	}

	results := <-done
	if len(results) != 1 {
		t.Fatalf("expected 1 result, got %d", len(results))
	}
	// A cancelled query must say it was cancelled, not that it broke — the
	// user pressed the button and should see that, not an error report.
	if results[0].Error != "cancelled" {
		t.Errorf("error = %q, want %q", results[0].Error, "cancelled")
	}
}

func TestClosedSessionIsReported(t *testing.T) {
	m, s := newTestDB(t)
	if err := m.Close(s.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Get(s.ID); err == nil {
		t.Error("Get on a closed session should fail")
	}
	// Closing twice is what happens when the disconnect button races the
	// app's lifecycle handler, and must not surface as an error.
	if err := m.Close(s.ID); err != nil {
		t.Errorf("closing an already-closed session errored: %v", err)
	}
}

// --- protocol-level tests -------------------------------------------------

func handle(t *testing.T, m *Manager, req map[string]any) Response {
	t.Helper()
	raw, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	var resp Response
	if err := json.Unmarshal(m.Handle(context.Background(), raw), &resp); err != nil {
		t.Fatalf("decoding response: %v", err)
	}
	return resp
}

func TestProtocolRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "proto.db")
	m := NewManager()
	t.Cleanup(m.CloseAll)

	open := handle(t, m, map[string]any{
		"op":     "openConnection",
		"id":     "req-1",
		"config": Config{Engine: SQLite, File: path},
	})
	if !open.OK {
		t.Fatalf("open failed: %+v", open.Error)
	}
	// The request id must come back so the app can match responses to
	// requests without depending on ordering.
	if open.ID != "req-1" {
		t.Errorf("response id = %q, want req-1", open.ID)
	}
	var opened struct {
		SessionID string `json:"sessionId"`
	}
	if err := json.Unmarshal(open.Data, &opened); err != nil {
		t.Fatal(err)
	}

	exec := handle(t, m, map[string]any{
		"op":        "execute",
		"sessionId": opened.SessionID,
		"sql":       "CREATE TABLE t (id INTEGER, label TEXT); INSERT INTO t VALUES (1, 'one'); SELECT * FROM t",
	})
	if !exec.OK {
		t.Fatalf("execute failed: %+v", exec.Error)
	}
	var payload struct {
		Results []Result `json:"results"`
	}
	if err := json.Unmarshal(exec.Data, &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Results) != 3 {
		t.Fatalf("expected 3 results, got %d", len(payload.Results))
	}
	last := payload.Results[2]
	if len(last.Rows) != 1 || deref(last.Rows[0][1]) != "one" {
		t.Errorf("final SELECT returned %+v", last.Rows)
	}
}

func TestProtocolErrorCodes(t *testing.T) {
	m := NewManager()
	t.Cleanup(m.CloseAll)

	tests := []struct {
		name string
		req  map[string]any
		want string
	}{
		{
			name: "unknown operation",
			req:  map[string]any{"op": "teleport"},
			want: CodeUnknownOp,
		},
		{
			name: "missing session",
			req:  map[string]any{"op": "execute", "sessionId": "conn-999", "sql": "SELECT 1"},
			want: CodeNoSession,
		},
		{
			name: "config required",
			req:  map[string]any{"op": "openConnection"},
			want: CodeBadRequest,
		},
		{
			name: "unreachable database",
			req: map[string]any{"op": "openConnection", "config": Config{
				Engine: PostgreSQL, Host: "127.0.0.1", Port: 1, Database: "d",
				User: "u", ConnectTimeoutSeconds: 2,
			}},
			want: CodeConnect,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			resp := handle(t, m, tc.req)
			if resp.OK {
				t.Fatalf("expected failure, got %s", resp.Data)
			}
			if resp.Error.Code != tc.want {
				t.Errorf("code = %q, want %q (message: %s)", resp.Error.Code, tc.want, resp.Error.Message)
			}
		})
	}
}

func TestProtocolMalformedJSON(t *testing.T) {
	m := NewManager()
	t.Cleanup(m.CloseAll)
	var resp Response
	if err := json.Unmarshal(m.Handle(context.Background(), []byte("{not json")), &resp); err != nil {
		t.Fatalf("the core returned something that is not JSON: %v", err)
	}
	if resp.OK || resp.Error.Code != CodeBadRequest {
		t.Errorf("resp = %+v, want a bad_request failure", resp)
	}
}

func TestProtocolValidateConfigRedactsPassword(t *testing.T) {
	m := NewManager()
	t.Cleanup(m.CloseAll)
	resp := handle(t, m, map[string]any{
		"op": "validateConfig",
		"config": Config{Engine: PostgreSQL, Host: "h", Database: "d",
			User: "u", Password: "hunter2"},
	})
	if !resp.OK {
		t.Fatalf("validate failed: %+v", resp.Error)
	}
	// This DSN is shown on screen and copied into bug reports.
	if strings.Contains(string(resp.Data), "hunter2") {
		t.Errorf("validateConfig leaked the password: %s", resp.Data)
	}
}

func TestProtocolSplitStatementsNeedsNoConnection(t *testing.T) {
	m := NewManager()
	t.Cleanup(m.CloseAll)
	resp := handle(t, m, map[string]any{
		"op":     "splitStatements",
		"engine": "postgres",
		"sql":    "SELECT 1; DELETE FROM t",
	})
	if !resp.OK {
		t.Fatalf("splitStatements failed: %+v", resp.Error)
	}
	var payload struct {
		Statements []Statement     `json:"statements"`
		Kinds      []StatementKind `json:"kinds"`
		ReadOnly   []bool          `json:"readOnly"`
	}
	if err := json.Unmarshal(resp.Data, &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Statements) != 2 {
		t.Fatalf("expected 2 statements, got %d", len(payload.Statements))
	}
	if payload.Kinds[0] != KindSelect || payload.Kinds[1] != KindDML {
		t.Errorf("kinds = %v", payload.Kinds)
	}
	if !payload.ReadOnly[0] || payload.ReadOnly[1] {
		t.Errorf("readOnly = %v, want [true false]", payload.ReadOnly)
	}
}

// waitFor polls until cond holds, failing the test rather than hanging
// forever if it never does.
func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatal("timed out waiting for condition")
}

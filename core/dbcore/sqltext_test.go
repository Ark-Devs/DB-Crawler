package dbcore

import (
	"testing"
)

func statementTexts(in []Statement) []string {
	out := make([]string, len(in))
	for i, s := range in {
		out[i] = s.Text
	}
	return out
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestSplitStatements(t *testing.T) {
	tests := []struct {
		name   string
		engine Engine
		sql    string
		want   []string
	}{
		{
			name:   "plain separation",
			engine: PostgreSQL,
			sql:    "SELECT 1; SELECT 2",
			want:   []string{"SELECT 1;", "SELECT 2"},
		},
		{
			name:   "trailing semicolon does not make an empty statement",
			engine: PostgreSQL,
			sql:    "SELECT 1;",
			want:   []string{"SELECT 1;"},
		},
		{
			// The whole reason splitting cannot be strings.Split: this is one
			// statement, and cutting it in half changes what it inserts.
			name:   "semicolon inside a string literal",
			engine: PostgreSQL,
			sql:    "INSERT INTO t VALUES ('a;b'); SELECT 1",
			want:   []string{"INSERT INTO t VALUES ('a;b');", "SELECT 1"},
		},
		{
			name:   "doubled quote escapes inside a literal",
			engine: PostgreSQL,
			sql:    "SELECT 'it''s; fine'; SELECT 2",
			want:   []string{"SELECT 'it''s; fine';", "SELECT 2"},
		},
		{
			name:   "semicolon inside a line comment",
			engine: PostgreSQL,
			sql:    "SELECT 1 -- trailing; comment\n; SELECT 2",
			want:   []string{"SELECT 1 -- trailing; comment\n;", "SELECT 2"},
		},
		{
			name:   "semicolon inside a block comment",
			engine: PostgreSQL,
			sql:    "SELECT /* a; b */ 1; SELECT 2",
			want:   []string{"SELECT /* a; b */ 1;", "SELECT 2"},
		},
		{
			name:   "quoted identifier containing a semicolon",
			engine: PostgreSQL,
			sql:    `SELECT "od;d" FROM t; SELECT 2`,
			want:   []string{`SELECT "od;d" FROM t;`, "SELECT 2"},
		},
		{
			name:   "sql server bracket identifier",
			engine: SQLServer,
			sql:    "SELECT [we;ird] FROM t; SELECT 2",
			want:   []string{"SELECT [we;ird] FROM t;", "SELECT 2"},
		},
		{
			name:   "mysql backtick identifier and hash comment",
			engine: MySQL,
			sql:    "SELECT `a;b` FROM t # note; here\n; SELECT 2",
			want:   []string{"SELECT `a;b` FROM t # note; here\n;", "SELECT 2"},
		},
		{
			// A function body is full of semicolons and is one statement.
			name:   "postgres dollar quoting",
			engine: PostgreSQL,
			sql:    "CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql; SELECT 1",
			want: []string{
				"CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql;",
				"SELECT 1",
			},
		},
		{
			name:   "tagged dollar quoting",
			engine: PostgreSQL,
			sql:    "SELECT $tag$ a; b $tag$; SELECT 2",
			want:   []string{"SELECT $tag$ a; b $tag$;", "SELECT 2"},
		},
		{
			name:   "sql server GO batch separator",
			engine: SQLServer,
			sql:    "CREATE TABLE t (id int)\nGO\nSELECT 1\nGO",
			want:   []string{"CREATE TABLE t (id int)", "SELECT 1"},
		},
		{
			name:   "comment-only input yields nothing to run",
			engine: PostgreSQL,
			sql:    "-- just a note\n/* and another */",
			want:   nil,
		},
		{
			name:   "empty input",
			engine: PostgreSQL,
			sql:    "   \n  ",
			want:   nil,
		},
		{
			name:   "unterminated literal does not lose the tail",
			engine: PostgreSQL,
			sql:    "SELECT 'oops",
			want:   []string{"SELECT 'oops"},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := statementTexts(SplitStatements(tc.engine, tc.sql))
			if !equalStrings(got, tc.want) {
				t.Errorf("SplitStatements()\n got: %q\nwant: %q", got, tc.want)
			}
		})
	}
}

func TestSplitStatementsOffsets(t *testing.T) {
	sql := "SELECT 1;\nSELECT 2"
	got := SplitStatements(PostgreSQL, sql)
	if len(got) != 2 {
		t.Fatalf("expected 2 statements, got %d", len(got))
	}
	// The editor uses these offsets to highlight the statement under the
	// cursor, so a slice of the original buffer has to land on the statement.
	if s := sql[got[1].Start:got[1].End]; s != "\nSELECT 2" {
		t.Errorf("second statement spans %q, want %q", s, "\nSELECT 2")
	}
}

func TestClassify(t *testing.T) {
	tests := []struct {
		sql  string
		want StatementKind
	}{
		{"SELECT 1", KindSelect},
		{"  select 1", KindSelect},
		{"(SELECT 1)", KindSelect},
		{"-- note\nSELECT 1", KindSelect},
		{"/* note */ SELECT 1", KindSelect},
		{"WITH x AS (SELECT 1) SELECT * FROM x", KindSelect},
		{"INSERT INTO t VALUES (1)", KindDML},
		{"UPDATE t SET a = 1", KindDML},
		{"DELETE FROM t", KindDML},
		{"CREATE TABLE t (id int)", KindDDL},
		{"DROP TABLE t", KindDDL},
		{"BEGIN", KindTx},
		{"COMMIT", KindTx},
		{"SET search_path = public", KindUtility},
		{"SHOW TABLES", KindUtility},
		{"EXPLAIN SELECT 1", KindUtility},
		{"PRAGMA table_info(t)", KindUtility},
		// A data-modifying CTE is a write wearing a SELECT's clothing.
		{"WITH d AS (SELECT id FROM t) DELETE FROM u WHERE id IN (SELECT id FROM d)", KindDML},
		{"WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x", KindDML},
		{"WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x", KindDML},
	}
	for _, tc := range tests {
		t.Run(tc.sql, func(t *testing.T) {
			if got := Classify(tc.sql); got != tc.want {
				t.Errorf("Classify(%q) = %q, want %q", tc.sql, got, tc.want)
			}
		})
	}
}

func TestIsReadOnly(t *testing.T) {
	readable := []string{
		"SELECT * FROM orders",
		"  select 1",
		"WITH x AS (SELECT 1) SELECT * FROM x",
		"EXPLAIN SELECT 1",
		"SHOW TABLES",
		"DESCRIBE orders",
		"PRAGMA table_info(orders)",
	}
	for _, sql := range readable {
		if !IsReadOnly(sql) {
			t.Errorf("IsReadOnly(%q) = false, want true", sql)
		}
	}

	// The guard is an allowlist. Anything not positively recognised as a read
	// must be refused, including the CTE that hides a DELETE and the statement
	// shapes this classifier has never seen.
	writable := []string{
		"UPDATE orders SET total = 0",
		"DELETE FROM orders",
		"INSERT INTO orders VALUES (1)",
		"DROP TABLE orders",
		"TRUNCATE TABLE orders",
		"WITH d AS (SELECT 1) DELETE FROM orders",
		"SET autocommit = 0",
		"PRAGMA journal_mode = WAL",
		"CALL some_procedure()",
		"EXEC sp_who",
		"GRANT SELECT ON orders TO bob",
		"VACUUM",
		"lorem ipsum not sql at all",
	}
	for _, sql := range writable {
		if IsReadOnly(sql) {
			t.Errorf("IsReadOnly(%q) = true, want false", sql)
		}
	}
}

func TestContainsWord(t *testing.T) {
	if !containsWord("INSERT INTO T VALUES (1) RETURNING ID", "RETURNING") {
		t.Error("expected RETURNING to be found as a word")
	}
	// A column called returning_date is not a RETURNING clause.
	if containsWord("SELECT RETURNING_DATE FROM T", "RETURNING") {
		t.Error("RETURNING_DATE should not match the word RETURNING")
	}
	if containsWord("SELECT PRERETURNING FROM T", "RETURNING") {
		t.Error("PRERETURNING should not match the word RETURNING")
	}
}

func TestQuoteIdentifier(t *testing.T) {
	tests := []struct {
		engine Engine
		in     string
		want   string
	}{
		{SQLServer, "orders", "[orders]"},
		{SQLServer, "we]ird", "[we]]ird]"},
		{MySQL, "orders", "`orders`"},
		{MySQL, "we`ird", "`we``ird`"},
		{PostgreSQL, "orders", `"orders"`},
		{PostgreSQL, `we"ird`, `"we""ird"`},
		{SQLite, "orders", `"orders"`},
	}
	for _, tc := range tests {
		if got := tc.engine.QuoteIdentifier(tc.in); got != tc.want {
			t.Errorf("%s.QuoteIdentifier(%q) = %q, want %q", tc.engine, tc.in, got, tc.want)
		}
	}
}

func TestPlaceholder(t *testing.T) {
	tests := []struct {
		engine Engine
		n      int
		want   string
	}{
		{SQLServer, 1, "@p1"},
		{SQLServer, 3, "@p3"},
		{PostgreSQL, 1, "$1"},
		{PostgreSQL, 2, "$2"},
		{MySQL, 1, "?"},
		{SQLite, 4, "?"},
	}
	for _, tc := range tests {
		if got := tc.engine.Placeholder(tc.n); got != tc.want {
			t.Errorf("%s.Placeholder(%d) = %q, want %q", tc.engine, tc.n, got, tc.want)
		}
	}
}

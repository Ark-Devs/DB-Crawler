package dbcore

import (
	"context"
	"strings"
	"testing"
)

func texts(in []Suggestion) []string {
	out := make([]string, len(in))
	for i, s := range in {
		out[i] = s.Text
	}
	return out
}

func contains(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}

func indexOf(list []string, want string) int {
	for i, s := range list {
		if s == want {
			return i
		}
	}
	return -1
}

// completeAt puts the cursor where the ‸ marker is.
func completeAt(t *testing.T, s *Session, marked string) Completion {
	t.Helper()
	cursor := strings.Index(marked, "‸")
	if cursor < 0 {
		t.Fatal("the test string needs a ‸ to mark the cursor")
	}
	text := strings.Replace(marked, "‸", "", 1)
	// Index is in bytes; Complete counts runes.
	return s.Complete(context.Background(), text, len([]rune(text[:cursor])))
}

func TestCompleteTablesAfterFrom(t *testing.T) {
	_, s := newTestDB(t)
	got := texts(completeAt(t, s, "SELECT * FROM ord‸").Suggestions)
	if !contains(got, "orders") {
		t.Errorf("expected orders in %v", got)
	}
	// `customers` does not start with "ord" and should not outrank it.
	if i, j := indexOf(got, "orders"), indexOf(got, "customers"); j >= 0 && i > j {
		t.Errorf("orders should rank above customers, got %v", got)
	}
}

func TestCompleteColumnsForAnAlias(t *testing.T) {
	_, s := newTestDB(t)
	c := completeAt(t, s, "SELECT o.‸ FROM orders o")

	got := texts(c.Suggestions)
	for _, want := range []string{"id", "customer_id", "reference", "total"} {
		if !contains(got, want) {
			t.Errorf("expected column %q in %v", want, got)
		}
	}
	// Behind a qualifier, only that table's columns belong — no keywords and
	// no other tables, or the list is useless on a phone screen.
	if contains(got, "SELECT") || contains(got, "customers") {
		t.Errorf("qualified completion leaked non-columns: %v", got)
	}
	if c.Prefix != "" {
		t.Errorf("prefix = %q, want empty right after the dot", c.Prefix)
	}
}

func TestCompleteQualifiedPrefixFilters(t *testing.T) {
	_, s := newTestDB(t)
	c := completeAt(t, s, "SELECT o.ref‸ FROM orders o")
	if c.Prefix != "ref" {
		t.Errorf("prefix = %q, want ref", c.Prefix)
	}
	got := texts(c.Suggestions)
	if !contains(got, "reference") {
		t.Errorf("expected reference in %v", got)
	}
	if contains(got, "notes") {
		t.Errorf("notes does not match the prefix: %v", got)
	}
}

func TestCompleteColumnsFromTheStatementsTables(t *testing.T) {
	_, s := newTestDB(t)
	got := texts(completeAt(t, s, "SELECT ‸ FROM customers").Suggestions)
	// The columns of the table in scope, without needing a qualifier.
	for _, want := range []string{"name", "email"} {
		if !contains(got, want) {
			t.Errorf("expected %q in %v", want, got)
		}
	}
}

func TestCompleteUsesOnlyTheStatementUnderTheCursor(t *testing.T) {
	_, s := newTestDB(t)
	// Two statements. The cursor is in the second, so the first statement's
	// table must not supply the columns.
	c := completeAt(t, s, "SELECT * FROM orders;\nSELECT c.‸ FROM customers c")
	got := texts(c.Suggestions)
	if !contains(got, "email") {
		t.Errorf("expected customers' columns, got %v", got)
	}
	if contains(got, "reference") {
		t.Errorf("orders' columns leaked from the other statement: %v", got)
	}
}

func TestCompleteKeywordsRankBelowNames(t *testing.T) {
	_, s := newTestDB(t)
	got := texts(completeAt(t, s, "SELECT * FROM o‸").Suggestions)
	table, keyword := indexOf(got, "orders"), indexOf(got, "ON")
	if table < 0 {
		t.Fatalf("orders missing from %v", got)
	}
	// The user knows the keywords; they cannot remember the table names.
	if keyword >= 0 && keyword < table {
		t.Errorf("keyword outranked a table: %v", got)
	}
}

func TestCompleteIgnoresStringsAndComments(t *testing.T) {
	_, s := newTestDB(t)
	// FROM inside a literal must not put us in table context.
	c := completeAt(t, s, "SELECT 'FROM orders' AS note, ‸")
	if c.Prefix != "" {
		t.Errorf("prefix = %q", c.Prefix)
	}
	// Nothing to assert about content beyond not crashing and not treating
	// the literal as structure; the scanner is shared with SplitStatements,
	// which is tested directly.
}

func TestTableReferences(t *testing.T) {
	tests := []struct {
		name      string
		statement string
		lookup    string
		want      tableRef
	}{
		{"bare table", "SELECT * FROM orders", "orders", tableRef{name: "orders"}},
		{"alias", "SELECT * FROM orders o", "o", tableRef{name: "orders"}},
		{"alias with AS", "SELECT * FROM orders AS o", "o", tableRef{name: "orders"}},
		{"schema qualified", "SELECT * FROM dbo.orders", "orders",
			tableRef{schema: "dbo", name: "orders"}},
		{"join", "SELECT * FROM a JOIN customers c ON 1=1", "c",
			tableRef{name: "customers"}},
		{"update", "UPDATE orders SET x = 1", "orders", tableRef{name: "orders"}},
		{"bracketed", "SELECT * FROM [orders] o", "o", tableRef{name: "orders"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			refs := tableReferences(tc.statement)
			got, ok := refs[tc.lookup]
			if !ok {
				t.Fatalf("%q not found in %v", tc.lookup, refs)
			}
			if got != tc.want {
				t.Errorf("got %+v, want %+v", got, tc.want)
			}
		})
	}

	t.Run("a keyword is not an alias", func(t *testing.T) {
		refs := tableReferences("SELECT * FROM orders WHERE id = 1")
		if _, ok := refs["where"]; ok {
			t.Error("WHERE was registered as a table alias")
		}
	})
}

func TestObjectsIncludeRoutinesWhereTheyExist(t *testing.T) {
	_, s := newTestDB(t)
	// SQLite has no stored routines, so the listing is tables and views only
	// — and crucially the absence must not fail the call.
	objects, err := s.Objects(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if len(objects) == 0 {
		t.Fatal("expected the seeded tables")
	}
	for _, o := range objects {
		if IsRoutine(o.Type) {
			t.Errorf("SQLite reported a routine: %+v", o)
		}
	}
}

func TestIsRoutine(t *testing.T) {
	for _, kind := range []string{ObjFunction, ObjProcedure} {
		if !IsRoutine(kind) {
			t.Errorf("%q should be a routine", kind)
		}
	}
	for _, kind := range []string{ObjTable, ObjView, ObjMatView} {
		if IsRoutine(kind) {
			t.Errorf("%q should not be a routine", kind)
		}
	}
}

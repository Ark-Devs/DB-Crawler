package dbcore

import (
	"strconv"
	"strings"
	"unicode"
)

// StatementKind is a coarse classification of what a statement will do. It
// drives two things: whether a read-only connection may run it, and whether
// the result is a grid of rows or a count of affected rows.
type StatementKind string

const (
	KindSelect  StatementKind = "select"  // returns rows, changes nothing
	KindDML     StatementKind = "dml"     // INSERT, UPDATE, DELETE, MERGE
	KindDDL     StatementKind = "ddl"     // CREATE, ALTER, DROP, TRUNCATE
	KindTx      StatementKind = "tx"      // BEGIN, COMMIT, ROLLBACK, SAVEPOINT
	KindUtility StatementKind = "utility" // SET, USE, SHOW, EXPLAIN, PRAGMA…
	KindOther   StatementKind = "other"
)

// Statement is one statement carved out of an editor buffer, with the offsets
// it occupied so the app can highlight it or place an error marker on it.
type Statement struct {
	Text  string `json:"text"`
	Start int    `json:"start"`
	End   int    `json:"end"`
}

// SplitStatements breaks an editor buffer into individual statements.
//
// It cannot just split on semicolons. A semicolon inside a string literal, a
// comment, a PostgreSQL dollar-quoted body, or a bracketed identifier is not a
// separator, and treating it as one truncates the statement into something
// that either fails or — much worse — succeeds while meaning something else.
func SplitStatements(engine Engine, sql string) []Statement {
	var out []Statement
	runes := []rune(sql)
	start := 0

	flush := func(end int) {
		text := strings.TrimSpace(string(runes[start:end]))
		if text != "" && !isOnlyComments(text) {
			out = append(out, Statement{
				Text:  text,
				Start: start,
				End:   end,
			})
		}
		start = end
	}

	for i := 0; i < len(runes); {
		switch {
		case runes[i] == '\'':
			i = skipQuoted(runes, i, '\'')

		case runes[i] == '"' && engine != MySQL:
			i = skipQuoted(runes, i, '"')

		case runes[i] == '`' && engine == MySQL:
			i = skipQuoted(runes, i, '`')

		case runes[i] == '[' && engine == SQLServer:
			i = skipUntil(runes, i+1, ']')

		case runes[i] == '-' && i+1 < len(runes) && runes[i+1] == '-':
			i = skipLineComment(runes, i)

		case runes[i] == '#' && engine == MySQL:
			i = skipLineComment(runes, i)

		case runes[i] == '/' && i+1 < len(runes) && runes[i+1] == '*':
			i = skipBlockComment(runes, i)

		case runes[i] == '$' && engine == PostgreSQL:
			if next, ok := skipDollarQuoted(runes, i); ok {
				i = next
			} else {
				i++
			}

		case runes[i] == ';':
			flush(i + 1)
			i++

		default:
			i++
		}
	}
	flush(len(runes))

	// SQL Server scripts use a bare GO on its own line as a batch separator.
	// It is not SQL and the server will reject it, so it has to be handled as
	// a split point rather than passed through.
	if engine == SQLServer {
		out = splitOnGoBatches(out)
	}
	return out
}

func skipQuoted(r []rune, i int, quote rune) int {
	i++ // opening quote
	for i < len(r) {
		if r[i] == quote {
			// A doubled quote is an escaped quote, not the end of the literal.
			if i+1 < len(r) && r[i+1] == quote {
				i += 2
				continue
			}
			return i + 1
		}
		// MySQL and SQLite also honour backslash escapes inside strings.
		if r[i] == '\\' && i+1 < len(r) {
			i += 2
			continue
		}
		i++
	}
	return i
}

func skipUntil(r []rune, i int, end rune) int {
	for i < len(r) && r[i] != end {
		i++
	}
	if i < len(r) {
		i++
	}
	return i
}

func skipLineComment(r []rune, i int) int {
	for i < len(r) && r[i] != '\n' {
		i++
	}
	return i
}

func skipBlockComment(r []rune, i int) int {
	i += 2
	depth := 1
	for i < len(r) {
		if r[i] == '/' && i+1 < len(r) && r[i+1] == '*' {
			depth++
			i += 2
			continue
		}
		if r[i] == '*' && i+1 < len(r) && r[i+1] == '/' {
			depth--
			i += 2
			if depth == 0 {
				return i
			}
			continue
		}
		i++
	}
	return i
}

// skipDollarQuoted handles PostgreSQL's $tag$ … $tag$ bodies, which is how
// function definitions arrive and which are full of semicolons that must not
// be treated as separators.
func skipDollarQuoted(r []rune, i int) (int, bool) {
	j := i + 1
	for j < len(r) && (r[j] == '_' || unicode.IsLetter(r[j]) || unicode.IsDigit(r[j])) {
		j++
	}
	if j >= len(r) || r[j] != '$' {
		return i, false
	}
	tag := string(r[i : j+1]) // includes both dollars
	rest := string(r[j+1:])
	end := strings.Index(rest, tag)
	if end < 0 {
		return len(r), true // unterminated: the rest of the buffer is the body
	}
	return j + 1 + len([]rune(rest[:end])) + len([]rune(tag)), true
}

// splitOnGoBatches breaks statements further at any line consisting only of
// GO, optionally followed by a repeat count.
func splitOnGoBatches(in []Statement) []Statement {
	var out []Statement
	for _, st := range in {
		lines := strings.Split(st.Text, "\n")
		var buf []string
		for _, line := range lines {
			if isGoSeparator(line) {
				if joined := strings.TrimSpace(strings.Join(buf, "\n")); joined != "" {
					out = append(out, Statement{Text: joined, Start: st.Start, End: st.End})
				}
				buf = nil
				continue
			}
			buf = append(buf, line)
		}
		if joined := strings.TrimSpace(strings.Join(buf, "\n")); joined != "" {
			out = append(out, Statement{Text: joined, Start: st.Start, End: st.End})
		}
	}
	return out
}

func isGoSeparator(line string) bool {
	f := strings.Fields(strings.TrimSpace(line))
	if len(f) == 0 || !strings.EqualFold(f[0], "GO") {
		return false
	}
	if len(f) == 1 {
		return true
	}
	if len(f) == 2 {
		_, err := strconv.Atoi(f[1])
		return err == nil
	}
	return false
}

// StripLeading removes comments and whitespace from the front of a statement
// so the first real keyword can be read.
func StripLeading(sql string) string {
	r := []rune(sql)
	i := 0
	for i < len(r) {
		switch {
		case unicode.IsSpace(r[i]):
			i++
		case r[i] == '-' && i+1 < len(r) && r[i+1] == '-':
			i = skipLineComment(r, i)
		case r[i] == '/' && i+1 < len(r) && r[i+1] == '*':
			i = skipBlockComment(r, i)
		case r[i] == '(':
			// A leading paren wraps a parenthesised SELECT; step in so the
			// keyword behind it is the one that gets classified.
			i++
		default:
			return string(r[i:])
		}
	}
	return ""
}

func isOnlyComments(sql string) bool {
	return StripLeading(sql) == ""
}

// firstKeyword returns the leading word of a statement, upper-cased.
func firstKeyword(sql string) string {
	s := StripLeading(sql)
	end := strings.IndexFunc(s, func(r rune) bool {
		return !unicode.IsLetter(r) && r != '_'
	})
	if end < 0 {
		end = len(s)
	}
	return strings.ToUpper(s[:end])
}

func upperFold(s string) string { return strings.ToUpper(s) }

// containsWord reports whether an already-upper-cased statement contains a
// keyword as a whole word, so that a column named `returning_date` does not
// read as a RETURNING clause.
func containsWord(upper, word string) bool {
	for i := 0; ; {
		j := strings.Index(upper[i:], word)
		if j < 0 {
			return false
		}
		j += i
		beforeOK := j == 0 || !isIdentRune(rune(upper[j-1]))
		after := j + len(word)
		afterOK := after >= len(upper) || !isIdentRune(rune(upper[after]))
		if beforeOK && afterOK {
			return true
		}
		i = j + len(word)
	}
}

func isIdentRune(r rune) bool {
	return r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r)
}

// Classify decides what a single statement does.
func Classify(sql string) StatementKind {
	switch firstKeyword(sql) {
	case "SELECT", "TABLE", "VALUES":
		return KindSelect
	case "WITH":
		return classifyCTE(sql)
	case "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE", "UPSERT", "COPY", "LOAD", "CALL", "EXEC", "EXECUTE":
		return KindDML
	case "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME", "COMMENT", "GRANT", "REVOKE", "VACUUM", "REINDEX", "ANALYZE", "CLUSTER":
		return KindDDL
	case "BEGIN", "START", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "END":
		return KindTx
	case "SET", "USE", "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "PRAGMA", "RESET", "DECLARE", "PRINT", "CHECKPOINT":
		return KindUtility
	}
	return KindOther
}

// classifyCTE decides whether a WITH statement reads or writes.
//
// PostgreSQL allows a data-modifying CTE, which gives a write two places to
// hide. `WITH x AS (…) DELETE FROM t` puts it after the CTE list, and
// `WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x` puts it inside the
// CTE body — that one still deletes every row while presenting SELECT as its
// outermost keyword, so a scan that only looked at the top nesting level would
// wave it straight through.
//
// So every depth is scanned, and any data-modifying keyword found outside a
// string, comment, or quoted identifier makes the whole statement a write.
//
// The asymmetry is deliberate. Reading a write as a read lets it run on a
// connection the user marked read-only, which is the accident this mechanism
// exists to prevent. Reading a read as a write only refuses a query the user
// can still run by clearing the flag.
func classifyCTE(sql string) StatementKind {
	for _, word := range scanKeywords(sql) {
		switch word {
		case "INSERT", "UPDATE", "DELETE", "MERGE":
			return KindDML
		}
	}
	return KindSelect
}

// scanKeywords returns the bare words of a statement, upper-cased, skipping
// string literals, comments, and quoted identifiers — every place a word can
// appear without being a keyword.
func scanKeywords(sql string) []string {
	r := []rune(sql)
	var out []string
	for i := 0; i < len(r); {
		switch {
		case r[i] == '\'':
			i = skipQuoted(r, i, '\'')
		case r[i] == '"':
			i = skipQuoted(r, i, '"')
		case r[i] == '`':
			i = skipQuoted(r, i, '`')
		case r[i] == '[':
			i = skipUntil(r, i+1, ']')
		case r[i] == '-' && i+1 < len(r) && r[i+1] == '-':
			i = skipLineComment(r, i)
		case r[i] == '/' && i+1 < len(r) && r[i+1] == '*':
			i = skipBlockComment(r, i)
		case r[i] == '$':
			if next, ok := skipDollarQuoted(r, i); ok {
				i = next
			} else {
				i++
			}
		case unicode.IsLetter(r[i]) || r[i] == '_':
			start := i
			for i < len(r) && isIdentRune(r[i]) {
				i++
			}
			out = append(out, strings.ToUpper(string(r[start:i])))
		default:
			i++
		}
	}
	return out
}

// IsReadOnly reports whether a statement is safe to run on a connection the
// user marked read-only.
//
// The check is a allowlist, not a blocklist: anything not positively
// recognised as a read is refused. A blocklist here fails open, and failing
// open on a production database from a phone is exactly the accident this flag
// exists to prevent.
func IsReadOnly(sql string) bool {
	switch Classify(sql) {
	case KindSelect:
		return true
	case KindUtility:
		switch firstKeyword(sql) {
		case "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "PRINT":
			return true
		case "PRAGMA":
			// PRAGMA reads settings; PRAGMA x = y writes one.
			return !strings.Contains(sql, "=")
		}
		return false
	}
	return false
}

// The row cap is deliberately *not* implemented by rewriting the user's SQL.
//
// The obvious trick — wrapping the statement in `SELECT * FROM (…) LIMIT n` —
// is wrong on SQL Server the moment the inner query has an ORDER BY, which a
// derived table forbids. Rewriting someone's statement also risks handing back
// results that quietly differ from what they asked for.
//
// Instead the cap is applied while reading: the reader stops after n+1 rows
// and closes the cursor, which tells the driver to stop fetching. The server
// may have planned for more, but nothing beyond the cap crosses the network,
// which is the part that matters on a mobile connection.

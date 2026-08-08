package dbcore

import (
	"context"
	"sort"
	"strings"
	"sync"
	"unicode"
)

// Suggestion is one completion offered for the word being typed.
type Suggestion struct {
	Text string `json:"text"`
	// Kind drives the icon: "keyword", "table", "view", "column", "schema",
	// "function", "procedure".
	Kind string `json:"kind"`
	// Detail is the grey text beside it — a column's type, a table's schema.
	Detail string `json:"detail,omitempty"`
}

// Completion is what the editor needs to replace the word under the cursor.
type Completion struct {
	// Prefix is the partial word being completed. The editor replaces exactly
	// this many characters, so it must be what was actually matched rather
	// than what the caller assumed.
	Prefix      string       `json:"prefix"`
	Suggestions []Suggestion `json:"suggestions"`
}

// catalog caches the names completion needs.
//
// Columns are fetched per table on first use rather than up front: a database
// with two thousand tables would otherwise mean two thousand round trips
// before the first keystroke could be answered.
type catalog struct {
	mu      sync.Mutex
	tables  []TableInfo
	fetched bool
	columns map[string][]ColumnInfo
}

func (c *catalog) tableList(ctx context.Context, s *Session) []TableInfo {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.fetched {
		// A failure here is not worth surfacing: completion is an
		// enhancement, and an editor that refuses to accept keystrokes
		// because a catalog query failed is worse than one without hints.
		if objects, err := s.Objects(ctx, s.defaultSchema(ctx)); err == nil {
			c.tables = objects
		}
		c.fetched = true
	}
	return c.tables
}

func (c *catalog) columnsFor(ctx context.Context, s *Session, schema, table string) []ColumnInfo {
	key := strings.ToLower(schema + "." + table)
	c.mu.Lock()
	if c.columns == nil {
		c.columns = make(map[string][]ColumnInfo)
	}
	cached, ok := c.columns[key]
	c.mu.Unlock()
	if ok {
		return cached
	}

	cols, err := s.columns(ctx, schema, table)
	if err != nil {
		cols = nil
	}
	c.mu.Lock()
	c.columns[key] = cols
	c.mu.Unlock()
	return cols
}

// defaultSchema is the schema completion looks in when the statement does not
// say. Cached on the session because it costs a round trip.
func (s *Session) defaultSchema(ctx context.Context) string {
	if !s.Engine.SupportsSchemas() {
		return ""
	}
	s.schemaOnce.Do(func() {
		schemas, err := s.Schemas(ctx)
		if err != nil {
			return
		}
		preferred := "public"
		if s.Engine == SQLServer {
			preferred = "dbo"
		}
		for _, name := range schemas {
			if name == preferred {
				s.cachedSchema = name
				return
			}
		}
		if len(schemas) > 0 {
			s.cachedSchema = schemas[0]
		}
	})
	return s.cachedSchema
}

// Complete suggests what could follow the cursor.
//
// The suggestions are narrowed by what the statement is doing: after FROM you
// want tables, after SELECT you want columns, and after a table alias and a
// dot you want only that table's columns. Offering everything everywhere is
// the same as offering nothing on a screen this size.
func (s *Session) Complete(ctx context.Context, sqlText string, cursor int) Completion {
	runes := []rune(sqlText)
	if cursor < 0 {
		cursor = 0
	}
	if cursor > len(runes) {
		cursor = len(runes)
	}

	prefix, start := wordBefore(runes, cursor)
	qualifier := qualifierBefore(runes, start)
	statement := statementAround(s.Engine, sqlText, cursor)
	refs := tableReferences(statement)

	var out []Suggestion

	if qualifier != "" {
		// `alias.` or `table.` — only that table's columns make sense.
		if ref, ok := refs[strings.ToLower(qualifier)]; ok {
			out = append(out, s.columnSuggestions(ctx, ref)...)
		} else {
			// Not an alias in this statement; try it as a table name.
			out = append(out, s.columnSuggestions(ctx,
				tableRef{schema: "", name: qualifier})...)
		}
		return Completion{Prefix: prefix, Suggestions: rank(prefix, out)}
	}

	switch contextBefore(runes, start) {
	case wantTable:
		out = append(out, s.tableSuggestions(ctx)...)
	case wantColumn:
		for _, ref := range uniqueRefs(refs) {
			out = append(out, s.columnSuggestions(ctx, ref)...)
		}
		out = append(out, s.tableSuggestions(ctx)...)
		out = append(out, keywordSuggestions()...)
	default:
		out = append(out, keywordSuggestions()...)
		out = append(out, s.tableSuggestions(ctx)...)
	}

	return Completion{Prefix: prefix, Suggestions: rank(prefix, out)}
}

func (s *Session) tableSuggestions(ctx context.Context) []Suggestion {
	var out []Suggestion
	for _, t := range s.catalog.tableList(ctx, s) {
		detail := t.Schema
		if detail == "" {
			detail = t.Type
		}
		out = append(out, Suggestion{Text: t.Name, Kind: t.Type, Detail: detail})
	}
	return out
}

func (s *Session) columnSuggestions(ctx context.Context, ref tableRef) []Suggestion {
	schema := ref.schema
	if schema == "" {
		schema = s.defaultSchema(ctx)
	}
	var out []Suggestion
	for _, c := range s.catalog.columnsFor(ctx, s, schema, ref.name) {
		out = append(out, Suggestion{
			Text:   c.Name,
			Kind:   "column",
			Detail: c.DataType,
		})
	}
	return out
}

// --- context detection ---------------------------------------------------

type completionContext int

const (
	wantAnything completionContext = iota
	wantTable
	wantColumn
)

// wordBefore returns the identifier being typed and where it starts.
func wordBefore(r []rune, cursor int) (string, int) {
	i := cursor
	for i > 0 && isIdentRune(r[i-1]) {
		i--
	}
	return string(r[i:cursor]), i
}

// qualifierBefore returns the name before a trailing dot, if there is one:
// the `o` in `o.total`.
func qualifierBefore(r []rune, wordStart int) string {
	i := wordStart
	if i == 0 || r[i-1] != '.' {
		return ""
	}
	i--
	end := i
	for i > 0 && isIdentRune(r[i-1]) {
		i--
	}
	return string(r[i:end])
}

// contextBefore classifies what the last meaningful keyword implies.
func contextBefore(r []rune, wordStart int) completionContext {
	words := lastWords(r[:wordStart], 3)
	for _, w := range words {
		switch w {
		case "FROM", "JOIN", "INTO", "UPDATE", "TABLE", "DESCRIBE", "DESC":
			return wantTable
		case "SELECT", "WHERE", "AND", "OR", "ON", "BY", "HAVING", "SET", "VALUES":
			return wantColumn
		}
	}
	return wantAnything
}

// lastWords returns up to n bare words before the cursor, nearest first,
// skipping string literals and comments.
func lastWords(r []rune, n int) []string {
	all := scanKeywords(string(r))
	if len(all) > n {
		all = all[len(all)-n:]
	}
	// Nearest first.
	for i, j := 0, len(all)-1; i < j; i, j = i+1, j-1 {
		all[i], all[j] = all[j], all[i]
	}
	return all
}

// statementAround returns the statement the cursor sits in, so completion is
// not confused by tables mentioned in a different statement in the buffer.
func statementAround(engine Engine, sqlText string, cursor int) string {
	for _, st := range SplitStatements(engine, sqlText) {
		if cursor >= st.Start && cursor <= st.End {
			return st.Text
		}
	}
	return sqlText
}

type tableRef struct {
	schema string
	name   string
}

// tableReferences finds the tables a statement uses, keyed by every name they
// can be referred to by — the alias and the bare table name.
//
// This is a scanner, not a parser. It looks for the names that follow FROM,
// JOIN, UPDATE, and INTO, which covers the shapes people actually type.
func tableReferences(statement string) map[string]tableRef {
	refs := make(map[string]tableRef)

	// One token list, not two. scanKeywords splits `o.ref` into `o` and `ref`
	// while identifierSequence keeps it whole, so walking them in parallel
	// drifts by one from the first dotted name onwards and every table after
	// it is read from the wrong slot.
	toks := identifierSequence(statement)

	for i := 0; i < len(toks); i++ {
		switch strings.ToUpper(toks[i]) {
		case "FROM", "JOIN", "UPDATE", "INTO":
		default:
			continue
		}
		if i+1 >= len(toks) {
			continue
		}
		name := toks[i+1]
		if isReservedFollower(strings.ToUpper(name)) {
			continue
		}

		ref := tableRef{name: name}
		if schema, table, found := strings.Cut(name, "."); found {
			ref.schema, ref.name = schema, table
		}
		if ref.name == "" {
			continue
		}
		refs[strings.ToLower(ref.name)] = ref

		// An alias follows, optionally after AS, and must not be a keyword
		// that belongs to the statement rather than to the table.
		if next := i + 2; next < len(toks) {
			alias := toks[next]
			if strings.EqualFold(alias, "AS") && next+1 < len(toks) {
				alias = toks[next+1]
			}
			if alias != "" && !strings.Contains(alias, ".") &&
				!isReservedFollower(strings.ToUpper(alias)) {
				refs[strings.ToLower(alias)] = ref
			}
		}
	}
	return refs
}

// isReservedFollower spots the words that can follow a table name without
// being an alias, so `FROM orders WHERE` does not register `WHERE` as one.
func isReservedFollower(w string) bool {
	switch w {
	case "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "ON",
		"GROUP", "ORDER", "HAVING", "LIMIT", "UNION", "SET", "VALUES",
		"SELECT", "OFFSET", "FETCH", "USING", "WITH", "RETURNING", "OUTPUT":
		return true
	}
	return false
}

// identifierSequence returns the words of a statement including dotted and
// quoted names, aligned with scanKeywords so the two can be indexed together.
func identifierSequence(statement string) []string {
	r := []rune(statement)
	var out []string
	for i := 0; i < len(r); {
		switch {
		case r[i] == '\'':
			i = skipQuoted(r, i, '\'')
		case r[i] == '-' && i+1 < len(r) && r[i+1] == '-':
			i = skipLineComment(r, i)
		case r[i] == '/' && i+1 < len(r) && r[i+1] == '*':
			i = skipBlockComment(r, i)
		case unicode.IsLetter(r[i]) || r[i] == '_' || r[i] == '"' ||
			r[i] == '[' || r[i] == '`':
			start := i
			for i < len(r) && (isIdentRune(r[i]) || r[i] == '.' ||
				r[i] == '"' || r[i] == '[' || r[i] == ']' || r[i] == '`') {
				i++
			}
			out = append(out, unquoteIdentifier(string(r[start:i])))
		default:
			i++
		}
	}
	return out
}

func unquoteIdentifier(s string) string {
	return strings.NewReplacer(`"`, "", "[", "", "]", "", "`", "").Replace(s)
}

func uniqueRefs(refs map[string]tableRef) []tableRef {
	seen := make(map[string]bool)
	var out []tableRef
	for _, ref := range refs {
		key := strings.ToLower(ref.schema + "." + ref.name)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, ref)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].name < out[j].name })
	return out
}

// rank filters by the prefix and orders the survivors.
//
// A name that starts with what was typed beats one that merely contains it,
// which is what makes typing three letters land on the table you meant rather
// than on something that happens to share a substring.
func rank(prefix string, in []Suggestion) []Suggestion {
	needle := strings.ToLower(prefix)
	type scored struct {
		s     Suggestion
		score int
	}
	var kept []scored
	seen := make(map[string]bool)

	for _, s := range in {
		key := s.Kind + "\x00" + strings.ToLower(s.Text)
		if seen[key] {
			continue
		}
		lower := strings.ToLower(s.Text)
		score := -1
		switch {
		case needle == "":
			score = 1
		case strings.HasPrefix(lower, needle):
			score = 0
		case strings.Contains(lower, needle):
			score = 2
		}
		if score < 0 {
			continue
		}
		// Columns and tables are worth more than keywords: the user knows the
		// keywords and cannot remember the names.
		if s.Kind == "keyword" {
			score += 3
		}
		seen[key] = true
		kept = append(kept, scored{s, score})
	}

	sort.SliceStable(kept, func(i, j int) bool {
		if kept[i].score != kept[j].score {
			return kept[i].score < kept[j].score
		}
		return strings.ToLower(kept[i].s.Text) < strings.ToLower(kept[j].s.Text)
	})

	out := make([]Suggestion, 0, len(kept))
	for _, k := range kept {
		out = append(out, k.s)
		if len(out) >= 40 {
			break
		}
	}
	return out
}

var sqlKeywords = []string{
	"SELECT", "FROM", "WHERE", "GROUP BY", "ORDER BY", "HAVING", "LIMIT",
	"INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN", "ON",
	"INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "AS", "AND",
	"OR", "NOT", "NULL", "IS NULL", "IS NOT NULL", "IN", "BETWEEN", "LIKE",
	"DISTINCT", "COUNT(*)", "SUM(", "AVG(", "MIN(", "MAX(", "CASE", "WHEN",
	"THEN", "ELSE", "END", "UNION", "UNION ALL", "WITH", "EXISTS", "ASC",
	"DESC", "TOP", "OFFSET", "FETCH NEXT",
}

func keywordSuggestions() []Suggestion {
	out := make([]Suggestion, 0, len(sqlKeywords))
	for _, k := range sqlKeywords {
		out = append(out, Suggestion{Text: k, Kind: "keyword"})
	}
	return out
}

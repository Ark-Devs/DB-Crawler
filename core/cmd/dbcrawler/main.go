// Command dbcrawler speaks the same JSON protocol as the mobile app, over
// stdin and stdout, one request per line.
//
// It exists so the core can be exercised against a real database from a
// terminal — no phone, no emulator, no Flutter toolchain. Every bug found here
// is one that never reaches the app, and the protocol it drives is byte for
// byte the one the app sends.
//
//	echo '{"op":"ping"}' | go run ./cmd/dbcrawler
//	go run ./cmd/dbcrawler -sqlite ./inventory.db -tables
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/Ark-Devs/DB-Crawler/core/dbcore"
)

func main() {
	var (
		sqlitePath = flag.String("sqlite", "", "open this SQLite file before reading requests")
		dsn        = flag.String("dsn", "", "open this raw DSN before reading requests")
		engine     = flag.String("engine", "", "engine for -dsn: sqlserver|postgres|mysql|sqlite")
		readOnly   = flag.Bool("read-only", false, "refuse anything that is not a read")
		runSQL     = flag.String("sql", "", "run this SQL against the opened connection and exit")
		listTables = flag.Bool("tables", false, "list tables on the opened connection and exit")
		maxRows    = flag.Int("max-rows", 100, "row cap for -sql")
	)
	flag.Parse()

	ctx := context.Background()
	m := dbcore.NewManager()
	defer m.CloseAll()

	sessionID := ""
	if *sqlitePath != "" || *dsn != "" {
		cfg := dbcore.Config{ReadOnly: *readOnly}
		switch {
		case *sqlitePath != "":
			cfg.Engine = dbcore.SQLite
			cfg.File = *sqlitePath
		default:
			parsed, err := dbcore.ParseEngine(*engine)
			if err != nil {
				exitf("%v (use -engine with -dsn)", err)
			}
			cfg.Engine = parsed
			cfg.RawDSN = *dsn
		}
		id, err := openConnection(ctx, m, cfg)
		if err != nil {
			exitf("%v", err)
		}
		sessionID = id
	}

	switch {
	case *listTables:
		requireSession(sessionID)
		emit(m.Handle(ctx, request(map[string]any{"op": "tables", "sessionId": sessionID})))
		return
	case *runSQL != "":
		requireSession(sessionID)
		emit(m.Handle(ctx, request(map[string]any{
			"op":        "execute",
			"sessionId": sessionID,
			"sql":       *runSQL,
			"maxRows":   *maxRows,
		})))
		return
	}

	// Interactive mode: one JSON request per line, one JSON response per line.
	// A blank line is ignored rather than treated as a parse error, because
	// piping a heredoc in almost always ends with one.
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for in.Scan() {
		line := strings.TrimSpace(in.Text())
		if line == "" {
			continue
		}
		emit(m.Handle(ctx, []byte(line)))
	}
	if err := in.Err(); err != nil {
		exitf("reading stdin: %v", err)
	}
}

func openConnection(ctx context.Context, m *dbcore.Manager, cfg dbcore.Config) (string, error) {
	raw := m.Handle(ctx, request(map[string]any{"op": "openConnection", "config": cfg}))
	var resp struct {
		OK    bool `json:"ok"`
		Error *struct {
			Message string `json:"message"`
		} `json:"error"`
		Data struct {
			SessionID string `json:"sessionId"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return "", err
	}
	if !resp.OK {
		return "", fmt.Errorf("%s", resp.Error.Message)
	}
	return resp.Data.SessionID, nil
}

func request(v map[string]any) []byte {
	out, err := json.Marshal(v)
	if err != nil {
		exitf("encoding request: %v", err)
	}
	return out
}

// emit re-indents the response, because the whole point of this harness is
// that a person reads the output.
func emit(raw []byte) {
	var pretty any
	if err := json.Unmarshal(raw, &pretty); err != nil {
		fmt.Println(string(raw))
		return
	}
	out, err := json.MarshalIndent(pretty, "", "  ")
	if err != nil {
		fmt.Println(string(raw))
		return
	}
	fmt.Println(string(out))
}

func requireSession(id string) {
	if id == "" {
		exitf("this flag needs a connection: pass -sqlite or -dsn")
	}
}

func exitf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "dbcrawler: "+format+"\n", args...)
	os.Exit(1)
}

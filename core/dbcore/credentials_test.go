package dbcore

import (
	"encoding/json"
	"net/url"
	"strings"
	"testing"
)

// The credentials cross three boundaries between the text field and the
// server: Dart builds a map, it is JSON-encoded across the FFI edge, and Go
// turns it into a DSN. A mistake anywhere in there looks identical to a wrong
// password — the server just says "login failed" — so each step is pinned
// down here rather than reasoned about.
//
// The payloads below are the literal shape ConnectionProfile.toCoreConfig
// produces. If that Dart method changes, these fail.

func TestConfigFromAppPayload(t *testing.T) {
	payload := `{
		"engine": "sqlserver",
		"host": "54.254.1.197",
		"port": 1433,
		"database": "SQ_Inventory",
		"user": "sa",
		"password": "P@ssw0rd with spaces & symbols!",
		"tls": "require",
		"connectTimeoutSeconds": 15,
		"readOnly": false
	}`

	var cfg Config
	if err := json.Unmarshal([]byte(payload), &cfg); err != nil {
		t.Fatalf("the app's payload does not decode: %v", err)
	}

	if cfg.Engine != SQLServer {
		t.Errorf("engine = %q", cfg.Engine)
	}
	if cfg.User != "sa" {
		t.Errorf("user = %q, want sa", cfg.User)
	}
	if want := "P@ssw0rd with spaces & symbols!"; cfg.Password != want {
		t.Errorf("password = %q, want %q", cfg.Password, want)
	}
	if cfg.Database != "SQ_Inventory" {
		t.Errorf("database = %q", cfg.Database)
	}
	if cfg.Port != 1433 {
		t.Errorf("port = %d", cfg.Port)
	}

	// And the credentials have to survive being rendered into a DSN, which is
	// where URL escaping could quietly eat them.
	dsn, err := cfg.DSN()
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatalf("the DSN we built is not parseable: %v", err)
	}
	if u.User.Username() != "sa" {
		t.Errorf("DSN username = %q", u.User.Username())
	}
	got, _ := u.User.Password()
	if want := "P@ssw0rd with spaces & symbols!"; got != want {
		t.Errorf("DSN password = %q, want %q", got, want)
	}
}

func TestPasswordIsNotTrimmedOrAltered(t *testing.T) {
	// A password is bytes, not a word. Trimming it would be a silent,
	// unfixable failure for anyone whose password legitimately has an edge
	// space — and a wrong "helpful" fix for anyone who pasted one by mistake.
	awkward := []string{
		" leading",
		"trailing ",
		"  both  ",
		"inner  double",
		"tab\tinside",
		"", // no password at all is a legitimate configuration
	}
	for _, want := range awkward {
		cfg := Config{
			Engine: SQLServer, Host: "h", User: "sa", Password: want,
		}
		dsn, err := cfg.DSN()
		if err != nil {
			t.Fatalf("password %q: %v", want, err)
		}
		u, err := url.Parse(dsn)
		if err != nil {
			t.Fatalf("password %q produced an unparseable DSN: %v", want, err)
		}
		got, hasPassword := u.User.Password()
		if want == "" {
			// url.UserPassword always records a password, empty or not; what
			// matters is that nothing was invented.
			if hasPassword && got != "" {
				t.Errorf("empty password became %q", got)
			}
			continue
		}
		if got != want {
			t.Errorf("password %q came back as %q", want, got)
		}
	}
}

func TestSQLServerAuthenticationMethod(t *testing.T) {
	t.Run("sql authentication names no provider", func(t *testing.T) {
		// The driver treats an absent `authenticator` as "try NTLM, fall back
		// to SQL". For a username with no domain that lands on SQL, which is
		// what we want.
		cfg := Config{Engine: SQLServer, Host: "h", User: "sa", Password: "p"}
		dsn, err := cfg.DSN()
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(dsn, "authenticator") {
			t.Errorf("SQL authentication should not pin a provider: %s", dsn)
		}
	})

	t.Run("windows authentication asks for ntlm", func(t *testing.T) {
		cfg := Config{
			Engine: SQLServer, Host: "h",
			User: `CORP\muhammed`, Password: "p", Auth: AuthWindows,
		}
		dsn, err := cfg.DSN()
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(dsn, "authenticator=ntlm") {
			t.Errorf("expected authenticator=ntlm in %s", dsn)
		}
	})

	t.Run("windows authentication without a domain is refused up front", func(t *testing.T) {
		cfg := Config{
			Engine: SQLServer, Host: "h", User: "sa", Password: "p",
			Auth: AuthWindows,
		}
		problems := strings.Join(cfg.Validate(), "; ")
		if !strings.Contains(problems, "DOMAIN") {
			t.Errorf("expected a domain complaint, got %q", problems)
		}
	})

	t.Run("an unset method means SQL authentication", func(t *testing.T) {
		cfg := Config{Engine: SQLServer, Host: "h", User: "sa"}
		if got := cfg.authMethod(); got != AuthSQL {
			t.Errorf("default auth = %q, want %q", got, AuthSQL)
		}
	})
}

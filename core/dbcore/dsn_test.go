package dbcore

import (
	"errors"
	"strings"
	"testing"
)

func TestConfigValidate(t *testing.T) {
	tests := []struct {
		name    string
		cfg     Config
		wantAny []string
	}{
		{
			name:    "sqlite needs a file",
			cfg:     Config{Engine: SQLite},
			wantAny: []string{"database file"},
		},
		{
			name:    "sqlite with a file is fine",
			cfg:     Config{Engine: SQLite, File: "/tmp/x.db"},
			wantAny: nil,
		},
		{
			name:    "networked engine needs host and user",
			cfg:     Config{Engine: PostgreSQL},
			wantAny: []string{"host is required", "username is required", "database is required"},
		},
		{
			name:    "unknown engine",
			cfg:     Config{Engine: "oracle"},
			wantAny: []string{"unknown engine"},
		},
		{
			name:    "port out of range",
			cfg:     Config{Engine: MySQL, Host: "h", User: "u", Port: 99999},
			wantAny: []string{"port must be"},
		},
		{
			name:    "valid sql server",
			cfg:     Config{Engine: SQLServer, Host: "h", User: "u"},
			wantAny: nil,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			problems := tc.cfg.Validate()
			if len(tc.wantAny) == 0 {
				if len(problems) != 0 {
					t.Fatalf("expected no problems, got %v", problems)
				}
				return
			}
			joined := strings.Join(problems, "; ")
			for _, want := range tc.wantAny {
				if !strings.Contains(joined, want) {
					t.Errorf("problems %q missing %q", joined, want)
				}
			}
		})
	}
}

func TestDSN(t *testing.T) {
	t.Run("sql server encrypts by default", func(t *testing.T) {
		cfg := Config{Engine: SQLServer, Host: "db.example.com", Database: "SQ_Inventory", User: "sa", Password: "p@ss word"}
		dsn, err := cfg.DSN()
		if err != nil {
			t.Fatal(err)
		}
		for _, want := range []string{"sqlserver://", "db.example.com:1433", "encrypt=true", "database=SQ_Inventory"} {
			if !strings.Contains(dsn, want) {
				t.Errorf("DSN %q missing %q", dsn, want)
			}
		}
		// A password with a space and an @ must survive URL encoding, or the
		// host is parsed out of the middle of the password.
		if !strings.Contains(dsn, "p%40ss%20word") {
			t.Errorf("DSN %q did not encode the password", dsn)
		}
	})

	t.Run("postgres maps tls modes", func(t *testing.T) {
		base := Config{Engine: PostgreSQL, Host: "h", Database: "d", User: "u"}
		cases := map[string]string{
			"disable": "sslmode=disable",
			"prefer":  "sslmode=prefer",
			"require": "sslmode=require",
			"verify":  "sslmode=verify-full",
		}
		for mode, want := range cases {
			cfg := base
			cfg.TLS = mode
			dsn, err := cfg.DSN()
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(dsn, want) {
				t.Errorf("tls %q gave %q, want %q", mode, dsn, want)
			}
		}
	})

	t.Run("mysql parses time and applies the port", func(t *testing.T) {
		cfg := Config{Engine: MySQL, Host: "h", Port: 3307, Database: "shop", User: "root", Password: "secret"}
		dsn, err := cfg.DSN()
		if err != nil {
			t.Fatal(err)
		}
		for _, want := range []string{"root:secret@tcp(h:3307)/shop", "parseTime=true"} {
			if !strings.Contains(dsn, want) {
				t.Errorf("DSN %q missing %q", dsn, want)
			}
		}
	})

	t.Run("sqlite read-only opens read-only", func(t *testing.T) {
		cfg := Config{Engine: SQLite, File: "/tmp/x.db", ReadOnly: true}
		dsn, err := cfg.DSN()
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(dsn, "mode=ro") {
			t.Errorf("DSN %q should open read-only", dsn)
		}
	})

	t.Run("raw dsn is passed through untouched", func(t *testing.T) {
		raw := "postgres://someone:pw@host/db?sslmode=disable&application_name=mine"
		cfg := Config{Engine: PostgreSQL, RawDSN: raw}
		dsn, err := cfg.DSN()
		if err != nil {
			t.Fatal(err)
		}
		if dsn != raw {
			t.Errorf("raw DSN was rewritten:\n got %q\nwant %q", dsn, raw)
		}
	})

	t.Run("ipv6 host is bracketed", func(t *testing.T) {
		cfg := Config{Engine: PostgreSQL, Host: "::1", Database: "d", User: "u"}
		dsn, err := cfg.DSN()
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(dsn, "[::1]:5432") {
			t.Errorf("DSN %q should bracket the IPv6 literal", dsn)
		}
	})

	t.Run("extra params are stable across calls", func(t *testing.T) {
		cfg := Config{Engine: PostgreSQL, Host: "h", Database: "d", User: "u",
			Params: map[string]string{"application_name": "crawler", "search_path": "public"}}
		first, err := cfg.DSN()
		if err != nil {
			t.Fatal(err)
		}
		for range 10 {
			again, _ := cfg.DSN()
			if again != first {
				t.Fatalf("DSN is not stable across calls:\n%q\n%q", first, again)
			}
		}
	})
}

func TestRedacted(t *testing.T) {
	cfg := Config{Engine: PostgreSQL, Host: "h", Database: "d", User: "u", Password: "hunter2"}
	if got := cfg.Redacted().Password; got == "hunter2" {
		t.Error("Redacted() kept the password")
	}
	// The original must be untouched — it is still needed to connect.
	if cfg.Password != "hunter2" {
		t.Error("Redacted() mutated the receiver")
	}

	dsnCases := []struct{ in, mustNotContain string }{
		{"postgres://user:hunter2@host/db", "hunter2"},
		{"sqlserver://sa:hunter2@host?database=d", "hunter2"},
		{"root:hunter2@tcp(h:3306)/shop", "hunter2"},
	}
	for _, tc := range dsnCases {
		raw := Config{Engine: PostgreSQL, RawDSN: tc.in}.Redacted().RawDSN
		if strings.Contains(raw, tc.mustNotContain) {
			t.Errorf("redacted DSN %q still contains the password", raw)
		}
	}
}

func TestParseEngine(t *testing.T) {
	aliases := map[string]Engine{
		"sqlserver":  SQLServer,
		"MSSQL":      SQLServer,
		"SQL Server": SQLServer,
		"postgres":   PostgreSQL,
		"postgresql": PostgreSQL,
		"pg":         PostgreSQL,
		"mysql":      MySQL,
		"MariaDB":    MySQL,
		"sqlite":     SQLite,
		"sqlite3":    SQLite,
		" sqlite ":   SQLite,
	}
	for in, want := range aliases {
		got, err := ParseEngine(in)
		if err != nil {
			t.Errorf("ParseEngine(%q) errored: %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("ParseEngine(%q) = %q, want %q", in, got, want)
		}
	}
	if _, err := ParseEngine("oracle"); err == nil {
		t.Error("ParseEngine(oracle) should fail")
	}
}

func TestConnectHint(t *testing.T) {
	tests := []struct {
		name string
		err  string
		want string
	}{
		{
			// The one that cost a release: an Android app without the INTERNET
			// permission cannot open a socket, and the raw driver error blames
			// the host.
			name: "socket refused by the OS",
			err:  "dial tcp 10.0.0.1:1433: socket: operation not permitted",
			want: "missing network permission",
		},
		{"timeout", "dial tcp 10.0.0.1:1433: i/o timeout", "reachable from this network"},
		{"refused", "dial tcp 10.0.0.1:1433: connection refused", "nothing is listening"},
		{"bad host", "dial tcp: lookup nope: no such host", "did not resolve"},
		{"bad credentials", "mssql: Login failed for user 'sa'", "credentials problem"},
		{"nothing useful to add", "some unrecognised driver failure", ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := connectHint(errors.New(tc.err))
			if tc.want == "" {
				if got != "" {
					t.Errorf("expected no hint, got %q", got)
				}
				return
			}
			if !strings.Contains(got, tc.want) {
				t.Errorf("hint %q does not mention %q", got, tc.want)
			}
		})
	}
}

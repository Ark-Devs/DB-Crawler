package dbcore

import (
	"fmt"
	"net"
	"net/url"
	"sort"
	"strconv"
	"strings"
)

// Config describes one saved connection, in the shape the connection editor
// collects it. It is deliberately structured rather than a single DSN string:
// a DSN typed on a phone keyboard is a bad experience and an easy way to leak
// a password into a text field that gets autocompleted somewhere.
//
// RawDSN is the escape hatch for the cases structure cannot cover. When it is
// set it wins outright, because a user who has gone to the trouble of writing
// a DSN does not want it silently rewritten.
type Config struct {
	Engine   Engine `json:"engine"`
	Host     string `json:"host,omitempty"`
	Port     int    `json:"port,omitempty"`
	Database string `json:"database,omitempty"`
	User     string `json:"user,omitempty"`
	Password string `json:"password,omitempty"`

	// File is the SQLite database path. Ignored by every other engine.
	File string `json:"file,omitempty"`

	// TLS is one of "disable", "prefer", "require", or "verify". The default
	// is "require" for a networked engine: these connections carry a password
	// and cross a mobile network, so unencrypted has to be a deliberate act.
	TLS string `json:"tls,omitempty"`

	// ConnectTimeoutSeconds bounds the initial handshake. Mobile networks fail
	// by hanging rather than refusing, so this is what stops the UI waiting
	// forever on a connection that is never going to open.
	ConnectTimeoutSeconds int `json:"connectTimeoutSeconds,omitempty"`

	// ReadOnly blocks anything that is not a read at the protocol layer. It is
	// what makes it safe to open production from a phone on a bus.
	ReadOnly bool `json:"readOnly,omitempty"`

	// Params are appended to the DSN verbatim, for the per-deployment knobs
	// that are not worth a field of their own.
	Params map[string]string `json:"params,omitempty"`

	RawDSN string `json:"rawDsn,omitempty"`
}

// tlsMode normalises the TLS field, defaulting to encrypted-and-verified for
// networked engines.
func (c Config) tlsMode() string {
	m := strings.ToLower(strings.TrimSpace(c.TLS))
	switch m {
	case "disable", "prefer", "require", "verify":
		return m
	case "":
		if c.Engine == SQLite {
			return "disable"
		}
		return "require"
	default:
		return "require"
	}
}

func (c Config) timeout() int {
	if c.ConnectTimeoutSeconds > 0 {
		return c.ConnectTimeoutSeconds
	}
	return 15
}

// hostPort renders host:port, defaulting the port per engine and bracketing
// IPv6 literals so that a raw ::1 does not produce an unparseable address.
func (c Config) hostPort() string {
	port := c.Port
	if port == 0 {
		port = c.Engine.DefaultPort()
	}
	return net.JoinHostPort(c.Host, strconv.Itoa(port))
}

// sortedParams gives the extra params a stable order so that a DSN is
// reproducible and therefore testable.
func (c Config) sortedParams() [][2]string {
	out := make([][2]string, 0, len(c.Params))
	for k, v := range c.Params {
		out = append(out, [2]string{k, v})
	}
	sort.Slice(out, func(i, j int) bool { return out[i][0] < out[j][0] })
	return out
}

// Validate reports the problems a user can fix, all at once, so the connection
// editor can mark every bad field in a single pass instead of making them
// discover the mistakes one save at a time.
func (c Config) Validate() []string {
	var problems []string
	if c.RawDSN != "" {
		if c.Engine == "" {
			problems = append(problems, "engine is required even with a raw DSN")
		}
		return problems
	}
	switch c.Engine {
	case SQLite:
		if strings.TrimSpace(c.File) == "" {
			problems = append(problems, "a database file is required")
		}
	case SQLServer, PostgreSQL, MySQL:
		if strings.TrimSpace(c.Host) == "" {
			problems = append(problems, "host is required")
		}
		if c.Port < 0 || c.Port > 65535 {
			problems = append(problems, "port must be between 1 and 65535")
		}
		if strings.TrimSpace(c.User) == "" {
			problems = append(problems, "username is required")
		}
		if c.Engine == PostgreSQL && strings.TrimSpace(c.Database) == "" {
			problems = append(problems, "database is required for PostgreSQL")
		}
	case "":
		problems = append(problems, "engine is required")
	default:
		problems = append(problems, fmt.Sprintf("unknown engine %q", c.Engine))
	}
	return problems
}

// DSN renders the driver-specific connection string.
func (c Config) DSN() (string, error) {
	if problems := c.Validate(); len(problems) > 0 {
		return "", fmt.Errorf("%s", strings.Join(problems, "; "))
	}
	if c.RawDSN != "" {
		return c.RawDSN, nil
	}
	switch c.Engine {
	case SQLServer:
		return c.sqlServerDSN(), nil
	case PostgreSQL:
		return c.postgresDSN(), nil
	case MySQL:
		return c.mysqlDSN(), nil
	case SQLite:
		return c.sqliteDSN(), nil
	}
	return "", fmt.Errorf("unknown engine %q", c.Engine)
}

func (c Config) sqlServerDSN() string {
	q := url.Values{}
	if c.Database != "" {
		q.Set("database", c.Database)
	}
	q.Set("connection timeout", strconv.Itoa(c.timeout()))
	// go-mssqldb spells the knobs "encrypt" and "TrustServerCertificate".
	// Azure SQL rejects an unencrypted login outright, so "require" is both
	// the safe default and the one that actually works against the managed
	// databases this app is aimed at.
	switch c.tlsMode() {
	case "disable":
		q.Set("encrypt", "disable")
	case "prefer":
		q.Set("encrypt", "false")
	case "require":
		q.Set("encrypt", "true")
		q.Set("TrustServerCertificate", "true")
	case "verify":
		q.Set("encrypt", "true")
		q.Set("TrustServerCertificate", "false")
	}
	for _, kv := range c.sortedParams() {
		q.Set(kv[0], kv[1])
	}
	u := url.URL{
		Scheme:   "sqlserver",
		User:     url.UserPassword(c.User, c.Password),
		Host:     c.hostPort(),
		RawQuery: q.Encode(),
	}
	return u.String()
}

func (c Config) postgresDSN() string {
	q := url.Values{}
	switch c.tlsMode() {
	case "disable":
		q.Set("sslmode", "disable")
	case "prefer":
		q.Set("sslmode", "prefer")
	case "require":
		q.Set("sslmode", "require")
	case "verify":
		q.Set("sslmode", "verify-full")
	}
	q.Set("connect_timeout", strconv.Itoa(c.timeout()))
	for _, kv := range c.sortedParams() {
		q.Set(kv[0], kv[1])
	}
	u := url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(c.User, c.Password),
		Host:     c.hostPort(),
		Path:     "/" + c.Database,
		RawQuery: q.Encode(),
	}
	return u.String()
}

func (c Config) mysqlDSN() string {
	q := url.Values{}
	// parseTime turns DATE and DATETIME into time.Time instead of []byte,
	// which is what lets the results grid format them as dates rather than
	// showing the raw bytes.
	q.Set("parseTime", "true")
	q.Set("loc", "UTC")
	q.Set("timeout", strconv.Itoa(c.timeout())+"s")
	switch c.tlsMode() {
	case "disable":
		q.Set("tls", "false")
	case "prefer":
		q.Set("tls", "preferred")
	case "require":
		q.Set("tls", "skip-verify")
	case "verify":
		q.Set("tls", "true")
	}
	for _, kv := range c.sortedParams() {
		q.Set(kv[0], kv[1])
	}
	auth := url.QueryEscape(c.User)
	if c.Password != "" {
		auth += ":" + url.QueryEscape(c.Password)
	}
	return fmt.Sprintf("%s@tcp(%s)/%s?%s", auth, c.hostPort(), c.Database, q.Encode())
}

func (c Config) sqliteDSN() string {
	q := url.Values{}
	// A phone can be interrupted mid-query by a call or a doze; a busy timeout
	// turns "database is locked" into a short wait instead of an error.
	q.Set("_pragma", "busy_timeout(5000)")
	if c.ReadOnly {
		q.Set("mode", "ro")
	}
	for _, kv := range c.sortedParams() {
		q.Add(kv[0], kv[1])
	}
	return "file:" + c.File + "?" + q.Encode()
}

// ForEnumeration returns a copy of the config suitable for listing the
// databases on a server, before the user has picked one.
//
// The target database is cleared, because at that point the field holds either
// nothing or a half-typed name, and connecting to a database that does not
// exist fails outright — which is exactly the moment the user needs the list.
//
// PostgreSQL is the exception: it cannot connect without a database at all, so
// it bootstraps through `postgres`, which every server has.
func (c Config) ForEnumeration() Config {
	if c.Engine == PostgreSQL {
		if strings.TrimSpace(c.Database) == "" {
			c.Database = "postgres"
		}
		return c
	}
	c.Database = ""
	return c
}

// Redacted returns a copy safe to log or show in a diagnostics screen. The
// password is the only field worth hiding and it is never worth showing.
func (c Config) Redacted() Config {
	if c.Password != "" {
		c.Password = "•••"
	}
	if c.RawDSN != "" {
		c.RawDSN = redactDSN(c.RawDSN)
	}
	return c
}

// redactDSN strips the password out of a DSN the user typed by hand, covering
// both the URL form and the key=value form.
func redactDSN(dsn string) string {
	if u, err := url.Parse(dsn); err == nil && u.User != nil {
		if _, ok := u.User.Password(); ok {
			u.User = url.UserPassword(u.User.Username(), "•••")
			return u.String()
		}
	}
	// MySQL's user:pass@tcp(...) form is not a URL.
	if at := strings.LastIndex(dsn, "@"); at > 0 {
		if colon := strings.Index(dsn[:at], ":"); colon >= 0 {
			return dsn[:colon] + ":•••" + dsn[at:]
		}
	}
	return dsn
}

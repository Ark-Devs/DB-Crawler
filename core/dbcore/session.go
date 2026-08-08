package dbcore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	_ "github.com/go-sql-driver/mysql"
	_ "github.com/jackc/pgx/v5/stdlib"
	_ "github.com/microsoft/go-mssqldb"
	_ "modernc.org/sqlite"
)

// ErrNoSession is returned when a request names a connection that is not open.
// The app treats it as "reconnect and retry", which is the normal case after
// the OS has suspended the app for long enough to drop its sockets.
var ErrNoSession = errors.New("connection is not open")

// ErrReadOnly is returned when a write is attempted on a connection the user
// marked read-only.
var ErrReadOnly = errors.New("this connection is read-only")

// Session is one open database connection, plus the bookkeeping needed to
// cancel work running on it.
type Session struct {
	ID     string
	Engine Engine
	Config Config

	db       *sql.DB
	openedAt time.Time

	mu      sync.Mutex
	running map[string]context.CancelFunc
}

// Manager owns every open session. One instance lives for the lifetime of the
// app process and is reached through the FFI entrypoint.
type Manager struct {
	mu       sync.RWMutex
	sessions map[string]*Session
	seq      atomic.Uint64
}

func NewManager() *Manager {
	return &Manager{sessions: make(map[string]*Session)}
}

func (m *Manager) nextID(prefix string) string {
	return fmt.Sprintf("%s-%d", prefix, m.seq.Add(1))
}

// Open dials the database and registers the session.
//
// database/sql does not connect on Open, so this pings before returning. A
// connection editor that says "connected" without having actually reached the
// server is worse than useless — the user finds out at the first query, by
// which point they have stopped thinking about the credentials they typed.
func (m *Manager) Open(ctx context.Context, cfg Config) (*Session, error) {
	dsn, err := cfg.DSN()
	if err != nil {
		return nil, err
	}
	db, err := sql.Open(cfg.Engine.driverName(), dsn)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", cfg.Engine, err)
	}

	// A handful of connections is plenty for one person on one phone, and a
	// low idle count means a backgrounded app is not holding server resources
	// it will never use. Mobile networks drop idle TCP silently, so idle
	// connections are also recycled well before a NAT would time them out.
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(2)
	db.SetConnMaxIdleTime(2 * time.Minute)
	db.SetConnMaxLifetime(30 * time.Minute)

	pingCtx, cancel := context.WithTimeout(ctx, time.Duration(cfg.timeout())*time.Second)
	defer cancel()
	if err := db.PingContext(pingCtx); err != nil {
		db.Close()
		return nil, fmt.Errorf("connect to %s: %w%s",
			describeTarget(cfg), err, connectHint(err))
	}

	s := &Session{
		ID:       m.nextID("conn"),
		Engine:   cfg.Engine,
		Config:   cfg,
		db:       db,
		openedAt: time.Now(),
		running:  make(map[string]context.CancelFunc),
	}
	m.mu.Lock()
	m.sessions[s.ID] = s
	m.mu.Unlock()
	return s, nil
}

func describeTarget(cfg Config) string {
	if cfg.Engine == SQLite {
		return cfg.File
	}
	return cfg.hostPort()
}

// connectHint explains the failures whose driver message points somewhere
// misleading. An empty string when there is nothing useful to add.
func connectHint(err error) string {
	msg := strings.ToLower(err.Error())
	switch {
	case strings.Contains(msg, "operation not permitted"),
		strings.Contains(msg, "permission denied"):
		// Android refuses socket() with EPERM when the app lacks the INTERNET
		// permission. It reads exactly like a firewall or a wrong password,
		// and is neither — nothing ever left the device.
		return "\n\nThe device refused to open the socket at all, which usually means" +
			" the app is missing network permission rather than anything being wrong" +
			" with the host or your credentials."
	case strings.Contains(msg, "i/o timeout"),
		strings.Contains(msg, "deadline exceeded"):
		return "\n\nNo reply from the host. Check it is reachable from this network" +
			" and that the port is open to you."
	case strings.Contains(msg, "connection refused"):
		return "\n\nThe host answered but nothing is listening on that port." +
			" Check the port, and that the server accepts TCP connections."
	case strings.Contains(msg, "no such host"):
		return "\n\nThe hostname did not resolve. Check the spelling, or use an IP address."
	case strings.Contains(msg, "certificate signed by unknown authority"),
		strings.Contains(msg, "certificate is not trusted"),
		strings.Contains(msg, "certificate is valid for"):
		// Almost always Verify against a self-signed certificate, which is
		// working exactly as intended.
		return "\n\nThe server's certificate could not be verified. If it is self-signed" +
			" — which SQL Server's default certificate is — use Require rather than Verify." +
			" The connection stays encrypted either way."
	case strings.Contains(msg, "negative serial number"):
		// Should be unreachable: the main packages carry
		// //go:debug x509negativeserial=1. If it surfaces, that directive has
		// been lost, so say so rather than blaming the server.
		return "\n\nThis is a known quirk of SQL Server's self-signed certificate that the" +
			" app is meant to tolerate. Please report it — the build is missing a setting."
	case strings.Contains(msg, "tls handshake"), strings.Contains(msg, "tls:"):
		return "\n\nThe server was reached but encryption could not be negotiated." +
			" Check whether it accepts encrypted connections, or try a different Encryption setting."
	case strings.Contains(msg, "login failed"),
		strings.Contains(msg, "password authentication failed"):
		return "\n\nThe server was reached — this is a credentials problem, not a network one."
	}
	return ""
}

// Get looks up an open session.
func (m *Manager) Get(id string) (*Session, error) {
	m.mu.RLock()
	s, ok := m.sessions[id]
	m.mu.RUnlock()
	if !ok {
		return nil, ErrNoSession
	}
	return s, nil
}

// Close cancels everything running on a session and closes it. Closing an
// already-closed session is not an error, because the app closes sessions from
// both the disconnect button and its lifecycle handlers and racing those two
// should not produce a visible failure.
func (m *Manager) Close(id string) error {
	m.mu.Lock()
	s, ok := m.sessions[id]
	delete(m.sessions, id)
	m.mu.Unlock()
	if !ok {
		return nil
	}
	s.cancelAll()
	return s.db.Close()
}

// CloseAll shuts every session down. Called when the app is being terminated.
func (m *Manager) CloseAll() {
	m.mu.Lock()
	sessions := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		sessions = append(sessions, s)
	}
	m.sessions = make(map[string]*Session)
	m.mu.Unlock()
	for _, s := range sessions {
		s.cancelAll()
		s.db.Close()
	}
}

// List describes every open session, for the app's connection indicator.
func (m *Manager) List() []SessionInfo {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]SessionInfo, 0, len(m.sessions))
	for _, s := range m.sessions {
		out = append(out, SessionInfo{
			ID:       s.ID,
			Engine:   s.Engine,
			Target:   describeTarget(s.Config),
			Database: s.Config.Database,
			ReadOnly: s.Config.ReadOnly,
			OpenedAt: s.openedAt.UTC().Format(time.RFC3339),
			Running:  s.runningCount(),
		})
	}
	return out
}

// SessionInfo is the app-facing summary of an open connection.
type SessionInfo struct {
	ID       string `json:"id"`
	Engine   Engine `json:"engine"`
	Target   string `json:"target"`
	Database string `json:"database,omitempty"`
	ReadOnly bool   `json:"readOnly"`
	OpenedAt string `json:"openedAt"`
	Running  int    `json:"running"`
}

func (s *Session) runningCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.running)
}

// track registers a cancellable operation so Cancel can reach it by id.
func (s *Session) track(id string, cancel context.CancelFunc) {
	s.mu.Lock()
	s.running[id] = cancel
	s.mu.Unlock()
}

func (s *Session) untrack(id string) {
	s.mu.Lock()
	delete(s.running, id)
	s.mu.Unlock()
}

// Cancel stops one in-flight operation. Cancelling something that has already
// finished is a no-op rather than an error: the user tapping "stop" just as
// the query lands is a race they should never see the losing side of.
func (s *Session) Cancel(opID string) bool {
	s.mu.Lock()
	cancel, ok := s.running[opID]
	s.mu.Unlock()
	if ok {
		cancel()
	}
	return ok
}

func (s *Session) cancelAll() {
	s.mu.Lock()
	for _, cancel := range s.running {
		cancel()
	}
	s.running = make(map[string]context.CancelFunc)
	s.mu.Unlock()
}

// guard enforces the read-only flag before a statement reaches the server.
//
// The server-side equivalent would be a read-only login, which is better and
// which the app recommends. This exists because most people will not have one,
// and a client-side guard that catches the accidental UPDATE-without-WHERE is
// worth having even though a determined user can turn it off.
func (s *Session) guard(sql string) error {
	if !s.Config.ReadOnly {
		return nil
	}
	if IsReadOnly(sql) {
		return nil
	}
	return fmt.Errorf("%w: %s is not permitted", ErrReadOnly, firstKeyword(sql))
}

package dbcore

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"runtime/debug"
	"strings"
)

// The app talks to this core through a single entrypoint that takes a JSON
// request and returns a JSON response.
//
// One entrypoint rather than a wide C API is a deliberate trade. Every
// additional exported symbol is another struct layout to keep in step between
// Go and Dart, and a mismatch there is a memory bug rather than a compile
// error. A JSON envelope costs a little encoding time — irrelevant next to a
// network round trip to a database — and in exchange the boundary has exactly
// one shape, which can be tested from either side without a phone.

// Request is one operation.
type Request struct {
	Op string `json:"op"`
	// ID is echoed back so the caller can match a response to its request
	// without relying on ordering.
	ID string `json:"id,omitempty"`

	SessionID string `json:"sessionId,omitempty"`
	// OpID names a cancellable execution. The app generates it before sending
	// so it can cancel a query that has not answered yet.
	OpID string `json:"opId,omitempty"`

	Config *Config `json:"config,omitempty"`

	SQL    string   `json:"sql,omitempty"`
	Args   []any    `json:"args,omitempty"`
	Schema string   `json:"schema,omitempty"`
	Table  string   `json:"table,omitempty"`
	Engine string   `json:"engine,omitempty"`
	Params []string `json:"params,omitempty"`

	// Cursor is a rune offset into SQL, for completion.
	Cursor int    `json:"cursor,omitempty"`
	Kind   string `json:"kind,omitempty"`

	MaxRows        int   `json:"maxRows,omitempty"`
	TimeoutSeconds int   `json:"timeoutSeconds,omitempty"`
	StopOnError    *bool `json:"stopOnError,omitempty"`
	Limit          int   `json:"limit,omitempty"`
}

// ErrorInfo carries a machine-readable code alongside the message, so the app
// can offer "reconnect" for a dropped session and "edit connection" for bad
// credentials instead of showing the same dead end for both.
type ErrorInfo struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Response is what comes back. Data is left as raw JSON so that adding a field
// to a payload does not require touching this envelope.
type Response struct {
	ID    string          `json:"id,omitempty"`
	OK    bool            `json:"ok"`
	Error *ErrorInfo      `json:"error,omitempty"`
	Data  json.RawMessage `json:"data,omitempty"`
}

// Error codes the app branches on.
const (
	CodeBadRequest   = "bad_request"
	CodeNoSession    = "no_session"
	CodeReadOnly     = "read_only"
	CodeValidation   = "validation"
	CodeConnect      = "connect_failed"
	CodeQuery        = "query_failed"
	CodeUnsupported  = "unsupported"
	CodeInternal     = "internal"
	CodeCancelled    = "cancelled"
	CodeUnknownOp    = "unknown_op"
	protocolVersion  = 1
	coreVersionLabel = "db-crawler-core/0.0.6"
)

// Handle decodes, dispatches, and encodes one request. It never returns an
// error: a failure is a Response with OK false, because the FFI boundary has
// no other channel to report one through.
func (m *Manager) Handle(ctx context.Context, raw []byte) []byte {
	var req Request
	if err := json.Unmarshal(raw, &req); err != nil {
		return encode(Response{OK: false, Error: &ErrorInfo{
			Code:    CodeBadRequest,
			Message: "malformed request: " + err.Error(),
		}})
	}
	resp := m.dispatch(ctx, req)
	resp.ID = req.ID
	return encode(resp)
}

// dispatch runs one operation, converting a panic into an error response.
//
// A panic crossing the FFI boundary does not unwind into Dart — it takes the
// whole process down, losing the user's editor buffer along with it. Turning
// it into a normal error keeps a driver bug on some unusual column type from
// costing them their unsaved work.
func (m *Manager) dispatch(ctx context.Context, req Request) (resp Response) {
	defer func() {
		if r := recover(); r != nil {
			resp = fail(CodeInternal, fmt.Sprintf("internal error in %q: %v\n%s",
				req.Op, r, debug.Stack()))
		}
	}()

	switch req.Op {
	case "ping":
		return ok(map[string]any{
			"version":         coreVersionLabel,
			"protocolVersion": protocolVersion,
		})

	case "engines":
		return ok(describeEngines())

	case "validateConfig":
		if req.Config == nil {
			return fail(CodeBadRequest, "config is required")
		}
		problems := req.Config.Validate()
		dsn := ""
		if len(problems) == 0 {
			// The redacted DSN is shown in the connection editor so the user
			// can see exactly what will be dialled, without the password.
			redacted, _ := req.Config.Redacted().DSN()
			dsn = redacted
		}
		return ok(map[string]any{"problems": problems, "dsn": dsn})

	case "openConnection":
		if req.Config == nil {
			return fail(CodeBadRequest, "config is required")
		}
		s, err := m.Open(ctx, *req.Config)
		if err != nil {
			return failFromError(err, CodeConnect)
		}
		return ok(map[string]any{
			"sessionId": s.ID,
			"engine":    s.Engine,
			"readOnly":  s.Config.ReadOnly,
		})

	case "testConnection":
		if req.Config == nil {
			return fail(CodeBadRequest, "config is required")
		}
		s, err := m.Open(ctx, *req.Config)
		if err != nil {
			return failFromError(err, CodeConnect)
		}
		version, _ := s.serverVersion(ctx)
		m.Close(s.ID)
		return ok(map[string]any{"reachable": true, "serverVersion": version})

	case "databasesFor":
		// Lists the databases on a server the app is not connected to, so the
		// connection editor can offer them rather than making someone recall a
		// name and type it exactly right on a phone keyboard.
		if req.Config == nil {
			return fail(CodeBadRequest, "config is required")
		}
		if req.Config.Engine == SQLite {
			// A SQLite connection is a file, not a server. Nothing to list.
			return ok(map[string]any{"databases": []string{}})
		}
		probe, err := m.Open(ctx, req.Config.ForEnumeration())
		if err != nil {
			return failFromError(err, CodeConnect)
		}
		names, err := probe.Databases(ctx)
		m.Close(probe.ID)
		if err != nil {
			return failFromError(err, CodeQuery)
		}
		return ok(map[string]any{"databases": names})

	case "closeConnection":
		if err := m.Close(req.SessionID); err != nil {
			return failFromError(err, CodeInternal)
		}
		return ok(map[string]any{"closed": true})

	case "closeAll":
		m.CloseAll()
		return ok(map[string]any{"closed": true})

	case "listConnections":
		return ok(m.List())

	case "cancel":
		s, err := m.Get(req.SessionID)
		if err != nil {
			return failFromError(err, CodeNoSession)
		}
		return ok(map[string]any{"cancelled": s.Cancel(req.OpID)})

	case "execute":
		s, err := m.Get(req.SessionID)
		if err != nil {
			return failFromError(err, CodeNoSession)
		}
		stopOnError := true
		if req.StopOnError != nil {
			stopOnError = *req.StopOnError
		}
		results, err := s.Execute(ctx, req.SQL, req.Args, QueryOptions{
			MaxRows:        req.MaxRows,
			TimeoutSeconds: req.TimeoutSeconds,
			OpID:           req.OpID,
			StopOnError:    stopOnError,
		})
		if err != nil {
			return failFromError(err, CodeQuery)
		}
		return ok(map[string]any{"results": results})

	case "databases":
		return m.withSession(req, func(s *Session) Response {
			names, err := s.Databases(ctx)
			if err != nil {
				return failFromError(err, CodeQuery)
			}
			return ok(map[string]any{"databases": names})
		})

	case "schemas":
		return m.withSession(req, func(s *Session) Response {
			names, err := s.Schemas(ctx)
			if err != nil {
				return failFromError(err, CodeQuery)
			}
			return ok(map[string]any{
				"schemas":         names,
				"supportsSchemas": s.Engine.SupportsSchemas(),
			})
		})

	case "tables":
		return m.withSession(req, func(s *Session) Response {
			// Tables, views, functions, and procedures in one list; the
			// explorer filters by kind rather than making four round trips.
			objects, err := s.Objects(ctx, req.Schema)
			if err != nil {
				return failFromError(err, CodeQuery)
			}
			return ok(map[string]any{"tables": objects})
		})

	case "routineDefinition":
		return m.withSession(req, func(s *Session) Response {
			if req.Table == "" {
				return fail(CodeBadRequest, "name is required")
			}
			def, err := s.RoutineDefinition(ctx, req.Schema, req.Table, req.Kind)
			if err != nil {
				return failFromError(err, CodeQuery)
			}
			return ok(map[string]any{"definition": def})
		})

	case "complete":
		return m.withSession(req, func(s *Session) Response {
			return ok(s.Complete(ctx, req.SQL, req.Cursor))
		})

	case "table":
		return m.withSession(req, func(s *Session) Response {
			if req.Table == "" {
				return fail(CodeBadRequest, "table is required")
			}
			detail, err := s.Table(ctx, req.Schema, req.Table)
			if err != nil {
				return failFromError(err, CodeQuery)
			}
			return ok(detail)
		})

	case "previewSql":
		return m.withSession(req, func(s *Session) Response {
			return ok(map[string]any{
				"preview": s.PreviewSQL(req.Schema, req.Table, req.Limit),
				"count":   s.CountSQL(req.Schema, req.Table),
			})
		})

	case "splitStatements":
		// Pure text work, so it needs no session — the editor calls it on
		// every keystroke pause to know which statement the cursor is in.
		engine, err := ParseEngine(orDefault(req.Engine, string(PostgreSQL)))
		if err != nil {
			return fail(CodeValidation, err.Error())
		}
		statements := SplitStatements(engine, req.SQL)
		kinds := make([]StatementKind, len(statements))
		readOnly := make([]bool, len(statements))
		for i, st := range statements {
			kinds[i] = Classify(st.Text)
			readOnly[i] = IsReadOnly(st.Text)
		}
		return ok(map[string]any{
			"statements": statements,
			"kinds":      kinds,
			"readOnly":   readOnly,
		})
	}

	return fail(CodeUnknownOp, fmt.Sprintf("unknown operation %q", req.Op))
}

func (m *Manager) withSession(req Request, fn func(*Session) Response) Response {
	s, err := m.Get(req.SessionID)
	if err != nil {
		return failFromError(err, CodeNoSession)
	}
	return fn(s)
}

// serverVersion asks the server what it is, for the connection test screen.
// A failure here is not a failure of the connection, so the caller ignores it.
func (s *Session) serverVersion(ctx context.Context) (string, error) {
	var query string
	switch s.Engine {
	case SQLServer:
		query = "SELECT @@VERSION"
	case PostgreSQL:
		query = "SELECT version()"
	case MySQL:
		query = "SELECT VERSION()"
	case SQLite:
		query = "SELECT sqlite_version()"
	default:
		return "", fmt.Errorf("unsupported engine %q", s.Engine)
	}
	var v string
	if err := s.db.QueryRowContext(ctx, query).Scan(&v); err != nil {
		return "", err
	}
	// SQL Server's @@VERSION is a multi-line banner; the first line is the
	// part worth showing on a phone.
	if i := strings.IndexByte(v, '\n'); i > 0 {
		v = strings.TrimSpace(v[:i])
	}
	return v, nil
}

// engineDescriptor tells the connection editor which fields to show and what
// to pre-fill, so the form is driven by the core rather than duplicated in the
// UI and drifting from it.
type engineDescriptor struct {
	ID          Engine   `json:"id"`
	Label       string   `json:"label"`
	DefaultPort int      `json:"defaultPort"`
	UsesFile    bool     `json:"usesFile"`
	UsesSchemas bool     `json:"usesSchemas"`
	TLSModes    []string `json:"tlsModes"`
}

func describeEngines() []engineDescriptor {
	networked := []string{"disable", "prefer", "require", "verify"}
	return []engineDescriptor{
		{SQLServer, "SQL Server / Azure SQL", 1433, false, true, networked},
		{PostgreSQL, "PostgreSQL", 5432, false, true, networked},
		{MySQL, "MySQL / MariaDB", 3306, false, false, networked},
		{SQLite, "SQLite", 0, true, false, nil},
	}
}

func orDefault(v, fallback string) string {
	if strings.TrimSpace(v) == "" {
		return fallback
	}
	return v
}

func ok(data any) Response {
	encoded, err := json.Marshal(data)
	if err != nil {
		return fail(CodeInternal, "could not encode response: "+err.Error())
	}
	return Response{OK: true, Data: encoded}
}

func fail(code, message string) Response {
	return Response{OK: false, Error: &ErrorInfo{Code: code, Message: message}}
}

// failFromError maps the sentinel errors onto their codes so the app can react
// to the kind of failure, falling back to the caller's guess otherwise.
func failFromError(err error, fallback string) Response {
	switch {
	case errors.Is(err, ErrNoSession):
		return fail(CodeNoSession, err.Error())
	case errors.Is(err, ErrReadOnly):
		return fail(CodeReadOnly, err.Error())
	case errors.Is(err, context.Canceled):
		return fail(CodeCancelled, "cancelled")
	}
	return fail(fallback, err.Error())
}

func encode(r Response) []byte {
	out, err := json.Marshal(r)
	if err != nil {
		// Marshalling a Response can only fail on the Data field, which was
		// already validated by ok(). This is the last resort.
		return []byte(`{"ok":false,"error":{"code":"internal","message":"response encoding failed"}}`)
	}
	return out
}

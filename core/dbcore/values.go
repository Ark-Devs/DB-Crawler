package dbcore

import (
	"encoding/base64"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// ValueKind tells the results grid how to render and align a column, and how
// an export should re-type it. It is carried per column rather than per cell
// so that a column of a million rows costs one label, not a million.
type ValueKind string

const (
	KindString   ValueKind = "string"
	KindNumber   ValueKind = "number"
	KindBool     ValueKind = "bool"
	KindDateTime ValueKind = "datetime"
	KindDate     ValueKind = "date"
	KindTime     ValueKind = "time"
	KindBytes    ValueKind = "bytes"
	KindJSON     ValueKind = "json"
	KindUUID     ValueKind = "uuid"
	KindUnknown  ValueKind = "unknown"
)

// Every cell crosses the FFI boundary as either JSON null or a JSON string.
//
// That looks lossy and is the opposite. Sending numbers as JSON numbers means
// routing them through a float64, which silently destroys DECIMAL(19,4) — the
// type every price and every ledger balance is stored in. A string plus the
// column's ValueKind keeps the exact digits the database returned while still
// telling the grid to right-align it and an export to write it unquoted.
//
// It also makes NULL unambiguous: JSON null is NULL, "" is the empty string,
// and no amount of driver-specific coercion can blur the two.

// kindForDatabaseType classifies a column from the type name the driver
// reports. Names are matched loosely because the same logical type is spelled
// differently by every engine — and by the same engine across versions.
func kindForDatabaseType(dbType string) ValueKind {
	t := strings.ToUpper(strings.TrimSpace(dbType))
	// Strip any length or precision suffix: VARCHAR(200) -> VARCHAR.
	if i := strings.IndexByte(t, '('); i > 0 {
		t = t[:i]
	}
	t = strings.TrimSpace(strings.TrimPrefix(t, "_"))

	switch t {
	case "BOOL", "BOOLEAN", "BIT":
		return KindBool
	case "UUID", "UNIQUEIDENTIFIER", "UNIQUEIDENTIFIER ":
		return KindUUID
	case "JSON", "JSONB":
		return KindJSON
	case "DATE":
		return KindDate
	case "TIME", "TIMETZ", "TIME WITH TIME ZONE", "TIME WITHOUT TIME ZONE":
		return KindTime
	}

	switch {
	case strings.Contains(t, "TIMESTAMP"), strings.Contains(t, "DATETIME"),
		t == "SMALLDATETIME", t == "DATETIMEOFFSET":
		return KindDateTime
	case strings.Contains(t, "INT"), // INT, BIGINT, SMALLINT, TINYINT, INTEGER, INT8
		strings.Contains(t, "DECIMAL"), strings.Contains(t, "NUMERIC"),
		strings.Contains(t, "MONEY"), strings.Contains(t, "FLOAT"),
		strings.Contains(t, "DOUBLE"), strings.Contains(t, "REAL"),
		t == "NUMBER", t == "SERIAL", t == "BIGSERIAL", t == "SMALLSERIAL":
		return KindNumber
	case strings.Contains(t, "BLOB"), strings.Contains(t, "BINARY"),
		t == "BYTEA", t == "IMAGE":
		return KindBytes
	case strings.Contains(t, "CHAR"), strings.Contains(t, "TEXT"),
		t == "XML", t == "CLOB", t == "ENUM", t == "SET", t == "NAME", t == "CITEXT":
		return KindString
	case t == "":
		return KindUnknown
	}
	return KindString
}

// Cell is the JSON-ready form of one scanned value: nil means SQL NULL.
type Cell *string

func cell(s string) Cell { return &s }

// convertValue turns whatever the driver handed back into the string form the
// app renders, and reports the kind it actually turned out to be. The declared
// column kind is passed in because it is the only way to tell a []byte that is
// really a DECIMAL from one that is really a JPEG.
func convertValue(v any, declared ValueKind) (Cell, ValueKind) {
	switch x := v.(type) {
	case nil:
		return nil, declared

	case bool:
		if x {
			return cell("true"), KindBool
		}
		return cell("false"), KindBool

	case string:
		return cell(x), declared

	case []byte:
		return convertBytes(x, declared)

	case time.Time:
		return cell(formatTime(x, declared)), declared

	case int64:
		return cell(strconv.FormatInt(x, 10)), KindNumber
	case int32:
		return cell(strconv.FormatInt(int64(x), 10)), KindNumber
	case int:
		return cell(strconv.Itoa(x)), KindNumber
	case uint64:
		return cell(strconv.FormatUint(x, 10)), KindNumber
	case float64:
		return cell(formatFloat(x)), KindNumber
	case float32:
		return cell(formatFloat(float64(x))), KindNumber

	case fmt.Stringer:
		// Covers driver-specific decimal and UUID wrappers, which all render
		// themselves exactly and would lose digits through a float.
		return cell(x.String()), declared
	}
	return cell(fmt.Sprintf("%v", v)), declared
}

// convertBytes decides whether a []byte is text the user wants to read or
// binary they want to know the size of.
//
// Drivers return []byte for a great deal that is not binary: MySQL returns it
// for DECIMAL, SQL Server for DECIMAL and MONEY, several return it for CHAR.
// Base64-encoding a price would be a bug the user only notices at the till.
func convertBytes(b []byte, declared ValueKind) (Cell, ValueKind) {
	switch declared {
	case KindBytes:
		return cell(base64.StdEncoding.EncodeToString(b)), KindBytes
	case KindNumber, KindString, KindJSON, KindUUID, KindDate, KindTime, KindDateTime:
		return cell(string(b)), declared
	}
	// Unknown type name: fall back to inspecting the bytes. Valid UTF-8 with
	// no control characters is text; anything else is treated as binary.
	if utf8.Valid(b) && !hasControlBytes(b) {
		return cell(string(b)), KindString
	}
	return cell(base64.StdEncoding.EncodeToString(b)), KindBytes
}

func hasControlBytes(b []byte) bool {
	for _, c := range b {
		if c < 0x09 || (c > 0x0d && c < 0x20) {
			return true
		}
	}
	return false
}

// formatTime renders a timestamp in the narrowest form that keeps its meaning,
// so a DATE column does not show a misleading midnight and a TIME column does
// not show a meaningless 1st of January year 1.
func formatTime(t time.Time, declared ValueKind) string {
	switch declared {
	case KindDate:
		return t.Format("2006-01-02")
	case KindTime:
		return t.Format("15:04:05.999999999")
	}
	return t.Format(time.RFC3339Nano)
}

// formatFloat prints a float without an exponent where one is not needed, and
// without the trailing noise that %v produces. Infinities and NaN have no JSON
// representation, so they are spelled out rather than dropped.
func formatFloat(f float64) string {
	switch {
	case math.IsNaN(f):
		return "NaN"
	case math.IsInf(f, 1):
		return "Infinity"
	case math.IsInf(f, -1):
		return "-Infinity"
	}
	// Plain decimal across the range a person reading a data grid expects to
	// see one, scientific notation only outside it. The %g default renders an
	// order total of 12345678901234.57 as 1.2345678901234568e+13 — correct,
	// unreadable, and not what the database shows.
	abs := math.Abs(f)
	if f == 0 || (abs >= 1e-4 && abs < 1e15) {
		return strconv.FormatFloat(f, 'f', -1, 64)
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}

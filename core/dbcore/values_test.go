package dbcore

import (
	"testing"
	"time"
)

func TestKindForDatabaseType(t *testing.T) {
	tests := []struct {
		dbType string
		want   ValueKind
	}{
		// SQL Server
		{"NVARCHAR", KindString},
		{"NVARCHAR(200)", KindString},
		{"DECIMAL", KindNumber},
		{"MONEY", KindNumber},
		{"SMALLMONEY", KindNumber},
		{"BIT", KindBool},
		{"UNIQUEIDENTIFIER", KindUUID},
		{"DATETIME2", KindDateTime},
		{"DATETIMEOFFSET", KindDateTime},
		{"SMALLDATETIME", KindDateTime},
		{"VARBINARY", KindBytes},
		{"IMAGE", KindBytes},
		// PostgreSQL
		{"int4", KindNumber},
		{"int8", KindNumber},
		{"numeric", KindNumber},
		{"bool", KindBool},
		{"uuid", KindUUID},
		{"jsonb", KindJSON},
		{"timestamptz", KindDateTime},
		{"bytea", KindBytes},
		{"text", KindString},
		{"citext", KindString},
		// MySQL
		{"TINYINT", KindNumber},
		{"BIGINT UNSIGNED", KindNumber},
		{"DECIMAL(19,4)", KindNumber},
		{"DATETIME", KindDateTime},
		{"DATE", KindDate},
		{"TIME", KindTime},
		{"BLOB", KindBytes},
		{"LONGBLOB", KindBytes},
		{"ENUM", KindString},
		// SQLite
		{"INTEGER", KindNumber},
		{"REAL", KindNumber},
		{"", KindUnknown},
	}
	for _, tc := range tests {
		t.Run(tc.dbType, func(t *testing.T) {
			if got := kindForDatabaseType(tc.dbType); got != tc.want {
				t.Errorf("kindForDatabaseType(%q) = %q, want %q", tc.dbType, got, tc.want)
			}
		})
	}
}

func deref(c Cell) string {
	if c == nil {
		return "<nil>"
	}
	return *c
}

func TestConvertValue(t *testing.T) {
	t.Run("null stays distinct from empty string", func(t *testing.T) {
		null, _ := convertValue(nil, KindString)
		if null != nil {
			t.Errorf("NULL became %q, want nil", deref(null))
		}
		empty, _ := convertValue("", KindString)
		if empty == nil || *empty != "" {
			t.Errorf("empty string became %v, want a pointer to \"\"", deref(empty))
		}
	})

	t.Run("decimal bytes keep every digit", func(t *testing.T) {
		// MySQL and SQL Server both hand back DECIMAL as bytes. Routing this
		// through a float64 would round it, and this is what a price column
		// looks like.
		got, kind := convertValue([]byte("12345678901234.5678"), KindNumber)
		if deref(got) != "12345678901234.5678" {
			t.Errorf("got %q, want the exact digits back", deref(got))
		}
		if kind != KindNumber {
			t.Errorf("kind = %q, want number", kind)
		}
	})

	t.Run("binary is base64, not mangled text", func(t *testing.T) {
		got, kind := convertValue([]byte{0x00, 0x01, 0xff}, KindBytes)
		if deref(got) != "AAH/" {
			t.Errorf("got %q, want base64 AAH/", deref(got))
		}
		if kind != KindBytes {
			t.Errorf("kind = %q, want bytes", kind)
		}
	})

	t.Run("untyped bytes are sniffed", func(t *testing.T) {
		text, kind := convertValue([]byte("hello"), KindUnknown)
		if deref(text) != "hello" || kind != KindString {
			t.Errorf("got (%q, %q), want (hello, string)", deref(text), kind)
		}
		binary, kind := convertValue([]byte{0x00, 0x01, 0x02}, KindUnknown)
		if kind != KindBytes {
			t.Errorf("kind = %q, want bytes for control bytes", kind)
		}
		if deref(binary) != "AAEC" {
			t.Errorf("got %q, want base64", deref(binary))
		}
	})

	t.Run("booleans", func(t *testing.T) {
		yes, kind := convertValue(true, KindBool)
		if deref(yes) != "true" || kind != KindBool {
			t.Errorf("got (%q, %q)", deref(yes), kind)
		}
		no, _ := convertValue(false, KindBool)
		if deref(no) != "false" {
			t.Errorf("got %q, want false", deref(no))
		}
	})

	t.Run("integers do not gain a decimal point", func(t *testing.T) {
		got, kind := convertValue(int64(42), KindNumber)
		if deref(got) != "42" || kind != KindNumber {
			t.Errorf("got (%q, %q), want (42, number)", deref(got), kind)
		}
	})

	t.Run("large int64 survives", func(t *testing.T) {
		// 9007199254740993 is the first integer a float64 cannot represent.
		got, _ := convertValue(int64(9007199254740993), KindNumber)
		if deref(got) != "9007199254740993" {
			t.Errorf("got %q, want 9007199254740993", deref(got))
		}
	})

	t.Run("timestamps render by declared precision", func(t *testing.T) {
		ts := time.Date(2026, 8, 8, 14, 30, 15, 0, time.UTC)
		full, _ := convertValue(ts, KindDateTime)
		if deref(full) != "2026-08-08T14:30:15Z" {
			t.Errorf("datetime = %q", deref(full))
		}
		// A DATE column showing a midnight time reads as data it does not have.
		onlyDate, _ := convertValue(ts, KindDate)
		if deref(onlyDate) != "2026-08-08" {
			t.Errorf("date = %q, want 2026-08-08", deref(onlyDate))
		}
		onlyTime, _ := convertValue(ts, KindTime)
		if deref(onlyTime) != "14:30:15" {
			t.Errorf("time = %q, want 14:30:15", deref(onlyTime))
		}
	})

	t.Run("floats print without exponent noise", func(t *testing.T) {
		got, _ := convertValue(float64(1.5), KindNumber)
		if deref(got) != "1.5" {
			t.Errorf("got %q, want 1.5", deref(got))
		}
	})
}

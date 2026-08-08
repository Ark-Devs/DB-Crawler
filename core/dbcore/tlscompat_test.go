package dbcore

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"os"
	"testing"
	"time"
)

// SQL Server's auto-generated self-signed certificate routinely has a serial
// number whose leading bit is set, which DER reads as negative. Go 1.23 began
// rejecting those while parsing, which kills the TLS handshake before
// verification is reached — so TrustServerCertificate does not rescue it, and
// the connection simply cannot be made.
//
// The fix is a //go:debug x509negativeserial=1 directive in each main package.
// These tests pin down both halves: that the rejection is real and looks like
// what users report, and that the directive is still present in the binaries
// that ship.

// negativeSerialCertificate builds a DER certificate whose serial number is
// negative.
//
// It has to be assembled by hand because x509.CreateCertificate refuses to
// issue one ("serial number must be positive"), so the top bit of an
// otherwise ordinary serial is flipped after the fact. Parsing does not check
// the signature, which is the only thing that invalidates.
func negativeSerialCertificate(t *testing.T) []byte {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(0x11223344),
		Subject:      pkix.Name{CommonName: "SSL_Self_Signed_Fallback"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}

	// INTEGER, 4 bytes, 0x11223344. Setting the top bit of the first content
	// byte is what makes a DER integer negative.
	marker := []byte{0x02, 0x04, 0x11, 0x22, 0x33, 0x44}
	i := bytes.Index(der, marker)
	if i < 0 {
		t.Fatal("could not find the serial number in the generated certificate")
	}
	der[i+2] = 0x91
	return der
}

func TestNegativeSerialIsRejectedByDefault(t *testing.T) {
	// Guards the premise. If a future Go drops the check, the workaround and
	// its directives can go, and this test failing is how we find out.
	t.Setenv("GODEBUG", "x509negativeserial=0")

	_, err := x509.ParseCertificate(negativeSerialCertificate(t))
	if err == nil {
		t.Skip("this Go no longer rejects negative serial numbers; the " +
			"//go:debug directives in ffi and cmd/dbcrawler can be removed")
	}
	// The exact wording reaches the user, so it is worth pinning: this is the
	// string people will search for.
	if got := err.Error(); got != "x509: negative serial number" {
		t.Errorf("parse error = %q, want %q", got, "x509: negative serial number")
	}
}

func TestNegativeSerialParsesWithTheCompatibilitySetting(t *testing.T) {
	t.Setenv("GODEBUG", "x509negativeserial=1")

	if _, err := x509.ParseCertificate(negativeSerialCertificate(t)); err != nil {
		t.Fatalf("x509negativeserial=1 should allow this certificate, got: %v", err)
	}
}

func TestShippedBinariesSetTheCompatibilityDirective(t *testing.T) {
	// A //go:debug directive is invisible to the type checker and to every
	// other test: delete it and everything still compiles and passes, while
	// the app silently loses the ability to reach a large share of SQL Server
	// installations. The only cheap guard is to assert it is still written
	// down, in the main packages where it takes effect.
	//
	// It has to be repeated per main package because the setting applies to
	// the binary being linked, not to the library.
	mains := map[string]string{
		"../ffi/ffi.go":            "the library the mobile app links",
		"../cmd/dbcrawler/main.go": "the terminal harness",
	}
	for path, what := range mains {
		source, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("reading %s: %v", path, err)
		}
		if !bytes.Contains(source, []byte("//go:debug x509negativeserial=1")) {
			t.Errorf("%s (%s) is missing //go:debug x509negativeserial=1;"+
				" without it a TLS handshake against SQL Server's default"+
				" self-signed certificate fails with \"negative serial number\"",
				path, what)
		}
	}
}

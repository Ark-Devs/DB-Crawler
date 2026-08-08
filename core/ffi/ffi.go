// Command ffi builds the DB Crawler core as a native shared library that the
// Flutter app loads through dart:ffi.
//
// Build with:
//
//	go build -buildmode=c-shared -o libdbcrawler.so ./ffi     (Android)
//	go build -buildmode=c-archive -o libdbcrawler.a ./ffi     (iOS)
//
// See tool/build-core.sh, which drives this for every architecture the app
// ships.

// SQL Server's auto-generated self-signed certificate routinely carries a
// serial number whose leading bit is set, which DER reads as negative. Go 1.23
// began rejecting those at parse time, so the TLS handshake fails before
// verification is even reached — meaning TrustServerCertificate does not help
// and the connection cannot be made at all.
//
// This restores the pre-1.23 parsing behaviour. It relaxes a strictness check,
// not a trust check: whether the certificate is trusted is still decided by the
// connection's Encryption setting. The alternative is telling people to turn
// encryption off to reach their own database, which is far worse than accepting
// a malformed serial number.
//go:debug x509negativeserial=1

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"sync"
	"unsafe"

	"github.com/Ark-Devs/DB-Crawler/core/dbcore"
)

var (
	once    sync.Once
	manager *dbcore.Manager
)

func core() *dbcore.Manager {
	once.Do(func() { manager = dbcore.NewManager() })
	return manager
}

// dbcrawler_call runs one JSON request and returns a JSON response.
//
// The returned pointer is heap-allocated by C.CString and is owned by the
// caller: Dart must hand it back to dbcrawler_free once it has copied the
// bytes out. Returning Go memory instead would be a use-after-free the moment
// the garbage collector moved it.
//
//export dbcrawler_call
func dbcrawler_call(request *C.char) *C.char {
	if request == nil {
		return C.CString(`{"ok":false,"error":{"code":"bad_request","message":"null request"}}`)
	}
	response := core().Handle(context.Background(), []byte(C.GoString(request)))
	return C.CString(string(response))
}

// dbcrawler_free releases a string returned by dbcrawler_call.
//
//export dbcrawler_free
func dbcrawler_free(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

// dbcrawler_shutdown closes every open connection.
//
// Android does not reliably deliver a process-exit callback, so the app calls
// this when it is backgrounded for long enough that its sockets are dead
// anyway. Leaving them open would hold server-side sessions that no client is
// ever coming back for.
//
//export dbcrawler_shutdown
func dbcrawler_shutdown() {
	core().CloseAll()
}

func main() {}

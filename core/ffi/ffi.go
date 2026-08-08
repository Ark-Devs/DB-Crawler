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

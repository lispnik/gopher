## Calling the library from Swift (or C)

`make capi` builds two files that ship together:

- `capi/build/libgopher.dylib`: SBCL's runtime and a C shim (`capi/host.c`)
- `capi/build/gopher.core`: the Lisp image (about 50 MB), loaded at startup

`capi/gopher.h` is the whole interface. Every function takes and returns UTF-8
C strings, and every result is JSON.

```c
int   gopher_init(const char *core_path);           // once, at launch
char *gopher_fetch(const char *url, const char *options_json);
char *gopher_fetch_streaming(const char *url, const char *options_json,
                             gopher_lines_callback callback, void *context);
char *gopher_make_identity(const char *cert_path, const char *key_path,
                           const char *options_json);
int   gopher_cancel(long request_id);
void  gopher_free(char *json);
const char *gopher_version(void);
```

`gopher_fetch` returns `{"ok": true, "status": ..., "document": {"lines": [...]}, ...}`.
When there is no usable reply, it returns `{"ok": false, "error": {"type", "message"}}`.
The header documents every option and field.

### In an Xcode project

1. Add `libgopher.dylib` to the target with Embed & Sign, so it goes to
   `Contents/Frameworks`. Its install name is `@rpath/libgopher.dylib`.
2. Copy `gopher.core` into the bundle's Resources.
3. Add `gopher.h` to the bridging header, or wrap it in a module map.
4. At launch:

```swift
let core = Bundle.main.path(forResource: "gopher", ofType: "core")!
guard gopher_init(core) == 0 else { fatalError("gopher runtime failed to start") }
```

5. Fetch off the main thread, and decode with `JSONDecoder`:

```swift
func fetch(_ url: String, options: [String: Any] = [:]) async throws -> Data {
    try await Task.detached {
        let opts = String(data: try JSONSerialization.data(withJSONObject: options), encoding: .utf8)!
        guard let p = gopher_fetch(url, opts) else { throw GopherError.notInitialized }
        defer { gopher_free(p) }
        return Data(bytes: p, count: strlen(p))
    }.value
}
```

To cancel, pass `"request_id": n` in the options and call `gopher_cancel(n)`
from any thread. The fetch then returns an error of type `request-cancelled`.

To draw a page while it downloads, call `gopher_fetch_streaming` with a
callback. It receives JSON arrays of lines, the same lines the final
`document` holds, on the fetching thread. Copy the string and hop to the main
actor to render. To make a Gemini identity, call
`gopher_make_identity(certPath, keyPath, "{\"common_name\": \"me\"}")` and
pass the paths as `client_certificate` / `client_key`.

To handle a changed certificate, the first fetch returns `certificate-mismatch`
with both fingerprints. If the user accepts, fetch again with
`"accept_new_certificate": true`. Pass `"known_hosts": <path in Application
Support>` so trust survives a relaunch.

### How it works

`make capi` saves the image with `save-lisp-and-die :callable-exports`. When
`gopher_init` calls `initialize_lisp`, the core reinitialises itself (reopens
OpenSSL and so on). Then, instead of running a REPL, it stores the address of
each `define-alien-callable` in `capi/capi.lisp` into the C global of the
same name (`gopher_lisp_fetch`, …) and returns. The public C functions call
through those pointers. SBCL attaches any foreign thread (a Swift
`Task`, a pthread) the first time it calls in. No Lisp condition can unwind
into C; every callable catches everything and reports it as JSON.

The dylib is linked from the objects in SBCL's `libsbcl.a` (an SBCL built
with `--with-sb-linkable-runtime`), minus `main.o`. `gopher.core` must be
built by that same SBCL build, so rebuild both together.

`make capi-test` runs `capi/test.c` against a small Python Gopher server. It
covers init, a menu fetch, a server error, a connection error, bad options,
calls from new threads, concurrent fetches, cancelling from another thread,
streaming callbacks, the timeout, deadline and proxy options, and identities.

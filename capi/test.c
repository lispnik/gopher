/*
 * test.c -- exercise libgopher.dylib from C.
 *   usage: test CORE_PATH PORT
 * PORT is a running capi/test-server.py.
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "gopher.h"

static int failures = 0;
static pthread_mutex_t print_lock = PTHREAD_MUTEX_INITIALIZER;
static int port;

static void check(int ok, const char *what, const char *json)
{
    pthread_mutex_lock(&print_lock);
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        failures++;
        if (json) printf("     got: %s\n", json);
    }
    pthread_mutex_unlock(&print_lock);
}

static int contains(const char *json, const char *needle)
{
    return json && strstr(json, needle) != NULL;
}

static void *fetch_menu(void *arg)
{
    char url[128];
    char *json;
    (void)arg;
    snprintf(url, sizeof url, "gopher://127.0.0.1:%d/", port);
    json = gopher_fetch(url, NULL);
    check(contains(json, "\"ok\":true") && contains(json, "\"text\":\"Hello from C\"")
          && contains(json, "\"kind\":\"menu\""),
          "fetch from a thread Lisp has not seen", json);
    gopher_free(json);
    return NULL;
}

struct batches { int calls; char seen[512]; };

static void on_lines(void *context, const char *lines_json)
{
    struct batches *b = context;
    b->calls++;
    strncat(b->seen, lines_json, sizeof b->seen - strlen(b->seen) - 1);
}

static void *fetch_stall(void *arg)
{
    char url[128];
    char **out = arg;
    snprintf(url, sizeof url, "gopher://127.0.0.1:%d/1/stall", port);
    *out = gopher_fetch(url, "{\"request_id\": 42, \"timeout\": 20}");
    return NULL;
}

int main(int argc, char **argv)
{
    char url[128];
    char *json;
    pthread_t thread;

    if (argc < 3) {
        fprintf(stderr, "usage: %s CORE PORT\n", argv[0]);
        return 2;
    }
    port = atoi(argv[2]);

    check(gopher_fetch("gopher://x/", NULL) == NULL, "fetch before init returns NULL", NULL);
    check(gopher_cancel(1) == -1, "cancel before init returns -1", NULL);
    check(gopher_init(argv[1]) == 0, "gopher_init", NULL);
    check(gopher_init(argv[1]) == 0, "gopher_init again is a no-op", NULL);
    check(strcmp(gopher_version(), "0.1.0") == 0, "gopher_version", gopher_version());

    /* A real fetch with a document. */
    snprintf(url, sizeof url, "gopher://127.0.0.1:%d/", port);
    json = gopher_fetch(url, "{\"timeout\": 5}");
    check(contains(json, "\"status\":\"success\"") && contains(json, "\"text\":\"A text file\"")
          && contains(json, "\"item_kind\":\"text\""),
          "fetch a menu", json);
    gopher_free(json);

    /* A server error is still a response. */
    snprintf(url, sizeof url, "gopher://127.0.0.1:%d/1/missing", port);
    json = gopher_fetch(url, NULL);
    check(contains(json, "\"ok\":true") && contains(json, "\"status\":\"not-found\""),
          "not-found is a response, not an error", json);
    gopher_free(json);

    /* No server at all. */
    json = gopher_fetch("gopher://127.0.0.1:1/", "{\"timeout\": 2}");
    check(contains(json, "\"ok\":false") && contains(json, "\"type\":\"connection-error\""),
          "closed port is a connection-error", json);
    gopher_free(json);

    /* Bad input never crashes. */
    json = gopher_fetch("gopher://127.0.0.1:1/", "{not json");
    check(contains(json, "\"type\":\"json-error\""), "malformed options JSON", json);
    gopher_free(json);
    json = gopher_fetch("gopher://127.0.0.1:1/", "{\"verify\": \"maybe\"}");
    check(contains(json, "\"type\":\"json-error\""), "bad option value", json);
    gopher_free(json);
    json = gopher_fetch("https://example.org/", NULL);
    check(contains(json, "\"type\":\"unsupported-scheme\""), "unsupported scheme", json);
    gopher_free(json);
    json = gopher_fetch("", NULL);
    check(contains(json, "\"ok\":false"), "empty URL", json);
    gopher_free(json);

    /* Gopher search input arrives via the query option, UTF-8 intact. */
    snprintf(url, sizeof url, "gopher://127.0.0.1:%d/7/search", port);
    json = gopher_fetch(url, "{\"query\": null}");
    check(contains(json, "\"status\":\"input\""), "search without a query asks for input", json);
    gopher_free(json);

    /* A thread Lisp has never seen. */
    pthread_create(&thread, NULL, fetch_menu, NULL);
    pthread_join(thread, NULL);

    /* Cancel, from this thread, a fetch blocked in another. */
    {
        char *result = NULL;
        pthread_create(&thread, NULL, fetch_stall, &result);
        usleep(500000);
        check(gopher_cancel(42) == 1, "gopher_cancel finds the request", NULL);
        pthread_join(thread, NULL);
        check(contains(result, "\"type\":\"request-cancelled\""), "cancelled fetch reports it", result);
        gopher_free(result);
    }
    check(gopher_cancel(999) == 0, "cancel of an unknown id", NULL);

    /* Several threads at once. */
    {
        pthread_t threads[4];
        int i;
        for (i = 0; i < 4; i++) pthread_create(&threads[i], NULL, fetch_menu, NULL);
        for (i = 0; i < 4; i++) pthread_join(threads[i], NULL);
    }

    /* Streaming: lines arrive in several callbacks, before the reply. */
    {
        struct batches b = { 0, "" };
        snprintf(url, sizeof url, "gopher://127.0.0.1:%d/0/slow", port);
        json = gopher_fetch_streaming(url, NULL, on_lines, &b);
        check(contains(json, "\"ok\":true"), "streaming fetch succeeds", json);
        check(b.calls >= 2, "lines arrived in more than one callback", b.seen);
        check(contains(b.seen, "line 0") && contains(b.seen, "line 2") && !contains(b.seen, "\".\""),
              "streamed lines are the document's lines", b.seen);
        gopher_free(json);
        json = gopher_fetch_streaming(url, NULL, NULL, NULL);
        check(contains(json, "\"ok\":true"), "streaming with no callback", json);
        gopher_free(json);
    }

    /* New options reach FETCH. */
    snprintf(url, sizeof url, "gopher://127.0.0.1:%d/1/stall", port);
    json = gopher_fetch(url, "{\"read_timeout\": 1, \"connect_timeout\": 5}");
    check(contains(json, "\"type\":\"timeout-error\""), "read_timeout option", json);
    gopher_free(json);
    json = gopher_fetch(url, "{\"timeout\": 20, \"deadline\": 1}");
    check(contains(json, "\"type\":\"timeout-error\""), "deadline option", json);
    gopher_free(json);
    json = gopher_fetch("guppy://127.0.0.1/", "{\"proxy\": \"socks5://127.0.0.1:9\"}");
    check(contains(json, "\"type\":\"connection-error\""), "proxy option", json);
    gopher_free(json);

    /* Identities. */
    {
        char cert[] = "/tmp/gopher-capi-test-XXXXXX";
        char key[64];
        int fd = mkstemp(cert);
        close(fd);
        snprintf(key, sizeof key, "%s.key", cert);
        json = gopher_make_identity(cert, key, "{\"common_name\": \"capi\", \"days\": 7}");
        check(contains(json, "\"ok\":true") && contains(json, "\"fingerprint\":\"sha256:"),
              "make an identity", json);
        gopher_free(json);
        json = gopher_make_identity(cert, key, "{\"key_type\": \"dsa\"}");
        check(contains(json, "\"type\":\"json-error\""), "bad key_type is reported", json);
        gopher_free(json);
        unlink(cert);
        unlink(key);
    }

    printf("%s (%d failure%s)\n", failures ? "FAILED" : "PASSED", failures,
           failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}

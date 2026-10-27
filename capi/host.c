/*
 * host.c -- the C side of libgopher.dylib.
 *
 * The three function pointers below are filled in by the Lisp core as it
 * starts: the core was saved with :callable-exports naming them, and SBCL
 * writes each callable's address into the C global of the same name before
 * initialize_lisp returns.  The public functions just call through them.
 */
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include "gopher.h"

extern int initialize_lisp(int argc, char *argv[], char *envp[]);
extern char **environ;

char *(*gopher_lisp_fetch)(const char *, const char *) = NULL;
char *(*gopher_lisp_fetch_streaming)(const char *, const char *, gopher_lines_callback, void *) = NULL;
char *(*gopher_lisp_make_identity)(const char *, const char *, const char *) = NULL;
int (*gopher_lisp_cancel)(long) = NULL;
char *(*gopher_lisp_version)(void) = NULL;

static pthread_mutex_t init_lock = PTHREAD_MUTEX_INITIALIZER;
static int initialized = 0;

int gopher_init(const char *core_path)
{
    /* initialize_lisp keeps pointers into argv, so it must outlive the call. */
    static char *argv[8];
    int result;

    pthread_mutex_lock(&init_lock);
    if (!initialized && core_path != NULL) {
        argv[0] = "libgopher";
        argv[1] = "--core";
        argv[2] = strdup(core_path);
        argv[3] = "--noinform";
        argv[4] = "--disable-ldb";
        argv[5] = "--lose-on-corruption";
        argv[6] = "--end-runtime-options";
        argv[7] = NULL;
        initialize_lisp(7, argv, environ);
        initialized = gopher_lisp_fetch != NULL && gopher_lisp_cancel != NULL
            && gopher_lisp_version != NULL && gopher_lisp_fetch_streaming != NULL
            && gopher_lisp_make_identity != NULL;
    }
    result = initialized ? 0 : -1;
    pthread_mutex_unlock(&init_lock);
    return result;
}

char *gopher_fetch(const char *url, const char *options_json)
{
    if (!initialized)
        return NULL;
    return gopher_lisp_fetch(url ? url : "", options_json ? options_json : "{}");
}

char *gopher_fetch_streaming(const char *url, const char *options_json,
                             gopher_lines_callback callback, void *context)
{
    if (!initialized)
        return NULL;
    return gopher_lisp_fetch_streaming(url ? url : "", options_json ? options_json : "{}",
                                       callback, context);
}

char *gopher_make_identity(const char *certificate_path, const char *key_path,
                           const char *options_json)
{
    if (!initialized)
        return NULL;
    return gopher_lisp_make_identity(certificate_path ? certificate_path : "",
                                     key_path ? key_path : "",
                                     options_json ? options_json : "{}");
}

int gopher_cancel(long id)
{
    if (!initialized)
        return -1;
    return gopher_lisp_cancel(id);
}

void gopher_free(char *string)
{
    free(string);
}

const char *gopher_version(void)
{
    static char *version = NULL;
    static pthread_mutex_t version_lock = PTHREAD_MUTEX_INITIALIZER;
    const char *result;

    if (!initialized)
        return "unknown";
    pthread_mutex_lock(&version_lock);
    if (version == NULL)
        version = gopher_lisp_version();
    result = version;
    pthread_mutex_unlock(&version_lock);
    return result;
}

/* Stub implementations for Qt WASM threading functions.
 * Qt6 is built with -feature-thread but Pyodide runs single-threaded.
 * These stubs prevent infinite recursion from auto-generated Emscripten stubs.
 */

#include <errno.h>
#include <semaphore.h>
#include <sched.h>
#include <pthread.h>

int pthread_setschedparam(pthread_t thread, int policy,
                          const struct sched_param *param) {
    (void)thread; (void)policy; (void)param;
    return ENOSYS;
}

int sched_get_priority_max(int policy) {
    (void)policy;
    return 0;
}

int sched_get_priority_min(int policy) {
    (void)policy;
    return 0;
}

int sem_timedwait(sem_t *sem, const struct timespec *abs_timeout) {
    (void)sem; (void)abs_timeout;
    return -1;
}

/* IndexedDB stubs — Qt uses these for persistent storage but they require
 * Emscripten's ASYNCIFY or Emscripten-provided JS implementations.
 * In single-threaded Pyodide without ASYNCIFY, we stub them as no-ops. */
void emscripten_idb_load(const char *db, const char *key, void **pbuf,
                         int *pnum, int *perror) {
    (void)db; (void)key; (void)pbuf; (void)pnum;
    if (perror) *perror = 1;
}

void emscripten_idb_store(const char *db, const char *key, void *buf,
                          int num, int *perror) {
    (void)db; (void)key; (void)buf; (void)num;
    if (perror) *perror = 1;
}

void emscripten_idb_delete(const char *db, const char *key, int *perror) {
    (void)db; (void)key;
    if (perror) *perror = 1;
}

int emscripten_idb_exists(const char *db, const char *key, int *pexists,
                          int *perror) {
    (void)db; (void)key;
    if (pexists) *pexists = 0;
    if (perror) *perror = 0;
    return 0;
}

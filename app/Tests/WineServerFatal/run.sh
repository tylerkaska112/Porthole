#!/bin/bash
# A wineserver that dies while starting must stop reading as running (Runtime/WineServerBridge.m, fatal_error).
# Takes the production fatal_error(), the flag's declaration and wineserver_is_running() out of the source, compiles them with a stand-in for the logger, and calls fatal_error from a
# thread the way the server thread does. Fails with the old source (the flag was cleared only when wineserver_main returned, which pthread_exit skips).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../Runtime/WineServerBridge.m"
OUT="$(mktemp -d)"
python3 -I - "$SRC" "$OUT/extracted.c" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
decl = 'static volatile int g_wineserver_running = 0;\n'
def func(sig):
    i = src.index(sig)
    j = src.index('\n}\n', i) + 3
    return i, src[i:j]
di = src.index(decl)
fi, fatal = func('void fatal_error( const char *err, ... ) {')
ri, running = func('int wineserver_is_running(void) {')
if not di < fi:
    print('FAIL: the flag is declared after fatal_error, which uses it'); sys.exit(1)
open(sys.argv[2], 'w').write(decl + fatal + '\n' + running)
PY
cat > "$OUT/main.c" <<'C'
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
static void wine_log_msg_impl(const char *fmt, ...) { (void)fmt; }
#include "extracted.c"
static void *server_thread(void *arg) { (void)arg; fatal_error("bind: %s", "Operation not permitted"); return NULL; }
int main(void) {
    g_wineserver_running = 1;                          // what wineserver_start() sets before it creates the thread
    pthread_t t; pthread_create(&t, NULL, server_thread, NULL); pthread_join(t, NULL);
    if (wineserver_is_running() != 0) { printf("FAIL: a server that died at start-up still reads as running\n"); return 1; }
    printf("ok:   a server that died at start-up no longer reads as running\n");
    return 0;
}
C
clang -Wall -Werror -o "$OUT/t" "$OUT/main.c" -I"$OUT" -lpthread
"$OUT/t" && echo "ALL PASSED"
rm -rf "$OUT"

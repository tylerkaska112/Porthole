// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
#include "itch_rar.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// The libarchive 3 C API, by name. The opaque pointers are all this file needs of its types.
typedef struct archive archive_t;
typedef struct archive_entry entry_t;
#define A_OK 0
#define A_EOF 1
#define A_WARN (-20)

static struct {
    archive_t *(*read_new)(void);
    int (*support_rar)(archive_t *);
    int (*support_rar5)(archive_t *);
    int (*open_filename)(archive_t *, const char *, size_t);
    int (*next_header)(archive_t *, entry_t **);
    int (*data_block)(archive_t *, const void **, size_t *, int64_t *);
    int (*data_skip)(archive_t *);
    int (*read_free)(archive_t *);
    const char *(*error_string)(archive_t *);
    const char *(*entry_pathname)(entry_t *);
    const char *(*entry_pathname_utf8)(entry_t *);
    unsigned int (*entry_filetype)(entry_t *);
    int64_t (*entry_size)(entry_t *);
    int (*entry_size_is_set)(entry_t *);
    int (*entry_is_encrypted)(entry_t *);
    const char *(*entry_symlink)(entry_t *);
    const char *(*entry_hardlink)(entry_t *);
    int loaded;
} lib;

static pthread_once_t once = PTHREAD_ONCE_INIT;

static void load(void) {
    void *h = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW);
    if (!h) h = dlopen("libarchive.dylib", RTLD_NOW);
    if (!h) return;
#define NEED(field, name) do { *(void **)&lib.field = dlsym(h, name); if (!lib.field) return; } while (0)
#define MAYBE(field, name) (*(void **)&lib.field = dlsym(h, name))
    NEED(read_new, "archive_read_new");
    NEED(support_rar, "archive_read_support_format_rar");
    NEED(open_filename, "archive_read_open_filename");
    NEED(next_header, "archive_read_next_header");
    NEED(data_block, "archive_read_data_block");
    NEED(read_free, "archive_read_free");
    NEED(error_string, "archive_error_string");
    NEED(entry_pathname, "archive_entry_pathname");
    NEED(entry_filetype, "archive_entry_filetype");
    NEED(entry_size, "archive_entry_size");
    MAYBE(support_rar5, "archive_read_support_format_rar5");
    MAYBE(data_skip, "archive_read_data_skip");
    MAYBE(entry_pathname_utf8, "archive_entry_pathname_utf8");
    MAYBE(entry_size_is_set, "archive_entry_size_is_set");
    MAYBE(entry_is_encrypted, "archive_entry_is_encrypted");
    MAYBE(entry_symlink, "archive_entry_symlink");
    MAYBE(entry_hardlink, "archive_entry_hardlink");
    lib.loaded = 1;
}

static void say(char *reason, size_t size, const char *text) {
    if (reason && size) { strncpy(reason, text, size - 1); reason[size - 1] = 0; }
}

int irar_is_rar(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    unsigned char b[8] = {0};
    ssize_t n = read(fd, b, sizeof b);
    close(fd);
    if (n < 7) return 0;
    static const unsigned char sig[6] = {'R', 'a', 'r', '!', 0x1A, 0x07};
    if (memcmp(b, sig, 6) != 0) return 0;
    return b[6] == 0x00 || (b[6] == 0x01 && n >= 8 && b[7] == 0x00);       // RAR 4, RAR 5
}

static int run(const char *path, irar_sink sink, void *context, int unpack, char *reason, size_t reason_size) {
    pthread_once(&once, load);
    if (!lib.loaded) { say(reason, reason_size, "the system archive library is missing"); return IRAR_UNSUPPORTED; }
    if (!irar_is_rar(path)) return IRAR_NOT_RAR;
    archive_t *a = lib.read_new();
    if (!a) { say(reason, reason_size, "memory"); return IRAR_IO; }
    int status = IRAR_OK;
    lib.support_rar(a);
    if (lib.support_rar5) lib.support_rar5(a);
    if (lib.open_filename(a, path, 1 << 16) != A_OK) {
        say(reason, reason_size, lib.error_string(a) ? lib.error_string(a) : "cannot open");
        lib.read_free(a);
        return IRAR_IO;
    }
    uint32_t item = 0;
    for (;;) {
        entry_t *e = NULL;
        int r = lib.next_header(a, &e);
        if (r == A_EOF) break;
        if (r < A_WARN) {         // FAILED or FATAL
            const char *why = lib.error_string(a);
            say(reason, reason_size, why ? why : "damaged");
            status = (why && (strstr(why, "ncrypt") || strstr(why, "assphrase") || strstr(why, "assword"))) ? IRAR_UNSUPPORTED : IRAR_DAMAGED;
            if (status == IRAR_UNSUPPORTED) say(reason, reason_size, "encrypted");
            else if (why && (strstr(why, "olume") || strstr(why, "multi"))) { say(reason, reason_size, "volumes"); status = IRAR_UNSUPPORTED; }
            break;
        }
        const char *name = (lib.entry_pathname_utf8 ? lib.entry_pathname_utf8(e) : NULL);
        if (!name) name = lib.entry_pathname(e);
        if (!name) name = "";
        unsigned int type = lib.entry_filetype(e) & 0170000;
        int flags = 0;
        if (type == 0040000) flags = IRAR_ITEM_DIR;
        else if (type == 0120000 || (lib.entry_hardlink && lib.entry_hardlink(e)) || (lib.entry_symlink && lib.entry_symlink(e))) flags = IRAR_ITEM_LINK;
        else if (type != 0100000 && type != 0) flags = IRAR_ITEM_OTHER;
        if (lib.entry_is_encrypted && lib.entry_is_encrypted(e)) { say(reason, reason_size, "encrypted"); status = IRAR_UNSUPPORTED; break; }
        int64_t size = (lib.entry_size_is_set && !lib.entry_size_is_set(e)) ? 0 : lib.entry_size(e);
        if (size < 0) size = 0;
        if (sink(context, IRAR_BEGIN, item, name, flags, (uint64_t)size, NULL, 0) != 0) { status = IRAR_ABORTED; break; }
        if (unpack && flags == 0) {
            const void *buffer; size_t length; int64_t offset;
            int d;
            while ((d = lib.data_block(a, &buffer, &length, &offset)) == A_OK) {
                if (length && sink(context, IRAR_DATA, item, name, 0, 0, buffer, length) != 0) { status = IRAR_ABORTED; break; }
            }
            if (status != IRAR_OK) break;
            if (d != A_EOF) {
                const char *why = lib.error_string(a);
                say(reason, reason_size, why ? why : "damaged");
                status = (why && (strstr(why, "ncrypt") || strstr(why, "assphrase"))) ? IRAR_UNSUPPORTED : IRAR_DAMAGED;
                if (status == IRAR_UNSUPPORTED) say(reason, reason_size, "encrypted");
                break;
            }
            if (sink(context, IRAR_END, item, name, 0, 0, NULL, 0) != 0) { status = IRAR_ABORTED; break; }
        } else if (unpack && lib.data_skip) {
            lib.data_skip(a);
            if (sink(context, IRAR_END, item, name, flags, 0, NULL, 0) != 0) { status = IRAR_ABORTED; break; }
        }
        item++;
    }
    lib.read_free(a);
    return status;
}

int irar_list(const char *path, irar_sink sink, void *context, char *reason, size_t reason_size) { return run(path, sink, context, 0, reason, reason_size); }
int irar_extract(const char *path, irar_sink sink, void *context, char *reason, size_t reason_size) { return run(path, sink, context, 1, reason, reason_size); }

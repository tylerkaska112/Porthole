// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.

#ifndef itch_rar_h
#define itch_rar_h

#include <stddef.h>
#include <stdint.h>

// A .rar reader for itch.io downloads (ItchRar.swift). RAR 4 and RAR 5 archives are read by the libarchive that ships with iOS (/usr/lib/libarchive.2.dylib), which is
// loaded when it is first needed: the SDK carries its library but no header, so the few functions used are looked up by name. Nothing of RAR's own algorithm is in
// Porthole. One archive file only: a set split into .part1.rar, .part2.rar... is refused with a reason, and so is a password-protected one.

enum {
    IRAR_OK = 0,
    IRAR_NOT_RAR = 1,
    IRAR_DAMAGED = 2,
    IRAR_UNSUPPORTED = 3,   // encrypted, split into volumes, or the system library cannot read RAR
    IRAR_ABORTED = 4,
    IRAR_IO = 6,
};

enum {
    IRAR_ITEM_DIR = 1,      // a folder
    IRAR_ITEM_LINK = 2,     // a symbolic or hard link
    IRAR_ITEM_OTHER = 4,    // a device, pipe... : nothing to unpack
};

enum { IRAR_BEGIN = 0, IRAR_DATA = 1, IRAR_END = 2 };

/// Whether a file starts with a RAR 4 or RAR 5 signature.
int irar_is_rar(const char *path);

/// Called for every item in archive order: IRAR_BEGIN (name, flags, size), then IRAR_DATA pieces, then IRAR_END. `item` counts from 0 and is the same in a listing and in an unpack.
/// A non-zero return stops the unpack (IRAR_ABORTED).
typedef int (*irar_sink)(void *context, int event, uint32_t item, const char *name, int flags, uint64_t size, const void *data, size_t length);

/// Lists the items without unpacking them (no IRAR_DATA/IRAR_END events), or unpacks them. `reason` receives a short word or sentence on failure.
int irar_list(const char *path, irar_sink sink, void *context, char *reason, size_t reason_size);
int irar_extract(const char *path, irar_sink sink, void *context, char *reason, size_t reason_size);

#endif

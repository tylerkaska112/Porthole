// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
#import "GameCapture.h"
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <os/lock.h>
#include <stdatomic.h>
#include <time.h>

#define GC_SLOTS 8

static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;
static struct { uintptr_t key; int w, h; unsigned long long ns; BOOL hidden; } g_slots[GC_SLOTS];
static NSHashTable<CAMetalLayer *> *g_layers;             // weak: every window layer seen, to give back framebufferOnly when a capture ends
static _Atomic(uintptr_t) g_winner;                       // the layer whose pictures are the game's
static _Atomic int g_active;

static PortholeGameFrameBlock g_block;
static int g_outW, g_outH, g_fps;
static CVPixelBufferPoolRef g_pool;
static CVMetalTextureCacheRef g_cache;
static id<MTLCommandQueue> g_queue;
static id<MTLDevice> g_device;
static unsigned long long g_lastCopyNs;
static _Atomic int g_inflight;
static _Atomic int g_number;

static unsigned long long gc_now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

/// The biggest window layer that is shown and has handed out a drawable in the last second; else the biggest of any shown one; else the biggest at all.
static uintptr_t gc_pick_winner_locked(unsigned long long now, int *w, int *h) {
    uintptr_t best = 0; long long bestArea = -1; int bw = 0, bh = 0;
    for (int pass = 0; pass < 3 && !best; pass++) {
        for (int i = 0; i < GC_SLOTS; i++) {
            if (!g_slots[i].key) continue;
            BOOL recent = now - g_slots[i].ns < 1000000000ULL;
            if (pass == 0 && (g_slots[i].hidden || !recent)) continue;
            if (pass == 1 && g_slots[i].hidden) continue;
            long long area = (long long)g_slots[i].w * g_slots[i].h;
            if (area > bestArea) { bestArea = area; best = g_slots[i].key; bw = g_slots[i].w; bh = g_slots[i].h; }
        }
    }
    if (w) *w = bw;
    if (h) *h = bh;
    return best;
}

void porthole_game_note_drawable(CAMetalLayer *layer, BOOL hidden) {
    CGSize d = layer.drawableSize;
    if (d.width < 16 || d.height < 16) return;
    unsigned long long now = gc_now();
    uintptr_t key = (uintptr_t)(__bridge void *)layer;
    os_unfair_lock_lock(&g_lock);
    int slot = -1, oldest = 0;
    BOOL known = NO;
    for (int i = 0; i < GC_SLOTS; i++) {
        if (g_slots[i].key == key) { slot = i; known = YES; break; }
        if (!g_slots[i].key) { if (slot < 0) slot = i; }
        else if (g_slots[i].ns < g_slots[oldest].ns) oldest = i;
    }
    if (slot < 0) slot = oldest;
    g_slots[slot].key = key; g_slots[slot].w = (int)d.width; g_slots[slot].h = (int)d.height; g_slots[slot].ns = now; g_slots[slot].hidden = hidden;
    if (!known) {      // a layer seen for the first time: remember it (weakly) so framebufferOnly can be given back
        if (!g_layers) g_layers = [NSHashTable weakObjectsHashTable];
        [g_layers addObject:layer];
    }
    atomic_store_explicit(&g_winner, gc_pick_winner_locked(now, NULL, NULL), memory_order_relaxed);
    os_unfair_lock_unlock(&g_lock);
}

CGSize porthole_game_picture_size(void) {
    int w = 0, h = 0;
    os_unfair_lock_lock(&g_lock);
    gc_pick_winner_locked(gc_now(), &w, &h);
    os_unfair_lock_unlock(&g_lock);
    return CGSizeMake(w, h);
}

BOOL porthole_game_capture_active(void) { return atomic_load_explicit(&g_active, memory_order_relaxed) != 0; }

BOOL porthole_game_capture_wants(CAMetalLayer *layer) {
    if (!atomic_load_explicit(&g_active, memory_order_relaxed)) return NO;
    if ((uintptr_t)(__bridge void *)layer != atomic_load_explicit(&g_winner, memory_order_relaxed)) return NO;
    if (layer.framebufferOnly) layer.framebufferOnly = NO;       // a texture that is only for display cannot be read; later drawables of this layer can be
    return YES;
}

int porthole_game_capture_start(int width, int height, int fps, PortholeGameFrameBlock block) {
    if (porthole_game_picture_size().width < 16) return -1;
    porthole_game_capture_stop();
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return -1;
    NSDictionary *attrs = @{ (id)kCVPixelBufferWidthKey: @(width), (id)kCVPixelBufferHeightKey: @(height),
                             (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                             (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES };
    CVPixelBufferPoolRef pool = NULL;
    if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &pool) != kCVReturnSuccess) return -1;
    CVMetalTextureCacheRef cache = NULL;
    if (CVMetalTextureCacheCreate(NULL, NULL, device, NULL, &cache) != kCVReturnSuccess) { CVPixelBufferPoolRelease(pool); return -1; }
    g_device = device; g_queue = [device newCommandQueue]; g_pool = pool; g_cache = cache;
    g_block = [block copy]; g_outW = width; g_outH = height; g_fps = fps > 0 ? fps : 30;
    g_lastCopyNs = 0; atomic_store(&g_inflight, 0); atomic_store(&g_number, 0);
    atomic_store(&g_active, 1);
    return 0;
}

void porthole_game_capture_stop(void) {
    if (!atomic_exchange(&g_active, 0)) return;
    NSArray<CAMetalLayer *> *layers = nil;
    os_unfair_lock_lock(&g_lock);
    layers = g_layers.allObjects;
    os_unfair_lock_unlock(&g_lock);
    for (CAMetalLayer *l in layers) l.framebufferOnly = YES;       // as the game had it
    // Give frames that are still being copied a moment, then release what they use.
    PortholeGameFrameBlock old = g_block;
    CVPixelBufferPoolRef pool = g_pool; CVMetalTextureCacheRef cache = g_cache;
    g_block = nil; g_pool = NULL; g_cache = NULL; g_queue = nil; g_device = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        (void)old;
        if (pool) CVPixelBufferPoolRelease(pool);
        if (cache) CFRelease(cache);
    });
}

void porthole_game_capture_presented(id<CAMetalDrawable> drawable) {
    if (!atomic_load_explicit(&g_active, memory_order_relaxed)) return;
    unsigned long long now = gc_now();
    if (g_lastCopyNs && now - g_lastCopyNs < 1000000000ULL / (unsigned long long)g_fps - 3000000ULL) return;      // the stream takes `fps` pictures a second
    if (atomic_load_explicit(&g_inflight, memory_order_relaxed) >= 2) return;                                    // the GPU is behind: skip rather than queue up
    id<MTLTexture> src = drawable.texture;
    PortholeGameFrameBlock block = g_block;
    id<MTLCommandQueue> queue = g_queue;
    CVPixelBufferPoolRef pool = g_pool; CVMetalTextureCacheRef cache = g_cache;
    int outW = g_outW, outH = g_outH;
    if (!src || !block || !queue || !pool || !cache || !(src.usage & MTLTextureUsageShaderRead)) return;           // still a display-only drawable from before the switch
    g_lastCopyNs = now;

    CVPixelBufferRef pixels = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pixels) != kCVReturnSuccess || !pixels) return;
    CVMetalTextureRef cvTexture = NULL;
    if (CVMetalTextureCacheCreateTextureFromImage(NULL, cache, pixels, NULL, MTLPixelFormatBGRA8Unorm, outW, outH, 0, &cvTexture) != kCVReturnSuccess || !cvTexture) {
        CVPixelBufferRelease(pixels); return;
    }
    id<MTLTexture> dst = CVMetalTextureGetTexture(cvTexture);

    // Fit the game's picture into the stream's size, its shape kept.
    double sw = (double)src.width, sh = (double)src.height;
    double scale = MIN((double)outW / sw, (double)outH / sh);
    double dw = sw * scale, dh = sh * scale;
    double dx = ((double)outW - dw) / 2, dy = ((double)outH - dh) / 2;
    BOOL bars = dw < outW - 1.5 || dh < outH - 1.5;

    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    if (bars) {      // black behind the picture (pool buffers are reused)
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = dst;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        [[cmd renderCommandEncoderWithDescriptor:pass] endEncoding];
    }
    MPSImageLanczosScale *filter = [[MPSImageLanczosScale alloc] initWithDevice:src.device];
    MPSScaleTransform t = { scale, scale, dx, dy };
    filter.scaleTransform = &t;
    filter.clipRect = MTLRegionMake2D((NSUInteger)llround(dx), (NSUInteger)llround(dy), (NSUInteger)MIN((double)outW, llround(dw)), (NSUInteger)MIN((double)outH, llround(dh)));
    [filter encodeToCommandBuffer:cmd sourceTexture:src destinationTexture:dst];
    int number = atomic_fetch_add(&g_number, 1);
    atomic_fetch_add(&g_inflight, 1);
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> done) {
        atomic_fetch_sub(&g_inflight, 1);
        if (done.status == MTLCommandBufferStatusCompleted && atomic_load(&g_active)) block(pixels, number);
        CVPixelBufferRelease(pixels);
        CFRelease(cvTexture);
    }];
    [cmd commit];
}

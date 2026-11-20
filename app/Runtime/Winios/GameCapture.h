// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
//
// The game's own picture for Discord Go Live (Discord branch): the frames a game window's Metal layer presents, copied on the GPU into pixel buffers of the stream's size.
// Nothing but the game: no touch controls, no in-game menu, no overlay, and the game's shape, not the phone's. The window layers are Winios.m's MadeiraWindowMetalLayer
// (DXMT and Vulkan games both present into one); it reports each drawable it hands out here, and while a capture runs the picture of each presented drawable is scaled
// into a pixel buffer and delivered.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

NS_ASSUME_NONNULL_BEGIN

/// One scaled picture of the game and its number.
typedef void (^PortholeGameFrameBlock)(CVPixelBufferRef pixels, int number);

/// The size in pixels of the game's picture now (the biggest window layer that is shown and drawing), or CGSizeZero when no window is drawing.
CGSize porthole_game_picture_size(void);

/// Starts delivering the game's picture, scaled to fit `width` x `height` with its own shape kept (black bars when the shape differs), at most `fps` pictures a second.
/// Returns 0 on success, -1 when no game window is drawing.
int porthole_game_capture_start(int width, int height, int fps, PortholeGameFrameBlock block);
void porthole_game_capture_stop(void);
BOOL porthole_game_capture_active(void);

// Called by MadeiraWindowMetalLayer (Winios.m).
/// Notes that `layer` handed out a drawable now (size and time), so the biggest drawing window can be told.
void porthole_game_note_drawable(CAMetalLayer *layer, BOOL hidden);
/// True when this layer's next drawable should be copied once presented (a capture runs and this is the game's window).
BOOL porthole_game_capture_wants(CAMetalLayer *layer);
/// The drawable was presented: copy its picture.
void porthole_game_capture_presented(id<CAMetalDrawable> drawable);

NS_ASSUME_NONNULL_END

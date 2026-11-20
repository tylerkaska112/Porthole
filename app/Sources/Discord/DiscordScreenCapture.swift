// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Porthole authors. See LICENSE.
import CoreMedia
import CoreVideo
import QuartzCore
import ReplayKit
import UIKit
import VideoToolbox

/// The game's picture for Go Live: what this app draws on the screen, taken with ReplayKit's in-app capture (this process only; nothing from other apps), scaled to the stream's size
/// and handed over 30 times a second. The game draws into Metal layers inside this app, which ReplayKit includes; so do the touch controls and the in-game menu, when they are shown.
/// iOS asks once per start whether Porthole may record the screen, and shows its recording indicator while this runs.
final class DiscordScreenCapture: @unchecked Sendable {
    let width: Int, height: Int, fps: Int
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var lastSent: CFTimeInterval = 0
    private var frame = 0
    private let lock = NSLock()
    private var active = false

    init(width: Int, height: Int, fps: Int) { self.width = width; self.height = height; self.fps = fps }

    /// The size to stream at for this device: the screen in landscape, scaled to fit 1280x720 and never enlarged (both sides even, as H.264 wants).
    static func outputSize(box: (width: Int, height: Int) = (1280, 720)) -> (width: Int, height: Int) {
        let native = UIScreen.main.nativeBounds.size
        let w = max(native.width, native.height), h = min(native.width, native.height)
        let scale = min(Double(box.width) / w, Double(box.height) / h, 1)
        return ((Int(w * scale) / 2) * 2, (Int(h * scale) / 2) * 2)
    }

    /// `onFrame` gets a picture of the stream's size and its number; `onFailure` says why capture could not start or stopped (the person said no, or iOS ended it).
    func start(onFrame: @escaping (CVPixelBuffer, Int) -> Void, onFailure: @escaping (String) -> Void) {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else { onFailure("This device cannot record the screen right now."); return }
        recorder.isMicrophoneEnabled = false
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session else { onFailure("The phone could not prepare the picture for the stream."); return }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)      // keep the screen's shape; black bars if it differs
        transfer = session
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height, kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
        var made: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &made)
        pool = made
        lock.lock(); active = true; lock.unlock()
        recorder.startCapture(handler: { [weak self] sample, type, error in
            guard let self, error == nil, type == .video, CMSampleBufferDataIsReady(sample), let source = CMSampleBufferGetImageBuffer(sample) else { return }
            self.lock.lock(); let on = self.active; self.lock.unlock()
            guard on else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastSent >= 1.0 / Double(self.fps) - 0.003 else { return }      // ReplayKit delivers up to 60 pictures a second; the stream takes 30
            self.lastSent = now
            guard let scaled = self.scale(source) else { return }
            let number = self.frame
            self.frame += 1
            onFrame(scaled, number)
        }, completionHandler: { error in
            guard let error else { return }
            let code = RPRecordingErrorCode(rawValue: (error as NSError).code)
            onFailure(code == .userDeclined ? "Screen recording was not allowed, so there is no picture to stream." : "Screen capture could not start: \(error.localizedDescription)")
        })
    }

    func stop() {
        lock.lock(); active = false; lock.unlock()
        if RPScreenRecorder.shared().isRecording { RPScreenRecorder.shared().stopCapture { _ in } }
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        transfer = nil; pool = nil
    }

    private func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let transfer, let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        return VTPixelTransferSessionTransferImage(transfer, from: source, to: out) == noErr ? out : nil
    }
}

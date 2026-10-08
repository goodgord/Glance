import AVFoundation
import Vision

/// One frame's worth of head/eye pose features.
struct GazeSample {
    /// [yaw, pitch, noseX, noseY, faceX, faceY, pupilX, pupilY]
    var features: [Double]
    /// Eye outline height ÷ width for each eye; drops sharply when that eye closes.
    var leftOpenness: Double = 0
    var rightOpenness: Double = 0
}

/// Runs the camera and turns frames into `GazeSample`s using Apple's Vision framework.
final class GazeTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on the main queue for every processed frame (nil = no face found).
    var onSample: ((GazeSample?) -> Void)?

    /// Minimum seconds between processed frames (~12 fps keeps CPU low).
    var interval: CFAbsoluteTime = 0.08

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "glance.camera")
    private let sequenceHandler = VNSequenceRequestHandler()
    private var lastProcessed: CFAbsoluteTime = 0
    private(set) var isRunning = false

    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static func defaultCamera() -> AVCaptureDevice? {
        let cams = availableCameras()
        return cams.first { $0.deviceType == .builtInWideAngleCamera } ?? cams.first
    }

    func start(cameraID: String?, completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.queue.async {
                let ok = self.configure(cameraID: cameraID)
                if ok { self.session.startRunning() }
                self.isRunning = ok
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.isRunning = false
        }
    }

    private func configure(cameraID: String?) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        let device = cameraID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? Self.defaultCamera()
        guard let device, let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)

        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        return true
    }

    // MARK: - Frame processing

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastProcessed >= interval else { return }
        lastProcessed = now
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let sample = Self.analyze(pixels, handler: sequenceHandler)
        DispatchQueue.main.async { self.onSample?(sample) }
    }

    private static func analyze(_ pixels: CVPixelBuffer, handler: VNSequenceRequestHandler) -> GazeSample? {
        // Rectangles (revision 3) gives continuous yaw/pitch; landmarks gives eyes, pupils and nose.
        let rects = VNDetectFaceRectanglesRequest()
        rects.revision = VNDetectFaceRectanglesRequestRevision3
        do { try handler.perform([rects], on: pixels, orientation: .up) } catch { return nil }

        guard let face = (rects.results ?? []).max(by: { area($0) < area($1) }) else { return nil }

        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = [face]
        do { try handler.perform([landmarks], on: pixels, orientation: .up) } catch { return nil }
        guard let lm = landmarks.results?.first?.landmarks else { return nil }

        return features(face: face, landmarks: lm)
    }

    private static func area(_ f: VNFaceObservation) -> CGFloat {
        f.boundingBox.width * f.boundingBox.height
    }

    private static func features(face: VNFaceObservation, landmarks lm: VNFaceLandmarks2D) -> GazeSample? {
        guard let nose = lm.nose, let leftEye = lm.leftEye, let rightEye = lm.rightEye,
              let leftPupil = lm.leftPupil, let rightPupil = lm.rightPupil else { return nil }

        let yaw = face.yaw?.doubleValue ?? 0
        let pitch = face.pitch?.doubleValue ?? 0
        let box = face.boundingBox

        // Nose position within the face box is a smooth proxy for head rotation.
        let noseC = centroid(nose.normalizedPoints)

        let l = pupilOffset(eye: leftEye.normalizedPoints, pupil: leftPupil.normalizedPoints)
        let r = pupilOffset(eye: rightEye.normalizedPoints, pupil: rightPupil.normalizedPoints)

        return GazeSample(features: [
            yaw, pitch,
            Double(noseC.x) - 0.5, Double(noseC.y) - 0.5,
            Double(box.midX), Double(box.midY),
            Double(l.x + r.x) / 2, Double(l.y + r.y) / 2,
        ], leftOpenness: openness(leftEye.normalizedPoints), rightOpenness: openness(rightEye.normalizedPoints))
    }

    private static func openness(_ eye: [CGPoint]) -> Double {
        guard let minX = eye.map(\.x).min(), let maxX = eye.map(\.x).max(),
              let minY = eye.map(\.y).min(), let maxY = eye.map(\.y).max() else { return 0 }
        return Double((maxY - minY) / max(maxX - minX, 0.0001))
    }

    private static func centroid(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        let s = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: s.x / CGFloat(pts.count), y: s.y / CGFloat(pts.count))
    }

    /// Pupil position relative to the eye outline, normalised by eye width.
    private static func pupilOffset(eye: [CGPoint], pupil: [CGPoint]) -> CGPoint {
        guard let p = pupil.first, !eye.isEmpty else { return .zero }
        let xs = eye.map(\.x), ys = eye.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let w = max(maxX - minX, 0.0001)
        return CGPoint(x: (p.x - (minX + maxX) / 2) / w, y: (p.y - (minY + maxY) / 2) / w)
    }
}

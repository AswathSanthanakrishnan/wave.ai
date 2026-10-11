import AVFoundation
import MediaPipeTasksVision
import MediaPipeTasksVisionHandLandmarker

/// Camera and inference are confined to one serial queue. Late frames are dropped.
final class HandCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: (([CGPoint], Double) -> Void)?
    var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "Wave.camera", qos: .userInitiated)
    private let session = AVCaptureSession()
    private var landmarker: HandLandmarker?
    private var configured = false
    private var lastTimestamp = 0
    private var running = false
    private var runtimeObserver: NSObjectProtocol?

    override init() {
        super.init()
        runtimeObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onError?(error?.localizedDescription ?? "Camera session failed. Toggle On to retry.")
        }
    }

    deinit {
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
    }

    func setRunning(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if enabled {
                    if !configured { try configure() }
                    running = true
                    if !session.isRunning { session.startRunning() }
                } else {
                    running = false
                    if session.isRunning { session.stopRunning() }
                }
            } catch {
                running = false
                onError?(error.localizedDescription)
            }
        }
    }

    private func configure() throws {
        let options = try HandLandmarkerModel.makeOptions(runningMode: .video, numberOfHands: 1)
        landmarker = try HandLandmarker(options: options)
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw CameraError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input) else { throw CameraError.configuration }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraError.configuration
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false // Mirrored exactly once when mapping the cursor.
        }
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard running, let landmarker,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = ProcessInfo.processInfo.systemUptime
        let timestamp = max(lastTimestamp + 1, Int(time * 1_000))
        lastTimestamp = timestamp
        do {
            let image = try MPImage(pixelBuffer: buffer)
            let result = try landmarker.detect(videoFrame: image, timestampInMilliseconds: timestamp)
            let points = result.landmarks.first?.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) } ?? []
            onFrame?(points, time)
        } catch {
            running = false
            session.stopRunning()
            onError?(error.localizedDescription)
        }
    }
}

private enum CameraError: LocalizedError {
    case unavailable, configuration
    var errorDescription: String? {
        switch self {
        case .unavailable: return "No camera found. Connect a camera and toggle On to retry."
        case .configuration: return "Cannot configure the camera. Toggle On to retry."
        }
    }
}

fileprivate let Log = Logger(tag: "AVIPlayer")

class AVIPlayer {

    let videoDecoder: IDF.JPEG.Decoder<UInt16>
    let videoBuffer: UnsafeMutableBufferPointer<UInt16>
    private var videoDataCallback: ((UnsafeMutableBufferPointer<UInt16>, Size) -> Void)? = nil
    private var audioDataCallback: ((UnsafeMutableRawBufferPointer) -> Void)? = nil
    private var audioSetClockCallback: ((_ sampleRate: UInt32, _ bitsPerSample: UInt8, _ channels: UInt8) -> Void)? = nil

    init() throws(IDF.Error) {
        self.videoDecoder = try IDF.JPEG.createDecoderRgb565(rgbElementOrder: .bgr, rgbConversion: .bt709)
        guard let videoBuffer = IDF.JPEG.Decoder<UInt16>.allocateOutputBuffer(capacity: 1280 * 720) else {
            throw IDF.Error(ESP_ERR_NO_MEM)
        }
        self.videoBuffer = videoBuffer

        var config = avi_player_config_t()
        config.buffer_size = 4192 * 1024
        config.video_cb = { (data, arg) in
            Unmanaged<AVIPlayer>.fromOpaque(arg!).takeUnretainedValue().videoCallback(data: data!)
        }
        config.audio_cb = { (data, arg) in
            Unmanaged<AVIPlayer>.fromOpaque(arg!).takeUnretainedValue().audioCallback(data: data!)
        }
        config.audio_set_clock_cb = { (rate, bits, ch, arg) in
            Unmanaged<AVIPlayer>.fromOpaque(arg!).takeUnretainedValue().audioSetClockCallback?(rate, UInt8(bits), UInt8(ch))
        }
        config.user_data = Unmanaged.passRetained(self).toOpaque()
        config.priority = 15
        try IDF.Error.check(avi_player_init(config))
    }

    private func videoCallback(data: UnsafeMutablePointer<frame_data_t>) {
        guard let callback = videoDataCallback else {
            return
        }
        if data.pointee.video_info.frame_format != FORMAT_MJEPG {
            Log.error("Unsupported video format")
            return
        }
        let inputBuffer = UnsafeRawBufferPointer(
            start: data.pointee.data,
            count: Int(data.pointee.data_bytes)
        )

        do throws(IDF.Error) {
            let _ = try videoDecoder.decode(inputBuffer: inputBuffer, outputBuffer: videoBuffer)
            callback(videoBuffer, Size(width: Int(data.pointee.video_info.width), height: Int(data.pointee.video_info.height)))
        } catch {
            Log.error("Failed to decode JPEG: \(error)")
        }
    }

    private func audioCallback(data: UnsafeMutablePointer<frame_data_t>) {
        guard let callback = audioDataCallback else {
            return
        }
        let audioBuffer = UnsafeMutableRawBufferPointer(
            start: data.pointee.data,
            count: data.pointee.data_bytes
        )
        callback(audioBuffer)
    }

    func onVideoData(_ callback: @escaping (UnsafeMutableBufferPointer<UInt16>, Size) -> Void) {
        self.videoDataCallback = callback
    }
    func onAudioData(_ callback: @escaping (UnsafeMutableRawBufferPointer) -> Void) {
        self.audioDataCallback = callback
    }
    func onAudioSetClock(_ callback: @escaping (_ sampleRate: UInt32, _ bitsPerSample: UInt8, _ channels: UInt8) -> Void) {
        self.audioSetClockCallback = callback
    }

    func play(file: String) throws(IDF.Error) {
        let err = file.utf8CString.withUnsafeBufferPointer {
            avi_player_play_from_file($0.baseAddress!)
        }
        try IDF.Error.check(err)
    }
}

fileprivate let Log = Logger(tag: "AVIPlayer")

class AVIPlayer {

    let videoDecoder: IDF.JPEG.Decoder<UInt16>
    let videoBuffer: UnsafeMutableBufferPointer<UInt16>
    let audioDecoder: esp_audio_dec_handle_t

    private var videoDataCallback: ((UnsafeMutableBufferPointer<UInt16>, Size) -> Void)? = nil
    private var audioDataCallback: ((UnsafeMutableRawBufferPointer) -> Void)? = nil
    private var audioSetClockCallback: ((_ sampleRate: UInt32, _ bitsPerSample: UInt8, _ channels: UInt8) -> Void)? = nil
    private var aviPlayEndCallback: (() -> Void)? = nil
    var pcmBuffer: UnsafeMutableRawBufferPointer

    private(set) var isPlaying = false

    init() throws(IDF.Error) {
        self.videoDecoder = try IDF.JPEG.createDecoderRgb565(rgbElementOrder: .bgr, rgbConversion: .bt709)
        guard let videoBuffer = IDF.JPEG.Decoder<UInt16>.allocateOutputBuffer(capacity: 1280 * 720) else {
            throw IDF.Error(ESP_ERR_NO_MEM)
        }
        self.videoBuffer = videoBuffer

        esp_mp3_dec_register()
        var decoderConfig = esp_audio_dec_cfg_t()
        decoderConfig.type = ESP_AUDIO_TYPE_MP3
        var audioDecoder: esp_audio_dec_handle_t?
        if esp_audio_dec_open(&decoderConfig, &audioDecoder) != ESP_AUDIO_ERR_OK {
            throw IDF.Error(ESP_FAIL)
        }
        self.audioDecoder = audioDecoder!
        pcmBuffer = Memory.allocateRaw(size: 32 * 1024, capability: .spiram)!

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
        config.avi_play_end_cb = { arg in
            let player = Unmanaged<AVIPlayer>.fromOpaque(arg!).takeUnretainedValue()
            player.isPlaying = false
            player.aviPlayEndCallback?()
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
        if data.pointee.audio_info.format == FORMAT_MP3 {
            var input = esp_audio_dec_in_raw_t()
            input.buffer = data.pointee.data
            input.len = UInt32(data.pointee.data_bytes)
            input.frame_recover = ESP_AUDIO_DEC_RECOVERY_PLC
            var output = esp_audio_dec_out_frame_t()
            output.buffer = pcmBuffer.assumingMemoryBound(to: UInt8.self).baseAddress!
            output.len = UInt32(pcmBuffer.count)

            let err = esp_audio_dec_process(audioDecoder, &input, &output)
            if err != ESP_AUDIO_ERR_OK {
                Log.error("Audio decode error: \(err)")
                return
            }

            let audioBuffer = UnsafeMutableRawBufferPointer(
                start: pcmBuffer.baseAddress!,
                count: Int(output.decoded_size)
            )
            callback(audioBuffer)
            return
        } else {
            let audioBuffer = UnsafeMutableRawBufferPointer(
                start: data.pointee.data,
                count: data.pointee.data_bytes
            )
            callback(audioBuffer)
        }
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
    func onPlayEnd(_ callback: @escaping () -> Void) {
        self.aviPlayEndCallback = callback
    }

    func play(file: String) throws(IDF.Error) {
        let err = file.utf8CString.withUnsafeBufferPointer {
            avi_player_play_from_file($0.baseAddress!)
        }
        try IDF.Error.check(err)
        isPlaying = true
    }

    func stop() throws(IDF.Error) {
        guard isPlaying else { return }
        isPlaying = false
        try IDF.Error.check(avi_player_play_stop())
    }
}

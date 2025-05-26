fileprivate let Log = Logger(tag: "main")

@_cdecl("app_main")
func app_main() {
    do {
        try main()
    } catch {
        Log.error("Main Function Exit with Error: \(error)")
    }
}
func main() throws(IDF.Error) {
    let tab5 = try M5StackTab5.begin()
    tab5.display.brightness = 1.0

    let multiTouch: MultiTouch = MultiTouch()
    multiTouch.task(xCoreID: 1) {
        tab5.touch.waitInterrupt()
        return try! tab5.touch.coordinates
    }

    let usbHost = USBHost()
    let mscDriver = USBHost.MSC()
    try usbHost.install()
    try mscDriver.install(taskStackSize: 4096, taskPriority: 5, xCoreID: 0, createBackgroundTask: true)
    Task.delay(1000)
    try mscDriver.mount(path: "/usb", maxFiles: 25)

    for file in FileManager.default.contentsOfDirectory(atPath: "/usb") ?? [] {
        Log.info("File: \(file)")
    }

    let aviPlayer = try AVIPlayer()
    aviPlayer.onVideoData { buffer, size in
        tab5.display.drawBitmap(start: (0, 0), end: (Int32(size.width), Int32(size.height)), data: buffer.baseAddress!)
    }
    aviPlayer.onAudioData { buffer in
        try! tab5.audio.write(buffer)
    }
    aviPlayer.onAudioSetClock { sampleRate, bitsPerSample, channels in
        Log.info("Audio Clock: \(sampleRate)Hz, \(bitsPerSample)-bit, \(channels) channels")
        try! tab5.audio.reconfigOutput(rate: sampleRate, bps: bitsPerSample, ch: channels)
        tab5.audio.volume = 40
    }

    try aviPlayer.play(file: "/usb/video10.avi")
}

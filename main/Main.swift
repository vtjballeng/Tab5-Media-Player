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
    let frameBuffer = Memory.allocate(type: UInt16.self, capacity: 1280 * 720, capability: [.cacheAligned, .spiram])!
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
}

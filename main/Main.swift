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
}

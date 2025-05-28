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

    var drawnBuffer = Memory.allocate(type: UInt16.self, capacity: 720 * 1280 * 2, capability: .spiram)!
    let cellHeight = 160
    let colors: [Color] = [.white, .red, .green, .blue, .yellow, .cyan, .magenta, .black]
    for i in 0..<(colors.count * 2) {
        let color = colors[i % colors.count]
        let startIndex = i * cellHeight * 720
        let endIndex = startIndex + cellHeight * 720
        for j in startIndex..<endIndex {
            drawnBuffer[j] = color.rgb565
        }
    }

    var offset = 0
    var frameBuffer = tab5.display.frameBuffer
    while true {
        tab5.display.drawBitmap(start: (0, 0), end: (720, 1280), data: drawnBuffer.slice(start: 720 * offset))
        offset += 10
        if offset >= 1280 { offset = 0 }
    }


    var index = 0
    while true {
        let colors: [Color] = [.white, .red, .green, .blue, .yellow, .cyan, .magenta, .black]
        if index * cellHeight >= 1280 {
            break
        }
        let cellHeight = min(cellHeight, 1280 - index * cellHeight)
        let color = colors[index % colors.count]
        for i in (index * cellHeight)..<(index + 1) * cellHeight {
            for j in 0..<720 {
                frameBuffer[720 * i + j] = color.rgb565
            }
        }
        index += 1
    }
    tab5.display.drawBitmap(start: (0, 0), end: (720, 1280), data: frameBuffer)

    let step = 10
    let tmpBuffer = Memory.allocate(type: UInt16.self, capacity: 720 * step, capability: .spiram)!
    while true {
        memcpy(tmpBuffer.mutableRawPointer, frameBuffer.slice(start: (1280 - step) * 720, count: step * 720).rawPointer, 720 * step * 2)
        memmove(frameBuffer.slice(start: step * 720).mutableRawPointer, frameBuffer.rawPointer, 1280 * (720 - step) * 2)
        memcpy(frameBuffer.mutableRawPointer, tmpBuffer.rawPointer, 720 * step * 2)
        tab5.display.drawBitmap(start: (0, 0), end: (720, 1280), data: frameBuffer)
    }
}

class FileSelect {

    let font: Font
    init(font: Font) {
        self.font = font
    }
}

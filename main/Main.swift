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
    let frameBuffer = tab5.display.frameBuffer
    tab5.display.brightness = 100

    let multiTouch: MultiTouch = MultiTouch()
    multiTouch.task(xCoreID: 1) {
        tab5.touch.waitInterrupt()
        return try! tab5.touch.coordinates
    }

    let fontPartition = IDF.Partition(type: 0x40, subtype: 0)!
    PixelWriter.defaultFont = Font(from: fontPartition)!

    let usbHost = USBHost()
    let mscDriver = USBHost.MSC()
    try usbHost.install()
    try mscDriver.install(taskStackSize: 4096, taskPriority: 5, xCoreID: 0, createBackgroundTask: true)
    Task.delay(1000)
    try mscDriver.mount(path: "/usb", maxFiles: 25)

    let fileManagerView = FileManagerView(size: tab5.display.size)
    fileManagerView.push(path: "", name: "usb")

    let aviPlayer = try AVIPlayer()
    let aviPlayerSemaphore = Semaphore.createBinary()!
    var pause = false, showControls = false
    let videoBufferTx = Queue<(UnsafeMutableBufferPointer<UInt8>, Int, Size)>(capacity: 4)!
    aviPlayer.onVideoData { buffer, bufferSize, frameSize in
        videoBufferTx.send((buffer, bufferSize, frameSize))
        while pause {
            Task.delay(100)
        }
        return false
    }
    aviPlayer.onAudioData { buffer in
        try! tab5.audio.write(buffer)
    }
    aviPlayer.onAudioSetClock { sampleRate, bitsPerSample, channels in
        Log.info("Audio Clock: \(sampleRate)Hz, \(bitsPerSample)-bit, \(channels) channels")
        try! tab5.audio.reconfigOutput(rate: sampleRate, bps: bitsPerSample, ch: channels)
        tab5.audio.volume = 40
    }
    aviPlayer.onPlayEnd {
        aviPlayerSemaphore.give()
    }
    Task(name: "MJpegDecoder", priority: 15, xCoreID: 1) { _ in
        let videoDecoder = try! IDF.JPEG.createDecoderRgb565(rgbElementOrder: .bgr, rgbConversion: .bt709)
        let videoBuffer = IDF.JPEG.Decoder<UInt16>.allocateOutputBuffer(capacity: tab5.display.size.width * tab5.display.size.height)!
        for (buffer, bufferSize, _) in videoBufferTx {
            let inputBuffer = UnsafeRawBufferPointer(
                start: buffer.baseAddress!,
                count: bufferSize
            )
            do throws(IDF.Error) {
                let _ = try videoDecoder.decode(inputBuffer: inputBuffer, outputBuffer: videoBuffer)
                let size = showControls ? Size(width: 720, height: 1280 - 300) : tab5.display.size
                tab5.display.drawBitmap(rect: Rect(origin: .zero, size: size), data: videoBuffer.baseAddress!)
                while pause {
                    Task.delay(100)
                    let size = showControls ? Size(width: 720, height: 1280 - 300) : tab5.display.size
                    tab5.display.drawBitmap(rect: Rect(origin: .zero, size: size), data: videoBuffer.baseAddress!)
                }
            } catch {
                Log.error("Failed to decode video frame: \(error)")
            }
            aviPlayer.returnVideoBuffer(buffer)
        }
    }

    let rect = Rect(x: 0, y: 1280 - 300, width: 720, height: 300)
    let playerControlView = PlayerControlView(size: rect.size)

    var selectedFile: String? = nil
    multiTouch.onEvent { event in
        guard case .tap(let point) = event else { return }
        if aviPlayer.isPlaying {
            if !showControls || point.y < 1280 - 300 {
                showControls.toggle()
            } else {
                let point = Point(x: point.x, y: point.y - (1280 - 300))
                let controlEvent = playerControlView.onTap(point: point)
                switch controlEvent {
                case .close:
                    try? aviPlayer.stop()
                    // aviPlayerSemaphore.give()
                case .playPause:
                    pause.toggle()
                case .volume(let diff):
                    tab5.audio.volume = max(0, min(100, tab5.audio.volume + diff))
                case .brightness(let diff):
                    tab5.display.brightness = max(10, min(100, tab5.display.brightness + diff))
                default:
                    break
                }
            }
            if showControls {
                let buffer = playerControlView.draw(
                    pause: !pause, volume: tab5.audio.volume, brightness: tab5.display.brightness
                )
                tab5.display.drawBitmap(rect: rect, data: buffer.baseAddress!)
            }
        } else {
            let (refresh, file) = fileManagerView.onTouch(event: event)
            if refresh {
                let buffer = fileManagerView.draw()
                tab5.display.drawBitmap(rect: Rect(origin: .zero, size: fileManagerView.size), data: buffer.baseAddress!)
            }
            if let file = file {
                selectedFile = file
            }
        }
    }

    while true {
        let buffer = fileManagerView.draw()
        tab5.display.drawBitmap(rect: Rect(origin: .zero, size: fileManagerView.size), data: buffer.baseAddress!)

        var playSucceed = false
        while true {
            if let file = selectedFile {
                Log.info("Selected file: \(file)")
                showControls = false
                memset(frameBuffer.baseAddress!, 0, tab5.display.size.width * tab5.display.size.height * 2)
                tab5.display.drawBitmap(rect: Rect(origin: .zero, size: tab5.display.size), data: frameBuffer.baseAddress!)
                do {
                    try aviPlayer.play(file: file)
                    playSucceed = true
                } catch {
                    Log.error("Failed to play video: \(error)")
                }
                selectedFile = nil
                break
            }
            Task.delay(10)
        }
        if !playSucceed {
            continue
        }
        aviPlayerSemaphore.take()
    }
}

class FileManagerView {

    class Directory {
        let path: String
        let name: String
        let items: [(name: String, isDirectory: Bool)]

        var page = 0
        var totalPages: Int {
            return (items.count + 9) / 10
        }
        func pageItem(at index: Int) -> (name: String, isDirectory: Bool)? {
            let itemIndex = page * 10 + index
            guard itemIndex < items.count else { return nil }
            return items[itemIndex]
        }

        init(path: String, name: String) {
            self.path = path + "/" + name
            self.name = name
            let items = FileManager.default.contentsOfDirectory(atPath: self.path) ?? []
            self.items = items.sorted().map {
                (name: $0, isDirectory: FileManager.default.isDirectory(atPath: path + "/" + name + "/" + $0))
            }
        }
    }

    var directories: [Directory] = []
    var currentDirectory: Directory? {
        return directories.last
    }
    let writer: PixelWriter
    var buffer: UnsafeMutableBufferPointer<UInt16> {
        return writer.buffer
    }
    var size: Size {
        return writer.screenSize
    }

    init(size: Size) {
        let buffer = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: size.width * size.height)
        self.writer = PixelWriter(buffer: buffer, screenSize: size)
    }

    private let headerHeight = 160
    private let cellHeight = 100
    private let footerHeight = 120

    func draw() -> UnsafeMutableBufferPointer<UInt16> {
        writer.clear(color: .white)
        drawHeader(rect: Rect(x: 0, y: 0, width: size.width, height: headerHeight))
        for i in 0..<10 {
            let y = headerHeight + i * cellHeight
            writer.drawLine(from: Point(x: 0, y: y), to: Point(x: size.width, y: y), color: .gray)
            if let item = currentDirectory?.pageItem(at: i) {
                drawCell(rect: Rect(x: 0, y: y, width: size.width, height: cellHeight), item: item)
            }
        }
        drawFooter(rect: Rect(x: 0, y: size.height - footerHeight, width: size.width, height: footerHeight))
        return buffer
    }

    private func drawHeader(rect: Rect) {
        writer.fillRect(rect: Rect(x: rect.minX, y: rect.maxY, width: rect.width, height: 2), color: .black)

        let fontSize = 72
        let leftOrigin = 40
        var title = currentDirectory?.name ?? ""
        if directories.count == 1 {
            if title == "usb" { title = "USB Storage" }
            if title == "sdcard" { title = "SD Card" }
        }
        if directories.count > 1 {
            title = "< " + title
        }
        writer.drawText(title,
            at: Point(x: rect.minX + leftOrigin, y: rect.minY + (rect.height - fontSize) / 2),
            fontSize: fontSize,
            color: .black
        )
    }

    private func drawCell(rect: Rect, item: (name: String, isDirectory: Bool)) {

        let fontSize = 48
        let leftOrigin = 40
        writer.drawText(item.name,
            at: Point(x: rect.minX + leftOrigin, y: rect.minY + (rect.height - fontSize) / 2),
            fontSize: fontSize,
            color: item.isDirectory ? .blue : .black
        )
    }

    private func drawFooter(rect: Rect) {
        writer.fillRect(rect: Rect(x: rect.minX, y: rect.minY, width: rect.width, height: 2), color: .black)

        let fontSize = 48
        writer.drawText("<<", at: Point(x: rect.minX + 40, y: rect.minY + (rect.height - fontSize) / 2), fontSize: fontSize, color: .black)

        let arrowWidth = PixelWriter.defaultFont!.width(of: ">>")
        writer.drawText(">>", at: Point(x: rect.maxX - arrowWidth - 40, y: rect.minY + (rect.height - fontSize) / 2), fontSize: fontSize, color: .black)

        let pageTitle = "\((currentDirectory?.page ?? 0) + 1) / \(currentDirectory?.totalPages ?? 1)"
        let pageWidth = PixelWriter.defaultFont!.width(of: pageTitle)
        writer.drawText(pageTitle,
            at: Point(x: rect.center.x - pageWidth / 2, y: rect.minY + (rect.height - fontSize) / 2),
            fontSize: fontSize,
            color: .black
        )
    }

    func push(path: String? = nil, name: String) {
        let directory = Directory(path: path ?? currentDirectory?.path ?? "", name: name)
        directories.append(directory)
    }

    func onTouch(event: MultiTouch.Event) -> (refresh: Bool, file: String?) {
        guard case .tap(let point) = event else { return (false, nil) }
        if directories.isEmpty { return (false, nil) }

        if point.y < headerHeight {
            // Header area, handle navigation
            if point.x < 200 { // Back button
                if directories.count > 1 {
                    directories.removeLast()
                    return (true, nil)
                }
            }
        } else if point.y > size.height - footerHeight {
            // Footer area, handle page navigation
            if point.x < 300 { // Previous page button
                currentDirectory?.page = max(0, (currentDirectory?.page ?? 0) - 1)
                return (true, nil)
            } else if point.x > size.width - 300 { // Next page button
                currentDirectory?.page = min((currentDirectory?.totalPages ?? 1) - 1, (currentDirectory?.page ?? 0) + 1)
                return (true, nil)
            }
        } else {
            // Cell area, handle item selection
            let cellIndex = (point.y - headerHeight) / cellHeight
            if let item = currentDirectory?.pageItem(at: Int(cellIndex)) {
                if item.isDirectory {
                    push(path: currentDirectory?.path, name: item.name)
                    return (true, nil)
                } else {
                    return (false, currentDirectory!.path + "/" + item.name)
                }
            }
        }
        return (false, nil)
    }
}

class PlayerControlView {
    let writer: PixelWriter
    var buffer: UnsafeMutableBufferPointer<UInt16> {
        return writer.buffer
    }
    var size: Size {
        return writer.screenSize
    }

    struct Icon {
        let offset: Point
        let icon: (size: Size, bitmap: [UInt32])

        func rect(margin: Int = 0) -> Rect {
            return Rect(
                origin: Point(x: offset.x - margin, y: offset.y - margin),
                size: Size(width: icon.size.width + margin * 2, height: icon.size.height + margin * 2)
            )
        }

        init(center: Point, icon: (size: Size, bitmap: [UInt32])) {
            self.offset = Point(x: center.x - icon.size.width / 2, y: center.y - icon.size.height / 2)
            self.icon = icon
        }
    }

    enum Event {
        case close
        case playPause
        case volume(diff: Int)
        case brightness(diff: Int)
    }

    private let closeButton = Icon(center: Point(x: 100, y: 150), icon: Icons.close)
    private let playButton = Icon(center: Point(x: 225, y: 150), icon: Icons.play)
    private let pauseButton = Icon(center: Point(x: 221, y: 150), icon: Icons.pause)
    private let volMinusButton = Icon(center: Point(x: 355, y: 85), icon: Icons.minus)
    private let volPlusButton = Icon(center: Point(x: 655, y: 85), icon: Icons.plus)
    private let volIcon = Icon(center: Point(x: 430, y: 85), icon: Icons.speaker)
    private let briMinusButton = Icon(center: Point(x: 355, y: 215), icon: Icons.minus)
    private let briPlusButton = Icon(center: Point(x: 655, y: 215), icon: Icons.plus)
    private let briIcon = Icon(center: Point(x: 433, y: 215), icon: Icons.light)

    init(size: Size) {
        let buffer = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: size.width * size.height)
        self.writer = PixelWriter(buffer: buffer, screenSize: size)
    }

    func draw(pause: Bool, volume: Int, brightness: Int) -> UnsafeMutableBufferPointer<UInt16> {
        writer.clear(color: .black)
        writer.drawLine(from: .zero, to: Point(x: size.width - 1, y: 0), color: .white)

        // Draw icons
        writer.drawBitmap(closeButton.icon, at: closeButton.offset, color: .white)
        if pause {
            writer.drawBitmap(pauseButton.icon, at: pauseButton.offset, color: .white)
        } else {
            writer.drawBitmap(playButton.icon, at: playButton.offset, color: .white)
        }
        writer.drawBitmap(volMinusButton.icon, at: volMinusButton.offset, color: .white)
        writer.drawBitmap(volPlusButton.icon, at: volPlusButton.offset, color: .white)
        writer.drawBitmap(volIcon.icon, at: volIcon.offset, color: .white)
        writer.drawBitmap(briMinusButton.icon, at: briMinusButton.offset, color: .white)
        writer.drawBitmap(briPlusButton.icon, at: briPlusButton.offset, color: .white)
        writer.drawBitmap(briIcon.icon, at: briIcon.offset, color: .white)

        let fontSize = 60
        let volumeText = "\(volume)"
        let volumeWidth = PixelWriter.defaultFont!.width(of: volumeText, fontSize: fontSize)
        writer.drawText("\(volume)",
            at: Point(x: 545 - volumeWidth / 2, y: 85 - fontSize / 2),
            fontSize: fontSize,
            color: .white
        )
        let brightnessText = "\(brightness)"
        let brightnessWidth = PixelWriter.defaultFont!.width(of: brightnessText, fontSize: fontSize)
        writer.drawText("\(brightness)",
            at: Point(x: 545 - brightnessWidth / 2, y: 215 - fontSize / 2),
            fontSize: fontSize,
            color: .white
        )

        return buffer
    }

    func onTap(point: Point) -> Event? {
        let margin = 20
        if closeButton.rect(margin: margin).contains(point) {
            return .close
        } else if playButton.rect(margin: margin).contains(point) {
            return .playPause
        } else if pauseButton.rect(margin: margin).contains(point) {
            return .playPause
        } else if volMinusButton.rect(margin: margin).contains(point) {
            return .volume(diff: -10)
        } else if volPlusButton.rect(margin: margin).contains(point) {
            return .volume(diff: 10)
        } else if briMinusButton.rect(margin: margin).contains(point) {
            return .brightness(diff: -10)
        } else if briPlusButton.rect(margin: margin).contains(point) {
            return .brightness(diff: 10)
        }
        return nil
    }
}

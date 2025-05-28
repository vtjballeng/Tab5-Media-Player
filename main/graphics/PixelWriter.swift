fileprivate let Log = Logger(tag: "PixelWriter")

struct PixelWriter {

    static var defaultFont: Font?

    let size: Size
    let offset: Point = .zero
    let buffer: UnsafeMutableBufferPointer<UInt16>
    let font: Font? = nil

    func drawPixel(at point: Point, color: Color) {
        let point = point + offset
        if point.x < 0 || point.x >= size.width || point.y < 0 || point.y >= size.height {
            return
        }
        buffer[Int(point.y * size.width) + Int(point.x)] = color.rgb565
    }

    func drawLine(from: Point, to: Point, color: Color) {
        let color = color.rgb565
        if from.x == to.x {
            let startY = min(from.y, to.y, 0)
            let endY = max(from.y, to.y, size.height - 1)
            for y in startY...endY {
                buffer[Int(y * size.width) + Int(from.x)] = color
            }
        } else if from.y == to.y {
            let startX = min(from.x, to.x, 0)
            let endX = max(from.x, to.x, size.width - 1)
            for x in startX...endX {
                buffer[Int(from.y) * size.width + Int(x)] = color
            }
        } else {
            Log.error("Only horizontal or vertical lines are supported.")
        }
    }

    func drawRect(rect: Rect, color: Color) {
        let startX = max(0, rect.minX)
        let endX = min(size.width, rect.maxX)
        let startY = max(0, rect.minY)
        let endY = min(size.height, rect.maxY)
        let color = color.rgb565

        for x in startX..<endX {
            buffer[Int(startY) * Int(size.width) + x] = color
            buffer[Int(endY - 1) * Int(size.width) + x] = color
        }
        for y in startY..<endY {
            buffer[y * Int(size.width) + startX] = color
            buffer[y * Int(size.width) + endX - 1] = color
        }
    }

    func drawText(_ text: String, at point: Point, fontSize: Int, color: Color) {
        guard let font = font ?? PixelWriter.defaultFont else {
            return
        }
        let color = color.rgb565
        font.drawBitmap(text, maxWidth: size.width - point.x) { (point, value) in
            let point = point + offset
            buffer[point.y * size.width + point.x] = value == 0 ? 0x0000 : color
        }
    }
}

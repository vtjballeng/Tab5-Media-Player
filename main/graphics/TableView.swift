class TableView {

    var size: Size
    var scrollOffset: Int = 0
    private var drawIntoFrameBuffer: (UnsafeMutableBufferPointer<UInt16>, Size) -> Void

    init(size: Size, draw: @escaping (UnsafeMutableBufferPointer<UInt16>, Size) -> Void) {
        self.size = size
        self.drawIntoFrameBuffer = draw
    }

    var count: Int { 0 }
    var cellHeight: Int { 44 }

    func drawRow(index: Int, into: inout [UInt16], size: Size) {
        // This method should be overridden by subclasses to draw the item
        fatalError("drawRow(item:at:into:) must be overridden")
    }

    private var rowCaches: (startIndex: Int, endIndex: Int, buffers: [[UInt16]])?
    private func renderRows() {
        let count = self.count
        let startIndex = scrollOffset / cellHeight
        let endIndex = min(count, startIndex + size.height / cellHeight + 1)
        if let rowCaches = rowCaches {
            if rowCaches.startIndex <= startIndex && rowCaches.endIndex >= endIndex { return }
            var newBuffers: [[UInt16]] = []
            for index in startIndex..<endIndex {
                if rowCaches.startIndex <= index && index < rowCaches.endIndex {
                    newBuffers.append(rowCaches.buffers[index - rowCaches.startIndex])
                    continue
                }
                var rowBuffer = [UInt16](unsafeUninitializedCapacity: size.pixels, initializingWith: { $1 = size.pixels })
                drawRow(index: index, into: &rowBuffer, size: Size(width: size.width, height: cellHeight))
                newBuffers.append(rowBuffer)
            }
            self.rowCaches = (startIndex: startIndex, endIndex: endIndex, buffers: newBuffers)
        } else {
            var newBuffers: [[UInt16]] = []
            for index in startIndex..<endIndex {
                var rowBuffer = [UInt16](unsafeUninitializedCapacity: size.pixels, initializingWith: { $1 = size.pixels })
                drawRow(index: index, into: &rowBuffer, size: Size(width: size.width, height: cellHeight))
                newBuffers.append(rowBuffer)
            }
            self.rowCaches = (startIndex: startIndex, endIndex: endIndex, buffers: newBuffers)
        }
    }
}

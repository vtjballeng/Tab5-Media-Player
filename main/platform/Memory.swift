class Memory {
    struct Capability: OptionSet {
        let rawValue: UInt32

        static let exec = Capability(rawValue: UInt32(MALLOC_CAP_EXEC))
        static let allow32bit = Capability(rawValue: UInt32(MALLOC_CAP_32BIT))
        static let allow8bit = Capability(rawValue: UInt32(MALLOC_CAP_8BIT))
        static let dma = Capability(rawValue: UInt32(MALLOC_CAP_DMA))
        static let pid2 = Capability(rawValue: UInt32(MALLOC_CAP_PID2))
        static let pid3 = Capability(rawValue: UInt32(MALLOC_CAP_PID3))
        static let pid4 = Capability(rawValue: UInt32(MALLOC_CAP_PID4))
        static let pid5 = Capability(rawValue: UInt32(MALLOC_CAP_PID5))
        static let pid6 = Capability(rawValue: UInt32(MALLOC_CAP_PID6))
        static let pid7 = Capability(rawValue: UInt32(MALLOC_CAP_PID7))
        static let spiram = Capability(rawValue: UInt32(MALLOC_CAP_SPIRAM))
        static let `internal` = Capability(rawValue: UInt32(MALLOC_CAP_INTERNAL))
        static let `default` = Capability(rawValue: UInt32(MALLOC_CAP_DEFAULT))
        static let iram8bit = Capability(rawValue: UInt32(MALLOC_CAP_IRAM_8BIT))
        static let retention = Capability(rawValue: UInt32(MALLOC_CAP_RETENTION))
        static let rtcram = Capability(rawValue: UInt32(MALLOC_CAP_RTCRAM))
        static let tcm = Capability(rawValue: UInt32(MALLOC_CAP_TCM))
        static let dmaDescAHB = Capability(rawValue: UInt32(MALLOC_CAP_DMA_DESC_AHB))
        static let dmaDescAXI = Capability(rawValue: UInt32(MALLOC_CAP_DMA_DESC_AXI))
        static let cacheAligned = Capability(rawValue: UInt32(MALLOC_CAP_CACHE_ALIGNED))
        static let simd = Capability(rawValue: UInt32(MALLOC_CAP_SIMD))
    }

    static func allocate<T>(type: T.Type, capacity: Int, capability: Capability = []) -> UniqueBuffer<T>? {
        let size = MemoryLayout<T>.size * capacity
        guard let pointer = heap_caps_malloc(size, capability.rawValue) else {
            return nil
        }
        let buffer = UnsafeMutableBufferPointer<T>(start: pointer.assumingMemoryBound(to: T.self), count: capacity)
        return UniqueBuffer<T>(buffer, dealloc: heap_caps_free)
    }

    protocol IntoRawPointer: ~Copyable {
        var rawPointer: UnsafeRawPointer { get }
    }
    protocol IntoMutableRawPointer: ~Copyable, IntoRawPointer {
        var mutableRawPointer: UnsafeMutableRawPointer { get }
    }
    protocol IntoPointer: ~Copyable, IntoRawPointer {
        associatedtype Element
        var pointer: UnsafePointer<Element> { get }
    }
    protocol IntoMutablePointer: ~Copyable, IntoMutableRawPointer, IntoPointer {
        var mutablePointer: UnsafeMutablePointer<Element> { get }
    }
    protocol IntoRawBuffer: ~Copyable, IntoRawPointer {
        var size: Int { get }
        var rawBuffer: UnsafeRawBufferPointer { get }
    }
    protocol IntoMutableRawBuffer: ~Copyable, IntoRawBuffer, IntoMutableRawPointer {
        var mutableRawBuffer: UnsafeMutableRawBufferPointer { get }
    }
    protocol IntoBuffer: ~Copyable, IntoPointer, IntoRawBuffer {
        var size: Int { get }
        var count: Int { get }
        var buffer: UnsafeBufferPointer<Element> { get }
    }
    protocol IntoMutableBuffer: ~Copyable, IntoBuffer, IntoMutableRawBuffer {
        var mutableBuffer: UnsafeMutableBufferPointer<Element> { get }
    }

    struct UniqueBuffer<T>: ~Copyable, IntoMutableBuffer {
        var rawPointer: UnsafeRawPointer { UnsafeRawPointer(mutableBuffer.baseAddress!) }
        var mutableRawPointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(mutableBuffer.baseAddress!) }
        var pointer: UnsafePointer<T> { UnsafePointer(mutableBuffer.baseAddress!) }
        var mutablePointer: UnsafeMutablePointer<T> { mutableBuffer.baseAddress! }
        var size: Int { MemoryLayout<T>.size * count }
        var rawBuffer: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: rawPointer, count: size) }
        var mutableRawBuffer: UnsafeMutableRawBufferPointer { UnsafeMutableRawBufferPointer(start: mutableRawPointer, count: size) }
        var count: Int { mutableBuffer.count }
        var buffer: UnsafeBufferPointer<T> { UnsafeBufferPointer(start: pointer, count: count) }
        let mutableBuffer: UnsafeMutableBufferPointer<T>
        private let dealloc: @convention(c) (UnsafeMutableRawPointer?) -> Void

        init(_ pointer: UnsafeMutableBufferPointer<T>, dealloc: @convention(c) (UnsafeMutableRawPointer?) -> Void) {
            self.mutableBuffer = pointer
            self.dealloc = dealloc
        }
        init(_ pointer: UnsafeMutablePointer<T>, count: Int, dealloc: @convention(c) (UnsafeMutableRawPointer?) -> Void) {
            self.init(UnsafeMutableBufferPointer(start: pointer, count: count), dealloc: dealloc)
        }
        init(_ pointer: UnsafeMutablePointer<T>, size: Int, dealloc: @convention(c) (UnsafeMutableRawPointer?) -> Void) {
            self.init(pointer, count: size / MemoryLayout<T>.size, dealloc: dealloc)
        }
        init(_ pointer: UnsafeMutableRawPointer, to: T.Type, count: Int, dealloc: @convention(c) (UnsafeMutableRawPointer?) -> Void) {
            let pointer = pointer.assumingMemoryBound(to: T.self)
            self.init(pointer, count: count, dealloc: dealloc)
        }
        init(_ pointer: UnsafeMutableRawPointer, to: T.Type, size: Int, dealloc: @convention(c) (UnsafeMutableRawPointer?) -> Void) {
            self.init(pointer, to: to, count: size / MemoryLayout<T>.size, dealloc: dealloc)
        }

        deinit {
            dealloc(mutableBuffer.baseAddress!)
        }

        consuming func shared() -> SharedBuffer<T> {
            let shared = SharedBuffer<T>(mutableBuffer, dealloc: dealloc)
            discard self
            return shared
        }
        func slice(start: Int = 0) -> UnsafeMutableBuffer<T> {
            UnsafeMutableBuffer<T>(mutablePointer.advanced(by: start), count: count - start)
        }
        func slice(start: Int = 0, count: Int) -> UnsafeMutableBuffer<T> {
            UnsafeMutableBuffer<T>(mutablePointer.advanced(by: start), count: count)
        }
        func slice(start: Int = 0, size: Int) -> UnsafeMutableBuffer<T> {
            UnsafeMutableBuffer<T>(mutablePointer.advanced(by: start), count: size / MemoryLayout<T>.size)
        }
        func unsafe() -> UnsafeMutableBuffer<T> {
            UnsafeMutableBuffer<T>(mutableBuffer)
        }

        subscript (_ index: Int) -> Element {
            get { mutablePointer[index] }
            mutating set { mutablePointer[index] = newValue }
        }
    }

    class SharedBuffer<T>: IntoMutableBuffer {
        var rawPointer: UnsafeRawPointer { UnsafeRawPointer(mutableBuffer.baseAddress!) }
        var mutableRawPointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(mutableBuffer.baseAddress!) }
        var pointer: UnsafePointer<T> { UnsafePointer(mutableBuffer.baseAddress!) }
        var mutablePointer: UnsafeMutablePointer<T> { mutableBuffer.baseAddress! }
        var size: Int { MemoryLayout<T>.size * count }
        var rawBuffer: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: rawPointer, count: size) }
        var mutableRawBuffer: UnsafeMutableRawBufferPointer { UnsafeMutableRawBufferPointer(start: mutableRawPointer, count: size) }
        var count: Int { mutableBuffer.count }
        var buffer: UnsafeBufferPointer<T> { UnsafeBufferPointer(start: pointer, count: count) }
        let mutableBuffer: UnsafeMutableBufferPointer<T>
        private let dealloc: @convention(c) (UnsafeMutableRawPointer?) -> Void

        init(_ pointer: UnsafeMutableBufferPointer<T>, dealloc: @convention(c) (UnsafeMutableRawPointer?) -> Void) {
            self.mutableBuffer = pointer
            self.dealloc = dealloc
        }
        convenience init(_ pointer: UnsafeMutablePointer<T>, count: Int, dealloc: @convention(c) (UnsafeMutableRawPointer?) -> Void) {
            self.init(UnsafeMutableBufferPointer(start: pointer, count: count), dealloc: dealloc)
        }
        convenience init(_ pointer: UnsafeMutablePointer<T>, size: Int, dealloc: @convention(c) (UnsafeMutableRawPointer?) -> Void) {
            self.init(pointer, count: size / MemoryLayout<T>.size, dealloc: dealloc)
        }
        convenience init(_ pointer: UnsafeMutableRawPointer, to: T.Type, count: Int, dealloc: @convention(c) (UnsafeMutableRawPointer?) -> Void) {
            let pointer = pointer.assumingMemoryBound(to: T.self)
            self.init(pointer, count: count, dealloc: dealloc)
        }
        convenience init(_ pointer: UnsafeMutableRawPointer, to: T.Type, size: Int, dealloc: @convention(c) (UnsafeMutableRawPointer?) -> Void) {
            self.init(pointer, to: to, count: size / MemoryLayout<T>.size, dealloc: dealloc)
        }

        deinit {
            dealloc(mutableBuffer.baseAddress!)
        }

        func slice(start: Int = 0) -> UnsafeMutableBuffer<T> {
            UnsafeMutableBuffer<T>(mutablePointer.advanced(by: start), count: count - start)
        }
        func slice(start: Int = 0, count: Int) -> UnsafeMutableBuffer<T> {
            UnsafeMutableBuffer<T>(mutablePointer.advanced(by: start), count: count)
        }
        func slice(start: Int = 0, size: Int) -> UnsafeMutableBuffer<T> {
            UnsafeMutableBuffer<T>(mutablePointer.advanced(by: start), count: size / MemoryLayout<T>.size)
        }
        func unsafe() -> UnsafeMutableBuffer<T> {
            UnsafeMutableBuffer<T>(mutableBuffer)
        }

        subscript (_ index: Int) -> Element {
            get { mutablePointer[index] }
            set { mutablePointer[index] = newValue }
        }
    }

    struct UnsafeMutableBuffer<T>: IntoMutableBuffer {
        var rawPointer: UnsafeRawPointer { UnsafeRawPointer(mutableBuffer.baseAddress!) }
        var mutableRawPointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(mutableBuffer.baseAddress!) }
        var pointer: UnsafePointer<T> { UnsafePointer(mutableBuffer.baseAddress!) }
        var mutablePointer: UnsafeMutablePointer<T> { mutableBuffer.baseAddress! }
        var size: Int { MemoryLayout<T>.size * count }
        var rawBuffer: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: rawPointer, count: size) }
        var mutableRawBuffer: UnsafeMutableRawBufferPointer { UnsafeMutableRawBufferPointer(start: mutableRawPointer, count: size) }
        var count: Int { mutableBuffer.count }
        var buffer: UnsafeBufferPointer<T> { UnsafeBufferPointer(start: pointer, count: count) }
        let mutableBuffer: UnsafeMutableBufferPointer<T>

        init(_ pointer: UnsafeMutableBufferPointer<T>) {
            self.mutableBuffer = pointer
        }
        init(_ pointer: UnsafeMutablePointer<T>, count: Int) {
            self.init(UnsafeMutableBufferPointer(start: pointer, count: count))
        }
        init(_ pointer: UnsafeMutablePointer<T>, size: Int) {
            self.init(pointer, count: size / MemoryLayout<T>.size)
        }
        init(_ pointer: UnsafeMutableRawPointer, to: T.Type, count: Int) {
            let pointer = pointer.assumingMemoryBound(to: T.self)
            self.init(pointer, count: count)
        }
        init(_ pointer: UnsafeMutableRawPointer, to: T.Type, size: Int) {
            self.init(pointer, to: to, count: size / MemoryLayout<T>.size)
        }

        func slice(start: Int = 0) -> UnsafeMutableBuffer<T> {
            UnsafeMutableBuffer<T>(mutablePointer.advanced(by: start), count: count - start)
        }
        func slice(start: Int = 0, count: Int) -> UnsafeMutableBuffer<T> {
            UnsafeMutableBuffer<T>(mutablePointer.advanced(by: start), count: count)
        }
        func slice(start: Int = 0, size: Int) -> UnsafeMutableBuffer<T> {
            UnsafeMutableBuffer<T>(mutablePointer.advanced(by: start), count: size / MemoryLayout<T>.size)
        }

        subscript (_ index: Int) -> Element {
            get { mutablePointer[index] }
            mutating set { mutablePointer[index] = newValue }
        }
    }
}

extension UnsafeRawPointer: Memory.IntoRawPointer {
    var rawPointer: UnsafeRawPointer { self }
}
extension UnsafeMutableRawPointer: Memory.IntoMutableRawPointer {
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(self) }
    var mutableRawPointer: UnsafeMutableRawPointer { self }
}
extension UnsafePointer: Memory.IntoPointer {
    typealias Element = Pointee
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(self) }
    var pointer: UnsafePointer<Element> { self }
}
extension UnsafeMutablePointer: Memory.IntoMutablePointer {
    typealias Element = Pointee
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(self) }
    var mutableRawPointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
    var pointer: UnsafePointer<Element> { UnsafePointer(self) }
    var mutablePointer: UnsafeMutablePointer<Element> { self }
}
extension UnsafeRawBufferPointer: Memory.IntoRawBuffer {
    var rawPointer: UnsafeRawPointer { baseAddress! }
    var size: Int { count }
    var rawBuffer: UnsafeRawBufferPointer { self }
}
extension UnsafeMutableRawBufferPointer: Memory.IntoMutableRawBuffer {
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(baseAddress!) }
    var mutableRawPointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(baseAddress!) }
    var size: Int { count }
    var rawBuffer: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: rawPointer, count: size) }
    var mutableRawBuffer: UnsafeMutableRawBufferPointer { self }
}
extension UnsafeBufferPointer: Memory.IntoBuffer {
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(baseAddress!) }
    var pointer: UnsafePointer<Element> { UnsafePointer(baseAddress!) }
    var size: Int { MemoryLayout<Element>.size * count }
    var rawBuffer: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: rawPointer, count: size) }
    var buffer: UnsafeBufferPointer<Element> { self }
}
extension UnsafeMutableBufferPointer: Memory.IntoMutableBuffer {
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(baseAddress!) }
    var mutableRawPointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(baseAddress!) }
    var pointer: UnsafePointer<Element> { UnsafePointer(baseAddress!) }
    var mutablePointer: UnsafeMutablePointer<Element> { baseAddress! }
    var size: Int { MemoryLayout<Element>.size * count }
    var rawBuffer: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: rawPointer, count: size) }
    var mutableRawBuffer: UnsafeMutableRawBufferPointer { UnsafeMutableRawBufferPointer(start: mutableRawPointer, count: size) }
    var buffer: UnsafeBufferPointer<Element> { UnsafeBufferPointer(start: pointer, count: count) }
    var mutableBuffer: UnsafeMutableBufferPointer<Element> { self }
}

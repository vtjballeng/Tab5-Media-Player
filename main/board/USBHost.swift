fileprivate let Log = Logger(tag: "USBHost")

class USBHost {

    func install() throws(IDF.Error) {
        var config = usb_host_config_t()
        config.intr_flags = ESP_INTR_FLAG_LEVEL1
        try IDF.Error.check(usb_host_install(&config))
        Task(name: "USBHost", priority: 10) { _ in self.task() }
    }

    private func task() {
        while true {
            var eventFlags: UInt32 = 0
            usb_host_lib_handle_events(portMAX_DELAY, &eventFlags)
            if (eventFlags & UInt32(USB_HOST_LIB_EVENT_FLAGS_NO_CLIENTS)) != 0 {
                usb_host_device_free_all()
            }
            if (eventFlags & UInt32(USB_HOST_LIB_EVENT_FLAGS_ALL_FREE)) != 0 {
                Log.info("All devices freed")
            }
        }
    }

    var deviceAddrList: [UInt8] {
        var addrList = [UInt8](repeating: 0, count: 16)
        var numDevices: Int32 = 0
        usb_host_device_addr_list_fill(Int32(addrList.count), &addrList, &numDevices)
        if numDevices != addrList.count {
            addrList.removeLast(addrList.count - Int(numDevices))
        }
        return addrList
    }
}

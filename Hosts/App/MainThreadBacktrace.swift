import Darwin
import Foundation

/// The main thread's stack, read from another thread while the main thread
/// is stuck.
///
/// `/usr/bin/sample` does this from outside, but it takes about a second to
/// attach: on a hang of a second and a half it caught only the idle run loop
/// afterwards, and attaching was itself a hitch of 0.18 s. From inside, a
/// backtrace is a `thread_suspend`, one `thread_get_state` and a walk up the
/// frame pointers, which every macOS binary and Swift by default keep: a few
/// microseconds of the main thread's time.
///
/// Nothing may allocate between suspending and resuming. The main thread can
/// be suspended holding the allocator's lock, and a `malloc` here would then
/// wait for it forever. Hence the buffer allocated once, up front.
final class MainThreadBacktrace: @unchecked Sendable {
    private let thread: thread_act_t
    private let stackLow: UInt
    private let stackHigh: UInt
    private let capacity = 128
    private let buffer: UnsafeMutablePointer<UInt>

    /// Must be made on the main thread: that is the thread it reads.
    init() {
        precondition(Thread.isMainThread)
        thread = mach_thread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        stackHigh = top
        stackLow = top - UInt(pthread_get_stacksize_np(pthread_self()))
        buffer = .allocate(capacity: capacity)
    }

    /// Return addresses, innermost first. Empty if the thread could not be
    /// read.
    func capture() -> [UInt] {
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        var count = 0
        if let (pc, fp) = registers() {
            buffer[0] = pc
            count = 1
            var frame = fp
            // Each frame starts with the caller's frame pointer, and the
            // return address sits right after it. Frames only ever get older
            // going up the stack, so a pointer that does not is the end.
            while count < capacity, frame >= stackLow, frame + 16 <= stackHigh, frame % 8 == 0 {
                let words = UnsafePointer<UInt>(bitPattern: frame)!
                let caller = words[0]
                let returnAddress = words[1]
                guard returnAddress != 0 else { break }
                buffer[count] = returnAddress
                count += 1
                guard caller > frame else { break }
                frame = caller
            }
        }
        thread_resume(thread)
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    private func registers() -> (pc: UInt, fp: UInt)? {
        #if arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(x86_THREAD_STATE64), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? (UInt(state.__rip), UInt(state.__rbp)) : nil
        #elseif arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? (UInt(state.__pc), UInt(state.__fp)) : nil
        #else
        return nil
        #endif
    }

    /// Names for addresses of this process, without attaching to it.
    ///
    /// `atos -p` would be simpler, and it cost a freeze of exactly 20 s, twice
    /// in two runs: it attaches to the live process and can hold it suspended
    /// until it times out — the one thing a tool for finding freezes must not
    /// do. So `dladdr` names the system's frames, whose symbols are exported,
    /// and `atos -o` reads the app's own executable from disk for the Swift
    /// functions and source lines that `dladdr` cannot see. Slow: call it
    /// after the hang, off the main thread.
    static func symbolicate(_ addresses: [UInt]) -> [UInt: String] {
        var names: [UInt: String] = [:]
        var ours: [(path: String, base: UInt, addresses: [UInt])] = []
        let bundle = Bundle.main.bundlePath

        for address in Set(addresses).sorted() {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let file = info.dli_fname else {
                names[address] = String(format: "0x%lx", address)
                continue
            }
            let path = String(cString: file)
            let base = UInt(bitPattern: info.dli_fbase)
            if path.hasPrefix(bundle) {
                if let index = ours.firstIndex(where: { $0.path == path }) {
                    ours[index].addresses.append(address)
                } else {
                    ours.append((path, base, [address]))
                }
            }
            let image = path.split(separator: "/").last.map(String.init) ?? path
            if let symbol = info.dli_sname {
                let offset = address - UInt(bitPattern: info.dli_saddr)
                names[address] = "\(String(cString: symbol)) (in \(image)) + \(offset)"
            } else {
                names[address] = String(format: "%@ + 0x%lx", image, address - base)
            }
        }

        for image in ours {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/atos")
            process.arguments = ["-o", image.path, "-l", String(format: "0x%lx", image.base)]
                + image.addresses.map { String(format: "0x%lx", $0) }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            guard process.terminationStatus == 0, lines.count == image.addresses.count else { continue }
            for (address, line) in zip(image.addresses, lines) where !line.hasPrefix("0x") {
                names[address] = String(line)
            }
        }
        return names
    }
}

#!/usr/bin/env swift

import Foundation

// Protocollo XPC (deve corrispondere a quello dell'helper)
@objc protocol FanHelperProtocol {
    func ping(reply: @escaping (Bool) -> Void)
    func getFanCount(reply: @escaping (Int) -> Void)
    func getFanRPM(index: Int, reply: @escaping (Int) -> Void)
    func getFanInfo(reply: @escaping ([String: Any]) -> Void)
    func setFanRPM(index: Int, rpm: Int, reply: @escaping (Bool) -> Void)
    func setFanMode(mode: Int, reply: @escaping (Bool) -> Void)
    func debugEnumerateKeys(reply: @escaping (String) -> Void)
    func isFanControlAvailable(reply: @escaping (Bool, String) -> Void)
    func testFOFCSequences(index: Int, targetRPM: Int, reply: @escaping (Bool, String) -> Void)
    func searchFOFCKeys(reply: @escaping (String) -> Void)
}

let FanHelperMachServiceName = "com.smol.fanhelper"

print("=== FOFC Test Script ===")
print("Connecting to helper...")

let connection = NSXPCConnection(machServiceName: FanHelperMachServiceName, options: .privileged)
connection.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
connection.resume()

guard let helper = connection.synchronousRemoteObjectProxyWithErrorHandler({ error in
    print("XPC Error: \(error)")
    exit(1)
}) as? FanHelperProtocol else {
    print("Failed to get helper proxy")
    exit(1)
}

// First search for FOFC keys
print("\n1. Searching for FOFC-related keys...")
let semaphore1 = DispatchSemaphore(value: 0)
helper.searchFOFCKeys { result in
    print("Search result: \(result)")
    semaphore1.signal()
}
semaphore1.wait()

// Wait a bit for the log to be written
Thread.sleep(forTimeInterval: 1.0)

// Then run the test sequences
print("\n2. Running FOFC sequence tests...")
let semaphore2 = DispatchSemaphore(value: 0)
helper.testFOFCSequences(index: 0, targetRPM: 3000) { success, message in
    print("Test result: success=\(success)")
    print("Message: \(message)")
    semaphore2.signal()
}
semaphore2.wait()

// Wait for log to be written
Thread.sleep(forTimeInterval: 1.0)

// Read the debug log
print("\n3. Debug log contents:")
if let log = try? String(contentsOfFile: "/tmp/smol_helper_debug.log", encoding: .utf8) {
    // Show last 100 lines
    let lines = log.components(separatedBy: "\n")
    let lastLines = lines.suffix(100)
    for line in lastLines {
        print(line)
    }
} else {
    print("Could not read debug log")
}

connection.invalidate()
print("\n=== Test Complete ===")

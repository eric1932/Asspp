import CApplePackageSAP
import Foundation

var failure: UnsafeMutablePointer<CChar>?
let hardware: [UInt8] = [2, 0, 0, 0, 0, 1]
let session = hardware.withUnsafeBufferPointer {
    apsap_create($0.baseAddress, UInt64($0.count), "/tmp/asspp-unused-cache", &failure)
}
guard session != 0 else { fatalError("C ABI session creation failed") }
apsap_cancel(session)
guard apsap_prepare(session, &failure) != 0, let error = failure else {
    fatalError("Cancelled session attempted preparation")
}
guard String(cString: error).contains("canceled") else { fatalError("Wrong cancellation result") }
apsap_free(error)
apsap_close(session)
apsap_close(session)
print("Static Swift C ABI lifecycle and cancellation passed without downloading resources")

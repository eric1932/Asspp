import CUnicorn
import Foundation

// Synthetic x86 code only. This executable never downloads assets or signs in.
enum ProbeError: Error {
    case emulator(String)
    case unexpectedResult(UInt64)
}

func checked(_ status: uc_err) throws {
    guard status == UC_ERR_OK else {
        throw ProbeError.emulator(String(cString: uc_strerror(status)))
    }
}

func run(_ instructions: [UInt8], expected: UInt64) throws {
    var engine: OpaquePointer?
    try checked(uc_open(UC_ARCH_X86, UC_MODE_64, &engine))
    defer { uc_close(engine) }

    let address: UInt64 = 0x10000
    try checked(uc_mem_map(engine, address, 0x10000, UInt32(UC_PROT_ALL.rawValue)))
    try instructions.withUnsafeBytes { bytes in
        try checked(uc_mem_write(engine, address, bytes.baseAddress, bytes.count))
    }
    try checked(uc_emu_start(engine, address, address + UInt64(instructions.count), 5_000_000, 10_000))
    var result: UInt64 = 0
    try checked(uc_reg_read(engine, Int32(UC_X86_REG_RAX.rawValue), &result))
    guard result == expected else { throw ProbeError.unexpectedResult(result) }
}

// mov rax, 42; add rax, 1
try run([0x48, 0xC7, 0xC0, 42, 0, 0, 0, 0x48, 0x83, 0xC0, 1], expected: 43)

// Long straight-line blocks exercise the TCI limitation seen by AssppWeb.
// xor eax, eax; 160 * inc rax
let longBlock: [UInt8] = [0x31, 0xC0] + Array(repeating: [UInt8](arrayLiteral: 0x48, 0xFF, 0xC0), count: 160).flatMap { $0 }
try run(longBlock, expected: 160)
print("Swift C bridge and long-block interpreter execution passed")

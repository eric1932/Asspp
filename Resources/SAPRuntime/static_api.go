package unicorn

/*
#include <stdint.h>
#include <unicorn/unicorn.h>

extern void assppCodeHook(uintptr_t token, uint64_t address, uint32_t size);
static void code_hook(uc_engine *engine, uint64_t address, uint32_t size, void *token) {
    assppCodeHook((uintptr_t)token, address, size);
}
static int32_t add_code_hook(uintptr_t engine, uintptr_t *handle, int32_t type,
    uintptr_t token, uint64_t begin, uint64_t end) {
    return uc_hook_add((uc_engine *)engine, (uc_hook *)handle, type, code_hook, (void *)token, begin, end);
}
static int32_t control(uintptr_t engine, uint32_t selector, uint32_t value) {
    return uc_ctl((uc_engine *)engine, selector, value);
}
*/
import "C"

import "unsafe"

// A statically compiled C trampoline replaces purego's dynamic callback path.
// No runtime library download, dlopen, code generation, or JIT is used.
//
//export assppCodeHook
func assppCodeHook(token C.uintptr_t, address C.uint64_t, size C.uint32_t) {
	if callback, ok := codeHookCallbacks.Load(uintptr(token)); ok {
		callback.(CodeHook)(uint64(address), uint32(size))
	}
}

func nativeEngine(handle uintptr) *C.uc_engine { return (*C.uc_engine)(unsafe.Pointer(handle)) }

func (e *Engine) register(_ uintptr) {
	e.api.version = func(major, minor *uint32) uint32 {
		return uint32(C.uc_version((*C.uint)(unsafe.Pointer(major)), (*C.uint)(unsafe.Pointer(minor))))
	}
	e.api.open = func(arch, mode int32, output *uintptr) int32 {
		var engine *C.uc_engine
		status := C.uc_open(C.uc_arch(arch), C.uc_mode(mode), &engine)
		*output = uintptr(unsafe.Pointer(engine))
		return int32(status)
	}
	e.api.close = func(h uintptr) int32 { return int32(C.uc_close(nativeEngine(h))) }
	e.api.query = func(h uintptr, query int32, value *uint64) int32 {
		var result C.size_t
		status := C.uc_query(nativeEngine(h), C.uc_query_type(query), &result)
		*value = uint64(result)
		return int32(status)
	}
	e.api.ctl = func(h uintptr, selector, value uint32) int32 {
		return int32(C.control(C.uintptr_t(h), C.uint32_t(selector), C.uint32_t(value)))
	}
	e.api.strerror = func(code int32) string { return C.GoString(C.uc_strerror(C.uc_err(code))) }
	e.api.memMap = func(h uintptr, address, size uint64, protection uint32) int32 {
		return int32(C.uc_mem_map(nativeEngine(h), C.uint64_t(address), C.size_t(size), C.uint32_t(protection)))
	}
	e.api.memUnmap = func(h uintptr, address, size uint64) int32 {
		return int32(C.uc_mem_unmap(nativeEngine(h), C.uint64_t(address), C.size_t(size)))
	}
	e.api.memRead = func(h uintptr, address uint64, pointer unsafe.Pointer, size uint64) int32 {
		return int32(C.uc_mem_read(nativeEngine(h), C.uint64_t(address), pointer, C.uint64_t(size)))
	}
	e.api.memWrite = func(h uintptr, address uint64, pointer unsafe.Pointer, size uint64) int32 {
		return int32(C.uc_mem_write(nativeEngine(h), C.uint64_t(address), pointer, C.uint64_t(size)))
	}
	e.api.regRead = func(h uintptr, register int32, pointer unsafe.Pointer) int32 {
		return int32(C.uc_reg_read(nativeEngine(h), C.int(register), pointer))
	}
	e.api.regWrite = func(h uintptr, register int32, pointer unsafe.Pointer) int32 {
		return int32(C.uc_reg_write(nativeEngine(h), C.int(register), pointer))
	}
	e.api.emuStart = func(h uintptr, begin, end, timeout, count uint64) int32 {
		return int32(C.uc_emu_start(nativeEngine(h), C.uint64_t(begin), C.uint64_t(end), C.uint64_t(timeout), C.size_t(count)))
	}
	e.api.emuStop = func(h uintptr) int32 { return int32(C.uc_emu_stop(nativeEngine(h))) }
	e.api.hookAdd = func(h uintptr, output *uintptr, kind int32, _ uintptr, token uintptr, begin, end uint64) int32 {
		return int32(C.add_code_hook(C.uintptr_t(h), (*C.uintptr_t)(unsafe.Pointer(output)), C.int32_t(kind), C.uintptr_t(token), C.uint64_t(begin), C.uint64_t(end)))
	}
	e.api.hookDel = func(h, hook uintptr) int32 { return int32(C.uc_hook_del(nativeEngine(h), C.uc_hook(hook))) }
}

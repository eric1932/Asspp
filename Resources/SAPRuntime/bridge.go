package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"sync/atomic"
	"unsafe"

	"github.com/majd/ipatool/v2/internal/sap/assets"
	"github.com/majd/ipatool/v2/internal/sap/machine"
)

type session struct {
	operation sync.Mutex
	state     sync.Mutex
	ctx       context.Context
	cancel    context.CancelFunc
	hardware  []byte
	directory string
	bundled   bool
	guest     *machine.Machine
	context   uint64
	ready     bool
	closed    bool
}

var sessions sync.Map
var nextSession atomic.Uint64

func fail(output **C.char, err error) C.int32_t {
	if output != nil {
		*output = C.CString(err.Error())
	}
	return -1
}

func resolve(handle C.uint64_t) (*session, error) {
	value, ok := sessions.Load(uint64(handle))
	if !ok {
		return nil, errors.New("SAP session is closed")
	}
	return value.(*session), nil
}

func payload(input *C.uint8_t, count C.uint64_t) ([]byte, error) {
	if input == nil || count == 0 || count > 1<<20 {
		return nil, errors.New("invalid SAP input size")
	}
	return C.GoBytes(unsafe.Pointer(input), C.int(count)), nil
}

func result(data []byte, output **C.uint8_t, count *C.uint64_t) {
	*output = nil
	*count = C.uint64_t(len(data))
	if len(data) > 0 {
		*output = (*C.uint8_t)(C.CBytes(data))
	}
}

//export apsap_create
func apsap_create(hardware *C.uint8_t, count C.uint64_t, directory *C.char, output **C.char) C.uint64_t {
	return createSession(hardware, count, directory, false, output)
}

//export apsap_create_bundled
func apsap_create_bundled(hardware *C.uint8_t, count C.uint64_t, directory *C.char, output **C.char) C.uint64_t {
	return createSession(hardware, count, directory, true, output)
}

func createSession(hardware *C.uint8_t, count C.uint64_t, directory *C.char, bundled bool, output **C.char) C.uint64_t {
	if output != nil {
		*output = nil
	}
	if hardware == nil || count == 0 || count > 20 || directory == nil {
		fail(output, errors.New("invalid SAP session configuration"))
		return 0
	}
	path := C.GoString(directory)
	if !filepath.IsAbs(path) {
		fail(output, errors.New("SAP resource path must be absolute"))
		return 0
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &session{ctx: ctx, cancel: cancel, hardware: C.GoBytes(unsafe.Pointer(hardware), C.int(count)), directory: path, bundled: bundled}
	id := nextSession.Add(1)
	sessions.Store(id, s)
	return C.uint64_t(id)
}

//export apsap_prepare
func apsap_prepare(handle C.uint64_t, output **C.char) C.int32_t {
	if output != nil {
		*output = nil
	}
	s, err := resolve(handle)
	if err != nil {
		return fail(output, err)
	}
	s.operation.Lock()
	defer s.operation.Unlock()
	if err := s.ctx.Err(); err != nil {
		return fail(output, err)
	}
	if s.closed || s.guest != nil {
		return fail(output, errors.New("SAP session cannot be prepared twice"))
	}
	var bundle assets.Bundle
	if s.bundled {
		bundle, err = assets.LoadBundledDirectory(s.ctx, s.directory)
	} else {
		bundle, err = assets.LoadFromDirectory(s.ctx, s.directory)
	}
	if err != nil {
		return fail(output, err)
	}
	guest, err := machine.Open(s.ctx, bundle)
	if err != nil {
		return fail(output, err)
	}
	s.state.Lock()
	s.guest = guest
	s.state.Unlock()
	if err := s.ctx.Err(); err != nil {
		return fail(output, err)
	}
	s.context, err = guest.Initialize(s.hardware)
	if err != nil {
		return fail(output, err)
	}
	return 0
}

//export apsap_exchange
func apsap_exchange(handle C.uint64_t, version C.uint32_t, input *C.uint8_t, count C.uint64_t,
	output **C.uint8_t, outputCount *C.uint64_t, state *C.int32_t, failure **C.char) C.int32_t {
	if failure != nil {
		*failure = nil
	}
	if output == nil || outputCount == nil || state == nil {
		return fail(failure, errors.New("missing SAP output fields"))
	}
	*output = nil
	*outputCount = 0
	*state = -1
	data, err := payload(input, count)
	if err != nil {
		return fail(failure, err)
	}
	defer clear(data)
	s, err := resolve(handle)
	if err != nil {
		return fail(failure, err)
	}
	s.operation.Lock()
	defer s.operation.Unlock()
	if err := s.ctx.Err(); err != nil {
		return fail(failure, err)
	}
	if s.closed || s.guest == nil || s.context == 0 || s.ready || version != 200 {
		return fail(failure, errors.New("SAP session is not ready for exchange"))
	}
	reply, next, err := s.guest.Exchange(uint32(version), s.hardware, s.context, data)
	if err != nil {
		return fail(failure, err)
	}
	result(reply, output, outputCount)
	clear(reply)
	*state = C.int32_t(next)
	s.ready = next == 0
	return 0
}

//export apsap_sign
func apsap_sign(handle C.uint64_t, input *C.uint8_t, count C.uint64_t,
	output **C.uint8_t, outputCount *C.uint64_t, failure **C.char) C.int32_t {
	if failure != nil {
		*failure = nil
	}
	if output == nil || outputCount == nil {
		return fail(failure, errors.New("missing SAP output fields"))
	}
	*output = nil
	*outputCount = 0
	data, err := payload(input, count)
	if err != nil {
		return fail(failure, err)
	}
	defer clear(data)
	s, err := resolve(handle)
	if err != nil {
		return fail(failure, err)
	}
	s.operation.Lock()
	defer s.operation.Unlock()
	if err := s.ctx.Err(); err != nil {
		return fail(failure, err)
	}
	if s.closed || !s.ready {
		return fail(failure, errors.New("SAP setup is incomplete"))
	}
	signature, err := s.guest.Sign(s.context, data)
	if err != nil {
		return fail(failure, err)
	}
	if len(signature) == 0 {
		return fail(failure, errors.New("empty SAP signature"))
	}
	result(signature, output, outputCount)
	clear(signature)
	return 0
}

//export apsap_cancel
func apsap_cancel(handle C.uint64_t) {
	s, err := resolve(handle)
	if err != nil {
		return
	}
	s.cancel()
	s.state.Lock()
	defer s.state.Unlock()
	if s.guest != nil {
		_ = s.guest.Stop()
	}
}

//export apsap_close
func apsap_close(handle C.uint64_t) {
	value, ok := sessions.LoadAndDelete(uint64(handle))
	if !ok {
		return
	}
	s := value.(*session)
	s.cancel()
	s.state.Lock()
	if s.guest != nil {
		_ = s.guest.Stop()
	}
	s.state.Unlock()
	s.operation.Lock()
	defer s.operation.Unlock()
	s.state.Lock()
	defer s.state.Unlock()
	s.closed = true
	if s.guest != nil {
		if s.context != 0 {
			_ = s.guest.Teardown(s.context)
		}
		_ = s.guest.Close()
		s.guest = nil
	}
	clear(s.hardware)
}

//export apsap_free
func apsap_free(allocation unsafe.Pointer) { C.free(allocation) }

func main() {}

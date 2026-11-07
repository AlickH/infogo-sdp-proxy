//go:build windows

package main

import (
	"syscall"
	"unsafe"
)

// fatalBox 在 GUI 模式下没有控制台，用弹窗提示致命错误
func fatalBox(msg string) {
	user32 := syscall.NewLazyDLL("user32.dll")
	proc := user32.NewProc("MessageBoxW")
	title, _ := syscall.UTF16PtrFromString("SDP 代理")
	text, _ := syscall.UTF16PtrFromString(msg)
	proc.Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x10)
}

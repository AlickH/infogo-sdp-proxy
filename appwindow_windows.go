//go:build windows

package main

import (
	"log"
	"path/filepath"
	"syscall"
	"time"
	"unsafe"

	webview2 "github.com/jchv/go-webview2"
)

var (
	user32Win          = syscall.NewLazyDLL("user32.dll")
	shcoreWin          = syscall.NewLazyDLL("shcore.dll")
	procFindWindowW    = user32Win.NewProc("FindWindowW")
	procShowWindow     = user32Win.NewProc("ShowWindow")
	procSetForeground  = user32Win.NewProc("SetForegroundWindow")
	procSetDpiCtx      = user32Win.NewProc("SetProcessDpiAwarenessContext")
	procSetDpiShcore   = shcoreWin.NewProc("SetProcessDpiAwareness")
	procSetDpiAware    = user32Win.NewProc("SetProcessDPIAware")
	procGetWindowRect  = user32Win.NewProc("GetWindowRect")
	procGetDpiForWin   = user32Win.NewProc("GetDpiForWindow")
	procSetWindowPos   = user32Win.NewProc("SetWindowPos")
	procCallWindowProc = user32Win.NewProc("CallWindowProcW")
	procSetWndProcLong = user32Win.NewProc("SetWindowLongPtrW")
)

const (
	swpNoMove   = 0x0002
	swpNoZOrder = 0x0004
	gwlpWndProc = ^uintptr(3) // -4
	swHide      = 0
	swShow      = 5
)

var originalWndProc uintptr

// windowProc 拦截关闭按钮：隐藏窗口而不是销毁（托盘继续运行）
var windowProc = syscall.NewCallback(func(hwnd, msg, wparam, lparam uintptr) uintptr {
	if msg == wmClose {
		procShowWindow.Call(hwnd, swHide)
		return 0
	}
	r, _, _ := procCallWindowProc.Call(originalWndProc, hwnd, msg, wparam, lparam)
	return r
})

// enforceMinSize 限制窗口最小尺寸（WebView2 没有提供 min size 选项）
func enforceMinSize(hwnd uintptr, minW, minH int) {
	go func() {
		type rect struct{ Left, Top, Right, Bottom int32 }
		for {
			var r rect
			if ok, _, _ := procGetWindowRect.Call(hwnd, uintptr(unsafe.Pointer(&r))); ok != 0 {
				w := int(r.Right - r.Left)
				h := int(r.Bottom - r.Top)
				if w < minW || h < minH {
					if w < minW {
						w = minW
					}
					if h < minH {
						h = minH
					}
					procSetWindowPos.Call(hwnd, 0, 0, 0, uintptr(w), uintptr(h), swpNoMove|swpNoZOrder)
				}
			}
			time.Sleep(300 * time.Millisecond)
		}
	}()
}

// enableDPIAwareness 开启 Per-Monitor V2 DPI 感知，避免高分屏文字发虚
func enableDPIAwareness() {
	if r, _, _ := procSetDpiCtx.Call(^uintptr(3)); r != 0 {
		return
	}
	if r, _, _ := procSetDpiShcore.Call(2); r == 0 {
		return
	}
	procSetDpiAware.Call()
}

const swRestore = 9

// runNativeWindow 用 WebView2 创建原生窗口加载管理界面，返回 false 表示不可用
func runNativeWindow(url, dataDir string) bool {
	opts := webview2.WebViewOptions{
		Debug:     false,
		AutoFocus: true,
		DataPath:  filepath.Join(dataDir, "webview2"),
		WindowOptions: webview2.WindowOptions{
			Title:  "SDP 代理",
			Width:  560,
			Height: 820,
			IconId: 1, // 内嵌图标资源 ID
			Center: true,
		},
	}
	w := webview2.NewWithOptions(opts)
	if w == nil {
		return false
	}
	defer w.Destroy()
	if hwnd := uintptr(w.Window()); hwnd != 0 {
		// 子类化窗口过程：X 按钮改为隐藏到托盘
		if orig, _, _ := procSetWndProcLong.Call(hwnd, gwlpWndProc, windowProc); orig != 0 {
			originalWndProc = orig
		}
		// 按系统 DPI 缩放窗口尺寸（内容按 CSS 像素设计）
		dpi, _, _ := procGetDpiForWin.Call(hwnd)
		if dpi == 0 {
			dpi = 96
		}
		scale := float64(dpi) / 96.0
		desWinW := int(560 * scale)
		desWinH := int(820 * scale)
		procSetWindowPos.Call(hwnd, 0, 0, 0, uintptr(desWinW), uintptr(desWinH), swpNoMove|swpNoZOrder)
		enforceMinSize(hwnd, int(520*scale), int(760*scale))
	}
	w.Navigate(url)
	w.Run()
	return true
}

// activateExistingWindow 激活已运行实例的窗口
func activateExistingWindow() bool {
	title, _ := syscall.UTF16PtrFromString("SDP 代理")
	hwnd, _, _ := procFindWindowW.Call(0, uintptr(unsafe.Pointer(title)))
	if hwnd == 0 {
		return false
	}
	procShowWindow.Call(hwnd, swShow)
	procShowWindow.Call(hwnd, swRestore)
	procSetForeground.Call(hwnd)
	log.Printf("[界面] 已激活现有窗口")
	return true
}

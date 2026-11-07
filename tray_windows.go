//go:build windows

package main

// Windows 托盘图标（纯 Win32 API，无 CGO）

import (
	"log"
	"runtime"
	"syscall"
	"time"
	"unsafe"
)

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")

	procRegisterClassExW    = user32.NewProc("RegisterClassExW")
	procCreateWindowExW     = user32.NewProc("CreateWindowExW")
	procDefWindowProcW      = user32.NewProc("DefWindowProcW")
	procGetMessageW         = user32.NewProc("GetMessageW")
	procTranslateMessage    = user32.NewProc("TranslateMessage")
	procDispatchMessageW    = user32.NewProc("DispatchMessageW")
	procLoadIconW           = user32.NewProc("LoadIconW")
	procCreatePopupMenu     = user32.NewProc("CreatePopupMenu")
	procAppendMenuW         = user32.NewProc("AppendMenuW")
	procTrackPopupMenu      = user32.NewProc("TrackPopupMenu")
	procGetCursorPos        = user32.NewProc("GetCursorPos")
	procSetForegroundWindow = user32.NewProc("SetForegroundWindow")
	procDestroyMenu         = user32.NewProc("DestroyMenu")
	procShellNotifyIconW    = shell32.NewProc("Shell_NotifyIconW")
	procGetModuleHandleW    = kernel32.NewProc("GetModuleHandleW")
	procEnumWindows         = user32.NewProc("EnumWindows")
	procGetWindowTextW      = user32.NewProc("GetWindowTextW")
	procGetClassNameW       = user32.NewProc("GetClassNameW")
	procPostMessageW        = user32.NewProc("PostMessageW")
	procRegisterWindowMsg   = user32.NewProc("RegisterWindowMessageW")
)

const (
	wmDestroy       = 0x0002
	wmApp           = 0x8000
	wmTrayCallback  = wmApp + 1
	wmLButtonDblClk = 0x0203
	wmRButtonUp     = 0x0205

	nimAdd     = 0x00000000
	nimModify  = 0x00000001
	nimDelete  = 0x00000002
	nifMessage = 0x00000001
	nifIcon    = 0x00000002
	nifTip     = 0x00000004

	mfString       = 0x00000000
	idiApplication = 32512

	tpmRightButton = 0x0002
	tpmReturnCmd   = 0x0100
	tpmNoNotify    = 0x0080
)

var (
	trayNID           notifyIconData
	taskbarCreatedMsg uint32
)

// addTrayIcon 添加/刷新托盘图标（Explorer 重启后需要重新添加）
func addTrayIcon() bool {
	if trayNID.HWnd == 0 {
		return false
	}
	for i := 0; i < 5; i++ {
		if r, _, _ := procShellNotifyIconW.Call(nimAdd, uintptr(unsafe.Pointer(&trayNID))); r != 0 {
			return true
		}
		time.Sleep(500 * time.Millisecond)
	}
	return false
}

type wndClassEx struct {
	CbSize        uint32
	Style         uint32
	LpfnWndProc   uintptr
	CbClsExtra    int32
	CbWndExtra    int32
	HInstance     syscall.Handle
	HIcon         syscall.Handle
	HCursor       syscall.Handle
	HbrBackground syscall.Handle
	LpszMenuName  *uint16
	LpszClassName *uint16
	HIconSm       syscall.Handle
}

type point struct{ X, Y int32 }

type msg struct {
	HWnd    syscall.Handle
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      point
}

type notifyIconData struct {
	CbSize           uint32
	HWnd             syscall.Handle
	UID              uint32
	UFlags           uint32
	UCallbackMessage uint32
	HIcon            syscall.Handle
	SzTip            [128]uint16
	DwState          uint32
	DwStateMask      uint32
	SzInfo           [256]uint16
	UVersion         uint32
	SzInfoTitle      [64]uint16
	DwInfoFlags      uint32
	GuidItem         syscall.GUID
	HBalloonIcon     syscall.Handle
}

const (
	wmClose     = 0x0010
	trayIDOpen  = 1001
	trayIDProxy = 1002
	trayIDExit  = 1003
)

var (
	trayHWnd   syscall.Handle
	trayOnOpen func()
)

// copyUTF16 安全拷贝 UTF-16 字符串到固定数组
func copyUTF16(dst []uint16, s string) {
	u := syscall.StringToUTF16(s)
	n := copy(dst[:len(dst)-1], u)
	dst[n] = 0
}

func utf16Ptr(s string) *uint16 {
	p, _ := syscall.UTF16PtrFromString(s)
	return p
}

func trayProc(hwnd syscall.Handle, m uint32, wparam, lparam uintptr) uintptr {
	switch m {
	case wmTrayCallback:
		switch uint32(lparam) & 0xFFFF {
		case wmLButtonDblClk:
			if trayOnOpen != nil {
				go trayOnOpen()
			}
		case wmRButtonUp:
			showTrayMenu(hwnd)
		}
		return 0
	case wmDestroy:
		nid := notifyIconData{CbSize: uint32(unsafe.Sizeof(notifyIconData{})), HWnd: hwnd, UID: 1}
		procShellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(&nid)))
		return 0
	}
	ret, _, _ := procDefWindowProcW.Call(uintptr(hwnd), uintptr(m), wparam, lparam)
	return ret
}

func showTrayMenu(hwnd syscall.Handle) {
	hMenu, _, _ := procCreatePopupMenu.Call()
	if hMenu == 0 {
		return
	}
	defer procDestroyMenu.Call(hMenu)
	procAppendMenuW.Call(hMenu, mfString, trayIDOpen, uintptr(unsafe.Pointer(utf16Ptr("打开主界面"))))
	proxyLabel := "开启系统代理"
	if systemProxyEnabled() {
		proxyLabel = "关闭系统代理"
	}
	procAppendMenuW.Call(hMenu, mfString, trayIDProxy, uintptr(unsafe.Pointer(utf16Ptr(proxyLabel))))
	procAppendMenuW.Call(hMenu, mfString, trayIDExit, uintptr(unsafe.Pointer(utf16Ptr("退出"))))

	var pt point
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	procSetForegroundWindow.Call(uintptr(hwnd))
	cmd, _, _ := procTrackPopupMenu.Call(hMenu,
		tpmRightButton|tpmReturnCmd|tpmNoNotify,
		uintptr(pt.X), uintptr(pt.Y), 0, uintptr(hwnd), 0)

	switch cmd {
	case trayIDOpen:
		if trayOnOpen != nil {
			go trayOnOpen()
		}
	case trayIDProxy:
		_ = setSystemProxy(!systemProxyEnabled())
	case trayIDExit:
		cleanupAndExit()
	}
}

// startTray 启动托盘图标；onOpen 为打开主界面的回调
func startTray(onOpen func()) {
	trayOnOpen = onOpen
	go func() {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("托盘崩溃: %v", r)
			}
		}()
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()

		hInst, _, _ := procGetModuleHandleW.Call(0)
		className := utf16Ptr("SDPProxyTrayWnd")
		wc := wndClassEx{
			CbSize:        uint32(unsafe.Sizeof(wndClassEx{})),
			LpfnWndProc:   syscall.NewCallback(trayProc),
			HInstance:     syscall.Handle(hInst),
			LpszClassName: className,
		}
		if r, _, err := procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc))); r == 0 {
			log.Printf("注册托盘窗口类失败: %v", err)
			return
		}
		hwnd, _, err := procCreateWindowExW.Call(0, uintptr(unsafe.Pointer(className)),
			uintptr(unsafe.Pointer(utf16Ptr("SDP 代理"))), 0, 0, 0, 0, 0, 0, 0, hInst, 0)
		if hwnd == 0 {
			log.Printf("创建托盘窗口失败: %v", err)
			return
		}
		trayHWnd = syscall.Handle(hwnd)

		// 优先使用 exe 内嵌图标（资源 ID 1），否则退回系统默认图标
		hIcon, _, _ := procLoadIconW.Call(hInst, 1)
		if hIcon == 0 {
			hIcon, _, _ = procLoadIconW.Call(0, idiApplication)
		}
		nid := notifyIconData{
			CbSize:           uint32(unsafe.Sizeof(notifyIconData{})),
			HWnd:             trayHWnd,
			UID:              1,
			UFlags:           nifMessage | nifIcon | nifTip,
			UCallbackMessage: wmTrayCallback,
			HIcon:            syscall.Handle(hIcon),
		}
		copyUTF16(nid.SzTip[:], "SDP 代理 - 零信任隧道")
		trayNID = nid
		// Explorer 重启广播
		if name, err := syscall.UTF16PtrFromString("TaskbarCreated"); err == nil {
			if r, _, _ := procRegisterWindowMsg.Call(uintptr(unsafe.Pointer(name))); r != 0 {
				taskbarCreatedMsg = uint32(r)
			}
		}
		if !addTrayIcon() {
			log.Printf("添加托盘图标失败(已重试5次)")
			return
		}
		log.Printf("托盘图标已创建")

		// 每 30 秒刷新一次，防止 Explorer 重启后图标消失
		go func() {
			t := time.NewTicker(30 * time.Second)
			defer t.Stop()
			for range t.C {
				if !addTrayIcon() {
					log.Printf("[托盘] 图标刷新失败，稍后重试")
				}
			}
		}()

		var m msg
		for {
			r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
			if int32(r) <= 0 {
				return
			}
			procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
			procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
		}
	}()
}

// cleanupAndExit 退出前恢复系统代理并关闭本程序的界面窗口
func cleanupAndExit() {
	if systemProxyEnabled() {
		if err := setSystemProxy(false); err != nil {
			log.Printf("恢复系统代理失败: %v", err)
		} else {
			log.Printf("已关闭系统代理")
		}
	}
	closeAppWindows()
	log.Printf("SDP 代理已退出")
	syscall.Exit(0)
}

// closeAppWindows 关闭标题为 "SDP" 的 Edge 应用窗口
func closeAppWindows() {
	cb := syscall.NewCallback(func(hwnd uintptr, lparam uintptr) uintptr {
		var title [256]uint16
		procGetWindowTextW.Call(hwnd, uintptr(unsafe.Pointer(&title[0])), 256)
		var cls [256]uint16
		procGetClassNameW.Call(hwnd, uintptr(unsafe.Pointer(&cls[0])), 256)
		t := syscall.UTF16ToString(title[:])
		c := syscall.UTF16ToString(cls[:])
		if (t == "SDP 代理" || t == "SDP") && c == "Chrome_WidgetWin_1" {
			procPostMessageW.Call(hwnd, wmClose, 0, 0)
			log.Printf("已关闭界面窗口: %s", t)
		}
		return 1
	})
	procEnumWindows.Call(cb, 0)
}

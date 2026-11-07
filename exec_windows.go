//go:build windows

package main

import (
	"os/exec"
	"syscall"
)

// hideWindow 避免子进程弹出控制台窗口
func hideWindow(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.HideWindow = true
}

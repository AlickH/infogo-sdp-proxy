//go:build !windows

package main

// 非 Windows 平台不使用 WebView2 原生窗口
func runNativeWindow(url, dataDir string) bool { return false }
func activateExistingWindow() bool             { return false }

// cleanupAndExit 非 Windows 平台无需恢复系统代理（由 App 自身处理）
func cleanupAndExit() {}

// enableDPIAwareness 非 Windows 平台无 DPI 问题
func enableDPIAwareness() {}

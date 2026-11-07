//go:build !windows

package main

// 非 Windows 平台无托盘（macOS 由 App 的菜单栏图标负责）
func startTray(onOpen func()) {}

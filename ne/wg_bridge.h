#ifndef WG_BRIDGE_H
#define WG_BRIDGE_H
// WGNE 桥接头：向 Swift 暴露 WireGuardKitGo(wg* Go c-archive 函数) 与
// WireGuardKitC(控制通道 ctl_info / sockaddr_ctl / CTLIOCGINFO、密钥函数)。
// <sys/types.h> 必须在 WireGuardKitC.h 之前，因其内部用到 u_int32_t / u_char。
#include <sys/types.h>
#include <stdint.h>
#include <stdbool.h>
#include "wireguard.h"
#include "WireGuardKitC.h"
#endif

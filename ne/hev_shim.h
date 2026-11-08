#ifndef HEV_SHIM_H
#define HEV_SHIM_H

int hev_socks5_tunnel_main_from_str(const unsigned char *config_str,
                                    unsigned int config_len,
                                    int tun_fd);
void hev_socks5_tunnel_quit(void);

#endif

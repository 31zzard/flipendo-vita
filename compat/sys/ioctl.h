#pragma once

// The Vita's newlib has no <sys/ioctl.h>. The network classes only call ioctl(fd, FIONBIO, &flag) to make a
// socket non-blocking, and networking is not used in single player: a do-nothing stand-in is enough for now.

#ifndef FIONBIO
#define FIONBIO 0x5421
#endif

#ifdef __cplusplus
extern "C" {
#endif

static inline int ioctl(int fd, unsigned long request, ...)
{
	(void)fd;
	(void)request;
	return 0;
}

#ifdef __cplusplus
}
#endif

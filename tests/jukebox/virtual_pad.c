#include <errno.h>
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int jukebox_test_pad_create(const char *name) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return -1;
    struct uinput_setup setup = {0};
    setup.id.bustype = BUS_USB;
    setup.id.vendor = 0x1234;
    setup.id.product = 0x5678;
    snprintf(setup.name, sizeof(setup.name), "%s", name);
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 ||
        ioctl(fd, UI_SET_KEYBIT, BTN_TRIGGER) < 0 ||
        ioctl(fd, UI_SET_EVBIT, EV_ABS) < 0) goto fail;
    for (int button = BTN_GAMEPAD; button <= BTN_THUMBR; ++button) {
        if (ioctl(fd, UI_SET_KEYBIT, button) < 0) goto fail;
    }
    for (int axis = ABS_X; axis <= ABS_Y; ++axis) {
        struct uinput_abs_setup abs = {0};
        abs.code = axis;
        abs.absinfo.minimum = -32767;
        abs.absinfo.maximum = 32767;
        if (ioctl(fd, UI_SET_ABSBIT, axis) < 0) goto fail;
        if (ioctl(fd, UI_ABS_SETUP, &abs) < 0) goto fail;
    }
    if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) goto fail;
    return fd;
fail:
    {
        int saved = errno;
        close(fd);
        errno = saved;
    }
    return -1;
}

void jukebox_test_pad_destroy(int fd) {
    if (fd >= 0) {
        ioctl(fd, UI_DEV_DESTROY);
        close(fd);
    }
}

/*
 * The smallest useful CVD1 initramfs init for the Ubuntu Touch guest.
 *
 * The guest kernel is built with virtio-blk and ext4 in the image, so all this has to do is bring
 * up the virtual devices, mount the root filesystem the bootconfig names, and hand over. No
 * busybox, no shell, no package dependencies: a statically linked binary is the whole initramfs
 * payload (plus one file), which keeps the guest's attack surface and the CI's dependency surface
 * both small.
 *
 * Bootconfig / command line keys understood:
 *   carbonhv.root=/dev/vda     root block device (default /dev/vda)
 *   carbonhv.rootfs=ext4       filesystem type (default ext4)
 *   carbonhv.rootflags=ro      mount flags (default rw)
 *
 * It mounts nothing it was not told to mount, never writes to the block device in ro mode, and
 * execs /sbin/init from the new root. If anything fails it prints the reason and panics the way an
 * init is supposed to: it is the guest's boot, and a silent hang is worse than an error.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <unistd.h>

static char root_device[64] = "/dev/vda";
static char root_fstype[32] = "ext4";
static unsigned long root_flags = 0;

static void die(const char *what)
{
    printf("carbonhv-init: %s: %s\n", what, strerror(errno));
    fflush(stdout);
    sync();
    reboot(RB_POWER_OFF);
    for (;;) {
        pause();
    }
}

/* Reads one `key=value` from the kernel command line (bootconfig keys arrive here too). */
static int cmdline_value(const char *key, char *out, size_t len)
{
    FILE *file = fopen("/proc/cmdline", "r");
    char line[4096];
    size_t key_len = strlen(key);
    char *cursor;

    if (!file) {
        return 0;
    }
    if (!fgets(line, sizeof(line), file)) {
        fclose(file);
        return 0;
    }
    fclose(file);

    for (cursor = line; (cursor = strstr(cursor, key)) != NULL; cursor += key_len) {
        if (cursor != line && cursor[-1] != ' ' && cursor[-1] != '\n') {
            continue;
        }
        if (cursor[key_len] != '=') {
            continue;
        }
        cursor += key_len + 1;
        size_t i = 0;
        while (cursor[i] && cursor[i] != ' ' && cursor[i] != '\n' && i + 1 < len) {
            out[i] = cursor[i];
            i++;
        }
        out[i] = '\0';
        return 1;
    }
    return 0;
}

static void wait_for_device(const char *path, int seconds)
{
    struct stat info;
    int waited;

    for (waited = 0; waited < seconds * 10; waited++) {
        if (stat(path, &info) == 0) {
            return;
        }
        usleep(100000);
    }
    errno = ENODEV;
    die(path);
}

int main(void)
{
    char value[64];

    if (cmdline_value("carbonhv.root", root_device, sizeof(root_device))) {
        /* keep the parsed value */
    }
    if (cmdline_value("carbonhv.rootfs", root_fstype, sizeof(root_fstype))) {
        /* keep the parsed value */
    }
    if (cmdline_value("carbonhv.rootflags", value, sizeof(value))) {
        root_flags = strcmp(value, "ro") == 0 ? MS_RDONLY : 0;
    }

    printf("carbonhv-init: root=%s fstype=%s flags=%s\n", root_device, root_fstype,
           root_flags & MS_RDONLY ? "ro" : "rw");
    fflush(stdout);

    mkdir("/dev", 0755);
    mkdir("/proc", 0755);
    mkdir("/sys", 0755);
    mkdir("/root", 0755);

    if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) != 0) {
        die("mount devtmpfs");
    }
    wait_for_device(root_device, 30);

    if (mount(root_device, "/root", root_fstype, root_flags, NULL) != 0) {
        die("mount root filesystem");
    }
    if (mount("proc", "/root/proc", "proc", 0, NULL) != 0) {
        printf("carbonhv-init: proc not mounted yet (%s), the guest init will do it\n",
               strerror(errno));
    }
    if (mount("sysfs", "/root/sys", "sysfs", 0, NULL) != 0) {
        printf("carbonhv-init: sysfs not mounted yet (%s), the guest init will do it\n",
               strerror(errno));
    }

    if (chdir("/root") != 0) {
        die("chdir into the new root");
    }
    if (mount(".", "/", NULL, MS_MOVE, NULL) != 0) {
        die("move the new root");
    }
    if (chroot(".") != 0) {
        die("chroot");
    }
    chdir("/");

    printf("carbonhv-init: handing over to /sbin/init\n");
    fflush(stdout);
    char *const argv[] = {"/sbin/init", NULL};
    char *const envp[] = {"HOME=/", "TERM=linux", "PATH=/sbin:/bin:/usr/sbin:/usr/bin", NULL};
    execve("/sbin/init", argv, envp);
    die("execve /sbin/init");
    return 0;
}

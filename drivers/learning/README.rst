================
Learning Drivers
================

This directory is for local, incremental driver learning experiments.
Keep code small, focused, and easy to debug with QEMU + GDB.

Current examples:

- ``chardev/learn_char.c``: simple character device ``/dev/learn_char0``
- ``learning/learn_char_test.c``: userspace read/write/ioctl test

Typical enable/build flow::

  scripts/config --file out/.config -e LEARNING_DRIVERS -e LEARNING_CHARDEV
  make O=out ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- olddefconfig
  make O=out ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc) Image dtbs

Userspace test build/run::

  make -C learning
  learning/learn_char_test /dev/learn_char0

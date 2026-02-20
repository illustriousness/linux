// SPDX-License-Identifier: GPL-2.0
/*
 * 面向 drivers/learning/chardev/learn_char.c 的最小用户态测试程序
 *
 * 编译：
 *   make -C learning
 *
 * 运行：
 *   learning/learn_char_test [/dev/learn_char0]
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define LEARN_CHAR_IOC_MAGIC	'L'
#define LEARN_CHAR_IOC_CLEAR	_IO(LEARN_CHAR_IOC_MAGIC, 0)
#define LEARN_CHAR_IOC_GET_LEN	_IOR(LEARN_CHAR_IOC_MAGIC, 1, uint32_t)

static int test_write_then_get_len(const char *path, const char *payload)
{
	int fd;
	ssize_t n;
	uint32_t len = 0;

	fd = open(path, O_RDWR);
	if (fd < 0) {
		perror("open(O_RDWR)");
		return -1;
	}

	if (ioctl(fd, LEARN_CHAR_IOC_CLEAR) < 0) {
		perror("ioctl(CLEAR)");
		close(fd);
		return -1;
	}

	n = write(fd, payload, strlen(payload));
	if (n < 0) {
		perror("write");
		close(fd);
		return -1;
	}

	if (ioctl(fd, LEARN_CHAR_IOC_GET_LEN, &len) < 0) {
		perror("ioctl(GET_LEN)");
		close(fd);
		return -1;
	}

	printf("[OK] write %zd bytes, driver len=%u\n", n, len);
	close(fd);
	return 0;
}

static int test_read_back(const char *path, const char *expected)
{
	int fd;
	char buf[512];
	ssize_t n;

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		perror("open(O_RDONLY)");
		return -1;
	}

	memset(buf, 0, sizeof(buf));
	n = read(fd, buf, sizeof(buf) - 1);
	if (n < 0) {
		perror("read");
		close(fd);
		return -1;
	}

	printf("[OK] read %zd bytes: \"%s\"\n", n, buf);
	if ((size_t)n != strlen(expected) || memcmp(buf, expected, n) != 0) {
		fprintf(stderr, "[FAIL] payload mismatch\n");
		close(fd);
		return -1;
	}

	close(fd);
	return 0;
}

static int test_clear_then_verify_len(const char *path)
{
	int fd;
	uint32_t len = 1234;

	fd = open(path, O_RDWR);
	if (fd < 0) {
		perror("open(O_RDWR)");
		return -1;
	}

	if (ioctl(fd, LEARN_CHAR_IOC_CLEAR) < 0) {
		perror("ioctl(CLEAR)");
		close(fd);
		return -1;
	}

	if (ioctl(fd, LEARN_CHAR_IOC_GET_LEN, &len) < 0) {
		perror("ioctl(GET_LEN)");
		close(fd);
		return -1;
	}

	printf("[OK] clear done, driver len=%u\n", len);
	if (len != 0) {
		fprintf(stderr, "[FAIL] len should be 0 after clear\n");
		close(fd);
		return -1;
	}

	close(fd);
	return 0;
}

int main(int argc, char **argv)
{
	const char *path = "/dev/learn_char0";
	const char *payload = "hello-from-userspace";

	if (argc > 1)
		path = argv[1];

	printf("Testing device: %s\n", path);

	if (test_write_then_get_len(path, payload) < 0)
		return 1;

	if (test_read_back(path, payload) < 0)
		return 1;

	if (test_clear_then_verify_len(path) < 0)
		return 1;

	printf("[PASS] all learn_char tests passed\n");
	return 0;
}

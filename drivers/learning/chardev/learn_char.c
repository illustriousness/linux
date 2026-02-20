// SPDX-License-Identifier: GPL-2.0
/*
 * 面向 QEMU/GDB 调试练习的字符设备示例。
 *
 * 建议断点：
 *   learn_char_init
 *   learn_char_open
 *   learn_char_read
 *   learn_char_write
 *   learn_char_ioctl
 *   learn_char_exit
 */

#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/fs.h>
#include <linux/ioctl.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/types.h>
#include <linux/uaccess.h>

#define LEARN_CHAR_NAME		"learn_char0"
#define LEARN_CHAR_CLASS	"learning"
#define LEARN_CHAR_BUF_SIZE	4096

#define LEARN_CHAR_IOC_MAGIC	'L'
#define LEARN_CHAR_IOC_CLEAR	_IO(LEARN_CHAR_IOC_MAGIC, 0)
#define LEARN_CHAR_IOC_GET_LEN	_IOR(LEARN_CHAR_IOC_MAGIC, 1, __u32)

/* 设备运行时状态；本示例只维护一个全局实例。 */
struct learn_char_device {
	/* 嵌入式 cdev 对象，由 cdev_add()/cdev_del() 管理。 */
	struct cdev cdev;

	/* 通过 alloc_chrdev_region() 申请到的设备号。 */
	dev_t devt;

	/* sysfs class 与 /dev 节点对应的对象。 */
	struct class *class;
	struct device *device;

	/* 串行化保护 buffer/len 及文件偏移相关更新。 */
	struct mutex lock;

	/* 内核侧数据缓冲区。 */
	char *buffer;

	/* 当前缓冲区中的有效字节数。 */
	size_t len;
};

/* 本学习驱动只创建一个设备实例。 */
static struct learn_char_device learn_char_dev;

static int learn_char_open(struct inode *inode, struct file *file)
{
	/* 该参数在本示例中不使用。 */
	(void)inode;

	/* 保存私有数据指针，供 read/write/ioctl 快速访问状态。 */
	file->private_data = &learn_char_dev;

	/* 打印日志，便于确认 open 路径并配合 GDB 调试。 */
	pr_info("learn_char: open\n");

	return 0;
}

static int learn_char_release(struct inode *inode, struct file *file)
{
	/* 这两个参数在本最小示例中不使用。 */
	(void)inode;
	(void)file;

	/* 打印 close 路径日志，便于观察生命周期。 */
	pr_info("learn_char: release\n");

	return 0;
}

static ssize_t learn_char_read(struct file *file, char __user *buf, size_t count,
			       loff_t *ppos)
{
	struct learn_char_device *dev = file->private_data;
	size_t pos;
	size_t available;
	size_t to_copy;
	ssize_t ret;

	/* 用户未请求读取任何数据，直接返回。 */
	if (!count)
		return 0;

	/* 拒绝非法负偏移。 */
	if (*ppos < 0)
		return -EINVAL;

	/* 加锁保护共享状态，避免并发读写竞争。 */
	mutex_lock(&dev->lock);

	/* 记录当前读取偏移。 */
	pos = (size_t)*ppos;

	/* 读取偏移已到有效数据末尾，返回 EOF。 */
	if (pos >= dev->len) {
		ret = 0;
		goto out_unlock;
	}

	/* 计算从当前偏移到有效数据末尾的可读字节数。 */
	available = dev->len - pos;

	/* 限制拷贝长度，避免越过有效数据范围。 */
	to_copy = min(count, available);

	/* 把内核缓冲区数据复制到用户缓冲区。 */
	if (copy_to_user(buf, dev->buffer + pos, to_copy)) {
		ret = -EFAULT;
		goto out_unlock;
	}

	/* 按成功读取的字节数推进文件偏移。 */
	*ppos = pos + to_copy;
	ret = to_copy;
	pr_info("learn_char: read %zu bytes (pos=%lld)\n", to_copy,
		(long long)*ppos);

out_unlock:
	/* 返回前统一释放互斥锁。 */
	mutex_unlock(&dev->lock);
	return ret;
}

static ssize_t learn_char_write(struct file *file, const char __user *buf,
				size_t count, loff_t *ppos)
{
	struct learn_char_device *dev = file->private_data;
	size_t pos;
	size_t space;
	size_t to_copy;
	ssize_t ret;

	/* 用户未请求写入任何数据，直接返回。 */
	if (!count)
		return 0;

	/* 拒绝非法负偏移。 */
	if (*ppos < 0)
		return -EINVAL;

	/* 加锁保护共享状态，避免并发读写竞争。 */
	mutex_lock(&dev->lock);

	/* 记录当前写入偏移。 */
	pos = (size_t)*ppos;

	/* 偏移已超出固定缓冲区，说明无空间可写。 */
	if (pos >= LEARN_CHAR_BUF_SIZE) {
		ret = -ENOSPC;
		goto out_unlock;
	}

	/* 计算从当前偏移开始剩余可写空间。 */
	space = LEARN_CHAR_BUF_SIZE - pos;

	/* 限制写入长度，避免写越界。 */
	to_copy = min(count, space);

	/* 把用户数据复制到内核缓冲区。 */
	if (copy_from_user(dev->buffer + pos, buf, to_copy)) {
		ret = -EFAULT;
		goto out_unlock;
	}

	/* 推进偏移，并按需更新有效数据长度。 */
	pos += to_copy;
	*ppos = pos;
	dev->len = max(dev->len, pos);
	ret = to_copy;

	/* 打印写路径日志，便于调试与运行期观察。 */
	pr_info("learn_char: write %zu bytes (len=%zu)\n", to_copy, dev->len);

out_unlock:
	/* 返回前统一释放互斥锁。 */
	mutex_unlock(&dev->lock);
	return ret;
}

static long learn_char_ioctl(struct file *file, unsigned int cmd,
			     unsigned long arg)
{
	struct learn_char_device *dev = file->private_data;
	__u32 len;

	switch (cmd) {
	case LEARN_CHAR_IOC_CLEAR:
		/* 清空缓冲区并重置有效长度。 */
		mutex_lock(&dev->lock);
		memset(dev->buffer, 0, LEARN_CHAR_BUF_SIZE);
		dev->len = 0;
		mutex_unlock(&dev->lock);
		pr_info("learn_char: clear buffer\n");
		return 0;

	case LEARN_CHAR_IOC_GET_LEN:
		/* 在持锁状态下读取当前有效长度快照。 */
		mutex_lock(&dev->lock);
		len = dev->len;
		mutex_unlock(&dev->lock);

		/* 通过 ioctl 的 arg 指针把长度返回给用户态。 */
		if (copy_to_user((__u32 __user *)arg, &len, sizeof(len)))
			return -EFAULT;
		return 0;

	default:
		/* 未知 ioctl 命令。 */
		return -ENOTTY;
	}
}

/* 字符设备操作表。 */
static const struct file_operations learn_char_fops = {
	.owner = THIS_MODULE,
	.open = learn_char_open,
	.release = learn_char_release,
	.read = learn_char_read,
	.write = learn_char_write,
	.unlocked_ioctl = learn_char_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl = learn_char_ioctl,
#endif
	.llseek = noop_llseek,
};

static int __init learn_char_init(void)
{
	int ret;

	/* 分配并清零设备数据缓冲区。 */
	learn_char_dev.buffer = kzalloc(LEARN_CHAR_BUF_SIZE, GFP_KERNEL);
	if (!learn_char_dev.buffer)
		return -ENOMEM;

	/* 首次使用前初始化互斥锁。 */
	mutex_init(&learn_char_dev.lock);

	/* 动态申请一组 major/minor。 */
	ret = alloc_chrdev_region(&learn_char_dev.devt, 0, 1, LEARN_CHAR_NAME);
	if (ret)
		goto err_free_buffer;

	/* 初始化并注册 cdev，让 VFS 可分发文件操作。 */
	cdev_init(&learn_char_dev.cdev, &learn_char_fops);
	learn_char_dev.cdev.owner = THIS_MODULE;

	ret = cdev_add(&learn_char_dev.cdev, learn_char_dev.devt, 1);
	if (ret)
		goto err_unregister;

	/* 创建 class，出现在 /sys/class/learning/ 下。 */
	learn_char_dev.class = class_create(LEARN_CHAR_CLASS);
	if (IS_ERR(learn_char_dev.class)) {
		ret = PTR_ERR(learn_char_dev.class);
		goto err_cdev_del;
	}

	/* 通过 udev/devtmpfs 创建 /dev/learn_char0 节点。 */
	learn_char_dev.device = device_create(learn_char_dev.class, NULL,
					      learn_char_dev.devt, NULL,
					      LEARN_CHAR_NAME);
	if (IS_ERR(learn_char_dev.device)) {
		ret = PTR_ERR(learn_char_dev.device);
		goto err_class_destroy;
	}

	pr_info("learn_char: registered /dev/%s (major=%u minor=%u)\n",
		LEARN_CHAR_NAME, MAJOR(learn_char_dev.devt),
		MINOR(learn_char_dev.devt));
	return 0;

/* 按与 init 相反的顺序回滚，保证资源释放正确。 */
err_class_destroy:
	class_destroy(learn_char_dev.class);
err_cdev_del:
	cdev_del(&learn_char_dev.cdev);
err_unregister:
	unregister_chrdev_region(learn_char_dev.devt, 1);
err_free_buffer:
	kfree(learn_char_dev.buffer);
	return ret;
}

static void __exit learn_char_exit(void)
{
	/* 模块卸载或内建收尾路径。 */
	device_destroy(learn_char_dev.class, learn_char_dev.devt);
	class_destroy(learn_char_dev.class);
	cdev_del(&learn_char_dev.cdev);
	unregister_chrdev_region(learn_char_dev.devt, 1);
	kfree(learn_char_dev.buffer);

	pr_info("learn_char: removed\n");
}

module_init(learn_char_init);
module_exit(learn_char_exit);

MODULE_DESCRIPTION("Learning character-device example");
MODULE_AUTHOR("Local Learning Tree");
MODULE_LICENSE("GPL");

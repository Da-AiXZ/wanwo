#include <LindChain/ProcEnvironment/Surface/libkern/kxld/image.h>
#include <LindChain/ProcEnvironment/Surface/libkern/klog.h>

#define KEXT_IDENTITY "$(NXBundleIdentifier)"

/* entry point of KEXT */
kern_return_t kinit(void)
{
	klog_log(KEXT_IDENTITY, "hello, from kext");	/* prints to kmsg */
	return KERN_SUCCESS;
}

/*
 * KEXT's on ksurface are required to have a module
 * initialization constructors are on purposefully
 * ignored for correctness and safety reasons about
 * the state of the userspace kernel.
 */
EXPORT_KSURFACE_MODULE({
	.magic = KSURFACE_KMOD_MAGIC,
	.abi_version = KSURFACE_KMOD_ABI_VERSION,
	.identifier = KEXT_IDENTITY,
	.version = KMOD_VERSION(1, 0, 0),
	.flags = KMOD_FLAG_PERSISTENT,

	/* must represent the amount of dependencies in the array */
	.dependency_count = 2,

	/*
	 * initialization handler which runs synchronious to all
	 * other kext's that initialize. please do not waste time.
	 */
	.init = kinit,

	/*
	 * if something wen't wrong kernel will tell us to deinitialize,
	 * in that case the kext shall tear it's modification's down, on
	 * failure it causes a panic.
	 */
	.deinit = NULL,

	/* get's it's own thread */
	.start = NULL,

	/* kernel tells us to stop, meaning the thread must be stoppable */
	.stop = NULL,

	/*
	 * dependencies if available load and initialize before your KEXT
	 * which means if not available KXLD won't load your KEXT,
	 * also the dependencies after being loaded and your KEXT loads
	 * into Nyxian's address space they dependecy entries get both
	 * version entries swapped with the actual version present
	 * so you can do runtime checks and such easily.
	 */
	.dependencies = {
		{
			.identifier = "com.apple.iphoneos",
			.min_version = KMOD_VERSION(18, 0, 0),
			.max_version = KMOD_VERSION(99, 99, 99),	/* spcify your ceiling */
		},
		{
			.identifier = "ksurface",
			.min_version = KMOD_VERSION(0, 11, 5),
			.max_version = KMOD_VERSION(0, 11, 5),
		}
	},
})

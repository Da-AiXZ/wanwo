/*
 * MIT License
 *
 * Copyright (c) 2026 emexlab
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#import <MobileDevelopmentKit/MDKThreadPool.h>
#import <MobileDevelopmentKit/MDKThreadPoolPrivate.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>

/* WanWo J-fix (registration: docs/gpl-compliance.md section N11): compile
 * thread stack expansion. Upstream created threads with attr == NULL, which
 * hands out the iOS secondary-thread default 512KB stack. Consumers run the
 * whole in-process build (including the recursive-descent compiler frontend)
 * on these threads: NXBuilder.buildProject dispatches via MDKPthreadDispatch
 * (NXBuilder.swift:303), and multithreaded clang compile phases execute
 * CCJobExecuteJob on MDKThreadPool worker threads (MDKPhaseEngine.m
 * withMultithreadingSupport:YES -> MDKPhaseRunner runPhase -> dispatchExecution).
 * Production crash evidence (.ips, 2026-10-21): SIGBUS on the 544KB stack
 * region of the dispatch thread inside the Swift parser/demangler recursion.
 * swiftc frontend convention is 8-64MB stacks, so we align to 64MB. Stack
 * pages are materialized lazily, so the reservation is cheap. Semantics are
 * otherwise unchanged (same signature, same dispatch behavior, larger stack). */
#define MDK_COMPILE_THREAD_STACK_SIZE (64UL * 1024UL * 1024UL)

/* WanWo J-fix helper: build a pthread_attr_t with the 64MB stack size.
 * Returns YES and leaves *outAttr initialized-and-ready on success; on any
 * failure it logs the reason, destroys the partial attr if needed, and
 * returns NO so the caller falls back to NULL attr (upstream default-stack
 * behavior). Never throws. */
static BOOL MDKThreadAttrWithLargeStack(pthread_attr_t *outAttr)
{
    int initResult = pthread_attr_init(outAttr);
    if(initResult != 0)
    {
        NSLog(@"MDKThreadPool: pthread_attr_init failed (%d), falling back to default stack size", initResult);
        return NO;
    }
    int stackResult = pthread_attr_setstacksize(outAttr, MDK_COMPILE_THREAD_STACK_SIZE);
    if(stackResult != 0)
    {
        NSLog(@"MDKThreadPool: pthread_attr_setstacksize(%lu) failed (%d), falling back to default stack size", (unsigned long)MDK_COMPILE_THREAD_STACK_SIZE, stackResult);
        pthread_attr_destroy(outAttr);
        return NO;
    }
    return YES;
}

static inline void *pthreadBlockTrampoline(void *ptr)
{
    void (^block)(void) = (__bridge_transfer void (^)(void))ptr;
    @autoreleasepool {
        block();
    }
    return NULL;
}

void MDKPthreadDispatch(void (^code)(void))
{
    pthread_t thread;
    void *blockPointer = (__bridge_retained void *)code;
    /* WanWo J-fix: create the thread with a 64MB stack when the attribute
     * machinery cooperates; fall back to NULL attr (upstream behavior)
     * otherwise. The attribute is destroyed immediately after creation. */
    pthread_attr_t dispatchAttr;
    pthread_attr_t *dispatchAttrPointer = NULL;
    if(MDKThreadAttrWithLargeStack(&dispatchAttr))
    {
        dispatchAttrPointer = &dispatchAttr;
    }
    int createResult = pthread_create(&thread, dispatchAttrPointer, pthreadBlockTrampoline, blockPointer);
    if(dispatchAttrPointer != NULL)
    {
        pthread_attr_destroy(&dispatchAttr);
    }
    if(createResult != 0)
    {
        /* WanWo J-fix hardening: upstream ignored the pthread_create return
         * value (leaking the retained block and calling pthread_detach on an
         * uninitialized thread). Release the block and skip the detach; the
         * success-path semantics are untouched. */
        NSLog(@"MDKPthreadDispatch: pthread_create failed (%d), block dropped", createResult);
        void (^droppedBlock)(void) = (__bridge_transfer void (^)(void))blockPointer;
        (void)droppedBlock;
        return;
    }
    pthread_detach(thread);
}

static void *MDKWorkerThreadMain(void *arg)
{
    /* getting thread worker */
    MDKWorkerThread *worker = (MDKWorkerThread *)arg;
    
    /* pin current thread to a certain groups of CPUs */
    thread_affinity_policy_data_t policy = { .affinity_tag = worker->cpuIndex + 1 };
    thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_AFFINITY_POLICY, (thread_policy_t)&policy, THREAD_AFFINITY_POLICY_COUNT);
    
    /* execution flow loop, gives me mach syscall server vibes ^^ */
    while(!atomic_load(&worker->shouldExit))
    {
        pthread_mutex_lock(&worker->mutex);
        
        /* waiting on work */
        while(!atomic_load(&worker->hasWork) && !atomic_load(&worker->shouldExit))
        {
            pthread_cond_wait(&worker->cond, &worker->mutex);
        }
        
        /* checking if we shall exit */
        if(atomic_load(&worker->shouldExit))
        {
            pthread_mutex_unlock(&worker->mutex);
            break;
        }
        
        /* setting blocks up  */
        void (^code)(void) = (__bridge_transfer void (^)(void))worker->currentBlock;
        void (^completion)(void) = (__bridge_transfer void (^)(void))worker->completionBlock;
        
        /* clear worker references to allow ARC to release captured objects */
        worker->currentBlock = NULL;
        worker->completionBlock = NULL;
        
        /* storing that we are working on API request rawrrr x3 */
        atomic_store(&worker->hasWork, false);
        
        pthread_mutex_unlock(&worker->mutex);
        
        /* checking if there is code to execute */
        @autoreleasepool {
            if(code)
            {
                code();
            }
            if(completion)
            {
                completion();
            }
        }
    }
    
    return NULL;
}

@interface MDKThreadPool ()

@property (nonatomic, strong, readonly) dispatch_semaphore_t semaphore;
@property (nonatomic, readonly) CFIndex threads;
@property (nonatomic, assign) MDKWorkerThread *workers;
@property (nonatomic, assign) CFIndex workerCount;

@end

@implementation MDKThreadPool {
    int _freeStack[64];
    CFIndex _freeTop;
    pthread_mutex_t _freeStackMutex;
}

+ (instancetype)poolWithThreads:(CFIndex)threads
{
    return [[self alloc] initWithThreads:threads];
}

+ (instancetype)pool
{
    return [[self alloc] init];
}

- (instancetype)initWithThreads:(CFIndex)threads
{
    /* otherwise memory corruption due to fixed amount of _freeStack */
    if(threads > 64)
    {
        threads = 64;
    }
    
    self = [super init];
    _threads = (threads == 0) ? 1 : threads;
    _semaphore = dispatch_semaphore_create(threads);
    _workerCount = threads;
    _workers = calloc(threads, sizeof(MDKWorkerThread));
    pthread_mutex_init(&_freeStackMutex, NULL);
    for(int i = 0; i < threads; i++)
    {
        _freeStack[i] = i;
    }
    _freeTop = threads;
    /* WanWo J-fix: pool workers execute multithreaded clang compile jobs
     * (MDKPhaseRunner dispatches CCJobExecuteJob onto these threads), so they
     * need the same 64MB stack as the MDKPthreadDispatch thread. A single
     * attribute is shared by every worker and destroyed after the loop. */
    pthread_attr_t workerAttr;
    pthread_attr_t *workerAttrPointer = NULL;
    if(MDKThreadAttrWithLargeStack(&workerAttr))
    {
        workerAttrPointer = &workerAttr;
    }
    for(int i = 0; i < threads; i++)
    {
        _workers[i].cpuIndex = i % CCGetMaximumPerformanceCores();
        _workers[i].shouldExit = false;
        _workers[i].hasWork = false;
        pthread_mutex_init(&_workers[i].mutex, NULL);
        pthread_cond_init(&_workers[i].cond, NULL);
        int createResult = pthread_create(&_workers[i].thread, workerAttrPointer, MDKWorkerThreadMain, &_workers[i]);
        if(createResult != 0)
        {
            NSLog(@"MDKThreadPool: worker pthread_create failed (index %d, result %d)", i, createResult);
        }
    }
    if(workerAttrPointer != NULL)
    {
        pthread_attr_destroy(&workerAttr);
    }
    return self;
}

- (instancetype)init
{
    return [self initWithThreads:(uint32_t)CCGetMaximumPerformanceCores()];
}

- (void)dispatchExecution:(void (^)(void))code withCompletion:(void (^)(void))completion
{
    dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
    
    pthread_mutex_lock(&_freeStackMutex);
    int workerIndex = _freeStack[--_freeTop];
    pthread_mutex_unlock(&_freeStackMutex);
    
    MDKWorkerThread *worker = &_workers[workerIndex];
    dispatch_semaphore_t sem = self.semaphore;
    pthread_mutex_lock(&worker->mutex);
    worker->currentBlock = (__bridge_retained void *)code;
    worker->completionBlock = (__bridge_retained void *)^{
        if (completion) completion();
        pthread_mutex_lock(&self->_freeStackMutex);
        self->_freeStack[self->_freeTop++] = workerIndex;
        pthread_mutex_unlock(&self->_freeStackMutex);
        dispatch_semaphore_signal(sem);
    };
    atomic_store(&worker->hasWork, true);
    pthread_cond_signal(&worker->cond);
    pthread_mutex_unlock(&worker->mutex);
}

- (void)dealloc
{
    for(int i = 0; i < _workerCount; i++)
    {
        pthread_mutex_lock(&_workers[i].mutex);
        atomic_store(&_workers[i].shouldExit, true);
        pthread_cond_broadcast(&_workers[i].cond);
        pthread_mutex_unlock(&_workers[i].mutex);
    }
    for(int i = 0; i < _workerCount; i++)
    {
        pthread_join(_workers[i].thread, NULL);
        pthread_mutex_destroy(&_workers[i].mutex);
        pthread_cond_destroy(&_workers[i].cond);
    }
    pthread_mutex_destroy(&_freeStackMutex);
    free(_workers);
}

@end

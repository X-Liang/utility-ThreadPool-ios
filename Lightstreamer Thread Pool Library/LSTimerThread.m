//
//  LSTimerThread.m
//  Lightstreamer Thread Pool Library
//
//  Created by Gianluca Bertani on 28/08/12.
//  Copyright (c) Lightstreamer Srl
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "LSTimerThread.h"
#import "LSInvocation.h"
#import "LSInvocation+Internals.h"
#import "LSLog.h"
#import "LSLog+Internals.h"


#pragma mark -
#pragma mark LSTimerThread extension

@interface LSTimerThread () {
	NSThread *_thread;
	BOOL _running;
}


#pragma mark -
#pragma mark Setting and removing timers on timer thread

- (void) threadPerformDelayedInvocation:(LSInvocation *)invocation;
- (void) threadCancelPreviousDelayedPerformWithInfo:(LSInvocation *)invocation;

- (void) threadPerformBlockInvocation:(LSInvocation *)invocation;


#pragma mark -
#pragma mark Thread run loop

- (void) threadRunLoop;
- (void) threadHeartBeat;

- (void) stopThread;


@end


#pragma mark -
#pragma mark LSTimerThread statics

static LSTimerThread *__sharedTimer= nil;


#pragma mark -
#pragma mark LSTimerThread implementation

@implementation LSTimerThread


#pragma mark -
#pragma mark Singleton management

+ (LSTimerThread *) sharedTimer {
	if (__sharedTimer)
		return __sharedTimer;
	
	@synchronized ([LSTimerThread class]) {
		if (!__sharedTimer)
			__sharedTimer= [[LSTimerThread alloc] initWithName:@"LSSharedTimerThread"];
	}
	
	return __sharedTimer;
}

+ (void) dispose {
	if (!__sharedTimer)
		return;
	
	@synchronized ([LSTimerThread class]) {
		if (__sharedTimer) {
			[__sharedTimer stopThread];
			
			__sharedTimer= nil;
		}
	}
}


#pragma mark -
#pragma mark Initialization

- (instancetype) initWithName:(nonnull NSString *)name {
	if ((self = [super init])) {
		
		// Initialization
        if (!name)
            @throw [NSException exceptionWithName:NSInvalidArgumentException
                                           reason:@"Timer thread name can't be nil"
                                         userInfo:nil];

        _running= YES;
		
		_thread= [[NSThread alloc] initWithTarget:self selector:@selector(threadRunLoop) object:nil];
		_thread.name= name;
		
		[_thread start];
	}
	
	return self;
}


#pragma mark -
#pragma mark Setting and removing timers

- (void) performBlock:(LSInvocationBlock)block afterDelay:(NSTimeInterval)delay {
    LSInvocation *invocation= [LSInvocation invocationWithBlock:block delay:delay];
    
    [self performSelector:@selector(threadPerformDelayedInvocation:) onThread:_thread withObject:invocation waitUntilDone:NO];
}

- (void) performSelector:(SEL)selector onTarget:(id)target withObject:(id)argument afterDelay:(NSTimeInterval)delay {
	LSInvocation *invocation= [LSInvocation invocationWithTarget:target selector:selector argument:argument delay:delay];
	
	[self performSelector:@selector(threadPerformDelayedInvocation:) onThread:_thread withObject:invocation waitUntilDone:NO];
}

- (void) performSelector:(SEL)selector onTarget:(id)target afterDelay:(NSTimeInterval)delay {
	LSInvocation *invocation= [LSInvocation invocationWithTarget:target selector:selector delay:delay];
	
	[self performSelector:@selector(threadPerformDelayedInvocation:) onThread:_thread withObject:invocation waitUntilDone:NO];
}

- (void) cancelPreviousPerformRequestsWithTarget:(id)target selector:(SEL)selector object:(id)argument {
	LSInvocation *invocation= [LSInvocation invocationWithTarget:target selector:selector argument:argument];
	
	[self performSelector:@selector(threadCancelPreviousDelayedPerformWithInfo:) onThread:_thread withObject:invocation waitUntilDone:NO];
}

- (void) cancelPreviousPerformRequestsWithTarget:(id)target selector:(SEL)selector {
	LSInvocation *invocation= [LSInvocation invocationWithTarget:target selector:selector];
	
	[self performSelector:@selector(threadCancelPreviousDelayedPerformWithInfo:) onThread:_thread withObject:invocation waitUntilDone:NO];
}

- (void) cancelPreviousPerformRequestsWithTarget:(id)target {
	LSInvocation *invocation= [LSInvocation invocationWithTarget:target];
	
	[self performSelector:@selector(threadCancelPreviousDelayedPerformWithInfo:) onThread:_thread withObject:invocation waitUntilDone:NO];
}


#pragma mark -
#pragma mark Setting and removing timers on timer thread

- (void) threadPerformDelayedInvocation:(LSInvocation *)invocation {
    if (invocation.block)
        [self performSelector:@selector(threadPerformBlockInvocation:) withObject:invocation afterDelay:invocation.delay];
    else
        [invocation.target performSelector:invocation.selector withObject:invocation.argument afterDelay:invocation.delay];
}

- (void) threadCancelPreviousDelayedPerformWithInfo:(LSInvocation *)invocation {
	if (invocation.selector) {
		[NSObject cancelPreviousPerformRequestsWithTarget:invocation.target selector:invocation.selector object:invocation.argument];
		
	} else {
		[NSObject cancelPreviousPerformRequestsWithTarget:invocation.target];
	}
}

- (void) threadPerformBlockInvocation:(LSInvocation *)invocation {
    invocation.block();
}


#pragma mark -
#pragma mark Thread run loop

- (void) threadRunLoop {
    @autoreleasepool {
        NSRunLoop *loop= [NSRunLoop currentRunLoop];
        
		[LSLog sourceType:LOG_SRC_TIMER source:self log:@"thread started"];
		
        do {
            @autoreleasepool {
                NSTimer *timer= [NSTimer timerWithTimeInterval:5.3 target:self selector:@selector(threadHeartBeat) userInfo:nil repeats:NO];
                @try {
                    [loop addTimer:timer forMode:NSDefaultRunLoopMode];
                    
                    BOOL ok= [loop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:4.7]];
                    if (!ok) {
                        
                        // Should never happen, but just in case avoid CPU starvation
                        [NSThread sleepForTimeInterval:0.1];
                    }
                    
                    [timer invalidate];
                    
                } @catch (NSException *e) {
					[LSLog sourceType:LOG_SRC_TIMER source:self log:@"exception caught while running thread: %@ (user info: %@)", e, e.userInfo];
                }
            }
            
        } while (_running);
        
		[LSLog sourceType:LOG_SRC_TIMER source:self log:@"thread stopped"];
    }
}

- (void) threadHeartBeat {
	
	// Dummy method to keep the run loop busy
}

- (void) stopThread {
	_running= NO;
	
	_thread= nil;
}


@end

//
//  LSURLDispatchOperation.m
//  Lightstreamer Thread Pool Library
//
//  Created by Gianluca Bertani on 03/09/12.
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

#import "LSURLDispatchOperation.h"
#import "LSURLDispatchOperation+Internals.h"
#import "LSURLDispatcherThread.h"
#import "LSURLDispatcher.h"
#import "LSURLDispatcher+Internals.h"
#import "LSInvocation.h"
#import "LSTimerThread.h"
#import "LSLog.h"
#import "LSLog+Internals.h"

#define ERROR_DOMAIN                          (@"LSURLDispatcherDomain")

#define ERROR_CODE_NO_CONNECTION              (-1701)


#pragma mark -
#pragma mark LSURLDispatchOperation extension

@interface LSURLDispatchOperation () {
    LSURLDispatcher * __weak _dispatcher;
    
	NSURLRequest *_request;
	NSString *_endPoint;
	id <LSURLDispatchDelegate> __weak _delegate;
	BOOL _gathedData;
	BOOL _isLong;
	
	LSURLDispatcherThread * __weak _thread;
	NSURLConnection *_connection;
	NSCondition *_waitForCompletion;
	
	NSURLResponse *_response;
	NSError *_error;
	NSMutableData *_data;
    
    // NSURLSession and NSURLSessionDataTask used only if available (iOS >= 7.0 or OS X >= 10.9)
    NSURLSession * __weak _session;
    NSURLSessionDataTask *_task;
}


#pragma mark -
#pragma mark Internal non-threaded operations

- (void) timeout;


#pragma mark -
#pragma mark Internal threaded operations

- (void) threadStart:(NSURLRequest *)request;
- (void) threadCancel;
- (void) threadTimeout;

@end


#pragma mark -
#pragma mark LSURLDispatchOperation implementation

@implementation LSURLDispatchOperation


#pragma mark -
#pragma mark Initialization

- (instancetype) initWithDispatcher:(LSURLDispatcher *)dispatcher session:(NSURLSession *)session request:(NSURLRequest *)request endPoint:(NSString *)endPoint delegate:(id <LSURLDispatchDelegate>)delegate gatherData:(BOOL)gatherData isLong:(BOOL)isLong {
	if ((self = [super init])) {
		
		// Initialization
        _dispatcher = dispatcher;
        
        _session= session;
		_request= request;
		_endPoint= endPoint;
		_delegate= delegate;
		_gathedData= gatherData;
		_isLong= isLong;
		
		_waitForCompletion= [[NSCondition alloc] init];
	}
	
	return self;
}


#pragma mark -
#pragma mark Execution

- (void) start {

	// Get a worker thread
	_thread= [_dispatcher preemptThreadForEndPoint:_endPoint];

	if (_gathedData)
		_data= [[NSMutableData alloc] init];
    
    // Prepare a copy of the request
    NSMutableURLRequest *request= [_request mutableCopy];
    
    // Check timeout
	NSTimeInterval timeout= [_request timeoutInterval];
    if (timeout > 0.0) {
        
        // Start the local timeout timer and clear the timeout for
        // the operating system (can't be trusted)
		[[LSTimerThread sharedTimer] performSelector:@selector(timeout) onTarget:self afterDelay:timeout];

        [request setTimeoutInterval:0.0];
    }

	// Start the connection on the dispatcher thread
    [self performSelector:@selector(threadStart:) onThread:_thread withObject:request waitUntilDone:NO];
}

- (void) startAndWaitForCompletion {
	
	// Acquire the completion lock
	[_waitForCompletion lock];

	// Start the connection
	[self start];
	
	// Wait for a signal
	[_waitForCompletion wait];
	[_waitForCompletion unlock];
}

- (void) cancel {
	
	// Cancel the connection on the dispatcher thread
	[self performSelector:@selector(threadCancel) onThread:_thread withObject:nil waitUntilDone:NO];
}

- (void) timeout {
	
	// Handle the timeout on the dispatcher thread
	[self performSelector:@selector(threadTimeout) onThread:_thread withObject:nil waitUntilDone:NO];
}


#pragma mark -
#pragma mark Methods of NSURLConnectionDelegate

- (void) connection:(NSURLConnection *)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
	
	// Avoid wasting time if the connection has been cancelled
	@synchronized (self) {
		if (connection != _connection)
			return;
	}
	
	if ([_delegate respondsToSelector:@selector(dispatchOperation:willSendRequestForAuthenticationChallenge:)]) {

		// Forward authentication call to delegate
		[_delegate dispatchOperation:self willSendRequestForAuthenticationChallenge:challenge];
		
	} else
		[challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
}

- (void) connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	
	// Avoid wasting time if the connection has been cancelled
	@synchronized (self) {
		if (connection != _connection)
			return;
	}
	
	_response= response;

	// Truncate current data buffer
	[_data setLength:0];
	
	// Cancel the timeout timer at the response only for long operations
	// other operations will cancel it at finish or fail
	if (_isLong)
		[[LSTimerThread sharedTimer] cancelPreviousPerformRequestsWithTarget:self selector:@selector(timeout)];
	
	// Call delegate
	[_delegate dispatchOperation:self didReceiveResponse:response];
}

- (void) connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
	
	// Avoid wasting time if the connection has been cancelled
	@synchronized (self) {
		if (connection != _connection)
			return;
	}
	
	[_data appendData:data];
	
	// Call delegate
	[_delegate dispatchOperation:self didReceiveData:data];
}

- (void) connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
	@synchronized (self) {

		// Avoid wasting time if the connection has been cancelled
		if (connection != _connection)
			return;
		
		// Clear the connection
		_connection= nil;
	}

	// Store the error
	_error= error;
	
	[LSLog sourceType:LOG_SRC_URL_DISPATCHER source:_dispatcher log:@"connection of operation %p for end-point: %@ failed with error: %@", self, _endPoint, error];
	
	// Cancel the timeout timer
	[[LSTimerThread sharedTimer] cancelPreviousPerformRequestsWithTarget:self selector:@selector(timeout)];

	// Notify waiting threads
	[_waitForCompletion lock];
	[_waitForCompletion broadcast];
	[_waitForCompletion unlock];
	
	// Notify the dispatcher
	[_dispatcher operation:self didFinishWithTask:nil];
	
	// Call delegate
	[_delegate dispatchOperation:self didFailWithError:_error];
}

- (void) connectionDidFinishLoading:(NSURLConnection *)connection {
	@synchronized (self) {
		
		// Avoid wasting time if the connection has been cancelled
		if (connection != _connection)
			return;
	
		// Clear the connection
		_connection= nil;
	}

	[LSLog sourceType:LOG_SRC_URL_DISPATCHER source:_dispatcher log:@"connection of operation %p for end-point: %@ finished loading", self, _endPoint];

	// Cancel the timeout timer
	[[LSTimerThread sharedTimer] cancelPreviousPerformRequestsWithTarget:self selector:@selector(timeout)];

	// Notify waiting threads
	[_waitForCompletion lock];
	[_waitForCompletion broadcast];
	[_waitForCompletion unlock];

	// Notify the dispatcher
	[_dispatcher operation:self didFinishWithTask:nil];

	// Call delegate
	[_delegate dispatchOperationDidFinish:self];
}


#pragma mark -
#pragma mark Events for NSURLSessionDataTask (for internal use only)

- (void) taskWillSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
    
    // Avoid wasting time if task has been cancelled
    @synchronized (self) {
        if (!_task)
            return;
    }
    
    if ([_delegate respondsToSelector:@selector(dispatchOperation:willSendRequestForAuthenticationChallenge:)]) {
        
        // Forward authentication call to delegate
        [_delegate dispatchOperation:self willSendRequestForAuthenticationChallenge:challenge];
        
    } else
        [challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
}

- (void) taskDidReceiveResponse:(NSURLResponse *)response {
    
    // Avoid wasting time if task has been cancelled
    @synchronized (self) {
        if (!_task)
            return;
    }
    
    _response= response;
    
    // Truncate current data buffer
    [_data setLength:0];
    
    // Cancel the timeout timer at the response only for long operations
    // other operations will cancel it at finish or fail
    if (_isLong)
        [[LSTimerThread sharedTimer] cancelPreviousPerformRequestsWithTarget:self selector:@selector(timeout)];
    
    // Call delegate
    [_delegate dispatchOperation:self didReceiveResponse:response];
}

- (void) taskDidReceiveData:(NSData *)data {
    
    // Avoid wasting time if task has been cancelled
    @synchronized (self) {
        if (!_task)
            return;
    }
    
    [_data appendData:data];
    
    // Call delegate
    [_delegate dispatchOperation:self didReceiveData:data];
}

- (void) taskDidFailWithError:(NSError *)error {
    @synchronized (self) {
        
        // Avoid wasting time if task has been cancelled
        if (!_task)
            return;
        
        // Clear the connection
        _task= nil;
    }
    
    // Store the error
    _error= error;
    
    [LSLog sourceType:LOG_SRC_URL_DISPATCHER source:_dispatcher log:@"connection of operation %p for end-point: %@ failed with error: %@", self, _endPoint, error];
    
    // Cancel the timeout timer
    [[LSTimerThread sharedTimer] cancelPreviousPerformRequestsWithTarget:self selector:@selector(timeout)];
    
    // Notify waiting threads
    [_waitForCompletion lock];
    [_waitForCompletion broadcast];
    [_waitForCompletion unlock];
    
    // Notify the dispatcher
    [_dispatcher operation:self didFinishWithTask:nil];
    
    // Call delegate
    [_delegate dispatchOperation:self didFailWithError:_error];
}

- (void) taskDidFinishLoading {
    @synchronized (self) {
        
        // Avoid wasting time if task has been cancelled
        if (!_task)
            return;
        
        // Clear the task
        _task= nil;
    }
    
    [LSLog sourceType:LOG_SRC_URL_DISPATCHER source:_dispatcher log:@"connection of operation %p for end-point: %@ finished loading", self, _endPoint];
    
    // Cancel the timeout timer
    [[LSTimerThread sharedTimer] cancelPreviousPerformRequestsWithTarget:self selector:@selector(timeout)];
    
    // Notify waiting threads
    [_waitForCompletion lock];
    [_waitForCompletion broadcast];
    [_waitForCompletion unlock];
    
    // Notify the dispatcher
    [_dispatcher operation:self didFinishWithTask:nil];
    
    // Call delegate
    [_delegate dispatchOperationDidFinish:self];
}


#pragma mark -
#pragma mark Internal threaded methods

- (void) threadStart:(NSURLRequest *)request {
    
    // Use NSURLSession if available (iOS >= 7.0 or OS X >= 10.9)
    if (_session) {
        
        [LSLog sourceType:LOG_SRC_URL_DISPATCHER source:_dispatcher log:@"starting task of operation %p for end-point: %@ on thread: %p", self, _endPoint, _thread];
        
        // Create a new data task
        _task= [_session dataTaskWithRequest:request];
        if (!_task) {
            
            // No task created
            NSError *error= [NSError errorWithDomain:ERROR_DOMAIN
                                                code:ERROR_CODE_NO_CONNECTION
                                            userInfo:@{NSLocalizedDescriptionKey: @"Couldn't create a new task for requested URL",
                                                       NSURLErrorKey: request.URL}];
            
            // Handle the error as a common connection error
            [self taskDidFailWithError:error];
            
        } else {
            
            // Notify the dispatcher
            [_dispatcher operation:self didStartWithTask:_task];
            
            // Resume the task
            [_task resume];
        }
        
    } else {
        
#if !TARGET_OS_TV
    
        [LSLog sourceType:LOG_SRC_URL_DISPATCHER source:_dispatcher log:@"starting connection of operation %p for end-point: %@ on thread: %p", self, _endPoint, _thread];
        
        // Create a new connection
        _connection= [[NSURLConnection alloc] initWithRequest:request delegate:self];
        if (!_connection) {
            
            // No connection created
            NSError *error= [NSError errorWithDomain:ERROR_DOMAIN
                                                code:ERROR_CODE_NO_CONNECTION
                                            userInfo:@{NSLocalizedDescriptionKey: @"Couldn't create a new connection to requested URL",
                                                       NSURLErrorKey: request.URL}];
            
            // Handle the error as a common connection error
            [self connection:_connection didFailWithError:error];
            
        } else {
            
            // Notify the dispatcher
            [_dispatcher operation:self didStartWithTask:nil];
            
            // Get run loop for dispatcher thread
            NSRunLoop *runLoop= [NSRunLoop currentRunLoop];
            
            // Start connection on dispatcher run loop
            [_connection scheduleInRunLoop:runLoop forMode:NSDefaultRunLoopMode];
            [_connection start];
        }
        
#endif // !TARGET_OS_TV

    }
}

- (void) threadCancel {
    
    // Use NSURLSession if available (iOS >= 7.0 or OS X >= 10.9)
    if (_session) {
        NSURLSessionDataTask *oldTask= nil;
        
        @synchronized (self) {
        
            // Avoid wasting time if the task has been cancelled or is already finished
            if (!_task)
                return;
        
            // Clear the connection
            oldTask= _task;
            _task= nil;
        }
        
        // Cancel connection
        [oldTask cancel];
        
        [LSLog sourceType:LOG_SRC_URL_DISPATCHER source:_dispatcher log:@"task of operation %p for end-point: %@ cancelled", self, _endPoint];
        
    } else {
        NSURLConnection *oldConnection= nil;
        
        @synchronized (self) {
            
            // Avoid wasting time if the connection has been cancelled or is already finished
            if (!_connection)
                return;
            
            // Clear the connection
            oldConnection= _connection;
            _connection= nil;
        }
        
        // Cancel connection
        [oldConnection cancel];
        
        [LSLog sourceType:LOG_SRC_URL_DISPATCHER source:_dispatcher log:@"connection of operation %p for end-point: %@ cancelled", self, _endPoint];
    }
		
	// Cancel the timeout timer
	[[LSTimerThread sharedTimer] cancelPreviousPerformRequestsWithTarget:self selector:@selector(timeout)];

	// Notify waiting threads
	[_waitForCompletion lock];
	[_waitForCompletion broadcast];
	[_waitForCompletion unlock];
	
	// Notify the dispatcher
	[_dispatcher operation:self didFinishWithTask:nil];
	
	// Call delegate
	[_delegate dispatchOperationDidFinish:self];
}

- (void) threadTimeout {
    
    // Use NSURLSession if available (iOS >= 7.0 or OS X >= 10.9)
    if (_session) {
        NSURLSessionDataTask *oldTask= nil;
        
        @synchronized (self) {
            
            // Avoid wasting time if the connection has been cancelled or is already finished
            if (!_task)
                return;
            
            // Clear the connection
            oldTask= _task;
            _task= nil;
        }
        
        // Cancel connection
        [oldTask cancel];
        
        [LSLog sourceType:LOG_SRC_URL_DISPATCHER source:_dispatcher log:@"task of operation %p for end-point: %@ timed out", self, _endPoint];
        

    } else {
        NSURLConnection *oldConnection= nil;
        
        @synchronized (self) {
            
            // Avoid wasting time if the connection has been cancelled or is already finished
            if (!_connection)
                return;
            
            // Clear the connection
            oldConnection= _connection;
            _connection= nil;
        }
        
        // Cancel connection
        [oldConnection cancel];
        
        [LSLog sourceType:LOG_SRC_URL_DISPATCHER source:_dispatcher log:@"connection of operation %p for end-point: %@ timed out", self, _endPoint];
    }
	
	// Compose the error
	_error= [[NSError alloc] initWithDomain:NSURLErrorDomain
									   code:NSURLErrorTimedOut
								   userInfo:@{NSURLErrorFailingURLStringErrorKey: [_request.URL description],
											  NSLocalizedDescriptionKey: @"The request timed out.",
											  NSUnderlyingErrorKey: [NSError errorWithDomain:ERROR_DOMAIN
																						code:NSURLErrorTimedOut
																					userInfo:nil]}];
	
	// Notify waiting threads
	[_waitForCompletion lock];
	[_waitForCompletion broadcast];
	[_waitForCompletion unlock];
	
	// Notify the dispatcher
	[_dispatcher operation:self didFinishWithTask:nil];
	
	// Call delegate
	[_delegate dispatchOperation:self didFailWithError:_error];
}


#pragma mark -
#pragma mark Access to underlying thread

- (LSURLDispatcherThread *) thread {
	return _thread;
}


#pragma mark -
#pragma mark Properties

@synthesize request= _request;
@synthesize endPoint= _endPoint;
@synthesize isLong= _isLong;

@synthesize response= _response;
@synthesize error= _error;
@synthesize data= _data;


@end


Thread Pool library for iOS
===========================

The thread pool and URL dispatch library used by Lightstreamer's iOS client library since v. 1.2.


What this library does
----------------------

This code was written to address a specific problem of iOS SDK and runtime:

* iOS runtime has a limit of 4 concurrent NSURLConnections to the same end-point; above
  this limit, connections will time out after some time without even trying.

The library uses thread pools to keep the number of concurrent connections under control
for each end-point, ensuring that a fifth (or subsequent) connection is enqueued by the 
thread pool and not submitted to the system. The library also offers methods to know in 
advance when a connection is going to succeed or time out for a given end-point. Last but
not least, the library enforces the timeout set in the URL request.

For more information on this topic, please read the related article on Lightstreamer's blog:

* http://blog.lightstreamer.com/2013/01/on-ios-url-connection-parallelism-and.html

What is included:

* an `LSThreadPool` class that lets you execute invocations on a fixed thread pool, and

* an `LSURLDispatcher` class that uses a thread pool to keep the number of concurrent
  connections by end-point under control.
  
* a bonus `LSTimerThread` class that lets you run timed invocation without using the
  main thread.

* a simple logging facility `LSLog` used internally by other classes.
  

LSThreadPool
------------

Use of `LSThreadPool` is really simple. Create it with a defined size and name (name 
will be used for logging):

```objective-c
// Create the thread pool
LSThreadPool *threadPool= [[LSThreadPool alloc] initWithName:@"Test" size:4];
```
	
Then, schedule invocations with its `scheduleInvocationForTarget:selector:` or 
`scheduleInvocationForTarget:selector:withObject:` methods. E.g.,

```objective-c
[threadPool scheduleInvocationForTarget:self selector:@selector(addOne)];
```

If you want something more handy you can use blocks. E.g.,

```objective-c
[threadPool scheduleInvocationForBlock:^() {
    // Do something
}];
```

Finally, dispose of the thread pool before releasing it when done:

```objective-c
[threadPool dispose];
threadPool= nil;
```

Threads are recycled if another scheduled call arrives within 10 seconds. After 15 seconds
a collector removes idle threads.


LSURLDispatcher
---------------

The `LSURLDispatcher` is a singleton and is able to automatically initialize itself. Use it to
start a connection request toward a NSURLRequest in one of three possible ways:

* as a **synschronous request**: in this case, the dispatcher will download the request URL
  and deliver it as a NSData; if the end-point is already at its connection limit,
  the caller will wait until a connection is freed;

* as a **short request**: the dispatcher will asynchronously connect and send events to your
  delegate as the connection proceeds; if the end-point is already at its connection limit,
  the dispatcher will wait in the background until a connection is freed; use short requests
  for short-lived operations that are expected to last a few seconds only;

* as a **long request**: the dispatcher will asynchronously connect only if the end-point is below 
  a configured limit (by default lower than the connection limit), otherwise, it will raise an exception; 
  use long requests for long-lived operations exepected to last for minutes or more (data streaming, 
  audio/video streaming, VoIP, etc.).
  
The distinction between **short- and long-lived requests** is important: an app that should open 4 long-lived
requests to the same end-point, such as audio, video and data streams, would have no way to contact the same end-point 
again until one of the requests is terminated, even for simple requests like downloading an icon. By keeping 
short- and long-lived requests separated and with different limits, the library ensures that short-lived requests
have always some spare connections to use.

To start a short-lived request simply do:

```objective-c
NSURL *url= [NSURL URLWithString:@"http://some/url"];
NSURLRequest *req= [NSURLRequest requestWithURL:url];

LSURLDispatchOperation *op= [[LSURLDispatcher sharedDispatcher] dispatchShortRequest:req delegate:self];
```

A request operation may be canceled at a later time, if necessary:

```objective-c
[op cancel];
```

With long operations you can also check in advance if a it is going to succeed
or not (that is, to know if the limit has been reached or not):

```objective-c
[[LSURLDispatcher sharedDispatcher] setMaxLongRunningRequestsPerEndPoint:2];

// ...

if (![[LSURLDispatcher sharedDispatcher] isLongRequestAllowed:req]) {
    NSLog(@"Connection limit reached");

} else {
    LSURLDispatchOperation *longOp= [[LSURLDispatcher sharedDispatcher] dispatchLongRequest:req delegate:self];
    // ...
}
```

All requests are operated on separate threads. Each end-point has its own pool of 4 connection
threads. In addition, for short and long requests each end-point has a general-purpose thread
dedicated to decoupling the caller from the wait of a free connection.

Threads are recycled if another request arrives within 10 seconds. After 15 seconds
a collector removes idle threads.

Starting with **version 1.6.0**, `LSURLDispatcher` uses a shared `NSURLSession` and a separate `NSURLSessionDataTask` 
for each operation, in place of an `NSURLConnection`. It reverts to `NSURLConnection` when `NSURLSession` is not
available, i.e. for iOS < 7.0 and OS X < 10.9.

The API remains exactly the same, enforcing the request limit as usual. There is just the addition of a new class 
setter/getter to force the use of `NSURLConnection` even when `NSURLSession` is available:

```objective-c
[[LSURLDispatcher sharedDispatcher] setUseNSURLSessionIfAvailable:NO];
```

On the threading level, there is an transparent but important difference between the use of `NSURLSession` and
`NSURLConnection`:

* as stated above, with `NSURLConnection` requests are operated on custom threads of `LSURLDispatcher`, with
their own run loop;
* with `NSURLSession`, requests are operated on the session's own threads, but `LSURLDispatcher` threads are 
still used for operations' delegate event delivery.

Also starting with version 1.6.0, the `LSURLDispatcher` may be safely used as a common instanced object, and not
as a singleton, but beware: since the end-point request limit is enforced at the instance level, using multiple
instances of `LSURLDispatcher` to access the same end-point will make the enforcement ineffective, and you could get 
fake timeouts as if you were not using the `LSURLDispatcher` at all. Since the connection limit is system-wide, 
the countermeasure, to be effective, *must* used as a singleton.


LSTimerThread
-------------

The `LSTimerThread` provides delayed calls to any method of any object, without using the main thread.
A shared thread is used to schedule calls, so make sure your called methods do not take too much time
to execute.

To use the timer just schedule the call as you would do with `performSelector:withArgument:afterDelay`
of `NSObject`. E.g.,

```objective-c
[[LSTimerThread sharedTimer] performSelector:@selector(timeout) onTarget:self afterDelay:timeout];
````

If you want something more handy you can use blocks. E.g.,

```objective-c
[[LSTimerThread sharedTimer] performBlock:^() {
    // Do something
} afterDelay:timeout];
```


LSLog
-----

The `LSLog` provides simple logging for separable sources. No logging levels are supported, but a logging 
delegation is provided through the `LSLogDelegate` protocol.

Supported sources are:

* `LOG_SRC_THREAD_POOL` for `LSThreadPool`
* `LOG_SRC_URL_DISPATCHER` for `LSURLDispatcher`
* `LOG_SRC_TIMER` for `LSTimerThread`

All logging may be considered of DEBUG level, so enable a source only if you need to debug it:

```objective-c
[LSLog enableSource:LOG_SRC_THREAD_POOL];
````

To enable delegation just set your `LSLogDelegate` implemenation on the `LSLog` class:

```objective-c
[LSLog setDelegate:myLogger];
````


Test cases
----------

A couple of simple test cases are included, which will show the strict enforcement on thread
pool size and connection limit per end-point. The test case on connection limit enforcement
runs with once with `NSURLConnection` and once with `NSURLSession`.


License
-------

This software is part of Lightstreamer's iOS client library since version 1.2. It is released
as open source under the Apache License 2.0. See LICENSE for more information.

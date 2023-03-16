#import "SentryPerformanceTracker.h"
#import "SentryHub+Private.h"
#import "SentryLog.h"
#import "SentrySDK+Private.h"
#import "SentryScope.h"
#import "SentrySpan.h"
#import "SentrySpanId.h"
#import "SentrySpanProtocol.h"
#import "SentryTracer.h"
#import "SentryTransactionContext+Private.h"
#import "SentryUIEventTracker.h"

NS_ASSUME_NONNULL_BEGIN

@interface
SentryPerformanceTracker () <SentryTracerDelegate>

@property (nonatomic, strong) NSMutableDictionary<SentrySpanId *, id<SentrySpan>> *spans;
@property (nonatomic, strong) NSMutableArray<id<SentrySpan>> *activeSpanStack;

@end

@implementation SentryPerformanceTracker

+ (instancetype)shared
{
    static SentryPerformanceTracker *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init
{
    if (self = [super init]) {
        self.spans = [[NSMutableDictionary alloc] init];
        self.activeSpanStack = [[NSMutableArray alloc] init];
    }
    return self;
}

- (SentrySpanId *)startSpanWithName:(NSString *)name operation:(NSString *)operation
{
    return [self startSpanWithName:name
                        nameSource:kSentryTransactionNameSourceCustom
                         operation:operation];
}

- (SentrySpanId *)startSpanWithName:(NSString *)name
                         nameSource:(SentryTransactionNameSource)source
                          operation:(NSString *)operation
{
    __block id<SentrySpan> activeSpan;
    dispatch_barrier_sync([self operationQueue], ^{
        activeSpan = [self.activeSpanStack lastObject];
    });

    __block id<SentrySpan> newSpan;
    if (activeSpan != nil) {
        newSpan = [activeSpan startChildWithOperation:operation description:name];
    } else {
        SentryTransactionContext *context =
            [[SentryTransactionContext alloc] initWithName:name
                                                nameSource:source
                                                 operation:operation];

        [SentrySDK.currentHub.scope useSpan:^(id<SentrySpan> span) {
            BOOL bindToScope = true;
            if (span != nil) {
                if ([SentryUIEventTracker isUIEventOperation:span.context.operation]) {
                    [span finishWithStatus:kSentrySpanStatusCancelled];
                } else {
                    bindToScope = false;
                }
            }

            newSpan = [SentrySDK.currentHub startTransactionWithContext:context
                                                            bindToScope:bindToScope
                                                        waitForChildren:YES
                                                  customSamplingContext:@ {}];

            if ([newSpan isKindOfClass:[SentryTracer class]]) {
                [(SentryTracer *)newSpan setDelegate:self];
            }
        }];
    }

    SentrySpanId *spanId = newSpan.context.spanId;

    if (spanId != nil) {
        dispatch_barrier_sync([self operationQueue], ^{
            self.spans[spanId] = newSpan;
        });
    } else {
        SENTRY_LOG_ERROR(@"startSpanWithName:operation: spanId is nil.");
        return [SentrySpanId empty];
    }

    return spanId;
}

- (void)measureSpanWithDescription:(NSString *)description
                         operation:(NSString *)operation
                           inBlock:(void (^)(void))block
{
    [self measureSpanWithDescription:description
                          nameSource:kSentryTransactionNameSourceCustom
                           operation:operation
                             inBlock:block];
}

- (void)measureSpanWithDescription:(NSString *)description
                        nameSource:(SentryTransactionNameSource)source
                         operation:(NSString *)operation
                           inBlock:(void (^)(void))block
{
    SentrySpanId *spanId = [self startSpanWithName:description
                                        nameSource:source
                                         operation:operation];
    [self pushActiveSpan:spanId];
    block();
    [self popActiveSpan];
    [self finishSpan:spanId];
}

- (void)measureSpanWithDescription:(NSString *)description
                         operation:(NSString *)operation
                      parentSpanId:(SentrySpanId *)parentSpanId
                           inBlock:(void (^)(void))block
{
    [self measureSpanWithDescription:description
                          nameSource:kSentryTransactionNameSourceCustom
                           operation:operation
                        parentSpanId:parentSpanId
                             inBlock:block];
}

- (void)measureSpanWithDescription:(NSString *)description
                        nameSource:(SentryTransactionNameSource)source
                         operation:(NSString *)operation
                      parentSpanId:(SentrySpanId *)parentSpanId
                           inBlock:(void (^)(void))block
{
    [self activateSpan:parentSpanId
           duringBlock:^{
               [self measureSpanWithDescription:description
                                     nameSource:source
                                      operation:operation
                                        inBlock:block];
           }];
}

- (void)activateSpan:(SentrySpanId *)spanId duringBlock:(void (^)(void))block
{

    if ([self pushActiveSpan:spanId]) {
        block();
        [self popActiveSpan];
    } else {
        block();
    }
}

- (nullable SentrySpanId *)activeSpanId
{
    __block SentrySpanId *spanId;
    dispatch_barrier_sync([self operationQueue], ^{
        spanId = [self.activeSpanStack lastObject].context.spanId;
    });
    return spanId;
}

- (BOOL)pushActiveSpan:(SentrySpanId *)spanId
{
    __block id<SentrySpan> toActiveSpan;
    dispatch_barrier_sync([self operationQueue], ^{
        toActiveSpan = self.spans[spanId];
    });

    if (toActiveSpan == nil) {
        return NO;
    }

    @synchronized(self.activeSpanStack) {
        [self.activeSpanStack addObject:toActiveSpan];
    }
    return YES;
}

- (void)popActiveSpan
{
    dispatch_barrier_sync([self operationQueue], ^{
        [self.activeSpanStack removeLastObject];
    });
}

- (void)finishSpan:(SentrySpanId *)spanId
{
    [self finishSpan:spanId withStatus:kSentrySpanStatusOk];
}

- (void)finishSpan:(SentrySpanId *)spanId withStatus:(SentrySpanStatus)status
{
    __block id<SentrySpan> spanTracker;
    dispatch_barrier_sync([self operationQueue], ^{
        spanTracker = self.spans[spanId];
        [self.spans removeObjectForKey:spanId];
    });

    [spanTracker finishWithStatus:status];
}

- (BOOL)isSpanAlive:(SentrySpanId *)spanId
{
    __block BOOL alive;
    dispatch_barrier_sync([self operationQueue], ^{
        alive =(self.spans[spanId] != nil);
    });
    return alive;
}

- (nullable id<SentrySpan>)getSpan:(SentrySpanId *)spanId
{
    __block id<SentrySpan> span;
    dispatch_barrier_sync([self operationQueue], ^{
        span = self.spans[spanId];
    });
    return span;
}

- (nullable id<SentrySpan>)activeSpanForTracer:(SentryTracer *)tracer
{
    __block id<SentrySpan> span;
    dispatch_barrier_sync([self operationQueue], ^{
        span = [self.activeSpanStack lastObject];
    });
    return span;
}

- (dispatch_queue_t)operationQueue {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.performancetracker.sentry.SQB", DISPATCH_QUEUE_CONCURRENT);
    });
     return queue;
}

@end

NS_ASSUME_NONNULL_END

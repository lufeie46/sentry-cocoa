import ObjectiveC
import XCTest

#if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)

class TestViewController: UIViewController {
}

class SentryUIViewControllerPerformanceTrackerTests: XCTestCase {

    let loadView = "loadView"
    let viewWillLoad = "viewWillLoad"
    let viewDidLoad = "viewDidLoad"
    let viewWillAppear = "viewWillAppear"
    let viewDidAppear = "viewDidAppear"
    let viewWillDisappear = "viewWillDisappear"
    let viewWillLayoutSubviews = "viewWillLayoutSubviews"
    let viewDidLayoutSubviews = "viewDidLayoutSubviews"
    let layoutSubviews = "layoutSubViews"
    let spanName = "spanName"
    let spanOperation = "spanOperation"
    
    private class Fixture {
        
        var options: Options {
            let options = Options()
            let imageName = String(
                cString: class_getImageName(SentryUIViewControllerSwizzlingTests.self)!,
                encoding: .utf8)! as NSString
            options.add(inAppInclude: imageName.lastPathComponent)
            options.debug = true
            return options
        }
        
        let viewController = TestViewController()
        let tracker = SentryPerformanceTracker()
        let dateProvider = TestCurrentDateProvider()
        
        var viewControllerName: String!
                
        func getSut() -> SentryUIViewControllerPerformanceTracker {
            CurrentDate.setCurrentDateProvider(dateProvider)
            
            viewControllerName = SwiftDescriptor.getObjectClassName(viewController)
        
            let result = SentryUIViewControllerPerformanceTracker.shared
            Dynamic(result).tracker = self.tracker
            
            return result
        }
    }
    
    private var fixture: Fixture!
    
    override func setUp() {
        super.setUp()
        fixture = Fixture()
        SentrySDK.start(options: fixture.options)
    }

    override func tearDown() {
        super.tearDown()
        clearTestState()
    }
    
    func testUILifeCycle_ViewDidAppear() throws {
        try assertUILifeCycle(finishStatus: SentrySpanStatus.ok) { sut, viewController, tracker, callbackExpectation, transactionSpan in
            sut.viewControllerViewDidAppear(viewController) {
                let blockSpan = self.getStack(tracker).last!
                XCTAssertEqual(blockSpan.parentSpanId, transactionSpan.spanId)
                XCTAssertEqual(blockSpan.spanDescription, self.viewDidAppear)
                callbackExpectation.fulfill()
            }

            // Simulate call to viewWillDisappear later on. As the transaction is already
            // finished above in viewDidAppear nothing should happend here.
            sut.viewControllerViewWillDisappear(viewController) {
                self.assertTrackerIsEmpty(tracker)
            }
        }
    }

    func testUILifeCycle_NoViewDidAppear_OnlyViewWillDisappear() throws {
        // Don't call viewDidAppear on purpose.

        try assertUILifeCycle(finishStatus: SentrySpanStatus.cancelled) { sut, viewController, tracker, callbackExpectation, transactionSpan in
            sut.viewControllerViewWillDisappear(viewController) {
                let blockSpan = self.getStack(tracker).last!
                XCTAssertEqual(blockSpan.parentSpanId, transactionSpan.spanId)
                XCTAssertEqual(blockSpan.spanDescription, self.viewWillDisappear)
                callbackExpectation.fulfill()
            }
        }
    }

    private func assertUILifeCycle(finishStatus: SentrySpanStatus, lifecycleEndingMethod: (SentryUIViewControllerPerformanceTracker, UIViewController, SentryPerformanceTracker, XCTestExpectation, Span) -> Void) throws {
        let sut = fixture.getSut()
        let viewController = fixture.viewController
        let tracker = fixture.tracker
        var transactionSpan: Span?
                
        let callbackExpectation = expectation(description: "Callback Expectation")
        callbackExpectation.expectedFulfillmentCount = 6
        
        XCTAssertTrue(getStack(tracker).isEmpty)
        sut.viewControllerLoadView(viewController) {
            let spans = self.getStack(tracker)
            transactionSpan = spans.first
            if let blockSpan = spans.last, let transactionSpan = transactionSpan {
                XCTAssertEqual(blockSpan.parentSpanId, transactionSpan.spanId)
                XCTAssertEqual(blockSpan.spanDescription, self.loadView)
            } else {
                XCTFail("Expected spans")
            }
            callbackExpectation.fulfill()
        }
        let tracer = try XCTUnwrap(transactionSpan as? SentryTracer)
        XCTAssertEqual(tracer.transactionContext.name, fixture.viewControllerName)
        XCTAssertEqual(tracer.transactionContext.nameSource, .component)
        XCTAssertFalse(tracer.isFinished)

        sut.viewControllerViewDidLoad(viewController) {
            if let blockSpan = self.getStack(tracker).last {
                XCTAssertEqual(blockSpan.parentSpanId, tracer.spanId)
                XCTAssertEqual(blockSpan.spanDescription, self.viewDidLoad)
            } else {
                XCTFail("Expected a span")
            }
            callbackExpectation.fulfill()
        }
        XCTAssertFalse(tracer.isFinished)
        
        sut.viewControllerViewWillLayoutSubViews(viewController) {
            if let blockSpan = self.getStack(tracker).last {
                XCTAssertEqual(blockSpan.parentSpanId, tracer.spanId)
                XCTAssertEqual(blockSpan.spanDescription, self.viewWillLayoutSubviews)
            } else {
                XCTFail("Expected a span")
            }
            callbackExpectation.fulfill()
        }
        XCTAssertFalse(tracer.isFinished)

        let layoutSubViewsSpan = try XCTUnwrap((Dynamic(transactionSpan).children as [Span]?)?.last)
        XCTAssertEqual(layoutSubViewsSpan.parentSpanId, tracer.spanId)
        XCTAssertEqual(layoutSubViewsSpan.spanDescription, self.layoutSubviews)
        
        sut.viewControllerViewDidLayoutSubViews(viewController) {
            if let blockSpan = self.getStack(tracker).last {
                XCTAssertEqual(blockSpan.parentSpanId, tracer.spanId)
                XCTAssertEqual(blockSpan.spanDescription, self.viewDidLayoutSubviews)
            } else {
                XCTFail("Expected a span")
            }
            callbackExpectation.fulfill()
        }
        XCTAssertFalse(tracer.isFinished)
        
        sut.viewControllerViewWillAppear(viewController) {
            if let blockSpan = self.getStack(tracker).last {
                XCTAssertEqual(blockSpan.parentSpanId, tracer.spanId)
                XCTAssertEqual(blockSpan.spanDescription, self.viewWillAppear)
            } else {
                XCTFail("Expected a span")
            }
            callbackExpectation.fulfill()
        }
        XCTAssertFalse(tracer.isFinished)
        
        lifecycleEndingMethod(sut, viewController, tracker, callbackExpectation, tracer)

        XCTAssertEqual(Dynamic(transactionSpan).children.asArray!.count, 7)
        XCTAssertTrue(tracer.isFinished)
        XCTAssertEqual(finishStatus.rawValue, tracer.status.rawValue)

        wait(for: [callbackExpectation], timeout: 0)

        assertTrackerIsEmpty(tracker)
    }
    
    func testTimeMeasurement() throws {
        let sut = fixture.getSut()
        let viewController = fixture.viewController
        let tracker = fixture.tracker
        var transactionSpan: Span?
        
        let callbackExpectation = expectation(description: "Callback Expectation")
        callbackExpectation.expectedFulfillmentCount = 6
                
        fixture.dateProvider.setDate(date: Date(timeIntervalSince1970: 0))
        var lastSpan: Span?
        
        sut.viewControllerLoadView(viewController) {
            transactionSpan = self.getStack(tracker).first
            lastSpan = self.getStack(tracker).last
            self.advanceTime(bySeconds: 1)
            callbackExpectation.fulfill()
        }
        try assertSpanDuration(span: lastSpan, expectedDuration: 1)
        
        sut.viewControllerViewDidLoad(viewController) {
            lastSpan = self.getStack(tracker).last
            self.advanceTime(bySeconds: 2)
            callbackExpectation.fulfill()
        }
        try assertSpanDuration(span: lastSpan, expectedDuration: 2)
        
        sut.viewControllerViewWillLayoutSubViews(viewController) {
            lastSpan = self.getStack(tracker).last
            self.advanceTime(bySeconds: 3)
            callbackExpectation.fulfill()
        }
        try assertSpanDuration(span: lastSpan, expectedDuration: 3)
        
        let layoutSubViewsSpan = try XCTUnwrap((Dynamic(transactionSpan).children as [Span]?)?.last)
        advanceTime(bySeconds: 4)
        
        sut.viewControllerViewDidLayoutSubViews(viewController) {
            lastSpan = self.getStack(tracker).last
            self.advanceTime(bySeconds: 2)
            callbackExpectation.fulfill()
        }
        try assertSpanDuration(span: lastSpan, expectedDuration: 2)
        try assertSpanDuration(span: layoutSubViewsSpan, expectedDuration: 4)
        
        sut.viewControllerViewWillAppear(viewController) {
            lastSpan = self.getStack(tracker).last
            self.advanceTime(bySeconds: 1)
            callbackExpectation.fulfill()
        }
        try assertSpanDuration(span: lastSpan, expectedDuration: 1)
        
        advanceTime(bySeconds: 4)

        sut.viewControllerViewDidAppear(viewController) {
            lastSpan = self.getStack(tracker).last
            self.advanceTime(bySeconds: 5)
            callbackExpectation.fulfill()
        }
        try assertSpanDuration(span: lastSpan, expectedDuration: 5)
        try assertSpanDuration(span: transactionSpan, expectedDuration: 22)
        
        wait(for: [callbackExpectation], timeout: 0)
    }
    
    func testTimeMeasurement_SkipLoadView() throws {
        let sut = fixture.getSut()
        let viewController = fixture.viewController
        let tracker = fixture.tracker
        var transactionSpan: Span?
                
        fixture.dateProvider.setDate(date: Date(timeIntervalSince1970: 0))
        var lastSpan: Span?
        
        sut.viewControllerViewDidLoad(viewController) {
            transactionSpan = self.getStack(tracker).first
            lastSpan = self.getStack(tracker).last
            self.advanceTime(bySeconds: 2)

        }
        try assertSpanDuration(span: lastSpan, expectedDuration: 2)
        
        sut.viewControllerViewWillLayoutSubViews(viewController) {
            lastSpan = self.getStack(tracker).last
            self.advanceTime(bySeconds: 3)
        }
        try assertSpanDuration(span: lastSpan, expectedDuration: 3)
        
        let layoutSubViewsSpan = try XCTUnwrap((Dynamic(transactionSpan).children as [Span]?)?.last)
        advanceTime(bySeconds: 4)
        
        sut.viewControllerViewDidLayoutSubViews(viewController) {
            lastSpan = self.getStack(tracker).last
            self.advanceTime(bySeconds: 2)
        }
        try assertSpanDuration(span: lastSpan, expectedDuration: 2)
        try assertSpanDuration(span: layoutSubViewsSpan, expectedDuration: 4)
        
        sut.viewControllerViewWillAppear(viewController) {
            lastSpan = self.getStack(tracker).last
            self.advanceTime(bySeconds: 1)
        }
        try assertSpanDuration(span: lastSpan, expectedDuration: 1)
        
        advanceTime(bySeconds: 4)
        
        sut.viewControllerViewDidAppear(viewController) {
            lastSpan = self.getStack(tracker).last
            self.advanceTime(bySeconds: 5)
        }
        try assertSpanDuration(span: lastSpan, expectedDuration: 5)
        try assertSpanDuration(span: transactionSpan, expectedDuration: 21)

        assertTrackerIsEmpty(tracker)
    }
    
    func testWaitingForCustomSpan() throws {
        let sut = fixture.getSut()
        let viewController = fixture.viewController
        let tracker = fixture.tracker
        var transactionSpan: Span?
        
        var lastSpan: Span?
        var customSpanId: SpanId?
        
        sut.viewControllerLoadView(viewController) {
            transactionSpan = self.getStack(tracker).first
            lastSpan = self.getStack(tracker).last
            customSpanId = tracker.startSpan(withName: self.spanName, operation: self.spanOperation)
        }
        let unwrappedLastSpan = try XCTUnwrap(lastSpan)
        XCTAssertTrue(unwrappedLastSpan.isFinished)
        
        sut.viewControllerViewWillAppear(viewController) {
            //intentionally left empty.
        }
        sut.viewControllerViewDidAppear(viewController) {
            //intentionally left empty.
            //Need to call viewControllerViewDidAppear to finish the transaction.
        }

        let unwrappedTransactionSpan = try XCTUnwrap(transactionSpan)
        let unwrappedCustomSpanId = try XCTUnwrap(customSpanId)
        XCTAssertFalse(unwrappedTransactionSpan.isFinished)
        tracker.finishSpan(unwrappedCustomSpanId)
        XCTAssertTrue(unwrappedTransactionSpan.isFinished)

        let children = try XCTUnwrap(Dynamic(unwrappedTransactionSpan).children.asArray)
        XCTAssertEqual(children.count, 4)

        assertTrackerIsEmpty(tracker)
    }
    
    func testSkipLoadViewAndViewDidLoad() {
        //Skipping loadView prevent the tracker from creating the view controller transaction and no span is created after this.
        
        let sut = fixture.getSut()
        let viewController = fixture.viewController
        let tracker = fixture.tracker
        
        sut.viewControllerViewWillLayoutSubViews(viewController) {
            XCTAssertTrue(self.getStack(tracker).isEmpty)
        }
        XCTAssertTrue(getStack(tracker).isEmpty)
        
        sut.viewControllerViewDidLayoutSubViews(viewController) {
            XCTAssertTrue(self.getStack(tracker).isEmpty)
        }
        XCTAssertTrue(getStack(tracker).isEmpty)
        
        sut.viewControllerViewWillAppear(viewController) {
            XCTAssertTrue(self.getStack(tracker).isEmpty)
        }
        XCTAssertTrue(getStack(tracker).isEmpty)
        
        sut.viewControllerViewDidAppear(viewController) {
            XCTAssertTrue(self.getStack(tracker).isEmpty)
        }

        assertTrackerIsEmpty(tracker)
    }
    
    func testSpanAssociatedConstants() {
        XCTAssertEqual(SENTRY_UI_PERFORMANCE_TRACKER_SPAN_ID, "SENTRY_UI_PERFORMANCE_TRACKER_SPAN_ID")
        XCTAssertEqual(SENTRY_UI_PERFORMANCE_TRACKER_LAYOUTSUBVIEW_SPAN_ID, "SENTRY_UI_PERFORMANCE_TRACKER_LAYOUTSUBVIEW_SPAN_ID")
    }
    
    func testOverloadCall() throws {
        let sut = fixture.getSut()
        let viewController = fixture.viewController
        let tracker = fixture.tracker
        var transactionSpan: Span?
        
        let callbackExpectation = expectation(description: "Callback Expectation")
        callbackExpectation.expectedFulfillmentCount = 3
        
        XCTAssertTrue(getStack(tracker).isEmpty)
        //we need loadView to start the tracking
        sut.viewControllerLoadView(viewController) {
            let spans = self.getStack(tracker)
            transactionSpan = spans.first
            
            callbackExpectation.fulfill()
        }
        
        var unwrappedTransactionSpan = try XCTUnwrap(transactionSpan)
        XCTAssertFalse(unwrappedTransactionSpan.isFinished)
        
        sut.viewControllerViewDidLoad(viewController) {
            let blockSpan = self.getStack(tracker).last!
            
            //this is the same as calling super.viewDidLoad in a custom class sub class
            sut.viewControllerViewDidLoad(viewController) {
                let innerblockSpan = self.getStack(tracker).last!
                XCTAssertTrue(innerblockSpan === blockSpan)
                
                callbackExpectation.fulfill()
            }
            
            callbackExpectation.fulfill()
        }

        unwrappedTransactionSpan = try XCTUnwrap(transactionSpan)
        XCTAssertFalse(unwrappedTransactionSpan.isFinished)
        XCTAssertEqual(Dynamic(unwrappedTransactionSpan).children.asArray!.count, 2)

        wait(for: [callbackExpectation], timeout: 0)
    }
    
    func testLoadView_withUIViewController() {
        let sut = fixture.getSut()
        let viewController = UIViewController()
        let tracker = fixture.tracker
        var transactionSpan: Span!
        let callbackExpectation = expectation(description: "Callback Expectation")
        
        XCTAssertTrue(getStack(tracker).isEmpty)
        
        sut.viewControllerLoadView(viewController) {
            let spans = self.getStack(tracker)
            transactionSpan = spans.first
            callbackExpectation.fulfill()
        }
               
        XCTAssertNil(transactionSpan)
        wait(for: [callbackExpectation], timeout: 0)
    }
    
    func testSecondLoadView() throws {
        let sut = fixture.getSut()
        let viewController = fixture.viewController
        let tracker = fixture.tracker
        var transactionSpan: Span?
        let callbackExpectation = expectation(description: "Callback Expectation")
        callbackExpectation.expectedFulfillmentCount = 2
        
        XCTAssertTrue(getStack(tracker).isEmpty)
        
        sut.viewControllerLoadView(viewController) {
            let spans = self.getStack(tracker)
            transactionSpan = spans.first
            callbackExpectation.fulfill()
        }
        
        //here we are calling loadView a second time,
        //which should create a child span of the transaction
        //already created in the previous call and not create a new transaction
        sut.viewControllerLoadView(viewController) {
            //This callback was intentionally left blank
            callbackExpectation.fulfill()
        }

        let children = try XCTUnwrap(Dynamic(transactionSpan).children.asArray)
        XCTAssertEqual(children.count, 2)
        wait(for: [callbackExpectation], timeout: 0)
    }
    
    func testMultiplesViewController() {
        let sut = fixture.getSut()
        let firstController = TestViewController()
        let secondController = TestViewController()
        let tracker = fixture.tracker

        var firstTransaction: SentryTracer!
        var secondTransaction: SentryTracer!

        sut.viewControllerViewDidLoad(firstController) {
            firstTransaction = self.getStack(tracker).first as? SentryTracer
        }

        sut.viewControllerViewDidLoad(secondController) {
            secondTransaction = self.getStack(tracker).first as? SentryTracer
        }

        //Callback methods intentionally left blank from now on
        sut.viewControllerViewWillLayoutSubViews(firstController) {
        }

        sut.viewControllerViewWillLayoutSubViews(secondController) {
        }

        sut.viewControllerViewDidLayoutSubViews(firstController) {
        }

        var firstSpanChildren: [Span]? = Dynamic(firstTransaction).children as [Span]?
        XCTAssertEqual(firstSpanChildren?.count, 4)

        sut.viewControllerViewDidLayoutSubViews(secondController) {
        }

        var secondSpanChildren: [Span]? = Dynamic(secondTransaction).children as [Span]?
        XCTAssertEqual(secondSpanChildren?.count, 4)

        sut.viewControllerViewWillAppear(firstController) {
        }

        sut.viewControllerViewWillAppear(secondController) {
        }

        sut.viewControllerViewDidAppear(firstController) {
        }

        firstSpanChildren = Dynamic(firstTransaction).children as [Span]?
        XCTAssertEqual(firstSpanChildren?.count, 6)

        sut.viewControllerViewDidAppear(secondController) {
        }

        secondSpanChildren = Dynamic(secondTransaction).children as [Span]?
        XCTAssertEqual(secondSpanChildren?.count, 6)
    }

    private func assertSpanDuration(span: Span?, expectedDuration: TimeInterval) throws {
        let span = try XCTUnwrap(span)
        let timestamp = try XCTUnwrap(span.timestamp)
        let startTimestamp = try XCTUnwrap(span.startTimestamp)
        let duration = timestamp.timeIntervalSince(startTimestamp)
        XCTAssertEqual(duration, expectedDuration)
    }
    
    private func assertTrackerIsEmpty(_ tracker: SentryPerformanceTracker) {
        XCTAssertEqual(0, getStack(tracker).count)
        XCTAssertEqual(0, getSpans(tracker).count)
    }

    private func getStack(_ tracker: SentryPerformanceTracker) -> [Span] {
        let result = Dynamic(tracker).activeSpanStack as [Span]?
        return result!
    }

    private func getSpans(_ tracker: SentryPerformanceTracker) -> [SpanId: Span] {
        let result = Dynamic(tracker).spans as [SpanId: Span]?
        return result!
    }

    private func advanceTime(bySeconds: TimeInterval) {
        fixture.dateProvider.setDate(date: fixture.dateProvider.date().addingTimeInterval(bySeconds))
    }
}
#endif

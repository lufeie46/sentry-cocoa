import XCTest

class SentryWatchdogTerminationIntegrationTests: XCTestCase {

    private class Fixture {
        let options: Options
        let client: TestClient!
        let crashWrapper: TestSentryCrashWrapper
        let currentDate = TestCurrentDateProvider()
        let fileManager: SentryFileManager
        let dispatchQueue = TestSentryDispatchQueueWrapper()
        
        init() {
            options = Options()
            
            client = TestClient(options: options)
            
            crashWrapper = TestSentryCrashWrapper.sharedInstance()
            SentryDependencyContainer.sharedInstance().crashWrapper = crashWrapper
            SentryDependencyContainer.sharedInstance().fileManager = try! SentryFileManager(options: options, andCurrentDateProvider: currentDate)

            let hub = SentryHub(client: client, andScope: nil, andCrashWrapper: crashWrapper, andCurrentDateProvider: currentDate)
            SentrySDK.setCurrentHub(hub)
            
            fileManager = try! SentryFileManager(options: options, andCurrentDateProvider: currentDate, dispatchQueueWrapper: dispatchQueue)
        }
    }
    
    private var fixture: Fixture!
    private var sut: SentryWatchdogTerminationTrackingIntegration!
    
    override func setUp() {
        super.setUp()
        
        fixture = Fixture()
        fixture.fileManager.store(TestData.appState)
    }
    
    override func tearDown() {
        sut?.uninstall()
        fixture.fileManager.deleteAllFolders()
        clearTestState()
        super.tearDown()
    }
    
    func testWhenUnitTests_TrackerNotInitialized() {
        let sut = SentryWatchdogTerminationTrackingIntegration()
        sut.install(with: Options())
        
        XCTAssertNil(Dynamic(sut).tracker.asAnyObject)
    }
    
    func testWhenNoUnitTests_TrackerInitialized() {
        let sut = SentryWatchdogTerminationTrackingIntegration()
        Dynamic(sut).setTestConfigurationFilePath(nil)
        sut.install(with: Options())
        
        XCTAssertNotNil(Dynamic(sut).tracker.asAnyObject)
    }
    
    func testTestConfigurationFilePath() {
        let sut = SentryWatchdogTerminationTrackingIntegration()
        let path = Dynamic(sut).testConfigurationFilePath.asString
        XCTAssertEqual(path, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"])
    }
    
#if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
    func testANRDetected_UpdatesAppStateToTrue() throws {
        givenInitializedTracker()
        
        Dynamic(sut).anrDetected()

        let appState = try XCTUnwrap(fixture.fileManager.readAppState())
        
        XCTAssertTrue(appState.isANROngoing)
    }
#endif
  
    func testANRStopped_UpdatesAppStateToFalse() {
        givenInitializedTracker()
        
        Dynamic(sut).anrStopped()
        
        guard let appState = fixture.fileManager.readAppState() else {
            XCTFail("appState must not be nil")
            return
        }
        XCTAssertFalse(appState.isANROngoing)
    }
    
    func test_OOMDisabled_RemovesEnabledIntegration() {
        givenInitializedTracker()
        let options = Options()
        options.enableWatchdogTerminationTracking = false
        
        let sut = SentryWatchdogTerminationTrackingIntegration()
        let result = sut.install(with: options)
        
        XCTAssertFalse(result)
    }
    
    private func givenInitializedTracker(isBeingTraced: Bool = false) {
        fixture.crashWrapper.internalIsBeingTraced = isBeingTraced
        sut = SentryWatchdogTerminationTrackingIntegration()
        let options = Options()
        Dynamic(sut).setTestConfigurationFilePath(nil)
        sut.install(with: options)
    }
    
}

import CoreAudio
import XCTest
@testable import VoxHaloKit

final class CoreAudioTapResourcesTests: XCTestCase {
    func testCreatesPrivateUnmutedStereoGlobalTapUsingActualUIDAndFormat() throws {
        let api = FakeCoreAudioTapAPI(createdTapUID: "actual-tap-uid")
        let processUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let aggregateUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let uuids = UUIDSequence([processUUID, aggregateUUID])
        let resources = CoreAudioTapResources(
            api: api,
            uuidGenerator: { uuids.next() }
        )

        let prepared = try resources.prepare()

        XCTAssertEqual(api.processTapConfiguration, ProcessTapConfiguration(
            name: "VoxHalo System Audio",
            uuid: processUUID,
            isPrivate: true,
            excludesProcessObjectIDs: [],
            isMuted: false
        ))
        let aggregate = try XCTUnwrap(api.aggregateConfiguration)
        XCTAssertEqual(aggregate.tapUID, "actual-tap-uid")
        XCTAssertTrue(aggregate.isPrivate)
        XCTAssertTrue(aggregate.driftCompensation)
        XCTAssertFalse(aggregate.tapAutoStart)
        XCTAssertTrue(aggregate.uid.hasPrefix(
            CoreAudioDeviceCatalog.privateAggregateUIDPrefix
        ))
        XCTAssertTrue(aggregate.name.contains(aggregateUUID.uuidString))
        XCTAssertEqual(prepared.aggregateDeviceID, FakeCoreAudioTapAPI.aggregateID)
        XCTAssertEqual(prepared.tapFormat.mSampleRate, 48_000)
        XCTAssertEqual(prepared.tapFormat.mChannelsPerFrame, 2)
        XCTAssertEqual(api.calls, [
            "createProcessTap", "readTapUID", "readTapFormat", "createAggregate"
        ])

        XCTAssertTrue(resources.hasLiveResources)
        XCTAssertTrue(resources.cleanup().isEmpty)
        XCTAssertFalse(resources.hasLiveResources)
    }

    func testEveryPreparationFailureRollsBackAllCreatedResources() {
        for step in [
            FakeCoreAudioTapStep.createProcessTap,
            .readTapUID,
            .readTapFormat,
            .createAggregate
        ] {
            let api = FakeCoreAudioTapAPI(failingAt: step)
            let resources = CoreAudioTapResources(api: api)

            XCTAssertThrowsError(try resources.prepare(), "failure at \(step)")

            XCTAssertTrue(api.liveTapIDs.isEmpty, "tap leaked at \(step)")
            XCTAssertTrue(
                api.liveAggregateIDs.isEmpty,
                "aggregate leaked at \(step)"
            )
            XCTAssertFalse(resources.hasLiveResources)
        }
    }

    func testCleanupContinuesAfterAggregateFailureAndRetainsOnlyFailedIDForRetry() throws {
        let api = FakeCoreAudioTapAPI(
            failingAt: .destroyAggregate,
            failureCount: 1
        )
        let resources = CoreAudioTapResources(api: api)
        _ = try resources.prepare()

        let firstErrors = resources.cleanup()

        XCTAssertEqual(firstErrors.count, 1)
        XCTAssertEqual(api.liveAggregateIDs, [FakeCoreAudioTapAPI.aggregateID])
        XCTAssertTrue(api.liveTapIDs.isEmpty)
        XCTAssertTrue(resources.hasLiveResources)
        XCTAssertEqual(Array(api.calls.suffix(2)), [
            "destroyAggregate", "destroyProcessTap"
        ])

        XCTAssertTrue(resources.cleanup().isEmpty)
        XCTAssertTrue(api.liveAggregateIDs.isEmpty)
        XCTAssertFalse(resources.hasLiveResources)
    }

    func testEveryPreparedTapAndAggregateUsesUniqueIdentity() throws {
        let firstAPI = FakeCoreAudioTapAPI(createdTapUID: "tap-one")
        let secondAPI = FakeCoreAudioTapAPI(createdTapUID: "tap-two")
        let first = CoreAudioTapResources(api: firstAPI)
        let second = CoreAudioTapResources(api: secondAPI)

        _ = try first.prepare()
        _ = try second.prepare()

        XCTAssertNotEqual(
            firstAPI.processTapConfiguration?.uuid,
            secondAPI.processTapConfiguration?.uuid
        )
        XCTAssertNotEqual(
            firstAPI.aggregateConfiguration?.uid,
            secondAPI.aggregateConfiguration?.uid
        )
        XCTAssertNotEqual(
            firstAPI.aggregateConfiguration?.name,
            secondAPI.aggregateConfiguration?.name
        )
        _ = first.cleanup()
        _ = second.cleanup()
    }
}

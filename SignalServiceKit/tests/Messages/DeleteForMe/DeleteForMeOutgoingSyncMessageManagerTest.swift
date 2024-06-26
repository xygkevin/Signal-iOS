//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import SignalServiceKit

import XCTest

final class DeleteForMeOutgoingSyncMessageManagerTest: XCTestCase {
    private var mockAddressableMessageFinder: MockDeleteForMeAddressableMessageFinder!
    private var mockSyncMessageSender: MockSyncMessageSender!
    private var mockRecipientDatabaseTable: MockRecipientDatabaseTable!
    private var mockThreadStore: MockThreadStore!
    private var mockTSAccountManager: MockTSAccountManager!

    private var outgoingSyncMessageManager: DeleteForMeOutgoingSyncMessageManagerImpl!

    override func setUp() {
        mockAddressableMessageFinder = MockDeleteForMeAddressableMessageFinder()
        mockSyncMessageSender = MockSyncMessageSender()
        mockRecipientDatabaseTable = MockRecipientDatabaseTable()
        mockThreadStore = MockThreadStore()
        mockTSAccountManager = MockTSAccountManager()

        outgoingSyncMessageManager = DeleteForMeOutgoingSyncMessageManagerImpl(
            addressableMessageFinder: mockAddressableMessageFinder,
            recipientDatabaseTable: mockRecipientDatabaseTable,
            syncMessageSender: mockSyncMessageSender,
            threadStore: mockThreadStore,
            tsAccountManager: mockTSAccountManager
        )
    }

    func testBatchedInteractionDeletes() {
        let thread = TSContactThread(contactAddress: .isolatedRandomForTesting())
        let messagesToDelete = (0..<1501).map { _ -> TSOutgoingMessage in
            return TSOutgoingMessage(uniqueId: .uniqueId(), thread: thread)
        }

        /// These should be ignored by the sync message sender, since they are
        /// not addressable.
        let interactionsToDelete = (0..<10).map { _ -> TSInteraction in
            return TSInteraction(uniqueId: .uniqueId(), thread: thread)
        }

        var expectedInteractionBatches: [Int] = [500, 500, 500, 1]
        mockSyncMessageSender.sendSyncMessageMock = { contents in
            guard let expectedBatchSize = expectedInteractionBatches.popFirst() else {
                XCTFail("Unexpected batch!")
                return
            }

            XCTAssertEqual(contents.messageDeletes.count, 1)
            XCTAssertEqual(contents.messageDeletes.first!.addressableMessages.count, expectedBatchSize)
        }

        MockDB().write { tx in
            outgoingSyncMessageManager.send(
                deletedInteractions: messagesToDelete + interactionsToDelete,
                thread: thread,
                tx: tx
            )
        }

        XCTAssertTrue(expectedInteractionBatches.isEmpty)
    }

    func testBatchedThreadDeletes() {
        let threadsToDelete = (0..<301).map { _ -> TSContactThread in
            return TSContactThread(contactAddress: .isolatedRandomForTesting())
        }

        var expectedThreadBatches: [Int] = [100, 100, 100, 1]
        mockSyncMessageSender.sendSyncMessageMock = { contents in
            guard let expectedBatchSize = expectedThreadBatches.popFirst() else {
                XCTFail("Unexpected batch!")
                return
            }

            XCTAssertEqual(contents.localOnlyConversationDelete.count, expectedBatchSize)
        }

        MockDB().write { tx in
            /// These should all be local-only deletes, since the threads have
            /// no messages (the `MockDeleteForMeAddressableMessageFinder` will
            /// return `[]` for all threads, at the time of writing).
            let deletionContexts: [DeleteForMeSyncMessage.Outgoing.ThreadDeletionContext] = threadsToDelete.map { thread in
                outgoingSyncMessageManager.buildThreadDeletionContext(
                    thread: thread,
                    isFullDelete: true,
                    tx: tx
                )!
            }

            outgoingSyncMessageManager.send(
                threadDeletionContexts: deletionContexts,
                tx: tx
            )
        }

        XCTAssertTrue(expectedThreadBatches.isEmpty)
    }
}

private extension String {
    static func uniqueId() -> String {
        return UUID().uuidString
    }
}

// MARK: - Mocks

private final class MockSyncMessageSender: DeleteForMeOutgoingSyncMessageManagerImpl.Shims.SyncMessageSender {
    var sendSyncMessageMock: ((
        _ contents: DeleteForMeOutgoingSyncMessage.Contents
    ) -> Void)!
    func sendSyncMessage(contents: DeleteForMeOutgoingSyncMessage.Contents, localThread: TSContactThread, tx: any DBWriteTransaction) {
        sendSyncMessageMock(contents)
    }
}

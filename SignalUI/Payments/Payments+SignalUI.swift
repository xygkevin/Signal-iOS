//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

// TODO: Rename this source file.

@objc
public protocol Payments: AnyObject {

    func walletAddressBase58() -> String?

    func walletAddressQRUrl() -> URL?

    func localPaymentAddressProtoData() -> Data?

    var shouldShowPaymentsUI: Bool { get }

    var paymentsEntropy: Data? { get }

    func isValidMobileCoinPublicAddress(_ publicAddressData: Data) -> Bool

    func processIncomingPaymentRequest(thread: TSThread,
                                       paymentRequest: TSPaymentRequest,
                                       transaction: SDSAnyWriteTransaction)

    func processIncomingPaymentNotification(thread: TSThread,
                                            paymentNotification: TSPaymentNotification,
                                            senderAddress: SignalServiceAddress,
                                            transaction: SDSAnyWriteTransaction)

    func processIncomingPaymentCancellation(thread: TSThread,
                                            paymentCancellation: TSPaymentCancellation,
                                            transaction: SDSAnyWriteTransaction)

    func processReceivedTranscriptPaymentRequest(thread: TSThread,
                                                 paymentRequest: TSPaymentRequest,
                                                 messageTimestamp: UInt64,
                                                 transaction: SDSAnyWriteTransaction)

    func processReceivedTranscriptPaymentNotification(thread: TSThread,
                                                      paymentNotification: TSPaymentNotification,
                                                      messageTimestamp: UInt64,
                                                      transaction: SDSAnyWriteTransaction)

    func processReceivedTranscriptPaymentCancellation(thread: TSThread,
                                                      paymentCancellation: TSPaymentCancellation,
                                                      messageTimestamp: UInt64,
                                                      transaction: SDSAnyWriteTransaction)

    func willInsertPayment(_ paymentModel: TSPaymentModel, transaction: SDSAnyWriteTransaction)
    func willUpdatePayment(_ paymentModel: TSPaymentModel, transaction: SDSAnyWriteTransaction)

    @objc(processIncomingPaymentSyncMessage:messageTimestamp:transaction:)
    func processIncomingPaymentSyncMessage(_ paymentProto: SSKProtoSyncMessageOutgoingPayment,
                                           messageTimestamp: UInt64,
                                           transaction: SDSAnyWriteTransaction)

    func scheduleReconciliationNow(transaction: SDSAnyWriteTransaction)

    func replaceAsUnidentified(paymentModel oldPaymentModel: TSPaymentModel,
                               transaction: SDSAnyWriteTransaction)

    func findPaymentModels(withMCLedgerBlockIndex mcLedgerBlockIndex: UInt64,
                           mcIncomingTransactionPublicKey: Data,
                           transaction: SDSAnyReadTransaction) -> [TSPaymentModel]

    func tryToInsertPaymentModel(_ paymentModel: TSPaymentModel,
                                 transaction: SDSAnyWriteTransaction) throws

    func didReceiveMCAuthError()

    var isKillSwitchActive: Bool { get }

    func warmCaches()

    func clearState(transaction: SDSAnyWriteTransaction)
}

// MARK: -

public protocol PaymentsSwift: Payments {

    var paymentsState: PaymentsState { get }
    func setPaymentsState(_ value: PaymentsState,
                          updateStorageService: Bool,
                          transaction: SDSAnyWriteTransaction)
    func enablePayments(transaction: SDSAnyWriteTransaction)
    func enablePayments(withPaymentsEntropy: Data, transaction: SDSAnyWriteTransaction) -> Bool
    func disablePayments(transaction: SDSAnyWriteTransaction)

    var currentPaymentBalance: PaymentBalance? { get }
    func updateCurrentPaymentBalance()
    func updateCurrentPaymentBalancePromise() -> Promise<TSPaymentAmount>

    func getEstimatedFee(forPaymentAmount paymentAmount: TSPaymentAmount) -> Promise<TSPaymentAmount>

    func prepareOutgoingPayment(recipient: SendPaymentRecipient,
                                paymentAmount: TSPaymentAmount,
                                memoMessage: String?,
                                paymentRequestModel: TSPaymentRequestModel?,
                                isOutgoingTransfer: Bool,
                                canDefragment: Bool) -> Promise<PreparedPayment>

    func initiateOutgoingPayment(preparedPayment: PreparedPayment) -> Promise<TSPaymentModel>

    func maximumPaymentAmount() -> Promise<TSPaymentAmount>

    var passphrase: PaymentsPassphrase? { get }

    func passphrase(forPaymentsEntropy paymentsEntropy: Data) -> PaymentsPassphrase?

    func paymentsEntropy(forPassphrase passphrase: PaymentsPassphrase) -> Data?

    func isValidPassphraseWord(_ word: String?) -> Bool

    func blockOnOutgoingVerification(paymentModel: TSPaymentModel) -> Promise<Bool>
}

// MARK: -

public struct PaymentsPassphrase: Equatable, Dependencies {

    public let words: [String]

    public init(words: [String]) throws {
        guard words.count == PaymentsConstants.passphraseWordCount else {
            owsFailDebug("words.count \(words.count) != \(PaymentsConstants.passphraseWordCount)")
            throw PaymentsError.invalidPassphrase
        }

        self.words = words
    }

    public var wordCount: Int { words.count }

    public var asPassphrase: String { words.joined(separator: " ") }

    public var debugDescription: String { asPassphrase }

    public static func parse(passphrase: String,
                             validateWords: Bool) throws -> PaymentsPassphrase {
        let words = Array(passphrase.lowercased().stripped.components(separatedBy: " ").compactMap { $0.nilIfEmpty })
        guard words.count == PaymentsConstants.passphraseWordCount else {
            Logger.warn("words.count \(words.count) != \(PaymentsConstants.passphraseWordCount)")
            throw PaymentsError.invalidPassphrase
        }
        if validateWords {
            for word in words {
                guard Self.paymentsSwift.isValidPassphraseWord(word) else {
                    Logger.verbose("Invalid passphrase word: \(word).")
                    Logger.warn("Invalid passphrase word.")
                    throw PaymentsError.invalidPassphrase
                }
            }
        }
        return try PaymentsPassphrase(words: words)
    }
}

// MARK: -

public class MockPayments: NSObject {
}

// MARK: -

extension MockPayments: PaymentsSwift {

    public var paymentsState: PaymentsState { .disabled }

    public func setPaymentsState(_ value: PaymentsState,
                                 updateStorageService: Bool,
                                 transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func enablePayments(transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func enablePayments(withPaymentsEntropy: Data, transaction: SDSAnyWriteTransaction) -> Bool {
        owsFail("Not implemented.")
    }

    public func disablePayments(transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public var shouldShowPaymentsUI: Bool {
        owsFail("Not implemented.")
    }

    public var paymentsEntropy: Data? { nil }

    public func walletAddressBase58() -> String? {
        owsFail("Not implemented.")
    }

    public func walletAddressQRUrl() -> URL? {
        owsFail("Not implemented.")
    }

    public func localPaymentAddressProtoData() -> Data? {
        owsFail("Not implemented.")
    }

    public var isKillSwitchActive: Bool { false }

    public func warmCaches() {
        // Do nothing.
    }

    public func clearState(transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public var currentPaymentBalance: PaymentBalance? {
        owsFail("Not implemented.")
    }

    public func updateCurrentPaymentBalance() {
        owsFail("Not implemented.")
    }

    public func updateCurrentPaymentBalancePromise() -> Promise<TSPaymentAmount> {
        owsFail("Not implemented.")
    }

    public func getEstimatedFee(forPaymentAmount paymentAmount: TSPaymentAmount) -> Promise<TSPaymentAmount> {
        owsFail("Not implemented.")
    }

    public func prepareOutgoingPayment(recipient: SendPaymentRecipient,
                                       paymentAmount: TSPaymentAmount,
                                       memoMessage: String?,
                                       paymentRequestModel: TSPaymentRequestModel?,
                                       isOutgoingTransfer: Bool,
                                       canDefragment: Bool) -> Promise<PreparedPayment> {
        owsFail("Not implemented.")
    }

    public func initiateOutgoingPayment(preparedPayment: PreparedPayment) -> Promise<TSPaymentModel> {
        owsFail("Not implemented.")
    }

    public func isValidMobileCoinPublicAddress(_ publicAddressData: Data) -> Bool {
        owsFail("Not implemented.")
    }

    public func processIncomingPaymentRequest(thread: TSThread,
                                              paymentRequest: TSPaymentRequest,
                                              transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func processIncomingPaymentNotification(thread: TSThread,
                                                   paymentNotification: TSPaymentNotification,
                                                   senderAddress: SignalServiceAddress,
                                                   transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func processIncomingPaymentCancellation(thread: TSThread,
                                                   paymentCancellation: TSPaymentCancellation,
                                                   transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func processReceivedTranscriptPaymentRequest(thread: TSThread,
                                                        paymentRequest: TSPaymentRequest,
                                                        messageTimestamp: UInt64,
                                                        transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func processReceivedTranscriptPaymentNotification(thread: TSThread,
                                                             paymentNotification: TSPaymentNotification,
                                                             messageTimestamp: UInt64,
                                                             transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func processReceivedTranscriptPaymentCancellation(thread: TSThread,
                                                             paymentCancellation: TSPaymentCancellation,
                                                             messageTimestamp: UInt64,
                                                             transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func processIncomingPaymentSyncMessage(_ paymentProto: SSKProtoSyncMessageOutgoingPayment,
                                                  messageTimestamp: UInt64,
                                                  transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func willInsertPayment(_ paymentModel: TSPaymentModel, transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func willUpdatePayment(_ paymentModel: TSPaymentModel, transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func scheduleReconciliationNow(transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func replaceAsUnidentified(paymentModel oldPaymentModel: TSPaymentModel,
                                      transaction: SDSAnyWriteTransaction) {
        owsFail("Not implemented.")
    }

    public func findPaymentModels(withMCLedgerBlockIndex mcLedgerBlockIndex: UInt64,
                                  mcIncomingTransactionPublicKey: Data,
                                  transaction: SDSAnyReadTransaction) -> [TSPaymentModel] {
        owsFail("Not implemented.")
    }

    public func tryToInsertPaymentModel(_ paymentModel: TSPaymentModel,
                                        transaction: SDSAnyWriteTransaction) throws {
        owsFail("Not implemented.")
    }

    public func didReceiveMCAuthError() {
        owsFail("Not implemented.")
    }

    public func maximumPaymentAmount() -> Promise<TSPaymentAmount> {
        owsFail("Not implemented.")
    }

    public var passphrase: PaymentsPassphrase? { nil }

    public func passphrase(forPaymentsEntropy paymentsEntropy: Data) -> PaymentsPassphrase? {
        owsFail("Not implemented.")
    }

    public func paymentsEntropy(forPassphrase passphrase: PaymentsPassphrase) -> Data? {
        owsFail("Not implemented.")
    }

    public func isValidPassphraseWord(_ word: String?) -> Bool {
        owsFail("Not implemented.")
    }

    public func blockOnOutgoingVerification(paymentModel: TSPaymentModel) -> Promise<Bool> {
        owsFail("Not implemented.")
    }
}

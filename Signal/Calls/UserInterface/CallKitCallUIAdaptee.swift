//
// Copyright 2016 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import CallKit
import SignalServiceKit
import SignalUI

/**
 * Connects user interface to the CallService using CallKit.
 *
 * User interface is routed to the CallManager which requests CXCallActions, and if the CXProvider accepts them,
 * their corresponding consequences are implemented in the CXProviderDelegate methods, e.g. using the CallService
 */
final class CallKitCallUIAdaptee: NSObject, CallUIAdaptee, @preconcurrency CXProviderDelegate {
    private let callManager: CallKitCallManager
    var callService: CallService { AppEnvironment.shared.callService }
    private let showNamesOnCallScreen: Bool
    private let provider: CXProvider
    private let audioActivity: AudioActivity

    // Instantiating more than one CXProvider can cause us to miss call transactions, so
    // we maintain the provider across Adaptees using a singleton pattern
    static private let providerReadyFlag: ReadyFlag = ReadyFlag(name: "CallKitCXProviderReady")
    private static var _sharedProvider: CXProvider?
    class func sharedProvider(useSystemCallLog: Bool) -> CXProvider {
        let configuration = buildProviderConfiguration(useSystemCallLog: useSystemCallLog)

        if let sharedProvider = self._sharedProvider {
            sharedProvider.configuration = configuration
            return sharedProvider
        } else {
            SwiftSingletons.register(self)
            let provider = CXProvider(configuration: configuration)
            _sharedProvider = provider
            return provider
        }
    }

    // The app's provider configuration, representing its CallKit capabilities
    class func buildProviderConfiguration(useSystemCallLog: Bool) -> CXProviderConfiguration {
        let providerConfiguration = CXProviderConfiguration()

        providerConfiguration.supportsVideo = true

        // Default maximumCallGroups is 2. We previously overrode this value to be 1.
        //
        // The terminology can be confusing. Even though we don't currently support "group calls"
        // *every* call is in a call group. Our call groups all just happen to be "groups" with 1
        // call in them.
        //
        // maximumCallGroups limits how many different calls CallKit can know about at one time.
        // Exceeding this limit will cause CallKit to error when reporting an additional call.
        //
        // Generally for us, the number of call groups is 1 or 0, *however* when handling a rapid
        // sequence of offers and hangups, due to the async nature of CXTransactions, there can
        // be a brief moment where the old limit of 1 caused CallKit to fail the newly reported
        // call, even though we were properly requesting hangup of the old call before reporting the
        // new incoming call.
        //
        // Specifically after 10 or so rapid fire call/hangup/call/hangup, eventually an incoming
        // call would fail to report due to CXErrorCodeRequestTransactionErrorMaximumCallGroupsReached
        //
        // ...so that's why we no longer use the non-default value of 1, which I assume was only ever
        // set to 1 out of confusion.
        // providerConfiguration.maximumCallGroups = 1

        providerConfiguration.maximumCallsPerCallGroup = 1

        providerConfiguration.supportedHandleTypes = [.phoneNumber, .generic]

        let iconMaskImage = #imageLiteral(resourceName: "signal-logo-128")
        providerConfiguration.iconTemplateImageData = iconMaskImage.pngData()

        // We don't set the ringtoneSound property, so that we use either the
        // default iOS ringtone OR the custom ringtone associated with this user's
        // system contact.
        providerConfiguration.includesCallsInRecents = useSystemCallLog

        return providerConfiguration
    }

    init(showNamesOnCallScreen: Bool, useSystemCallLog: Bool) {
        AssertIsOnMainThread()

        Logger.debug("")

        self.callManager = CallKitCallManager(showNamesOnCallScreen: showNamesOnCallScreen)

        self.provider = type(of: self).sharedProvider(useSystemCallLog: useSystemCallLog)

        self.audioActivity = AudioActivity(audioDescription: "[CallKitCallUIAdaptee]", behavior: .call)
        self.showNamesOnCallScreen = showNamesOnCallScreen

        super.init()

        // We cannot assert singleton here, because this class gets rebuilt when the user changes relevant call settings

        self.provider.setDelegate(self, queue: nil)
    }

    private func localizedCallerNameWithSneakyTransaction(for call: SignalCall) -> String {
        switch call.mode {
        case .individual(let call):
            if showNamesOnCallScreen {
                return SSKEnvironment.shared.databaseStorageRef.read { tx in SSKEnvironment.shared.contactManagerRef.displayName(for: call.thread, transaction: tx) }
            }
            return OWSLocalizedString(
                "CALLKIT_ANONYMOUS_CONTACT_NAME",
                comment: "The generic name used for calls if CallKit privacy is enabled"
            )
        case .groupThread(let call):
            if showNamesOnCallScreen {
                let groupName = SSKEnvironment.shared.databaseStorageRef.read { tx -> String? in
                    let groupThread = TSGroupThread.fetch(forGroupId: call.groupId, tx: tx)
                    guard let groupThread else {
                        owsFailDebug("Missing group thread for active call.")
                        return nil
                    }
                    let contactManager = SSKEnvironment.shared.contactManagerRef
                    return contactManager.displayName(for: groupThread, transaction: tx)
                }
                if let groupName {
                    return groupName
                }
            }
            return OWSLocalizedString(
                "CALLKIT_ANONYMOUS_GROUP_NAME",
                comment: "The generic name used for group calls if CallKit privacy is enabled"
            )
        case .callLink(let call):
            if showNamesOnCallScreen {
                return call.callLinkState.localizedName
            }
            return CallLinkState.defaultLocalizedName
        }
    }

    // MARK: CallUIAdaptee

    @MainActor
    func startOutgoingCall(call: SignalCall) {
        Logger.info("")

        // Add the new outgoing call to the app's list of calls.
        // So we can find it in the provider delegate callbacks.
        Self.providerReadyFlag.runNowOrWhenDidBecomeReadySync {
            self.callManager.addCall(call)
            self.callManager.startOutgoingCall(call)
        }
    }

    @MainActor
    private func endCallOnceReported(_ call: SignalCall, reason: CXCallEndedReason) {
        Self.providerReadyFlag.runNowOrWhenDidBecomeReadySync {
            switch call.commonState.systemState {
            case .notReported:
                // Do nothing. This call was never reported to CallKit, so we don't need to report it ending.
                // This happens for calls missed while offline.
                // (If CallKit ever adds a way to report *past* missed calls, this might be a place to do it.)
                break
            case .pending:
                // We've reported the call to CallKit, but CallKit hasn't confirmed it yet.
                // Try again soon, but give up if the call ends some other way and is destroyed.
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1), qos: .userInitiated) { [weak call] in
                    guard let call = call else {
                        return
                    }
                    self.endCallOnceReported(call, reason: reason)
                }
            case .reported:
                self.provider.reportCall(with: call.localId, endedAt: nil, reason: reason)
                self.callManager.removeCall(call)
            case .removed:
                Logger.warn("call \(call.localId) already ended, but is now ending a second time with reason code \(reason)")
            }
        }
    }

    // Called from CallService after call has ended to clean up any remaining CallKit call state.
    @MainActor
    func failCall(_ call: SignalCall, error: CallError) {
        Logger.info("")

        let reason: CXCallEndedReason
        switch error {
        case .timeout:
            reason = .unanswered
        default:
            reason = .failed
        }
        self.endCallOnceReported(call, reason: reason)
    }

    @MainActor
    func reportIncomingCall(_ call: SignalCall, completion: @escaping (Error?) -> Void) {
        Logger.info("")

        // Construct a CXCallUpdate describing the incoming call, including the caller.
        let update = CXCallUpdate()
        update.localizedCallerName = localizedCallerNameWithSneakyTransaction(for: call)
        update.remoteHandle = callManager.createCallHandleWithSneakyTransaction(for: call)
        update.hasVideo = { () -> Bool in
            switch call.mode {
            case .individual(let individualCall):
                return individualCall.offerMediaType == .video
            case .groupThread:
                return true
            case .callLink:
                owsFail("Can't ring Call Link calls.")
            }
        }()

        disableUnsupportedFeatures(callUpdate: update)

        // TODO: Add proper Sendable support to these types.
        let addCall = {
            self.callManager.addCall(call)
        }

        Self.providerReadyFlag.runNowOrWhenDidBecomeReadySync {
            call.commonState.markPendingReportToSystem()

            // Report the incoming call to the system
            self.provider.reportNewIncomingCall(with: call.localId, update: update) { error in
                /*
                 Only add incoming call to the app's list of calls if the call was allowed (i.e. there was no error)
                 since calls may be "denied" for various legitimate reasons. See CXErrorCodeIncomingCallError.
                 */
                AppEnvironment.shared.pushRegistrationManagerRef.didFinishReportingIncomingCall()

                guard error == nil else {
                    completion(error)
                    Logger.error("failed to report new incoming call, error: \(error!)")
                    return
                }

                completion(nil)

                addCall()
            }
        }
    }

    @MainActor
    func answerCall(_ call: SignalCall) {
        Logger.info("")

        Self.providerReadyFlag.runNowOrWhenDidBecomeReadySync {
            self.callManager.answer(call: call)
        }
    }

    private var ignoreFirstUnmuteAfterRemoteAnswer = false
    @MainActor
    func recipientAcceptedCall(_ call: CallMode) {
        Logger.info("")

        Self.providerReadyFlag.runNowOrWhenDidBecomeReadySync {
            self.provider.reportOutgoingCall(with: call.commonState.localId, connectedAt: nil)

            let update = CXCallUpdate()
            self.disableUnsupportedFeatures(callUpdate: update)

            self.provider.reportCall(with: call.commonState.localId, updated: update)

            // When we tell CallKit about the call, it tries
            // to unmute the call. We can work around this
            // by ignoring the next "unmute" request from
            // CallKit after the call is answered.
            self.ignoreFirstUnmuteAfterRemoteAnswer = call.isOutgoingAudioMuted

            // Enable audio for remotely accepted calls after the session is configured.
            SUIEnvironment.shared.audioSessionRef.isRTCAudioEnabled = true
        }
    }

    func localHangupCall(_ call: SignalCall) {
        AssertIsOnMainThread()
        Logger.info("")

        guard call.commonState.systemState == .reported else {
            callService.handleLocalHangupCall(call)
            return
        }

        Self.providerReadyFlag.runNowOrWhenDidBecomeReadySync {
            self.callManager.localHangup(call: call)
        }
    }

    func remoteDidHangupCall(_ call: SignalCall) {
        AssertIsOnMainThread()
        Logger.info("")
        endCallOnceReported(call, reason: .remoteEnded)
    }

    func remoteBusy(_ call: SignalCall) {
        AssertIsOnMainThread()
        Logger.info("")
        endCallOnceReported(call, reason: .unanswered)
    }

    func didAnswerElsewhere(call: SignalCall) {
        Logger.info("")
        endCallOnceReported(call, reason: .answeredElsewhere)
    }

    func didDeclineElsewhere(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.info("")
        endCallOnceReported(call, reason: .declinedElsewhere)
    }

    func wasBusyElsewhere(call: SignalCall) {
        AssertIsOnMainThread()
        Logger.info("")
        // CallKit doesn't have a reason for "busy elsewhere", .declinedElsewhere is close enough.
        endCallOnceReported(call, reason: .declinedElsewhere)
    }

    func setIsMuted(call: SignalCall, isMuted: Bool) {
        AssertIsOnMainThread()
        Logger.info("")

        Self.providerReadyFlag.runNowOrWhenDidBecomeReadySync {
            self.callManager.setIsMuted(call: call, isMuted: isMuted)
        }
    }

    func setHasLocalVideo(call: SignalCall, hasLocalVideo: Bool) {
        AssertIsOnMainThread()
        Logger.debug("")
        callService.updateIsLocalVideoMuted(isLocalVideoMuted: !hasLocalVideo)

        // Update the CallKit UI.
        Self.providerReadyFlag.runNowOrWhenDidBecomeReadySync {
            let update = CXCallUpdate()
            update.hasVideo = hasLocalVideo
            self.provider.reportCall(with: call.localId, updated: update)
        }
    }

    // MARK: CXProviderDelegate

    @MainActor
    func providerDidBegin(_ provider: CXProvider) {
        Self.providerReadyFlag.setIsReady()
    }

    @MainActor
    func providerDidReset(_ provider: CXProvider) {
        Logger.info("")

        // End any ongoing calls if the provider resets, and remove them from the app's list of calls,
        // since they are no longer valid.
        callService.individualCallService.handleCallKitProviderReset()

        // Remove all calls from the app's list of calls.
        callManager.removeAllCalls()
    }

    @MainActor
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Logger.info("CXStartCallAction")

        guard let call = callManager.callWithLocalId(action.callUUID) else {
            Logger.error("unable to find call")
            return
        }

        // We can't wait for long before fulfilling the CXAction, else CallKit will show a "Failed Call". We don't 
        // actually need to wait for the outcome of the handleOutgoingCall promise, because it handles any errors by 
        // manually failing the call.
        switch call.mode {
        case .individual:
            self.callService.individualCallService.handleOutgoingCall(call)
        case .groupThread, .callLink:
            break
        }

        action.fulfill()
        provider.reportOutgoingCall(with: call.localId, startedConnectingAt: nil)

        let update = CXCallUpdate()
        update.localizedCallerName = localizedCallerNameWithSneakyTransaction(for: call)
        provider.reportCall(with: call.localId, updated: update)

        switch call.mode {
        case .individual:
            break
        case .groupThread(let groupThreadCall):
            switch groupThreadCall.groupCallRingState {
            case .shouldRing where groupThreadCall.ringRestrictions.isEmpty, .ringing:
                // Let CallService call recipientAcceptedCall when someone joins.
                break
            case .ringingEnded:
                Logger.warn("ringing ended before we even reported the call to CallKit (maybe our peek info was out of date)")
                fallthrough
            case .doNotRing, .shouldRing:
                // Immediately consider ourselves connected.
                recipientAcceptedCall(call.mode)
            case .incomingRing, .incomingRingCancelled:
                owsFailDebug("should not happen for an outgoing call")
                // Recover by considering ourselves connected
                recipientAcceptedCall(call.mode)
            }
        case .callLink:
            recipientAcceptedCall(call.mode)
        }
    }

    @MainActor
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Logger.info("Received \(#function) CXAnswerCallAction \(action.timeoutDate)")
        guard let call = callManager.callWithLocalId(action.callUUID) else {
            owsFailDebug("call as unexpectedly nil")
            action.fail()
            return
        }

        switch call.mode {
        case .callLink:
            owsFail("Can't answer Call Link calls.")
        case .groupThread(let groupThreadCall):
            // Explicitly unmute to request permissions, if needed.
            callService.updateIsLocalAudioMuted(isLocalAudioMuted: call.isOutgoingAudioMuted || groupThreadCall.shouldMuteAutomatically())
            // Explicitly start video to request permissions, if needed.
            // This has the added effect of putting the video mute button in the correct state
            // if the user has disabled camera permissions for the app.
            callService.updateIsLocalVideoMuted(isLocalVideoMuted: groupThreadCall.ringRtcCall.isOutgoingVideoMuted)
            callService.joinGroupCallIfNecessary(call, groupCall: groupThreadCall)
            action.fulfill()
        case .individual(let individualCall):
            // Explicitly start video to request permissions, if needed.
            // This has the added effect of putting the video mute button in the correct state
            // if the user has disabled camera permissions for the app.
            callService.updateIsLocalVideoMuted(isLocalVideoMuted: !individualCall.hasLocalVideo)
            if individualCall.state == .localRinging_Anticipatory {
                // We can't answer the call until RingRTC is ready
                individualCall.state = .accepting
                individualCall.deferredAnswerCompletion = {
                    action.fulfill()
                }
            } else {
                owsAssertDebug(individualCall.state == .localRinging_ReadyToAnswer)
                callService.individualCallService.handleAcceptCall(call)
                action.fulfill()
            }
        }
    }

    @MainActor
    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Logger.info("Received \(#function) CXEndCallAction")
        guard let call = callManager.callWithLocalId(action.callUUID) else {
            Logger.error("trying to end unknown call with localId: \(action.callUUID)")
            action.fail()
            return
        }

        callService.handleLocalHangupCall(call)

        // Signal to the system that the action has been successfully performed.
        action.fulfill()

        // Remove the ended call from the app's list of calls.
        self.callManager.removeCall(call)
    }

    @MainActor
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Logger.info("Received \(#function) CXSetHeldCallAction")
        guard let call = callManager.callWithLocalId(action.callUUID) else {
            action.fail()
            return
        }

        // Update the IndividualCall's underlying hold state.
        self.callService.individualCallService.setIsOnHold(call: call, isOnHold: action.isOnHold)

        // Signal to the system that the action has been successfully performed.
        action.fulfill()
    }

    @MainActor
    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Logger.info("Received \(#function) CXSetMutedCallAction")
        guard nil != callManager.callWithLocalId(action.callUUID) else {
            Logger.info("Failing CXSetMutedCallAction for unknown (ended?) call: \(action.callUUID)")
            action.fail()
            return
        }

        defer { ignoreFirstUnmuteAfterRemoteAnswer = false }
        guard !ignoreFirstUnmuteAfterRemoteAnswer || action.isMuted else {
            action.fulfill()
            return
        }

        self.callService.updateIsLocalAudioMuted(isLocalAudioMuted: action.isMuted)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        AssertIsOnMainThread()

        Logger.warn("unimplemented \(#function) for CXSetGroupCallAction")
    }

    public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        AssertIsOnMainThread()

        Logger.warn("unimplemented \(#function) for CXPlayDTMFCallAction")
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        AssertIsOnMainThread()

        if let muteAction = action as? CXSetMutedCallAction {
            guard callManager.callWithLocalId(muteAction.callUUID) != nil else {
                // When a call is over, if it was muted, CallKit "helpfully" attempts to unmute the
                // call with "CXSetMutedCallAction", presumably to help us clean up state.
                //
                // That is, it calls func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction)
                //
                // We don't need this - we have our own mechanism for coalescing audio state, so
                // we acknowledge the action, but perform a no-op.
                //
                // However, regardless of fulfilling or failing the action, the action "times out"
                // on iOS13. CallKit similarly "auto unmutes" ended calls on iOS12, but on iOS12
                // it doesn't timeout.
                //
                // Presumably this is a regression in iOS13 - so we ignore it.
                // #RADAR FB7568405
                Logger.info("ignoring timeout for CXSetMutedCallAction for ended call: \(muteAction.callUUID)")
                return
            }
        }

        owsFailDebug("Timed out while performing \(action)")
    }

    @MainActor
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        AssertIsOnMainThread()

        _ = SUIEnvironment.shared.audioSessionRef.startAudioActivity(self.audioActivity)

        guard let call = self.callService.callServiceState.currentCall else {
            owsFailDebug("No current call for AudioSession")
            return
        }

        switch call.mode {
        case .individual(let individualCall) where individualCall.direction == .incoming:
            // Only enable audio upon activation for locally accepted calls.
            SUIEnvironment.shared.audioSessionRef.isRTCAudioEnabled = true
        case .individual, .groupThread, .callLink:
            break
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        AssertIsOnMainThread()

        SUIEnvironment.shared.audioSessionRef.isRTCAudioEnabled = false
        SUIEnvironment.shared.audioSessionRef.endAudioActivity(self.audioActivity)
    }

    // MARK: - Util

    private func disableUnsupportedFeatures(callUpdate: CXCallUpdate) {
        // Call Holding is failing to restart audio when "swapping" calls on the CallKit screen
        // until user returns to in-app call screen.
        callUpdate.supportsHolding = false

        // Not yet supported
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false

        // Is there any reason to support this?
        callUpdate.supportsDTMF = false
    }
}

//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient
import SignalRingRTC
import SignalServiceKit
import SignalUI

protocol CallLinkManager {
    func createCallLink(rootKey: CallLinkRootKey) async throws -> CallLinkManagerImpl.CreateResult

    func updateCallLinkName(
        _ name: String,
        rootKey: CallLinkRootKey,
        adminPasskey: Data,
        authCredential: SignalServiceKit.CallLinkAuthCredential
    ) async throws -> SignalUI.CallLinkState

    func updateCallLinkRestrictions(
        requiresAdminApproval: Bool,
        rootKey: CallLinkRootKey,
        adminPasskey: Data,
        authCredential: SignalServiceKit.CallLinkAuthCredential
    ) async throws -> SignalUI.CallLinkState
}

class CallLinkManagerImpl: CallLinkManager {
    private let networkManager: NetworkManager
    private let serverParams: GenericServerPublicParams
    private let sfuClient: SignalRingRTC.SFUClient
    // Even though we never use this, we need to retain it to ensure
    // `sfuClient` continues to work properly.
    private let sfuClientHttpClient: AnyObject
    private let tsAccountManager: any TSAccountManager

    init(
        networkManager: NetworkManager,
        serverParams: GenericServerPublicParams,
        tsAccountManager: any TSAccountManager
    ) {
        self.networkManager = networkManager
        self.serverParams = serverParams
        let httpClient = CallHTTPClient()
        self.sfuClient = SignalRingRTC.SFUClient(httpClient: httpClient.ringRtcHttpClient)
        self.sfuClientHttpClient = httpClient
        self.tsAccountManager = tsAccountManager
    }

    // MARK: - Create Call Link

    private struct CallLinkCreateAuthResponse: Decodable {
        var credential: Data
    }

    private func fetchCreateCredential(for roomId: Data, localAci: Aci) async throws -> CreateCallLinkCredential {
        let credentialRequestContext = CreateCallLinkCredentialRequestContext.forRoomId(roomId)
        let httpRequest = TSRequest(
            url: URL(string: "v1/call-link/create-auth")!,
            method: "POST",
            parameters: [
                "createCallLinkCredentialRequest": credentialRequestContext.getRequest().serialize().asData.base64EncodedString()
            ]
        )
        let httpResult = try await self.networkManager.makePromise(request: httpRequest, canUseWebSocket: true).awaitable()
        guard httpResult.responseStatusCode == 200, let responseBodyData = httpResult.responseBodyData else {
            throw OWSGenericError("Couldn't handle successful result from the server.")
        }
        let httpResponse = try JSONDecoder().decode(CallLinkCreateAuthResponse.self, from: responseBodyData)
        let credentialResponse = try CreateCallLinkCredentialResponse(contents: [UInt8](httpResponse.credential))
        return try credentialRequestContext.receive(credentialResponse, userId: localAci, params: self.serverParams)
    }

    struct CreateResult {
        var adminPasskey: Data
        var callLinkState: SignalUI.CallLinkState
    }

    func createCallLink(rootKey: CallLinkRootKey) async throws -> CreateResult {
        let roomId = rootKey.deriveRoomId()
        let localIdentifiers = self.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction!
        let sfuUrl = DebugFlags.callingUseTestSFU.get() ? TSConstants.sfuTestURL : TSConstants.sfuURL
        let secretParams = CallLinkSecretParams.deriveFromRootKey(rootKey.bytes)
        let createCredential = try await fetchCreateCredential(for: roomId, localAci: localIdentifiers.aci)
        let createCredentialPresentation = createCredential.present(roomId: roomId, userId: localIdentifiers.aci, serverParams: self.serverParams, callLinkParams: secretParams)
        let publicParams = secretParams.getPublicParams()
        let adminPasskey = CallLinkRootKey.generateAdminPasskey()
        let callLinkState = CallLinkState(try await self.sfuClient.createCallLink(
            sfuUrl: sfuUrl,
            createCredentialPresentation: createCredentialPresentation.serialize(),
            linkRootKey: rootKey,
            adminPasskey: adminPasskey,
            callLinkPublicParams: publicParams.serialize(),
            restrictions: CallLinkState.Restrictions.adminApproval
        ).unwrap())
        return CreateResult(adminPasskey: adminPasskey, callLinkState: callLinkState)
    }

    func updateCallLinkName(
        _ name: String,
        rootKey: CallLinkRootKey,
        adminPasskey: Data,
        authCredential: SignalServiceKit.CallLinkAuthCredential
    ) async throws -> SignalUI.CallLinkState {
        let sfuUrl = DebugFlags.callingUseTestSFU.get() ? TSConstants.sfuTestURL : TSConstants.sfuURL
        let secretParams = CallLinkSecretParams.deriveFromRootKey(rootKey.bytes)
        let authCredentialPresentation = authCredential.present(callLinkParams: secretParams)
        return SignalUI.CallLinkState(try await self.sfuClient.updateCallLinkName(
            sfuUrl: sfuUrl,
            authCredentialPresentation: authCredentialPresentation.serialize(),
            linkRootKey: rootKey,
            adminPasskey: adminPasskey,
            newName: name
        ).unwrap())
    }

    func updateCallLinkRestrictions(
        requiresAdminApproval: Bool,
        rootKey: CallLinkRootKey,
        adminPasskey: Data,
        authCredential: SignalServiceKit.CallLinkAuthCredential
    ) async throws -> SignalUI.CallLinkState {
        let sfuUrl = DebugFlags.callingUseTestSFU.get() ? TSConstants.sfuTestURL : TSConstants.sfuURL
        let secretParams = CallLinkSecretParams.deriveFromRootKey(rootKey.bytes)
        let authCredentialPresentation = authCredential.present(callLinkParams: secretParams)
        return SignalUI.CallLinkState(try await self.sfuClient.updateCallLinkRestrictions(
            sfuUrl: sfuUrl,
            authCredentialPresentation: authCredentialPresentation.serialize(),
            linkRootKey: rootKey,
            adminPasskey: adminPasskey,
            restrictions: requiresAdminApproval ? .adminApproval : .none
        ).unwrap())
    }
}

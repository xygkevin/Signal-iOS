//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import "TSErrorMessage.h"
#import "ContactsManagerProtocol.h"
#import "TSContactThread.h"
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSUInteger TSErrorMessageSchemaVersion = 2;

#pragma mark -

@interface TSErrorMessage ()

@property (nonatomic, getter=wasRead) BOOL read;

@property (nonatomic, readonly) NSUInteger errorMessageSchemaVersion;

@end

#pragma mark -

@implementation TSErrorMessage

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self) {
        return self;
    }

    if (self.errorMessageSchemaVersion < 1) {
        _read = YES;
    }

    if (self.errorMessageSchemaVersion == 1) {
        NSString *_Nullable phoneNumber = [coder decodeObjectForKey:@"recipientId"];
        if (phoneNumber) {
            _recipientAddress = [SignalServiceAddress legacyAddressWithServiceIdString:nil phoneNumber:phoneNumber];
            OWSAssertDebug(_recipientAddress.isValid);
        }
    }

    _errorMessageSchemaVersion = TSErrorMessageSchemaVersion;

    if (self.isDynamicInteraction) {
        self.read = YES;
    }

    return self;
}

- (instancetype)initErrorMessageWithBuilder:(TSErrorMessageBuilder *)errorMessageBuilder
{
    self = [super initMessageWithBuilder:errorMessageBuilder];

    if (!self) {
        return self;
    }

    _errorType = errorMessageBuilder.errorType;
    _sender = errorMessageBuilder.senderAddress;
    _recipientAddress = errorMessageBuilder.recipientAddress;
    _errorMessageSchemaVersion = TSErrorMessageSchemaVersion;
    _wasIdentityVerified = errorMessageBuilder.wasIdentityVerified;

    if (self.isDynamicInteraction) {
        self.read = YES;
    }

    return self;
}

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
             receivedAtTimestamp:(uint64_t)receivedAtTimestamp
                          sortId:(uint64_t)sortId
                       timestamp:(uint64_t)timestamp
                  uniqueThreadId:(NSString *)uniqueThreadId
                   attachmentIds:(NSArray<NSString *> *)attachmentIds
                            body:(nullable NSString *)body
                      bodyRanges:(nullable MessageBodyRanges *)bodyRanges
                    contactShare:(nullable OWSContact *)contactShare
                       editState:(TSEditState)editState
                 expireStartedAt:(uint64_t)expireStartedAt
                       expiresAt:(uint64_t)expiresAt
                expiresInSeconds:(unsigned int)expiresInSeconds
                       giftBadge:(nullable OWSGiftBadge *)giftBadge
               isGroupStoryReply:(BOOL)isGroupStoryReply
              isViewOnceComplete:(BOOL)isViewOnceComplete
               isViewOnceMessage:(BOOL)isViewOnceMessage
                     linkPreview:(nullable OWSLinkPreview *)linkPreview
                  messageSticker:(nullable MessageSticker *)messageSticker
                   quotedMessage:(nullable TSQuotedMessage *)quotedMessage
    storedShouldStartExpireTimer:(BOOL)storedShouldStartExpireTimer
           storyAuthorUuidString:(nullable NSString *)storyAuthorUuidString
              storyReactionEmoji:(nullable NSString *)storyReactionEmoji
                  storyTimestamp:(nullable NSNumber *)storyTimestamp
              wasRemotelyDeleted:(BOOL)wasRemotelyDeleted
                       errorType:(TSErrorMessageType)errorType
                            read:(BOOL)read
                recipientAddress:(nullable SignalServiceAddress *)recipientAddress
                          sender:(nullable SignalServiceAddress *)sender
             wasIdentityVerified:(BOOL)wasIdentityVerified
{
    self = [super initWithGrdbId:grdbId
                        uniqueId:uniqueId
               receivedAtTimestamp:receivedAtTimestamp
                            sortId:sortId
                         timestamp:timestamp
                    uniqueThreadId:uniqueThreadId
                     attachmentIds:attachmentIds
                              body:body
                        bodyRanges:bodyRanges
                      contactShare:contactShare
                         editState:editState
                   expireStartedAt:expireStartedAt
                         expiresAt:expiresAt
                  expiresInSeconds:expiresInSeconds
                         giftBadge:giftBadge
                 isGroupStoryReply:isGroupStoryReply
                isViewOnceComplete:isViewOnceComplete
                 isViewOnceMessage:isViewOnceMessage
                       linkPreview:linkPreview
                    messageSticker:messageSticker
                     quotedMessage:quotedMessage
      storedShouldStartExpireTimer:storedShouldStartExpireTimer
             storyAuthorUuidString:storyAuthorUuidString
                storyReactionEmoji:storyReactionEmoji
                    storyTimestamp:storyTimestamp
                wasRemotelyDeleted:wasRemotelyDeleted];

    if (!self) {
        return self;
    }

    _errorType = errorType;
    _read = read;
    _recipientAddress = recipientAddress;
    _sender = sender;
    _wasIdentityVerified = wasIdentityVerified;

    return self;
}

// clang-format on

// --- CODE GENERATION MARKER

- (OWSInteractionType)interactionType
{
    return OWSInteractionType_Error;
}

- (NSString *)previewTextWithTransaction:(SDSAnyReadTransaction *)transaction
{
    switch (_errorType) {
        case TSErrorMessageNoSession:
            return OWSLocalizedString(@"ERROR_MESSAGE_NO_SESSION", @"");
        case TSErrorMessageInvalidMessage:
            return OWSLocalizedString(@"ERROR_MESSAGE_INVALID_MESSAGE", @"");
        case TSErrorMessageInvalidVersion:
            return OWSLocalizedString(@"ERROR_MESSAGE_INVALID_VERSION", @"");
        case TSErrorMessageDuplicateMessage:
            return OWSLocalizedString(@"ERROR_MESSAGE_DUPLICATE_MESSAGE", @"");
        case TSErrorMessageInvalidKeyException:
            return OWSLocalizedString(@"ERROR_MESSAGE_INVALID_KEY_EXCEPTION", @"");
        case TSErrorMessageWrongTrustedIdentityKey:
            return OWSLocalizedString(@"ERROR_MESSAGE_WRONG_TRUSTED_IDENTITY_KEY", @"");
        case TSErrorMessageNonBlockingIdentityChange:
            return [TSErrorMessage safetyNumberChangeDescriptionFor:self.recipientAddress tx:transaction];
        case TSErrorMessageUnknownContactBlockOffer:
            return OWSLocalizedString(@"UNKNOWN_CONTACT_BLOCK_OFFER",
                @"Message shown in conversation view that offers to block an unknown user.");
        case TSErrorMessageGroupCreationFailed:
            return OWSLocalizedString(@"GROUP_CREATION_FAILED",
                @"Message shown in conversation view that indicates there were issues with group creation.");
        case TSErrorMessageSessionRefresh:
            return OWSLocalizedString(
                @"ERROR_MESSAGE_SESSION_REFRESH", @"Text notifying the user that their secure session has been reset");
        case TSErrorMessageDecryptionFailure: {
            if (self.sender) {
                NSString *formatString = OWSLocalizedString(@"ERROR_MESSAGE_DECRYPTION_FAILURE",
                    @"Error message for a decryption failure. Embeds {{sender short name}}.");
                NSString *senderName = [self.contactsManager shortDisplayNameForAddress:self.sender
                                                                            transaction:transaction];
                return [[NSString alloc] initWithFormat:formatString, senderName];
            } else {
                return OWSLocalizedString(
                    @"ERROR_MESSAGE_DECRYPTION_FAILURE_UNKNOWN_SENDER", @"Error message for a decryption failure.");
            }
        }
        default:
            OWSFailDebug(@"failure: unknown error type");
            break;
    }
    return OWSLocalizedString(@"ERROR_MESSAGE_UNKNOWN_ERROR", @"");
}

+ (instancetype)invalidVersionWithEnvelope:(SSKProtoEnvelope *)envelope
                           withTransaction:(SDSAnyWriteTransaction *)transaction
{
    return [[TSErrorMessageBuilder errorMessageBuilderWithErrorType:TSErrorMessageInvalidVersion
                                                           envelope:envelope
                                                        transaction:transaction] build];
}

+ (instancetype)invalidKeyExceptionWithEnvelope:(SSKProtoEnvelope *)envelope
                                withTransaction:(SDSAnyWriteTransaction *)transaction
{
    return [[TSErrorMessageBuilder errorMessageBuilderWithErrorType:TSErrorMessageInvalidKeyException
                                                           envelope:envelope
                                                        transaction:transaction] build];
}

+ (instancetype)missingSessionWithEnvelope:(SSKProtoEnvelope *)envelope
                           withTransaction:(SDSAnyWriteTransaction *)transaction
{
    return [[TSErrorMessageBuilder errorMessageBuilderWithErrorType:TSErrorMessageNoSession
                                                           envelope:envelope
                                                        transaction:transaction] build];
}

+ (instancetype)sessionRefreshWithSourceAci:(AciObjC *)sourceAci withTransaction:(SDSAnyWriteTransaction *)transaction
{
    return [[TSErrorMessageBuilder errorMessageBuilderWithErrorType:TSErrorMessageSessionRefresh
                                                          sourceAci:sourceAci
                                                                 tx:transaction] build];
}

+ (instancetype)nonblockingIdentityChangeInThread:(TSThread *)thread
                                          address:(SignalServiceAddress *)address
                              wasIdentityVerified:(BOOL)wasIdentityVerified
{
    TSErrorMessageBuilder *builder =
        [TSErrorMessageBuilder errorMessageBuilderWithThread:thread errorType:TSErrorMessageNonBlockingIdentityChange];
    builder.recipientAddress = address;
    builder.wasIdentityVerified = wasIdentityVerified;
    return [builder build];
}

+ (instancetype)failedDecryptionForSender:(nullable SignalServiceAddress *)sender
                                   thread:(TSThread *)thread
                                timestamp:(uint64_t)timestamp
                              transaction:(SDSAnyWriteTransaction *)transaction
{
    TSErrorMessageBuilder *builder =
        [TSErrorMessageBuilder errorMessageBuilderWithThread:thread errorType:TSErrorMessageDecryptionFailure];
    builder.senderAddress = sender;
    builder.timestamp = timestamp;
    return [builder build];
}

+ (instancetype)failedDecryptionForSender:(SignalServiceAddress *)sender
                         untrustedGroupId:(nullable NSData *)untrustedGroupId
                                timestamp:(uint64_t)timestamp
                              transaction:(SDSAnyWriteTransaction *)transaction
{
    TSThread *_Nullable thread = nil;
    if (untrustedGroupId.length > 0) {
        [TSGroupThread ensureGroupIdMappingForGroupId:untrustedGroupId transaction:transaction];
        TSGroupThread *_Nullable groupThread = [TSGroupThread fetchWithGroupId:untrustedGroupId
                                                                   transaction:transaction];
        // If we aren't sure that the sender is a member of the reported groupId, we should fall back
        // to inserting the placeholder in the contact thread.
        if ([groupThread.groupMembership isFullMember:sender]) {
            thread = groupThread;
        }
        OWSAssertDebug(thread);
    }
    if (!thread) {
        thread = [TSContactThread getThreadWithContactAddress:sender transaction:transaction];
        OWSAssertDebug(thread);
    }
    if (!thread) {
        return nil;
    }
    return [self failedDecryptionForSender:sender thread:thread timestamp:timestamp transaction:transaction];
}

#pragma mark - OWSReadTracking

- (uint64_t)expireStartedAt
{
    return 0;
}

- (BOOL)shouldAffectUnreadCounts
{
    return NO;
}

- (void)markAsReadAtTimestamp:(uint64_t)readTimestamp
                       thread:(TSThread *)thread
                 circumstance:(OWSReceiptCircumstance)circumstance
     shouldClearNotifications:(BOOL)shouldClearNotifications
                  transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);

    if (self.read) {
        return;
    }

    OWSLogDebug(@"marking as read uniqueId: %@ which has timestamp: %llu", self.uniqueId, self.timestamp);

    [self anyUpdateErrorMessageWithTransaction:transaction
                                         block:^(TSErrorMessage *message) {
                                             message.read = YES;
                                         }];

    // Ignore `circumstance` - we never send read receipts for error messages.
}

@end

NS_ASSUME_NONNULL_END

//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import <SignalServiceKit/BaseModel.h>

NS_ASSUME_NONNULL_BEGIN

@class DBWriteTransaction;
@class OWSStorage;
@class SSKProtoEnvelope;

@interface IncomingGroupsV2MessageJob : BaseModel

@property (nonatomic, readonly) NSDate *createdAt;
@property (nonatomic, readonly) NSData *envelopeData;
@property (nonatomic, readonly, nullable) NSData *plaintextData;
@property (nonatomic, readonly) BOOL wasReceivedByUD;
@property (nonatomic, readonly, nullable) NSData *groupId;
@property (nonatomic, readonly) uint64_t serverDeliveryTimestamp;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithUniqueId:(NSString *)uniqueId NS_UNAVAILABLE;
- (instancetype)initWithGrdbId:(int64_t)grdbId uniqueId:(NSString *)uniqueId NS_UNAVAILABLE;

- (instancetype)initWithEnvelopeData:(NSData *)envelopeData
                       plaintextData:(NSData *_Nullable)plaintextData // optional for historical reasons
                             groupId:(NSData *_Nullable)groupId
                     wasReceivedByUD:(BOOL)wasReceivedByUD
             serverDeliveryTimestamp:(uint64_t)serverDeliveryTimestamp NS_DESIGNATED_INITIALIZER;

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run
// `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
                       createdAt:(NSDate *)createdAt
                    envelopeData:(NSData *)envelopeData
                         groupId:(nullable NSData *)groupId
                   plaintextData:(nullable NSData *)plaintextData
         serverDeliveryTimestamp:(uint64_t)serverDeliveryTimestamp
                 wasReceivedByUD:(BOOL)wasReceivedByUD
NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(grdbId:uniqueId:createdAt:envelopeData:groupId:plaintextData:serverDeliveryTimestamp:wasReceivedByUD:));

// clang-format on

// --- CODE GENERATION MARKER

@property (nonatomic, readonly, nullable) SSKProtoEnvelope *envelope;

@end

NS_ASSUME_NONNULL_END

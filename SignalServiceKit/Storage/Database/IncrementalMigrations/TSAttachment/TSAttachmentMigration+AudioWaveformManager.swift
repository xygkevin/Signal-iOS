//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Accelerate
import AVFoundation
import Foundation

extension TSAttachmentMigration {

    struct AudioWaveform {
        let decibelSamples: [Float]

        func archive() throws -> Data {
            return try NSKeyedArchiver.archivedData(withRootObject: decibelSamples, requiringSecureCoding: false)
        }
    }

    class AudioWaveformManager {

        static func buildAudioWaveForm(
            unencryptedFilePath: String
        ) throws -> TSAttachmentMigration.AudioWaveform {
            let asset: AVAsset = try assetFromUnencryptedAudioFile(atAudioPath: unencryptedFilePath)

            guard asset.isReadable else {
                throw OWSAssertionError("unexpectedly encountered unreadable audio file.")
            }

            guard CMTimeGetSeconds(asset.duration) <= Self.maximumDuration else {
                throw OWSAssertionError("Audio too long")
            }

            return try sampleWaveform(asset: asset)
        }

        private static func assetFromUnencryptedAudioFile(
            atAudioPath audioPath: String
        ) throws -> AVAsset {
            let audioUrl = URL(fileURLWithPath: audioPath)

            var asset = AVURLAsset(url: audioUrl)

            if !asset.isReadable {
                if let extensionOverride = Self.alternativeAudioFileExtension(fileExtension: audioUrl.pathExtension) {
                    let symlinkPath = OWSFileSystem.temporaryFilePath(
                        fileExtension: extensionOverride,
                        isAvailableWhileDeviceLocked: true
                    )
                    try FileManager.default.createSymbolicLink(
                        atPath: symlinkPath,
                        withDestinationPath: audioPath
                    )
                    asset = AVURLAsset(url: URL(fileURLWithPath: symlinkPath))
                }
            }

            return asset
        }

        private static func alternativeAudioFileExtension(fileExtension: String) -> String? {
            // In some cases, Android sends audio messages with the "audio/mpeg" mime type. This
            // makes our choice of file extension ambiguous—`.mp3` or `.m4a`? AVFoundation uses the
            // extension to read the file, and if the extension is wrong, it won't be readable.
            //
            // We "lie" about the extension to generate the waveform so that AVFoundation may read
            // it. This is brittle but necessary to work around the buggy marriage of Android's
            // content type and AVFoundation's behavior.
            //
            // Note that we probably still want this code even if Android updates theirs, because
            // iOS users might have existing attachments.
            //
            // See:
            // <https://github.com/signalapp/Signal-iOS/issues/3590>.
            switch fileExtension {
            case "m4a": return "aac"
            case "mp3": return "m4a"
            default: return nil
            }
        }

        // MARK: - Sampling

        /// The maximum duration asset that we will display waveforms for.
        /// It's too intensive to sample a waveform for really long audio files.
        private static let maximumDuration: TimeInterval = 15 * kMinuteInterval
        private static let silenceThreshold: Float = -50
        private static let sampleCount = 100

        private static func downsample(samples: [Float], toSampleCount sampleCount: Int) -> [Float] {
            // Do nothing if the number of requested samples is less than 1
            guard sampleCount > 0 else { return [] }

            // If the requested sample count is equal to the sample count, just return the samples
            guard samples.count != sampleCount else { return samples }

            // Calculate the number of samples each downsampled value should take into account
            let sampleDistribution = Float(samples.count) / Float(sampleCount)

            // Calculate the number of samples we need to factor in when downsampling. Since there
            // is no such thing as a fractional sample, we need to round this up to the nearest Int.
            // When we calculated the distribution later, it will factor in that some of these samples
            // are weighted differently than others in the resulting output.
            let sampleLength = Int(ceil(sampleDistribution))

            // Calculate the weight of each sample in the downsampled group.
            // For whole number `sampleDistribution` the distribution is always
            // equivalent across all of the samples. If the sampleDistribution
            // is _not_ a whole number, we factor the bookending values in
            // relative to remainder proportion
            let distribution: [Float] = {
                let averageProportion = 1 / sampleDistribution

                var array = [Float](repeating: averageProportion, count: sampleLength)

                if samples.count % sampleCount != 0 {
                    // Calculate the proportion that the partial sample should be weighted at
                    let remainderProportion = (sampleDistribution.truncatingRemainder(dividingBy: 1)) * averageProportion

                    // The partial sample is factored into the "bookends" (first and last element of the distribution)
                    // by averaging the average distribution and the remainder distribution together.
                    // This provides a lightweight "anti-aliasing" effect.
                    let bookEndProportions = (averageProportion + remainderProportion) / 2

                    array[0] = bookEndProportions
                    array[sampleLength - 1] = bookEndProportions
                }

                return array
            }()

            // If we can ever guarantee that `samples.count` is always a multiple of `sampleCount`, we should
            // switch to using the faster `vDSP_desamp`. For now, we can't use it since it only supports the
            // integer stride lengths. This should be okay, since this should only be operating on already
            // downsampled data (~100 points) rather than the original millions of points.
            let result: [Float] = (0..<sampleCount).map { downsampledIndex in
                let sampleStart = Int(floor(Float(downsampledIndex) * sampleDistribution))
                return samples[sampleStart..<sampleStart + sampleLength].enumerated().reduce(0) { result, value in
                    return result + distribution[value.offset] * value.element
                }
            }

            return result
        }

        private static func sampleWaveform(asset: AVAsset) throws -> TSAttachmentMigration.AudioWaveform {
            let assetReader = try AVAssetReader(asset: asset)

            // We just draw the waveform based on the first track.
            guard let audioTrack = assetReader.asset.tracks.first else {
                throw OWSAssertionError("audio file has no tracks")
            }

            let trackOutput = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            assetReader.add(trackOutput)

            let decibelSamples = try readDecibels(from: assetReader)

            return TSAttachmentMigration.AudioWaveform(decibelSamples: decibelSamples)
        }

        private static func readDecibels(from assetReader: AVAssetReader) throws -> [Float] {
            var outputSamples = [Float]()
            var readBuffer = Data()

            let samplesToGroup = max(1, sampleCount(from: assetReader) / Self.sampleCount)

            assetReader.startReading()
            while assetReader.status == .reading {
                guard let trackOutput = assetReader.outputs.first else {
                    throw OWSAssertionError("track output unexpectedly missing")
                }

                // Process any newly read data.
                guard let nextSampleBuffer = trackOutput.copyNextSampleBuffer(),
                    let blockBuffer = CMSampleBufferGetDataBuffer(nextSampleBuffer) else {
                        // There is no more data to read, break
                        break
                }

                var readBufferLength = 0
                var readBufferPointer: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(
                    blockBuffer,
                    atOffset: 0,
                    lengthAtOffsetOut: &readBufferLength,
                    totalLengthOut: nil,
                    dataPointerOut: &readBufferPointer
                )
                readBuffer.append(UnsafeBufferPointer(start: readBufferPointer, count: readBufferLength))
                CMSampleBufferInvalidate(nextSampleBuffer)

                // Try and process any pending samples, we may not have read enough data yet to do this.
                let processedSamples = convertToDecibels(fromAmplitudes: readBuffer, from: assetReader, groupSize: samplesToGroup)
                outputSamples += processedSamples

                // If we successfully processed samples, remove any processed samples
                // from the read buffer.
                if processedSamples.count > 0 {
                    readBuffer.removeFirst(processedSamples.count * samplesToGroup * MemoryLayout<Int16>.size)
                }
            }

            return outputSamples
        }

        private static func sampleCount(from assetReader: AVAssetReader) -> Int {
            let samplesPerChannel = Int(assetReader.asset.duration.value)

            // We will read in the samples from each channel, interleaved since
            // we only draw one waveform. This gives us an average of the channels
            // if it is, for example, a stereo audio file.
            return samplesPerChannel * channelCount(from: assetReader)
        }

        private static func channelCount(from assetReader: AVAssetReader) -> Int {
            guard let output = assetReader.outputs.first as? AVAssetReaderTrackOutput,
                let formatDescriptions = output.track.formatDescriptions as? [CMFormatDescription] else { return 0 }

            var channelCount = 0

            for description in formatDescriptions {
                guard let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { continue }
                channelCount = Int(basicDescription.pointee.mChannelsPerFrame)
            }

            return channelCount
        }

        private static func convertToDecibels(fromAmplitudes sampleBuffer: Data, from assetReader: AVAssetReader, groupSize: Int) -> [Float] {
            var downSampledData = [Float]()

            sampleBuffer.withUnsafeBytes { samples in
                let sampleLength = sampleBuffer.count / MemoryLayout<Int16>.size
                var decibelSamples = [Float](repeating: 0.0, count: sampleLength)

                // maximum amplitude storable in Int16 = 0 dB (loudest)
                var zeroDecibelEquivalent: Float = Float(Int16.max)

                var loudestClipValue: Float = 0.0
                var quietestClipValue = Self.silenceThreshold
                let samplesToProcess = vDSP_Length(sampleLength)

                // convert 16bit int amplitudes to float representation
                vDSP_vflt16([Int16](samples.bindMemory(to: Int16.self)), 1, &decibelSamples, 1, samplesToProcess)

                // take the absolute amplitude value
                vDSP_vabs(decibelSamples, 1, &decibelSamples, 1, samplesToProcess)

                // convert to dB
                vDSP_vdbcon(decibelSamples, 1, &zeroDecibelEquivalent, &decibelSamples, 1, samplesToProcess, 1)

                // clip between loudest + quietest
                vDSP_vclip(decibelSamples, 1, &quietestClipValue, &loudestClipValue, &decibelSamples, 1, samplesToProcess)

                let sampleCount = sampleLength / groupSize
                downSampledData = downsample(samples: decibelSamples, toSampleCount: sampleCount)
            }

            return downSampledData
        }
    }
}

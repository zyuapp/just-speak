import Accelerate
import CoreML
import FluidAudio
import Foundation

/// CTC log-probabilities for vocabulary rescoring. Matches `CtcKeywordSpotter`'s staged inference
/// (15 s windows, 2 s overlap averaged, padding frames trimmed) using bulk memory copies and
/// vectorized log-softmax instead of per-element `MLMultiArray` subscripting.
nonisolated struct CtcLogProbs: Sendable {
    let frames: [[Float]]
    let frameDuration: Double

    private static let sampleRate = 16_000
    private static let windowSamples = ASRConstants.maxModelSamples
    private static let overlapSamples = 32_000

    static func compute(samples: [Float], models: CtcModels) async throws -> CtcLogProbs {
        guard !samples.isEmpty else { return CtcLogProbs(frames: [], frameDuration: 0) }

        var frames: [[Float]] = []
        var frameDuration = 0.0
        let stride = windowSamples - overlapSamples
        var start = 0

        while true {
            let end = min(start + windowSamples, samples.count)
            let window = try await computeWindow(samples[start..<end], models: models)
            if frameDuration == 0 { frameDuration = window.frameDuration }
            append(window.frames, to: &frames, frameDuration: frameDuration, isFirst: start == 0)
            if end >= samples.count { break }
            start += stride
        }

        return CtcLogProbs(frames: frames, frameDuration: frameDuration)
    }

    private static func append(
        _ window: [[Float]],
        to frames: inout [[Float]],
        frameDuration: Double,
        isFirst: Bool
    ) {
        guard !isFirst, frameDuration > 0 else {
            frames.append(contentsOf: window)
            return
        }

        let overlapFrames = Int(Double(overlapSamples) / Double(sampleRate) / frameDuration)
        let overlapCount = min(overlapFrames, frames.count, window.count)
        let existingStart = frames.count - overlapCount
        for index in 0..<overlapCount {
            var averaged = [Float](repeating: 0, count: window[index].count)
            vDSP.add(frames[existingStart + index], window[index], result: &averaged)
            vDSP.multiply(0.5, averaged, result: &averaged)
            frames[existingStart + index] = averaged
        }
        frames.append(contentsOf: window.dropFirst(overlapCount))
    }

    private static func computeWindow(
        _ samples: ArraySlice<Float>,
        models: CtcModels
    ) async throws -> CtcLogProbs {
        let melOutput = try await models.melSpectrogram.prediction(
            from: try melInput(samples, model: models.melSpectrogram)
        )
        guard let mel = melOutput.featureValue(for: "melspectrogram_features")?.multiArrayValue else {
            throw ASRError.processingFailed("Missing melspectrogram_features from CTC MelSpectrogram model")
        }

        var melLength = melOutput.featureValue(for: "mel_length")?.multiArrayValue?[0].intValue
            ?? mel.shape.last?.intValue ?? 0
        if mel.shape.count == 4 { melLength = mel.shape[2].intValue }

        let encoderOutput = try await models.encoder.prediction(
            from: try encoderInput(mel: mel, melLength: melLength)
        )
        guard let logits = encoderOutput.featureValue(for: "ctc_head_raw_output")?.multiArrayValue
            ?? encoderOutput.featureValue(for: "ctc_head_output")?.multiArrayValue else {
            throw ASRError.processingFailed("Missing CTC head output from encoder model")
        }

        let allFrames = try logSoftmaxFrames(logits)
        let validFrames = trimmedFrameCount(total: allFrames.count, sampleCount: samples.count)
        let frames = Array(allFrames.prefix(validFrames))
        let frameDuration = frames.isEmpty
            ? 0
            : Double(samples.count) / Double(frames.count) / Double(sampleRate)
        return CtcLogProbs(frames: frames, frameDuration: frameDuration)
    }

    private static func melInput(_ samples: ArraySlice<Float>, model: MLModel) throws -> MLFeatureProvider {
        let constraint = model.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint
        let shape: [NSNumber] = constraint?.shape.count == 2
            ? [1, NSNumber(value: windowSamples)]
            : [NSNumber(value: windowSamples)]
        let dataType: MLMultiArrayDataType = constraint?.dataType == .float16 ? .float16 : .float32
        let audio = try MLMultiArray(shape: shape, dataType: dataType)
        write(samples, into: audio)

        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: samples.count)
        return try MLDictionaryFeatureProvider(dictionary: [
            "audio": MLFeatureValue(multiArray: audio),
            "audio_length": MLFeatureValue(multiArray: length),
        ])
    }

    private static func write(_ samples: ArraySlice<Float>, into array: MLMultiArray) {
        let count = array.count
        if array.dataType == .float16 {
            let destination = array.dataPointer.bindMemory(to: Float16.self, capacity: count)
            destination.initialize(repeating: 0, count: count)
            for (offset, sample) in samples.enumerated() { destination[offset] = Float16(sample) }
        } else {
            let destination = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            destination.initialize(repeating: 0, count: count)
            samples.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress!, count: source.count)
            }
        }
    }

    private static func encoderInput(mel: MLMultiArray, melLength: Int) throws -> MLFeatureProvider {
        guard melLength > 0 else {
            throw ASRError.processingFailed("Invalid mel_length for CTC encoder input")
        }

        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: melLength)
        let flag = try MLMultiArray(shape: [1, 1, 1, 1], dataType: .float16)
        flag[0] = 1
        return try MLDictionaryFeatureProvider(dictionary: [
            "melspectrogram_features": MLFeatureValue(multiArray: mel),
            "mel_length": MLFeatureValue(multiArray: length),
            "input_1": MLFeatureValue(multiArray: flag),
        ])
    }

    /// Reads `[1, T, V]` or `[1, V, 1, T]` logits through their strides and applies log-softmax per frame.
    private static func logSoftmaxFrames(_ logits: MLMultiArray) throws -> [[Float]] {
        let shape = logits.shape.map(\.intValue)
        let strides = logits.strides.map(\.intValue)
        let (timeSteps, vocabSize, timeStride, vocabStride): (Int, Int, Int, Int)
        switch shape.count {
        case 3: (timeSteps, vocabSize, timeStride, vocabStride) = (shape[1], shape[2], strides[1], strides[2])
        case 4: (timeSteps, vocabSize, timeStride, vocabStride) = (shape[3], shape[1], strides[3], strides[1])
        default: throw ASRError.processingFailed("Unexpected CTC output rank: \(logits.shape)")
        }
        guard timeSteps > 0, vocabSize > 0 else { return [] }

        let read = elementReader(logits)
        return (0..<timeSteps).map { time in
            var row = (0..<vocabSize).map { read(time * timeStride + $0 * vocabStride) }
            logSoftmax(&row)
            return row
        }
    }

    private static func elementReader(_ array: MLMultiArray) -> (Int) -> Float {
        switch array.dataType {
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            return { Float(pointer[$0]) }
        case .double:
            let pointer = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
            return { Float(pointer[$0]) }
        default:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            return { pointer[$0] }
        }
    }

    private static func logSoftmax(_ row: inout [Float]) {
        let maximum = vDSP.maximum(row)
        vDSP.add(-maximum, row, result: &row)
        var exponentials = [Float](repeating: 0, count: row.count)
        vForce.exp(row, result: &exponentials)
        vDSP.add(-logf(vDSP.sum(exponentials)), row, result: &row)
    }

    private static func trimmedFrameCount(total: Int, sampleCount: Int) -> Int {
        guard total > 0, sampleCount < windowSamples else { return total }
        let samplesPerFrame = Double(windowSamples) / Double(total)
        let validFrames = Int(ceil(Double(sampleCount) / samplesPerFrame))
        return max(1, min(validFrames, total))
    }
}

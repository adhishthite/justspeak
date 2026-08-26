// MARK: - Binary Helpers (WAV Header Generator)

extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian) { Array($0) }
    }
}

func createWavData(from pcm16Data: Data, sampleRate: Int = 16000, channels: Int = 1) -> Data {
    var wav = Data()
    let dataSize = pcm16Data.count
    let chunkSize = UInt32(36 + dataSize)
    
    // RIFF Chunk Descriptor
    wav.append("RIFF".data(using: .ascii)!)
    wav.append(contentsOf: chunkSize.littleEndianBytes)
    wav.append("WAVE".data(using: .ascii)!)
    
    // fmt Sub-chunk
    wav.append("fmt ".data(using: .ascii)!)
    wav.append(contentsOf: UInt32(16).littleEndianBytes) // Subchunk1Size (16 for PCM)
    wav.append(contentsOf: UInt16(1).littleEndianBytes)  // AudioFormat (1 = PCM Linear)
    wav.append(contentsOf: UInt16(channels).littleEndianBytes)
    wav.append(contentsOf: UInt32(sampleRate).littleEndianBytes)
    wav.append(contentsOf: UInt32(sampleRate * channels * 2).littleEndianBytes) // ByteRate
    wav.append(contentsOf: UInt16(channels * 2).littleEndianBytes)              // BlockAlign
    wav.append(contentsOf: UInt16(16).littleEndianBytes)                         // BitsPerSample
    
    // data Sub-chunk
    wav.append("data".data(using: .ascii)!)
    wav.append(contentsOf: UInt32(dataSize).littleEndianBytes)
    wav.append(pcm16Data)
    
    return wav
}


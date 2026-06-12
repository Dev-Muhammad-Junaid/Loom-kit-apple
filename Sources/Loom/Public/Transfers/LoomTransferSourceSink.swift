//
//  LoomTransferSourceSink.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation

/// Offset-based readable object source used by Loom bulk transfer.
public protocol LoomTransferSource: Sendable {
    /// Total readable object length.
    var byteLength: UInt64 { get }
    /// Reads a chunk beginning at `offset` and bounded by `maxLength`.
    func read(offset: UInt64, maxLength: Int) async throws -> Data
}

/// Offset-based writable object sink used by Loom bulk transfer.
public protocol LoomTransferSink: Sendable {
    /// Truncates any previously written content to the given contiguous prefix length.
    func truncate(to byteCount: UInt64) async throws
    /// Writes a chunk at the requested byte offset.
    func write(_ data: Data, at offset: UInt64) async throws
    /// Finalizes the accepted object after Loom has written the expected bytes.
    func finalize(offer: LoomTransferOffer, bytesWritten: UInt64) async throws
}

/// Optional sink capability: read back previously written bytes.
///
/// WID-342: resumed transfers can only be integrity-verified end-to-end if
/// the engine can rebuild the running SHA-256 over the bytes that were
/// written in the *previous* session. Sinks that adopt this protocol get
/// full integrity verification on resume; sinks that don't fall back to
/// the historical behavior (resumed transfers skip hash verification,
/// now explicitly logged).
public protocol LoomReadableTransferSink: LoomTransferSink {
    /// Reads back a chunk of previously written content.
    func readWritten(offset: UInt64, maxLength: Int) async throws -> Data
}

/// URL-backed transfer source that reads from a file on disk without buffering the whole file.
public actor LoomFileTransferSource: LoomTransferSource {
    /// File URL read by this transfer source.
    public let url: URL
    /// Total readable file size in bytes.
    public let byteLength: UInt64

    private let handle: FileHandle

    public init(url: URL) throws {
        self.url = url
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        byteLength = size
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    public func read(offset: UInt64, maxLength: Int) async throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: maxLength) ?? Data()
    }
}

/// URL-backed transfer sink that writes sequential chunks into a file on disk.
public actor LoomFileTransferSink: LoomTransferSink, LoomReadableTransferSink {
    /// File URL written by this transfer sink.
    public let url: URL

    private let handle: FileHandle
    /// Lazily opened read handle for resume-rehash (WID-342). Separate from
    /// the write handle so seeks for verification never disturb write position.
    private var readHandle: FileHandle?

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) == false {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
        try? readHandle?.close()
    }

    public func truncate(to byteCount: UInt64) async throws {
        try handle.truncate(atOffset: byteCount)
    }

    public func write(_ data: Data, at offset: UInt64) async throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
    }

    public func readWritten(offset: UInt64, maxLength: Int) async throws -> Data {
        if readHandle == nil {
            readHandle = try FileHandle(forReadingFrom: url)
        }
        guard let readHandle else { return Data() }
        try readHandle.seek(toOffset: offset)
        return try readHandle.read(upToCount: maxLength) ?? Data()
    }

    public func finalize(offer _: LoomTransferOffer, bytesWritten _: UInt64) async throws {}
}

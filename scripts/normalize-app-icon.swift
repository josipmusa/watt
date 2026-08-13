#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: normalize-app-icon.swift <input.png> <output.png>\n".utf8))
    exit(64)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let size = 1024
let bytesPerPixel = 4
let bytesPerRow = size * bytesPerPixel

guard
    let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
    let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    FileHandle.standardError.write(Data("Unable to read \(inputURL.path)\n".utf8))
    exit(1)
}

var pixels = [UInt8](repeating: 0, count: size * bytesPerRow)
guard let context = CGContext(
    data: &pixels,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
) else {
    FileHandle.standardError.write(Data("Unable to create the icon bitmap\n".utf8))
    exit(1)
}

context.interpolationQuality = .high
context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: size, height: size))

// Image generators commonly render transparent icon corners as opaque black.
// Remove only near-black pixels connected to the canvas edge, preserving every
// dark pixel enclosed by the artwork itself.
var exterior = [Bool](repeating: false, count: size * size)
var queue = [Int]()
queue.reserveCapacity(size * size / 4)

func isExteriorBackground(_ index: Int) -> Bool {
    let offset = index * bytesPerPixel
    return pixels[offset + 3] > 0
        && max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) <= 10
}

func enqueue(_ index: Int) {
    guard !exterior[index], isExteriorBackground(index) else { return }
    exterior[index] = true
    queue.append(index)
}

for coordinate in 0..<size {
    enqueue(coordinate)
    enqueue((size - 1) * size + coordinate)
    enqueue(coordinate * size)
    enqueue(coordinate * size + size - 1)
}

var cursor = 0
while cursor < queue.count {
    let index = queue[cursor]
    cursor += 1
    let x = index % size
    let y = index / size
    if x > 0 { enqueue(index - 1) }
    if x + 1 < size { enqueue(index + 1) }
    if y > 0 { enqueue(index - size) }
    if y + 1 < size { enqueue(index + size) }
}

for index in queue {
    let offset = index * bytesPerPixel
    pixels[offset] = 0
    pixels[offset + 1] = 0
    pixels[offset + 2] = 0
    pixels[offset + 3] = 0
}

guard
    let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )
else {
    FileHandle.standardError.write(Data("Unable to create \(outputURL.path)\n".utf8))
    exit(1)
}

CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("Unable to write \(outputURL.path)\n".utf8))
    exit(1)
}

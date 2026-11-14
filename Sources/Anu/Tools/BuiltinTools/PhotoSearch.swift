import Foundation
import CoreGraphics

/// "Find my photos of waterfalls" (AI Edge Gallery's Media Search): each
/// photo's contents are labelled on this device by Vision's image classifier,
/// and the words asked for are matched against those labels. Nothing leaves
/// the device, and labels are kept only in memory for the session.
enum PhotoSearch {
    /// How many of the newest photos are looked through.
    static let scanLimit = 400
    /// The least confidence a label needs to count.
    static let minConfidence: Float = 0.25
    /// Matches shown in the chat.
    static let shownLimit = 4

    /// Words that mean the same thing as one of Vision's labels.
    static let synonyms: [String: [String]] = [
        "dog": ["dog", "canine", "puppy"], "puppy": ["dog", "puppy"],
        "cat": ["cat", "feline", "kitten"], "kitten": ["cat", "kitten"],
        "flower": ["flower", "blossom", "bloom", "petal"], "blossom": ["flower", "blossom"],
        "beach": ["beach", "shore", "sand", "coast"], "sea": ["ocean", "sea", "water_body"],
        "ocean": ["ocean", "sea", "water_body"], "mountain": ["mountain", "hill", "peak"],
        "waterfall": ["waterfall"], "tree": ["tree", "forest", "foliage"],
        "food": ["food", "meal", "dish", "dessert", "fruit", "vegetable"],
        "car": ["car", "automobile", "vehicle"], "sunset": ["sunset", "sunrise", "sky"],
        "people": ["people", "person", "adult", "child", "crowd"], "person": ["people", "person", "adult"],
        "selfie": ["people", "person", "portrait"], "document": ["document", "text", "paper", "receipt"],
        "receipt": ["receipt", "document", "text"], "screenshot": ["screenshot", "text", "document"],
        "plant": ["plant", "foliage", "leaf", "tree", "flower"], "leaf": ["leaf", "foliage", "plant"],
    ]

    /// The label words to look for, from what was asked ("waterfalls" → waterfall).
    static func wanted(_ query: String) -> [[String]] {
        let stop: Set<String> = ["a", "an", "the", "my", "of", "with", "and", "photo", "photos", "picture",
                                 "pictures", "pic", "pics", "image", "images", "some", "any", "all", "me", "show", "find"]
        return query.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count > 1 && !stop.contains($0) }
            .map { word in
                let one = singular(word)
                return synonyms[one] ?? [one]
            }
    }

    static func singular(_ word: String) -> String {
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("sses") || word.hasSuffix("shes") || word.hasSuffix("ches") { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 3 { return String(word.dropLast()) }
        return word
    }

    /// Whether a photo's labels answer every word asked for (any synonym each).
    static func matches(_ wanted: [[String]], labels: [String: Float]) -> Bool {
        guard !wanted.isEmpty else { return false }
        return wanted.allSatisfy { options in
            labels.contains { label, confidence in
                confidence >= minConfidence && options.contains { label == $0 || label.hasPrefix($0 + "_") || label.hasSuffix("_" + $0) }
            }
        }
    }

    struct Hit: Sendable {
        let id: String
        let date: Date?
        let thumbnail: Data?
    }

    /// The last search's pictures, taken once by the chat to show them.
    nonisolated(unsafe) private static var shown: [Data] = []
    private static let lock = NSLock()

    static func keepShown(_ photos: [Data]) { lock.lock(); shown = photos; lock.unlock() }
    static func takeShown() -> [Data] { lock.lock(); defer { shown = []; lock.unlock() }; return shown }
}

#if canImport(Photos) && canImport(Vision)
import Photos
import Vision
import ImageIO
import UniformTypeIdentifiers

extension PhotoSearch {
    /// True when the last search couldn't look at any photo.
    nonisolated(unsafe) static var unavailable = false
    /// Why the last classification failed, for diagnosis.
    nonisolated(unsafe) static var lastError: String?
    /// Labels already worked out this session, by photo id.
    nonisolated(unsafe) private static var cache: [String: [String: Float]] = [:]

    /// Vision's labels for an image, by confidence.
    static func labels(_ image: CGImage) -> [String: Float] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch {
            lastError = String(describing: error)
            return [:]
        }
        var out: [String: Float] = [:]
        for observation in request.results ?? [] where observation.confidence >= 0.1 {
            out[observation.identifier.lowercased()] = observation.confidence
        }
        return out
    }

    /// The newest photos whose contents match `query`, newest first.
    static func search(_ query: String, limit: Int = scanLimit) -> [Hit] {
        let words = wanted(query)
        guard !words.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        let manager = PHImageManager.default()
        let request = PHImageRequestOptions()
        request.isSynchronous = true
        request.deliveryMode = .highQualityFormat
        request.resizeMode = .fast
        request.isNetworkAccessAllowed = false   // never fetch from iCloud for a search

        var hits: [Hit] = []
        var looked = 0, failed = 0
        lastError = nil
        assets.enumerateObjects { asset, _, _ in
            var thumbnail: CGImage?
            func image() -> CGImage? {
                if let thumbnail { return thumbnail }
                manager.requestImage(for: asset, targetSize: CGSize(width: 360, height: 360),
                                     contentMode: .aspectFill, options: request) { picture, _ in
                    #if canImport(UIKit)
                    thumbnail = picture?.cgImage
                    #else
                    thumbnail = picture?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    #endif
                }
                return thumbnail
            }
            let labels: [String: Float]
            if let known = cache[asset.localIdentifier] {
                labels = known
            } else {
                guard let picture = image() else { return }
                looked += 1
                labels = Self.labels(picture)
                if labels.isEmpty { failed += 1 } else { cache[asset.localIdentifier] = labels }
            }
            guard matches(words, labels: labels) else { return }
            let jpeg = hits.count < shownLimit ? image().flatMap(Self.jpeg) : nil
            hits.append(Hit(id: asset.localIdentifier, date: asset.creationDate, thumbnail: jpeg))
        }
        // Vision couldn't label any of them (the simulator can't): say so.
        unavailable = looked > 0 && failed == looked
        return hits
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
#endif

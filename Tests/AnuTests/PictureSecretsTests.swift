import XCTest
import CoreGraphics
import CoreText
import ImageIO
@testable import Anu

/// Secrets in pictures (SECRETS-1, ADR-082): answers about a photo mask codes,
/// card numbers and passwords, the stream is held at a possible code, and
/// screen-like pictures have their secrets blacked out before any model sees
/// them. All fixtures are made up and drawn here.
final class PictureSecretsTests: XCTestCase {
    private let mask = OneTimeCodes.mask

    // MARK: Answers

    func testCodeIsMaskedWhenTheAnswerOrTheQuestionSpeaksOfOne() {
        XCTAssertEqual(ShownSecrets.mask("Your code is 483920.", asked: "what does it say?"), "Your code is \(mask).")
        // Only the question speaks of a code.
        XCTAssertEqual(ShownSecrets.mask("It's 483920.", asked: "What's the code?"), "It's \(mask).")
        XCTAssertEqual(ShownSecrets.mask("It says 482 913", asked: "read me the verification text"), "It says \(mask)")
    }

    func testYearsAndRoomNumbersAreLeftAloneWithoutCodeTalk() {
        let answer = "The sign says the museum opened in 1998 and room 4512 is upstairs."
        XCTAssertEqual(ShownSecrets.mask(answer, asked: "what does the sign say?"), answer)
    }

    func testLabelledPasswordsAndPinsAreMasked() {
        XCTAssertEqual(ShownSecrets.mask("The Wi-Fi password is tulip-garden42.", asked: "what's on the card?"),
                       "The Wi-Fi password is \(mask).")
        XCTAssertEqual(ShownSecrets.mask("PIN: 7731", asked: "what's this?"), "PIN: \(mask)")
    }

    func testCardNumbersAreMaskedOnlyWhenTheyPassLuhn() {
        XCTAssertEqual(ShownSecrets.mask("Card 4242 4242 4242 4242 expires soon", asked: "what's this?"),
                       "Card \(mask) expires soon")
        let notACard = "Order 1234 5678 9012 3456 shipped"
        XCTAssertEqual(ShownSecrets.mask(notACard, asked: "status?"), notACard)
    }

    func testKnownCodesAreMaskedHoweverTheyAreWritten() {
        let out = ShownSecrets.mask("I named the file 482-913.txt", asked: "rename it", known: ["482913"])
        XCTAssertFalse(out.contains("482"), out)
    }

    func testShieldNeverStreamsACode() {
        let shield = AnswerShield(asked: "what does the text say?")
        var shown = ""
        for token in ["Your", " code", " is", " 48", "39", "20", ". Use", " it soon."] {
            shown += shield.next(token)
        }
        XCTAssertEqual(shown, "Your code is ", "the stream stops at the first possible code")
        XCTAssertTrue(shield.isHolding)
        XCTAssertEqual(shield.finish("Your code is 483920. Use it soon."), "Your code is \(mask). Use it soon.")
    }

    func testShieldStreamsAnswersWithoutLongNumbers() {
        let shield = AnswerShield(asked: "what is it?")
        var shown = ""
        for token in ["A", " red", " door", " with", " 2", " cats."] { shown += shield.next(token) }
        XCTAssertEqual(shown, "A red door with 2 cats.")
        XCTAssertFalse(shield.isHolding)
    }

    // MARK: Screens

    func testScreenLikeDetection() {
        XCTAssertTrue(ScreenSecrets.isScreenLike(width: 1179, height: 2556, properties: [:]), "a phone screenshot's shape")
        let screenshot: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Screenshot"]]
        XCTAssertTrue(ScreenSecrets.isScreenLike(width: 1000, height: 1000, properties: screenshot))
        let camera: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple"]]
        XCTAssertFalse(ScreenSecrets.isScreenLike(width: 1179, height: 2556, properties: camera), "a camera photo")
        XCTAssertFalse(ScreenSecrets.isScreenLike(width: 1000, height: 1000, properties: [:]))
    }

    func testScreenCodeIsBlackedOutBeforeAnyModelSeesIt() throws {
        let screen = try Self.render(["Messages", "Your code is 483920", "Do not share it"], width: 600, height: 1300)
        XCTAssertTrue(TextRecognizer.recognizeText(in: screen).contains("483920"), "the fixture must be readable")

        let result = ScreenSecrets.mask(screen)
        XCTAssertGreaterThan(result.masked, 0)
        XCTAssertTrue(result.codes.contains { $0.contains("483920") }, "\(result.codes)")
        let after = TextRecognizer.recognizeText(in: result.image)
        XCTAssertFalse(after.contains("483920"), "the code must not be readable: \(after)")
        XCTAssertTrue(after.localizedCaseInsensitiveContains("share"), "the rest of the screen stays: \(after)")
    }

    func testScreenCardNumberAndPasswordAreBlackedOut() throws {
        let screen = try Self.render(["Wallet", "4242 4242 4242 4242", "password: Xk9#mP2qL"], width: 600, height: 1300)
        let after = TextRecognizer.recognizeText(in: ScreenSecrets.mask(screen).image)
        XCTAssertFalse(after.replacingOccurrences(of: " ", with: "").contains("4242424242424242"), after)
        XCTAssertFalse(after.contains("Xk9"), after)
    }

    func testPreparedScreenshotIsMaskedAndSmall() throws {
        let screen = try Self.render(["Bank", "Your code is 483920"], width: 1179, height: 2556, fontSize: 90)
        let prepared = try XCTUnwrap(PhotoPreparation.prepare(Self.png(screen)))
        let image = try XCTUnwrap(PhotoPreparation.cgImage(prepared.data))
        XCTAssertLessThanOrEqual(max(image.width, image.height), PhotoPreparation.maxSide)
        XCTAssertFalse(TextRecognizer.recognizeText(in: image).contains("483920"))
        XCTAssertGreaterThan(prepared.masked, 0)
    }

    func testAPhotoIsNotMaskedButIsCutToSize() throws {
        // A 4:3 picture with camera metadata: the model may read it (ADR-082).
        let photo = try Self.render(["Your code is 483920"], width: 2000, height: 1500, fontSize: 120)
        let data = try Self.png(photo, properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple"]])
        let prepared = try XCTUnwrap(PhotoPreparation.prepare(data))
        XCTAssertEqual(prepared.masked, 0)
        let image = try XCTUnwrap(PhotoPreparation.cgImage(prepared.data))
        XCTAssertEqual(max(image.width, image.height), PhotoPreparation.maxSide)
    }

    // MARK: Fixtures

    static func render(_ lines: [String], width: Int, height: Int, fontSize: CGFloat = 44) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("No bitmap context here.")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        var y = CGFloat(height) - fontSize * 3
        for text in lines {
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!)
            ctx.textPosition = CGPoint(x: 30, y: y)
            CTLineDraw(line, ctx)
            y -= fontSize * 2.2
        }
        guard let image = ctx.makeImage() else { throw XCTSkip("Couldn't render.") }
        return image
    }

    static func png(_ image: CGImage, properties: [CFString: Any] = [:]) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else {
            throw XCTSkip("No PNG encoder here.")
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("Couldn't encode.") }
        return out as Data
    }
}

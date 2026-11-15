import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import Anu

/// Anu Keyboard's pure parts (Android ADR-109, ADR-149): layouts, shift,
/// field rules, and reading/writing the field.
final class KeyboardLogicTests: XCTestCase {

    // MARK: Layout

    func testQwertyRowsAndBottomRow() {
        let rows = KeyboardLayout.rows(.letters, shift: .off)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].map { if case .text(let t, _) = $0 { return t } else { return "?" } }.joined(), "qwertyuiop")
        XCTAssertEqual(rows[1].first, .gap())
        XCTAssertEqual(rows[2].first, .shift())
        XCTAssertEqual(rows[2].last, .backspace())
        XCTAssertEqual(rows[3], [.page(.symbols, label: "123"), .globe(), .space(), .enter()])
    }

    func testShiftUppercasesLettersAndGlobeIsOptional() {
        let rows = KeyboardLayout.rows(.letters, shift: .once, globe: false)
        XCTAssertEqual(rows[0].first, .text("Q"))
        XCTAssertFalse(rows[3].contains(.globe()))
    }

    func testSymbolPagesLinkToEachOtherAndBack() {
        let symbols = KeyboardLayout.rows(.symbols, shift: .off)
        XCTAssertEqual(symbols[0].count, 10)
        XCTAssertEqual(symbols[2].first, .page(.more, label: "#+="))
        XCTAssertEqual(symbols[3].first, .page(.letters, label: "ABC"))
        let more = KeyboardLayout.rows(.more, shift: .off)
        XCTAssertEqual(more[2].first, .page(.symbols, label: "123"))
    }

    func testPadsForNumbersAndPhones() {
        let number = KeyboardLayout.pad(.numbers)
        XCTAssertEqual(number[0], [.text("1"), .text("2"), .text("3"), .text("-")])
        XCTAssertEqual(number[3], [.globe(), .text("."), .text("0"), .enter(weight: 1)])
        let phone = KeyboardLayout.pad(.phone, globe: false)
        XCTAssertEqual(phone[0].last, .text("+"))
        XCTAssertEqual(phone[3], [.text("#"), .text("0"), .enter(weight: 1)])
        XCTAssertTrue(KeyboardLayout.usesPad(.phone))
        XCTAssertFalse(KeyboardLayout.usesPad(.symbolsFirst))
        XCTAssertEqual(KeyboardLayout.startPage(.symbolsFirst), .symbols)
    }

    func testRowWeightsFillEvenly() {
        // Every letter row is ten key-widths, so keys line up.
        for row in KeyboardLayout.rows(.letters, shift: .off).prefix(3) {
            XCTAssertEqual(row.reduce(0) { $0 + $1.weight }, 10, accuracy: 0.001)
        }
    }

    // MARK: Shift

    func testShiftTapDoubleTapAndRelease() {
        XCTAssertEqual(ShiftRules.tap(.off, sinceLastTap: 5), .once)
        XCTAssertEqual(ShiftRules.tap(.once, sinceLastTap: 0.2), .locked)
        XCTAssertEqual(ShiftRules.tap(.once, sinceLastTap: 1), .off)
        XCTAssertEqual(ShiftRules.tap(.locked, sinceLastTap: 0.1), .off)
        XCTAssertEqual(ShiftRules.afterText(.once), .off)
        XCTAssertEqual(ShiftRules.afterText(.locked), .locked)
        XCTAssertEqual(ShiftRules.auto(.locked, capsNow: false), .locked)
        XCTAssertEqual(ShiftRules.auto(.off, capsNow: true), .once)
        XCTAssertEqual(ShiftRules.auto(.once, capsNow: false), .off)
    }

    func testSentenceAndWordStarts() {
        XCTAssertTrue(ShiftRules.sentenceStart(nil))
        XCTAssertTrue(ShiftRules.sentenceStart(""))
        XCTAssertTrue(ShiftRules.sentenceStart("Done. "))
        XCTAssertTrue(ShiftRules.sentenceStart("Really?  "))
        XCTAssertTrue(ShiftRules.sentenceStart("line\n"))
        XCTAssertFalse(ShiftRules.sentenceStart("Done."))
        XCTAssertFalse(ShiftRules.sentenceStart("hello "))
        XCTAssertTrue(ShiftRules.wordStart("new "))
        XCTAssertFalse(ShiftRules.wordStart("new"))
    }

    // MARK: Field policy

    private typealias K = FieldTraits.KeyboardType
    private typealias R = FieldTraits.ReturnKey

    func testPlainFieldGetsLettersAndAI() {
        let p = FieldPolicy.of(FieldTraits())
        XCTAssertEqual(p.layout, .letters)
        XCTAssertTrue(p.ai)
        XCTAssertFalse(p.isPrivate)
        XCTAssertFalse(p.chat)
        XCTAssertEqual(p.autoCaps, .sentences)
        XCTAssertEqual(p.enter, .newline)
        XCTAssertNil(p.stripNote)
    }

    func testSecureAndCredentialFieldsArePrivate() {
        for traits in [FieldTraits(isSecureTextEntry: true),
                       FieldTraits(textContentType: "password"),
                       FieldTraits(textContentType: "new-password"),
                       FieldTraits(textContentType: "one-time-code"),
                       FieldTraits(textContentType: "cc-number")] {
            let p = FieldPolicy.of(traits)
            XCTAssertTrue(p.isPrivate, "\(traits)")
            XCTAssertFalse(p.ai)
            XCTAssertEqual(p.autoCaps, .none, "a private field isn't read, not even for capitals")
            XCTAssertEqual(p.stripNote, "Private field. Anu reads nothing here.")
            XCTAssertFalse(p.wantsCapital(before: "Hi. "))
        }
    }

    func testPadsGetNoAI() {
        XCTAssertEqual(FieldPolicy.of(FieldTraits(keyboardType: K.numberPad)).layout, .numbers)
        XCTAssertEqual(FieldPolicy.of(FieldTraits(keyboardType: K.decimalPad)).layout, .numbers)
        XCTAssertEqual(FieldPolicy.of(FieldTraits(keyboardType: K.asciiCapableNumberPad)).layout, .numbers)
        XCTAssertEqual(FieldPolicy.of(FieldTraits(keyboardType: K.phonePad)).layout, .phone)
        XCTAssertEqual(FieldPolicy.of(FieldTraits(textContentType: "tel")).layout, .phone)
        XCTAssertEqual(FieldPolicy.of(FieldTraits(keyboardType: K.numbersAndPunctuation)).layout, .symbolsFirst)
        for traits in [FieldTraits(keyboardType: K.numberPad), FieldTraits(keyboardType: K.phonePad),
                       FieldTraits(keyboardType: K.numbersAndPunctuation), FieldTraits(textContentType: "postal-code")] {
            let p = FieldPolicy.of(traits)
            XCTAssertFalse(p.ai, "\(traits)")
            XCTAssertFalse(p.isPrivate)
            XCTAssertEqual(p.stripNote, "No AI in number fields.")
        }
    }

    func testEmailLinkAndSearchFieldsKeepAI() {
        for type in [K.emailAddress, K.url, K.webSearch, K.twitter, K.asciiCapable] {
            XCTAssertTrue(FieldPolicy.of(FieldTraits(keyboardType: type)).ai, "type \(type)")
        }
    }

    func testReturnKeyAndChat() {
        XCTAssertEqual(FieldPolicy.of(FieldTraits(returnKeyType: R.search)).enter, .search)
        XCTAssertEqual(FieldPolicy.of(FieldTraits(returnKeyType: R.google)).enter, .search)
        XCTAssertEqual(FieldPolicy.of(FieldTraits(returnKeyType: R.go)).enter, .go)
        XCTAssertEqual(FieldPolicy.of(FieldTraits(returnKeyType: R.done)).enter, .done)
        let chat = FieldPolicy.of(FieldTraits(returnKeyType: R.send))
        XCTAssertEqual(chat.enter, .send)
        XCTAssertTrue(chat.chat)
        XCTAssertTrue(chat.enter.isAction)
        XCTAssertFalse(FieldPolicy.of(FieldTraits(returnKeyType: R.send, isSecureTextEntry: true)).chat)
        XCTAssertEqual(KeyboardAction.strip(chat: true).first, .reply)
        XCTAssertFalse(KeyboardAction.strip(chat: false).contains(.reply))
        XCTAssertEqual(KeyboardAction.strip(chat: false).prefix(3), [.proofread, .expand, .emoji])
    }

    func testCapsModes() {
        XCTAssertEqual(FieldPolicy.of(FieldTraits(autocapitalization: 0)).autoCaps, .none)
        XCTAssertTrue(FieldPolicy.of(FieldTraits(autocapitalization: 3)).wantsCapital(before: "abc"))
        let words = FieldPolicy.of(FieldTraits(autocapitalization: 1))
        XCTAssertTrue(words.wantsCapital(before: "Jane "))
        XCTAssertFalse(words.wantsCapital(before: "Ja"))
    }

    #if canImport(UIKit)
    /// The raw values the pure policy uses are UIKit's own.
    func testRawValuesMatchUIKit() {
        XCTAssertEqual(K.numberPad, UIKeyboardType.numberPad.rawValue)
        XCTAssertEqual(K.phonePad, UIKeyboardType.phonePad.rawValue)
        XCTAssertEqual(K.decimalPad, UIKeyboardType.decimalPad.rawValue)
        XCTAssertEqual(K.numbersAndPunctuation, UIKeyboardType.numbersAndPunctuation.rawValue)
        XCTAssertEqual(K.asciiCapableNumberPad, UIKeyboardType.asciiCapableNumberPad.rawValue)
        XCTAssertEqual(K.emailAddress, UIKeyboardType.emailAddress.rawValue)
        XCTAssertEqual(K.webSearch, UIKeyboardType.webSearch.rawValue)
        XCTAssertEqual(R.send, UIReturnKeyType.send.rawValue)
        XCTAssertEqual(R.search, UIReturnKeyType.search.rawValue)
        XCTAssertEqual(R.continue, UIReturnKeyType.continue.rawValue)
        XCTAssertEqual(FieldTraits.Autocapitalization.sentences, UITextAutocapitalizationType.sentences.rawValue)
        XCTAssertEqual(FieldTraits.Autocapitalization.allCharacters, UITextAutocapitalizationType.allCharacters.rawValue)
        let privateTypes: [UITextContentType] = [.password, .newPassword, .oneTimeCode, .creditCardNumber,
                                                 .creditCardSecurityCode, .creditCardExpiration,
                                                 .creditCardExpirationMonth, .creditCardExpirationYear,
                                                 .creditCardName, .creditCardGivenName, .creditCardMiddleName,
                                                 .creditCardFamilyName, .creditCardType]
        for type in privateTypes {
            XCTAssertTrue(FieldTraits.privateContentTypes.contains(type.rawValue), type.rawValue)
        }
        XCTAssertEqual(UITextContentType.telephoneNumber.rawValue, "tel")
        XCTAssertEqual(UITextContentType.postalCode.rawValue, "postal-code")
    }
    #endif

    // MARK: Reading and writing the field

    func testRewriteUsesSelectionElseTextBefore() {
        XCTAssertEqual(KeyboardText.forRewrite(FieldText(before: "abc", selected: " sel ")),
                       EditPlan(mode: .replaceSelection, source: " sel ", input: "sel"))
        XCTAssertEqual(KeyboardText.forRewrite(FieldText(before: "hello wrld ")),
                       EditPlan(mode: .replaceBefore, source: "hello wrld ", input: "hello wrld"))
        XCTAssertNil(KeyboardText.forRewrite(FieldText(before: "  ")))
        XCTAssertNil(KeyboardText.forRewrite(FieldText(before: nil, selected: nil)))
    }

    func testTailCutsALongReadAtASentence() {
        // 2,202 characters: the read keeps the last 2,000 (98 a's, ". ", 1,900
        // b's) and cuts at the sentence break inside its first 400.
        let long = String(repeating: "a", count: 300) + ". " + String(repeating: "b", count: 1_900)
        XCTAssertEqual(KeyboardText.tail(long), " " + String(repeating: "b", count: 1_900))
        // No break near the start: the whole read is kept.
        let unbroken = String(repeating: "c", count: 2_500)
        XCTAssertEqual(KeyboardText.tail(unbroken).count, 2_000)
        XCTAssertEqual(KeyboardText.tail("short. text"), "short. text")
    }

    func testContinueInsertsAndKeepsSelection() {
        XCTAssertEqual(KeyboardText.forContinue(FieldText(before: "I went"))?.mode, .insert)
        let keep = KeyboardText.forContinue(FieldText(before: "", selected: "Hi"))
        XCTAssertEqual(keep?.keep, true)
        XCTAssertEqual(KeyboardText.output(keep!, result: "there."), "Hi there.")
        XCTAssertEqual(KeyboardText.forReply(FieldText(before: "")), EditPlan(mode: .insert, source: "", input: ""))
    }

    func testOutputKeepsSpacesAndJoinsWithASpace() {
        let replace = EditPlan(mode: .replaceBefore, source: "  teh cat ", input: "teh cat")
        XCTAssertEqual(KeyboardText.output(replace, result: "The cat"), "  The cat ")
        XCTAssertEqual(KeyboardText.edit(replace, result: "The cat"), KeyboardEdit(deleteBefore: 10, insert: "  The cat "))
        let insert = EditPlan(mode: .insert, source: "I went", input: "I went")
        XCTAssertEqual(KeyboardText.edit(insert, result: "home."), KeyboardEdit(deleteBefore: 0, insert: " home."))
        XCTAssertEqual(KeyboardText.join("word", ", then"), ", then")
        XCTAssertEqual(KeyboardText.join("word ", "next"), "next")
        XCTAssertEqual(KeyboardText.join("", "first"), "first")
        let sel = EditPlan(mode: .replaceSelection, source: "x", input: "x")
        XCTAssertEqual(KeyboardText.edit(sel, result: "y"), KeyboardEdit(deleteBefore: 0, insert: "y"))
    }

    func testDeleteCountIsInCharactersNotUTF16() {
        let plan = EditPlan(mode: .replaceBefore, source: "hi 👍🏽🇮🇳", input: "hi 👍🏽🇮🇳")
        XCTAssertEqual(KeyboardText.edit(plan, result: "x").deleteBefore, 5)
    }

    func testStillThereChecksTheFieldAsItIsNow() {
        let before = EditPlan(mode: .replaceBefore, source: "teh cat", input: "teh cat")
        XCTAssertTrue(KeyboardText.stillThere(before, now: FieldText(before: "Hello teh cat")))
        XCTAssertFalse(KeyboardText.stillThere(before, now: FieldText(before: "teh cat sat")))
        XCTAssertFalse(KeyboardText.stillThere(before, now: FieldText(before: "teh cat", selected: "x")))
        let sel = EditPlan(mode: .replaceSelection, source: "abc", input: "abc")
        XCTAssertTrue(KeyboardText.stillThere(sel, now: FieldText(before: "", selected: "abc")))
        XCTAssertFalse(KeyboardText.stillThere(sel, now: FieldText(before: "abc")))
    }

    func testWithoutEcho() {
        XCTAssertEqual(KeyboardText.withoutEcho(input: "I went", result: "I went home."), "home.")
        XCTAssertEqual(KeyboardText.withoutEcho(input: "I went", result: " Then home."), "Then home.")
    }

    func testEmojiAreKeptWholeSplitAndDeduplicated() {
        XCTAssertEqual(KeyboardText.emoji("🎂🎉🥳 🎉, 👍🏽 | 🇮🇳 👨‍👩‍👧 party ❤️", max: 6),
                       ["🎂", "🎉", "🥳", "👍🏽", "🇮🇳", "👨‍👩‍👧"])
        XCTAssertEqual(KeyboardText.emoji("Here you go: 😀 😃.", max: 6), ["😀", "😃"])
        XCTAssertEqual(KeyboardText.emoji("no emoji here 123", max: 6), [])
        XCTAssertEqual(KeyboardText.emoji("❤️", max: 6), ["❤️"])
        XCTAssertFalse(KeyboardText.isEmoji("a😀"))
    }

    func testAskEditTypesDeletesWholeCharactersAndCaps() {
        XCTAssertEqual(KeyboardText.askEdit("ab", typed: "c"), "abc")
        XCTAssertEqual(KeyboardText.askEdit("a👍🏽", typed: nil), "a")
        XCTAssertEqual(KeyboardText.askEdit("", typed: nil), "")
        XCTAssertEqual(KeyboardText.askEdit(String(repeating: "a", count: 300), typed: "b").count, 300)
    }

    func testPlanMetaRoundTrip() {
        let plan = EditPlan(mode: .insert, source: " text", input: "text", keep: true)
        XCTAssertEqual(EditPlan.from(meta: plan.meta, original: " text"), plan)
        XCTAssertNil(EditPlan.from(meta: [:], original: "x"))
    }
}

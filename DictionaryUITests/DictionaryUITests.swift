import XCTest

/// End-to-end runs through the features that span the app, the network and
/// the on-device databases: browsing A to Z, downloading a dictionary and
/// browsing it, multi-dictionary flashcards, and pronunciation.
///
/// Run with a freshly installed app (`xcrun simctl uninstall booted
/// com.igaurab.Dictionary`), since one test downloads the Nepali dictionary
/// and expects it not to be there yet.
final class DictionaryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: - English

    func test1BrowseEnglishAndPronounce() {
        openMenuItem("Browse")
        // Browse remembers the last dictionary; start from English.
        let picker = app.buttons["Dictionary"]
        if picker.waitForExistence(timeout: 2) {
            picker.tap()
            app.buttons["WordNet 3.1"].tap()
        }

        let table = app.tables["browse.table"]
        XCTAssertTrue(table.waitForExistence(timeout: 30), "browse list never appeared")
        XCTAssertTrue(table.cells.firstMatch.waitForExistence(timeout: 5))
        snap("browse-english-top")

        // The letter index: jump to M the way a thumb would, then check the
        // rows on screen really are M words.
        jump(in: table, toIndexTitle: "M", of: letters("# A B C D E F G H I J K L M N O P Q R S T U V W X Y Z"))
        let visible = table.cells.allElementsBoundByIndex.prefix(6).compactMap { $0.staticTexts.firstMatch.label.first }
        XCTAssertTrue(visible.allSatisfy { $0 == "m" || $0 == "M" }, "index jump landed on \(visible)")
        snap("browse-english-M")

        let cell = table.cells.element(boundBy: 2)
        let word = cell.staticTexts.firstMatch.label
        cell.tap()

        // The main window pushes the same entry behind the sheet, so pick the
        // button the reader can actually reach.
        XCTAssertTrue(app.buttons["entry.pronounce"].firstMatch.waitForExistence(timeout: 10),
                      "entry for \(word) has no pronounce button")
        guard let pronounce = app.buttons.matching(identifier: "entry.pronounce")
            .allElementsBoundByIndex.first(where: \.isHittable) else {
            return XCTFail("pronounce button is not on screen")
        }
        XCTAssertTrue(app.navigationBars[word].exists || app.staticTexts[word].exists)
        pronounce.tap()
        snap("entry-pronounce")

        // Back to the list keeps the place.
        tapBack()
        XCTAssertTrue(table.cells.staticTexts[word].waitForExistence(timeout: 5))
    }

    func test2PronunciationSettings() {
        app.buttons["Settings"].tap()
        let sample = app.buttons["Play Sample"]
        scrollTo(sample)
        XCTAssertTrue(sample.exists)
        XCTAssertTrue(app.buttons["Voice"].exists || app.staticTexts["Voice"].exists)
        sample.tap()
        snap("settings-pronunciation")
        app.buttons["Done"].firstMatch.tap()
    }

    // MARK: - Nepali

    func test3DownloadNepaliThenBrowseAndFlashcards() {
        app.buttons["Settings"].tap()
        let dictionaries = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dictionaries'")).firstMatch
        scrollTo(dictionaries)
        dictionaries.tap()

        let download = app.buttons["download.ne-sabdakosh"]
        let installed = app.staticTexts["installed.ne-sabdakosh"]
        if !installed.exists {
            scrollTo(download)
            download.tap()
            XCTAssertTrue(installed.waitForExistence(timeout: 180), "Nepali never finished downloading")
        }
        snap("dictionaries-nepali-installed")
        app.buttons["Done"].firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()

        // Browse Nepali: first visit builds the word list.
        openMenuItem("Browse")
        app.buttons["Dictionary"].tap()
        app.buttons["नेपाली बृहत् शब्दकोश"].tap()
        let table = app.tables["browse.table"]
        let first = table.cells.staticTexts["अ"]
        XCTAssertTrue(first.waitForExistence(timeout: 60), "Nepali list did not start at अ")
        snap("browse-nepali-top")

        jump(in: table, toIndexTitle: "क", of: letters("अ आ इ ई उ ऊ ऋ ए ऐ ओ औ क ख ग घ ङ च छ ज झ ञ ट ठ ड ढ ण त थ द ध न प फ ब भ म य र ल व श ष स ह ॐ"))
        let label = table.cells.element(boundBy: 1).staticTexts.firstMatch.label
        // By scalar: "कँ" is one character, so hasPrefix("क") would say no.
        XCTAssertEqual(label.unicodeScalars.first, "क", "index jump landed on \(label)")
        snap("browse-nepali-ka")

        table.cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["नेपाली बृहत् शब्दकोश".uppercased()].waitForExistence(timeout: 10),
                      "Nepali entry did not open on the Nepali definition")
        snap("entry-nepali")
        tapBack()
        app.buttons["Done"].firstMatch.tap()

        // Random flashcards drawn from English and Nepali together.
        openMenuItem("Random Flashcards")
        let nepaliChip = app.buttons["flashcards.dictionary.नेपाली"]
        XCTAssertTrue(nepaliChip.waitForExistence(timeout: 10), "no dictionary chips")
        if !nepaliChip.isSelected { nepaliChip.tap() }
        let counter = app.staticTexts["1 of 20"]
        XCTAssertTrue(counter.waitForExistence(timeout: 30), "mixed deck did not deal 20 cards")
        snap("flashcards-mixed-front")

        // Only Nepali: every card should be labelled and in Devanagari.
        let englishChip = app.buttons["flashcards.dictionary.English"]
        if englishChip.isSelected { englishChip.tap() }
        XCTAssertTrue(counter.waitForExistence(timeout: 30))
        let front = app.staticTexts.allElementsBoundByIndex.map(\.label)
            .first { $0.unicodeScalars.first.map { (0x0900...0x097F).contains($0.value) } == true }
        XCTAssertNotNil(front, "Nepali-only deck shows no Devanagari word")
        snap("flashcards-nepali-front")
        app.otherElements.containing(.staticText, identifier: front ?? "").firstMatch.tap()
        snap("flashcards-nepali-back")

        // Leave English selected for the next run.
        englishChip.tap()
    }

    // MARK: - Helpers

    /// The back chevron that is on screen: with a sheet up, the main window's
    /// stack sits behind it with its own.
    private func tapBack() {
        let back = app.navigationBars.buttons.matching(identifier: "BackButton")
            .allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(back, "no back button on screen")
        back?.tap()
    }

    /// Closing a sheet that looked a word up leaves that entry open in the
    /// main window, as it would after a search; step back to the home page.
    private func openMenuItem(_ title: String) {
        var tries = 0
        while !app.buttons["More"].isHittable && tries < 3 {
            tapBack()
            tries += 1
        }
        app.buttons["More"].tap()
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "menu has no \(title)")
        item.tap()
    }

    private func letters(_ spaced: String) -> [String] {
        spaced.split(separator: " ").map(String.init)
    }

    /// Taps the letter index at `title`, then checks the first row on screen
    /// and nudges up or down a letter until it matches, since UIKit centres
    /// the titles at a spacing the test can only estimate.
    private func jump(in table: XCUIElement, toIndexTitle title: String, of titles: [String]) {
        guard let target = titles.firstIndex(of: title) else { return XCTFail("no \(title)") }
        let index = table.otherElements["Section index"]
        XCTAssertTrue(index.exists, "no section index")
        let step: CGFloat = 13.33
        var slot = CGFloat(target)
        for _ in 0..<6 {
            let y = index.frame.midY + (slot - CGFloat(titles.count - 1) / 2) * step
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: index.frame.midX, dy: y)).tap()
            let header = table.otherElements.allElementsBoundByIndex.first {
                titles.contains($0.label)
            }?.label
            guard let header, let landed = titles.firstIndex(of: header) else { return }
            if landed == target { return }
            slot += CGFloat(target - landed)
        }
    }

    private func scrollTo(_ element: XCUIElement) {
        var swipes = 0
        while !element.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent(name + ".png"))
        }
    }
}

import XCTest

/// シミュレーターでアプリを通しで操作する。
/// 「宏伸のAirPods Pro」がBluetoothでつながっていて音量10/16、マイクの代わりに合成した録音（ふつうの部屋40dB）を使う。
final class OtomoreMeterUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    private func launch(volume: String, reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "OTOMORE_MOCK_VOLUME": volume,
            "OTOMORE_MOCK_ROUTE": "宏伸のAirPods Pro",
            "OTOMORE_MOCK_ROUTE_KIND": "bluetooth",
            "OTOMORE_MOCK_MIC": "1",
            "OTOMORE_MOCK_SCENE": "room",
            "OTOMORE_RESET": reset ? "1" : "0"
        ]
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func any(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func button(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func scrollTo(_ app: XCUIApplication, _ el: XCUIElement, up: Bool = true) {
        for _ in 0..<10 {
            if el.exists && el.isHittable { return }
            if up { app.swipeUp() } else { app.swipeDown() }
        }
    }

    func testFullFlow() {
        let app = launch(volume: "0.625", reset: true)

        // 1. メイン画面：イヤホン名・種類の自動判定・音量
        XCTAssertTrue(any(app, "宏伸のAirPods Pro").waitForExistence(timeout: 15), "イヤホン名が表示されない")
        XCTAssertTrue(any(app, "カナル型").exists, "AirPods Pro がカナル型と判定されていない")
        XCTAssertTrue(app.staticTexts["10"].exists, "音量 10/16 が表示されない")
        XCTAssertTrue(any(app, "イヤホンの名前から自動で判定しました").exists)
        shot(app, "01_メイン画面")

        // 2. 判定と場面の物差し
        app.swipeUp()
        shot(app, "02_判定")
        let shinRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "新幹線（走行中）")).firstMatch
        scrollTo(app, shinRow)
        shot(app, "03_場面の物差し")
        XCTAssertTrue(shinRow.exists, "新幹線（走行中）の行がない")

        // 3. 内訳（帯域ごとのグラフ）
        shinRow.tap()
        XCTAssertTrue(any(app, "帯域ごとの内訳").waitForExistence(timeout: 5), "内訳画面が開かない")
        XCTAssertTrue(any(app, "いちばん目立つのは").exists)
        shot(app, "04_内訳_新幹線走行中")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 4. 実測（合成録音）
        let measure = button(app, "iPhoneを耳の横に当てて実測する")
        scrollTo(app, measure, up: false)
        XCTAssertTrue(measure.exists, "実測ボタンがない")
        measure.tap()
        let start = button(app, "測定をはじめる")
        XCTAssertTrue(start.waitForExistence(timeout: 5), "測定画面が開かない")
        shot(app, "05_測定画面")
        start.tap()
        XCTAssertTrue(any(app, "周りの音を測っています").waitForExistence(timeout: 8), "周りの音の測定に進まない")
        shot(app, "06_測定中")
        XCTAssertTrue(any(app, "測定が終わりました").waitForExistence(timeout: 30), "測定が終わらない")
        shot(app, "07_測定完了")
        button(app, "閉じる").tap()

        // 5. 実測が反映された画面
        let here = any(app, "測った場所で、隣に人がいたら")
        scrollTo(app, here)
        XCTAssertTrue(here.exists, "測った場所での判定が出ない")
        XCTAssertTrue(any(app, "判定（実測をもとに計算）").exists || any(app, "実測を使う").exists)
        shot(app, "08_実測後")
        app.terminate()

        // 6. 音量を6/16にして起動し直す：保存した実測が、いまの音量に換算されて残っているか
        let app2 = launch(volume: "0.375", reset: false)
        XCTAssertTrue(any(app2, "宏伸のAirPods Pro").waitForExistence(timeout: 15))
        XCTAssertTrue(app2.staticTexts["6"].exists, "音量 6/16 が表示されない")
        shot(app2, "09_音量6_起動直後")
        let here2 = any(app2, "測った場所で、隣に人がいたら")
        scrollTo(app2, here2)
        XCTAssertTrue(here2.exists, "保存した実測が残っていない")
        shot(app2, "10_音量6_実測の換算")
    }
}

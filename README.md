# 音漏れメーター（iPhoneアプリ）

イヤホンの音が隣の人にどれくらい聞こえているかを、新幹線・図書館・カフェなど場面ごとに判定するiPhoneアプリです。

- iPhoneの音量（16段階）を自動で読み取り、音量ボタンを押すとその場で判定が変わります
- 接続中のイヤホンの名前から種類を判定します（AirPods Pro → カナル型 など）
- iPhone本体のマイクを耳の横に当てて10秒で実測できます。AirPodsは高音質のまま鳴らし、マイクはiPhoneのものを使います

## インストール（SideStore）

1. iPhoneのSafariで、このリポジトリの Releases から最新の `OtomoreMeter.ipa` を開いてダウンロードする
2. LocalDevVPN で Connect してから SideStore を開く
3. 「My Apps」→ 左上の「＋」→ ダウンロードした `OtomoreMeter.ipa` を選ぶ

最新版はいつでも `releases/latest/download/OtomoreMeter.ipa` から落とせます。

ヘルスケアの「ヘッドフォン音量」も読みたいときは、代わりに `OtomoreMeter-health.ipa` を入れてみてください。ヘルスケアの許可を付けた版です。無料のApple IDでは入らないことがあるので、そのときは通常版を使ってください（ヘルスケアの欄以外は同じです）。

## ビルド

`main` に push すると GitHub Actions が署名なしの IPA を作り、Release に置きます（Macは不要）。
同じワークフローで、計算モデルをWeb版と同じ入力で実行した結果（`modelcheck.txt`）も出力します。

- プロジェクト生成: XcodeGen（`project.yml`）
- 対応: iOS 16以降、iPhone

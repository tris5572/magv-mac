# magv macOS native

SwiftUI＋AppKitによる漫画ビューワーの段階的な移植。現在は**形式検証・閲覧の核・日常操作・補助機能**を実装した開発版です。仕様全体の移植完了ではありません。

macOS 26以降・Apple Siliconを暫定のビルド対象としています。Xcodeで `magv-mac.xcodeproj` の `magv-mac` スキームを実行してください。既存アプリとは別のBundle ID `dev.tris.magv-native` を使用します。

現在できること:

- ZIP／RAR、対応画像、画像フォルダを開く。⌘O、ウィンドウへのドロップ、外部オープンの入口を実装。
- 自然順、直接指定画像からの開始、内部フォルダ、AppleDouble／__MACOSX除外。
- アーカイブは一覧を先に取得し、表示ページだけを展開。展開ファイルをページ単位で解放し、全件の展開量がキャッシュ上限を超える本も読み進められる。
- 単体／自動見開き、右／左開き、向き補正、ページ移動、クリック／ドラッグできるページバー。
- 方向に応じた左右キー、Shift／⌘付き左右キー、Home／End、Space／Shift+Space。
- ホイールの抑制、右クリックの移動メニュー、上端ホバーの表示切替。
- 読み込みキャンセル、最新要求のみの反映、エラー時の現在ソース維持。
- 起動中の閲覧位置・最近使った20件、↑↓と`r`による兄弟ソース切替。
- アーカイブの名前変更、先頭への`!`追加、名前のWeb検索（`f`）。名前変更は拡張子を保ち、競合時は`_`を追加する。
- 親フォルダ／画像フォルダへの権限選択。名前変更シートは日本語変換確定のReturnを送信と区別する。
- 表示モード・方向とウィンドウ位置／サイズを専用JSONへ保存。モニター変更時は表示可能範囲へ補正。
- スライドショー（初期5秒、0.5〜100,000秒を0.5秒刻み）。末尾・画像エラー・ソース切替・名前変更・閉じる操作で停止する。
- 中クリック／表示メニューのルーペ（600×600pt、表示画像の8倍）。必要に応じて高解像度の画像を取得する。
- 前後の画像と許可済みの隣接ソースの先読み、同時読み込みの共有、外部更新時のキャッシュ失効。
- Image I/Oでの縮小デコード、総量256MiBの画像キャッシュ（ルーペはその内64MiBまで）、全体2GiBの一時展開予算。
- メモリ圧迫時の先読み破棄と、専用キャッシュの通常終了時／異常終了後の清掃。

依存物はlibarchive 3.8.10の静的XCFrameworkを同梱。RAR5の一覧取得専用パッチを含み、再ビルド手順も保存しています。実行時のHomebrew、外部展開コマンド、WebView、JavaScript、WASMは不要です。初回ビルドにも外部Swiftパッケージのダウンロードはありません。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/test.sh

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project magv-mac.xcodeproj -scheme magv-mac -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

`test.sh` はコアのSwift Testingテストに加え、アプリ本体のReaderSession／InputRouterを使った非GUIスモークテストを実行します。`./scripts/test.sh --ui` では、画面セッションがあるMacで名前変更シートのAppKit入力・Return／変更ボタン・エラー後の再入力から実ファイルのリネームまでと、ページ移動中のキャンバスの描画維持をオフスクリーン画像比較で追加検証します。Xcodeアプリのビルドとは別に実行してください。

`./scripts/benchmark.sh` は合成PNG 100枚、`./scripts/benchmark.sh --large` は2000×3000px・300枚・500MiB未満の合成JPEGとZIPでコア処理時間を測定します。全件展開する従来相当の経路とも比較します。実データには `./scripts/benchmark.sh --compare /path/to/book.zip` を使用できます。UI描画を含む体感速度の測定とは別です。

第4段階の主要機能を実装し、52件のコアテストとセッションスモークを追加・実行しました。ルーペ／再生の実画面、トラックパッド・VoiceOver・日本語IME、RARの追加実ファイル、大容量時の速度・メモリ、署名・公証を含む配布検証は継続します。

- [仕様原文](docs/native-spec.md)
- [段階別計画・検証結果・制限](docs/implementation-plan.md)
- [同梱ライブラリの出典と再ビルド](Packages/MagvCore/Vendor/README.md)

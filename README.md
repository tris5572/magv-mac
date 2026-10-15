# magv macOS native

SwiftUI＋AppKitによる漫画ビューワーの段階的な移植。現在は**形式検証と閲覧の核**を実装した開発版です。仕様全体の移植完了ではありません。

macOS 26以降・Apple Siliconを暫定のビルド対象としています。Xcodeで `magv-mac.xcodeproj` の `magv-mac` スキームを実行してください。既存アプリとは別のBundle ID `dev.tris.magv-native` を使用します。

現在できること:

- ZIP／RAR、対応画像、画像フォルダを開く。⌘O、ウィンドウへのドロップ、外部オープンの入口を実装。
- 自然順、直接指定画像からの開始、内部フォルダ、AppleDouble／__MACOSX除外。
- 単体／自動見開き、右／左開き、向き補正、ページ移動、クリック／ドラッグできるページバー。
- 方向に応じた左右キー、Shift／⌘付き左右キー、Home／End、Space／Shift+Space。
- ホイールの抑制、右クリックの移動メニュー、上端ホバーの表示切替。
- 読み込みキャンセル、最新要求のみの反映、エラー時の現在ソース維持。
- 起動中の閲覧位置・最近使った20件、表示モード・方向の再起動後の保存。
- Image I/Oでの縮小デコード、256MiBの画像キャッシュ、展開量・画像寸法の制限。

依存物はlibarchive 3.8.10の静的XCFrameworkを同梱。実行時のHomebrew、外部展開コマンド、WebView、JavaScript、WASMは不要です。初回ビルドにも外部Swiftパッケージのダウンロードはありません。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/test.sh

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project magv-mac.xcodeproj -scheme magv-mac -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

`test.sh` はコアのSwift Testingテストに加え、アプリ本体のReaderSession／InputRouterを使った非GUIスモークテストを実行します。Xcodeアプリのビルドとは別に実行してください。

兄弟ソース切替、リネーム／!付与、名前検索、ウィンドウ復元、スライドショー、ルーペ、先読み、配布検証は次段階です。権限試作、RARの追加実ファイル検証、キャッシュの全体管理にも未完了項目があります。

- [仕様原文](docs/native-spec.md)
- [段階別計画・検証結果・制限](docs/implementation-plan.md)
- [同梱ライブラリの出典と再ビルド](Packages/MagvCore/Vendor/README.md)

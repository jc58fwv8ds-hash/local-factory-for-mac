# Harness Remote for iPhone

Harness自身が5回の制作サイクルで雛形から完成させた、Mac版Harnessへ自然言語の制作指示を送るSwiftUIアプリです。

## 使い方

1. Mac版Harnessで対象プロジェクトを選び、「リモート指示を許可」をオンにします。
2. iPhoneへMacに表示された6桁コードを入力し、「Harnessへ接続」を押します。
3. 「暗号化接続済み」を確認して制作指示を送り、受付結果を確認します。
4. 終了後はMac版Harnessのリモート受付をオフにします。

通信は同じローカルネットワーク上のMultipeer Connectivityを使い、暗号化を必須にしています。接続コードと制作指示は端末へ永続保存しません。指示は最大4,000文字、通信データは最大8KB、通信版は1です。

## 設計

- SwiftUIの`NavigationStack`と意味的なシステムカラーを使用
- ライト／ダーク外観とDynamic Typeへ追従
- 主要操作を44pt以上、主ボタンを50pt以上に設定
- 状態を色だけで区別せず、アイコン・見出し・説明を併用
- Mac版と共通のCenturion系App IconをAsset Catalogから配布
- 接続、指示入力、受付結果、プライバシー説明を責務別のカードに分離
- UI状態を`RemoteSession`、Multipeer通信を`RemoteClientTransport`、JSON境界を`RemoteProtocol`へ分離

## 検証済み環境

- Xcode 26.6 / iOS 26.5 Simulator
- iPhone 14 Pro Simulator
- Debug buildおよび8件のSwift Testingテスト
- ライト／ダーク外観の目視確認
- iPhoneからMac版Harnessへ日本語指示を送信し、受付結果をiPhoneへ返す実往復

テストはXcodeで共有scheme `HarnessRemote`を選択して実行できます。物理iPhoneへ入れる場合は、XcodeのSigning & Capabilitiesで自分のTeamと固有のBundle Identifierを設定してください。

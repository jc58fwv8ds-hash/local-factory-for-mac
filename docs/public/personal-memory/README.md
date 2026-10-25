# Personal Memory

Apple Watch で一日の出来事を録音し、iPhone を経由して Mac に渡し、**Mac の中のローカル AI** で「読み返せる一日の記憶」にまとめるアプリです。

- **利用料はかかりません。** 文字起こしは端末内の音声認識、要約は Mac のローカルモデル(Ollama)で行います。クラウドの AI や API キーは使いません。
- **日本語に対応しています。** 文字起こしは macOS の日本語の端末内認識を使います。
- **録音はあなたの端末と、あなたが選んだフォルダにだけ置かれます。** サーバーはありません。

## 構成

| 場所 | 中身 |
|---|---|
| `WatchMemory/` | Watch アプリ。録音、聴き直し、iPhone への送信 |
| `PersonalMemory/` | iPhone アプリ。Watch からの受信、聴き直し、Mac への受け渡し |
| `SharedAudio/` | iPhone と Watch で共通の録音一覧と再生 |
| `SessionDomain/` | 録音の区切りの記録と、受け渡し用のファイル形式(`.pmchunk`) |
| `CalendarAssistant/` | Mac アプリ「Personal Memory Calendar」。文字起こし、予定の候補、一日の記憶 |

## できること

- **Watch で録音**: 約 10 分ごとに区切って保存します。録音中も文字盤に戻れます。タイマーなどで中断されても、停止ボタンを押すまで自動で再開します。原本は Watch に残ります。
- **iPhone から Mac へ**: iPhone と Mac で同じフォルダ(例: iCloud Drive の「Personal Memory」)を一度選ぶと、Watch から届いた録音を iPhone がそのフォルダに置き、Mac のアプリが取り込みます。1 つの録音は 1 つの `.pmchunk` ファイル(情報と音声をまとめ、SHA-256 で検査)なので、同期の途中の半端な状態を取り込みません。同じ Wi‑Fi なら 6 桁の番号でつないで直接送ることもできます。
- **Mac で一日の記憶**: 日付を選んで「一日の記憶にまとめる」と、その日の録音をローカル AI が出来事ごとに要約し、時刻順に並べます。AI の答えは、引用が文字起こしにそのまま含まれるか、時刻があり得るかを検査し、合わないものは保存しません。要約は直せて、直した項目はまとめ直しても残ります。
- **Mac で予定の候補**: 録音から今後の予定を提案し、確認した 1 件ずつだけカレンダーに追加します。

## 必要なもの

- Xcode 26 以降、iOS 17 / watchOS 10 / macOS 14 以降
- Mac で AI を使う場合: [Ollama](https://ollama.com) と日本語に強いモデル(既定は Qwen3.8-27B の Q4_K_M。アプリの「ローカルAIの設定」で変えられます)

## ビルド

```sh
# 録音・受け渡しの部品の試験(Mac 上で動きます)
swift test

# Mac アプリ(Builds/ に .app を作ります)
cd CalendarAssistant && zsh build-app.sh
```

iPhone と Watch のアプリは `PersonalMemory.xcodeproj` を Xcode で開き、各ターゲットの Signing で自分の開発チームを選んでから実機に入れてください(バンドル ID も自分のものに変えてください)。Watch の裏での録音には実機が必要です。

## 作り方について

このアプリの部品の一部は、ローカルモデルで Swift のコードを作るアプリ [Local Factory for Mac](https://github.com/jc58fwv8ds-hash/local-factory-for-mac) で作りました。人が目的・試験・隠し試験を書き、Local Factory が実装し、人が検査して取り込んでいます(人が直した箇所は記録しています)。

## ライセンス

MIT

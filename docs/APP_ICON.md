# アプリアイコン(Local Factory for Mac)

## デザイン(2026-10-08 から: Local Factory)

グレー一色のドット絵の工場です。のこぎり形の三角屋根が 3 つ並び、右端の三角は長方形の煙突の手前に重なります。
窓はオレンジがかった黄色(`#FFB52E`、左上に明るい `#FFD978`)で 4 つ、煙は煙突から左上へ流れながら大きくなります。
背景は淡いオレンジのグラデーションで、枠は macOS の角の丸い正方形(824/1024)に合わせています。

- アプリ内のロゴは同じドット絵を `Sources/HarnessApp/Views/FactoryLogoView.swift` で描き、処理中は煙が動きます。
- アイコン画像は `scripts/render_factory_icon.py` で描きます(ドットの並びは FactoryLogoView.swift から読みます)。
- 以前の守護者のアイコンは `Assets/AppIcon-master-guardian.png` に残しています。

## macOS向け仕様

- マスター: `Assets/AppIcon-1024.png`（1024 × 1024、RGBA）
- 小サイズ: 16、32、128、256、512ポイントと各Retina表現
- Finder／Dock: `AppIcon.icns`
- アプリ内ブランド表示: `AppIcon.png`
- `Info.plist`: `CFBundleIconFile = AppIcon`

主題を中央に保ち、文字を使わず、16 ポイントでも工場と煙の形が分かるようにしています。

## 再生成

```bash
scripts/build_app_icon.sh
```

このスクリプトはマスター画像から`work/AppIcon.iconset`を作り、`scripts/make_icns.swift`で指定したResourcesディレクトリへ`AppIcon.icns`をまとめます。同時にアプリ内表示用PNGも配置します。出力先を省略した単独実行では`work/Harness.app/Contents/Resources`を使い、Release工程ではパッケージャが一時バンドルのResourcesとフルXcodeのSwift実行ファイルを明示します。

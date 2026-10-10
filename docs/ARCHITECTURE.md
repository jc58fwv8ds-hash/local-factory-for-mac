# アーキテクチャ

## 設計原則

1. 制作物が主役。AI・Terminal・Gitは裏側に置く。
2. モデル、エージェント制御、ツール、GUIを分離する。
3. 結果と現在の目的を先に見せ、生ログは必要時だけ開く。
4. 読み取り・通常編集・ビルド・テストは自動化し、削除・署名・公開は人が承認する。
5. モデル本体を勝手に再学習させず、修正可能なプロジェクト記憶を蓄積する。

これらはレビュー時の目標ではなく、自動チェックを含む開発の完了条件です。具体的な規則は[開発の完了条件](DEVELOPMENT_RULES.md)に定義します。

## レイヤー

```text
SwiftUI GUI
  ├─ プロジェクトライブラリ
  ├─ 制作ステージ
  ├─ プレビュー
  ├─ 自然言語入力
  └─ 状態・承認
        ↓
Agent Coordinator
  ├─ 計画
  ├─ コンテキスト管理
  ├─ 実行ループ
  └─ 結果の要約
        ↓
Capabilities
  ├─ File / Git
  ├─ Shell
  ├─ Xcode / xcodebuild
  ├─ Simulator / simctl
  └─ Screenshot / visual check
        ↓
Model Provider
  ├─ Ollama
  ├─ LM Studio
  └─ 将来のローカルモデル
```

画像コミュニケーションは通常のテキスト推論へ条件分岐を足さず、画像理解、ローカル画像処理、画像生成・編集を別能力として経路選択します。Coreの`VisualAttachmentPolicy`が入力上限、`VisualEditPolicy`が非破壊recipe、`VisualModelRoutingPolicy`が能力不足時の停止、`VisualReferenceBoundary`が画像内命令の隔離を担当します。App層の`VisionVisualTextRecognizer`はApple Visionのaccurate OCRで日本語・英語・開発固有語を一時認識し、Coreの`VisualTextRecognitionPolicy`が信頼度・行数・文字数・位置を検査します。`VisualTextPromptBuilder`はOCR結果を画像と照合すべき未信頼の参考情報として引用し、権限を与えません。OCR本文と画像byteはworkspaceへ保存しません。Viewは画像I/O、OCR、base64化を行いません。調査根拠と段階実装は[画像コミュニケーション調査・採用方針](RESEARCH-VISUAL-COMMUNICATION-2026-08.md)と[音声・OCR・操作理解の再検証](RESEARCH-VOICE-OCR-UX-2026-09.md)に固定します。

音声コミュニケーションも同じ権限境界を再利用します。App層の`SystemVoiceMicrophoneAuthorizer`だけがAVFoundationのマイク許可を扱い、`AppleSpeechTranscriptionProvider`が端末内SpeechAnalyzer／SpeechDetector、言語資産を扱って次turn向けにSpeechモデルを短時間保持します。`SpeechDetector.results`は通常のactivity eventを返さないため、SpeechDetectorはAnalyzerのVAD処理抑制だけに使います。`AppleSpeechAudioActivityDetector`が入力PCMから発話開始と後続無音を局所検出し、`VoiceConversationSession`はfinal transcriptまたはvolatile transcriptのtimeoutも独立したturn確定経路にします。再生中の監視ではAVAudioEngineのvoice processingをbest effortで有効にし、失敗時も明示割り込みを残します。`AppleSpeechAudioInputBridge`はリアルタイムqueueだけでactivity検出、buffer変換、AsyncStream投入を行い、状態遷移時だけMainActorへ通知します。`VoiceCaptureSession`はPush-to-talk、`VoiceConversationSession`はturn境界、通常会話への引継ぎ、読み上げ、再生中監視、取消、次turnの寿命を管理します。Coreの`VoiceTurnEndpointPolicy`は発話末尾に応じて無音猶予を変え、`VoiceBargeInPolicy`はecho、短い相づち、訂正・実発話を分離し、`VoiceConversationPromptGuidance`は音声向けの短い自然な返答を指示します。`VoiceConversationTiming`は本文を含まない時間だけを一時保持し、`VoiceActionAuthorityPolicy`は会話送信以外の権限を与えません。画面上の明示割り込みと終了は常に残し、音声割り込みを進行中作業の取消や承認と同一視しません。`VoiceCapsuleManifest`は声のidentity、参照hash、style、同意、利用範囲だけを持ち、TTS Engine名・embedding・cacheを可搬資産へ混ぜません。調査根拠と実装順は[音声会話・Voice Capsule採用方針](RESEARCH-VOICE-2026-08.md)と[音声・OCR・操作理解の再検証](RESEARCH-VOICE-OCR-UX-2026-09.md)に固定します。

音声、通常／遠隔指示、Computer Operator、選択projectの同時変更はCoreの`WorkspaceInteractionPolicy`が一つの状態表で判定します。Viewのdisabledは説明用であり、安全境界にはしません。`WorkspaceStore+InteractionPolicy`をすべての入口が通り、Computer処理中の別指示、音声中のComputer開始、実行中のproject切替、checkpoint上書きを拒否します。`ComputerOperatorSession`も計画作成時のproject IDと実行対象を再照合し、Storeを迂回した呼出しで古い計画を別sourceへ適用しません。

音声の選択はCoreの`VoiceModelCatalog`／`VoiceModelLibraryPolicy`、Appの`VoiceLibraryStore`、`SystemVoiceCatalog`、`VoicePreviewSession`、`AppleVoiceSpeechRenderer`へ分離します。Aegis／Lumen／PulseはOS音声を使う固定profileで、model weightではありません。追加したMac音声はidentifierだけをUserDefaultsへ保存し、OS音声本文を複製しません。`AppleVoiceResponseSpeaker`は会話turnごとに現在profileを取得する薄いadapterで、`VoiceConversationSession`は選択の永続化を知りません。標準profileの固定styleだけを音声用promptへ渡し、OSから得た任意の音声名はpromptへ渡しません。詳しくは[音声モデルライブラリ調査](RESEARCH-VOICE-MODEL-LIBRARY-2026-09.md)に固定します。

MP3からの声モデル作成は`SystemVoiceSampleImporter`、`SystemVoiceCapsuleAssetStore`、`VoiceCapsuleLibraryStore`、作成画面へ分離します。Importerはsecurity-scoped URLを開いてサイズ・時間・音声trackを検査し、24kHz monoのWAVへ変換します。Asset StoreはVoice Capsuleごとの専用directoryへ正規化音声、任意transcript、モデル非依存manifestをatomicに保存し、SHA-256一致を確認できたものだけを再読込します。元MP3は複製せず、directoryと各資産はprivate permissionにします。private利用の明示attestationは外部共有権限にならず、Qwen3-TTS Adapterが未導入の間はライブラリ上でも生成可能と扱いません。詳しくは[MP3 Voice Capsule調査](RESEARCH-VOICE-CAPSULE-MP3-2026-09.md)に固定します。

文字起こしなしで作ったCapsuleには、`VoiceCapsuleTranscriptPolicy`、Asset Storeの追記、Library Store、専用シートを通して後から正確な本文を追加できます。最初にtranscriptをprivate fileへatomic保存し、hashを含むmanifestを次にatomic更新するため、追加途中で停止しても旧manifestは余分なfileを無視できます。参照音声、作成日時、Capsule／参照ID、同意、利用範囲は変えません。既存transcriptの編集は別のrevision確認が完成するまで拒否します。

Qwen3-TTSのMac経路はCoreの`VoiceEngineSynthesisPolicy`、Appの`VoiceEngineStore`、`Qwen3TTSMLXAdapter`、同梱Python workerへ分離します。状態診断はApple Silicon、専用runtime、modelファイルを段階別に確認します。Asset Storeでhash照合済みの参照音声と正確なtranscriptだけを`0700`の一時directoryへ渡し、生成文をコマンド引数やログへ載せません。workerはoffline modeのローカルmodelだけを使い、出力WAVをSwift側で容量・sample rate・長さまで再検査します。LLMのOllama／LM Studio管理とは独立させ、実モデル品質の合格前は会話Speakerへ接続しません。詳しくは[Qwen3-TTS Mac Adapter調査](RESEARCH-QWEN3-TTS-MLX-2026-09.md)に固定します。

v0.6.3ではGUI、ユーザーが選べる色・明暗・タイポグラフィ、複数プロジェクトのライフサイクル、制作計画編集、前世代バックアップ付き永続化、安全ポリシーに加え、Ollama / LM Studioのモデル検出・導入・選択・削除、実機メモリ・空き容量による導入適合判定、取得率表示と中断後の再開、実推論と中断後の再実行、読み取り専用コンテキスト生成、ソース変更監視、承認付きの単一ファイル編集・新規作成、自然言語からの複数ファイル成果物計画と段階Coordinator、Git復元ポイント、Swift Package／Xcode検証、編集直後の自動検証、失敗ログからの安全な段階的複数ファイル再修正と再起動後の再開、検証中断の再実行、出所付き会話と未信頼外部レビュー境界、ローカル完結／ChatGPT併用の制作ループ、暗号化・明示有効化・6桁コード付きiPhoneリモート入口、安全なiPhone Xcode雛形、実Simulator runtimeの一覧・起動・画面取得、無料Personal Team向け物理iPhone事前診断と明示承認付き実行、実macOS GUI QA、Universal Releaseバンドル生成、主要GUI導線の安定識別まで確認しています。制作ループの進捗は`ProjectMilestoneProgress`が証拠に基づいて単調に更新し、旧版で完了だけが記録されたプロジェクトも読込時に100%へ整合させます。旧形式の単一プロジェクトは起動時にライブラリ形式へ自動移行します。モデル取得は必ず実機容量確認を挟みます。

プロジェクト生成とソース判定は`ProjectFactory` / `ProjectSourceAnalyzer`、検索・状態遷移・詳細更新は`ProjectLibrary`へ集約します。制作計画の追加・編集・並べ替え・状態変更・削除は`ProjectWorkPlanWorkflow`へ集約します。`WorkspaceStore`は画面状態とユースケースの調停に限定し、プロジェクト、制作計画、モデル選択、推論の操作を別extensionへ分割しています。推論に伴うドメイン変更は`ProjectInferenceWorkflow`へ集約し、UIストアから状態遷移の詳細を追い出しています。SwiftUI側も一覧コンテナ、モデルカード、Studio部品、プレビュー、共通フォーム、編集シートを独立させています。

`ProjectSourceScanner`はactorとしてGUIスレッドから分離し、読み取り専用・最大2,500項目・隠しファイル除外という境界を持ちます。診断結果だけを`SourceInspection`として保存し、ファイル内容やソースツリーはプロジェクトJSONへ取り込みません。

`ProjectSourceMonitor`はScannerの結果から、相対パス・サイズ・更新時刻によるセッション内Snapshotを作り、追加・変更・削除を比較します。Snapshotと変更パスはメモリだけに保持し、永続化する`SourceInspection`には集計値とFNV-1aによる短いrevisionだけを追加します。これにより再起動後も変更有無を検出できますが、ワークスペースJSONからソースツリーを復元することはできません。一般のmacOSパッケージ内部は走査せず、`.xcodeproj/project.pbxproj`と`.xcworkspace/contents.xcworkspacedata`だけを既知のXcodeメタデータとして上限内へ加えます。Harness自身の保存・復元直後は`detectsChanges: false`で基準を更新し、既知の変更を外部変更として二重通知しません。GUIは起動時、プロジェクト選択時、アプリがactiveへ戻った時に30秒の最小間隔を守って再確認します。

アーカイブ、ゴミ箱、一覧からの削除は`ProjectLibrary`内の登録状態だけを変更します。読み込んだソースパスは参照情報として保持し、元ファイルの削除は行いません。

ワークスペース永続化は`WorkspaceRepository`、復元元とエラー表現は`WorkspaceRecovery`へ分離しています。初回保存では主ファイルとバックアップを同時に作り、以後は新しい主ファイルを書く前に直前の有効世代を`workspace.backup.json`へ原子的に保存します。主ファイルが読めなければバックアップを読み、`WorkspaceStore`は復元を画面通知します。主ファイルとバックアップの両方が壊れている場合はスターターを表示しても既存ファイルへの保存を拒否し、破損データを無言で上書きしません。

現在は外部ランタイムをアダプターとして利用しますが、`RuntimeKind.harness`を予約済みです。ここへ将来、アプリ同梱のMLXまたはllama.cpp実行系を接続し、Ollama / LM Studioを任意の互換レイヤーにします。

推論は次の一方向の依存に分割しています。

```text
SwiftUI
  ↓
WorkspaceStore+Inference（非同期処理の調停）
  ├─ ProjectInferenceWorkflow（プロジェクト状態遷移）
  ├─ ProjectSourceContextCollector（上限付き・読み取り専用収集）
  ├─ ProjectPromptBuilder（文脈と会話履歴の合成）
  ├─ WorkspaceStore+ConversationResponse（ストリーミングと1回限定の再検討）
  │    └─ ContinuationResponsePolicy（比較元・同文判定・再検討用指示）
  └─ ModelInferenceProvider
       └─ LocalInferenceService
            └─ InferenceStreamParser（NDJSON / SSE）
```

`LocalInferenceService`がOllamaのNDJSONとLM StudioのOpenAI互換SSEを共通のテキストストリームへ変換するため、`WorkspaceStore`とSwiftUIはランタイム固有のJSONを扱いません。ストリーム解析も`InferenceStreamParser`へ分離し、通信と形式解釈を独立して試験できます。

制作の反復状態は`CreationLoopState`、遷移は`CreationLoopWorkflow`へ集約します。Viewは方式と現在フェーズを表示するだけで、指示受付、ローカル提案、検証開始・完了、外部レビュー取込、完成の遷移を個別に判断しません。永続化するのは方式、フェーズ、反復回数、直近検証の成否、更新時刻だけです。旧JSONに制作ループがなければローカル完結・指示待ちへ移行します。

制作の百分率と工程は`ProjectMilestoneProgress`が制作開始、提案完成、検証開始、検証成否、完成という確認済みイベントから更新します。`CreationCompletionPolicy`は制作候補の未完了、中断チェックポイント、修正待ち、未反映の成果物計画、現在の検証成否を一か所で判定します。Viewや非同期Adapterは数値や完成条件を計算しません。完成操作は全条件を満たした場合だけ工程をリリース、進捗を100%へ進め、作業状態を一括で完了へ書き換えません。制作指示や計画内容を変更すると以前の検証成功を失効させます。旧版ですでに完了として保存されたデータは工程と100%だけを復号時に整合させ、残された作業証拠を保存します。

`RunCoordinatorWorkflow`は長時間制作の順序だけをCoreで調停します。`ProjectInstructionContext.productionCandidates`から実制作項目を1件選び、項目UUIDと`RunCoordinatorPhase`を固定したまま、既存の`FileChangeSession`、`ProjectValidationSession`、`CreationCompletionPolicy`へ接続します。検証成功後も`approveCurrent`までは項目を完了にせず、検証種別・終了コード・出力を一方向の短い指紋にした同じ失敗が2回続く場合と、ユーザー確認なしの6サイクル到達時に停止します。外部ソース変更も同じCore境界で検証証拠を失効させます。永続化する上限24件の台帳は項目UUID・イベント・時刻だけで、プロンプト、ファイル内容、コマンド出力、パスを持ちません。Viewは`RunCoordinatorCard`、調停は`WorkspaceStore+RunCoordinator`へ分離し、書込・検証処理を複製しません。

`RunCoordinatorRecovery`はワークスペース読込時に固定項目UUIDと台帳証拠を照合します。固定項目が消えた状態は計画確認へ、成功証拠のない検証済み状態は再検証へ戻します。正常な復帰はフェーズ、固定項目、サイクル数、承認数を保ち、読込だけで制作を進めません。

検証失敗はCoreの`ValidationFailureClassifier`が、実装、テスト挙動、toolchain、Simulator、署名、依存関係、資源不足、混在、判定不能へ分類します。対象は失敗出力の先頭・末尾あわせて最大120,000文字です。実装原因の根拠は、接続ルートを基準に`BuildFailureAnalyzer`が安全な既存ファイルとして確認した`BuildFailureAnalysis.diagnostics`だけです。生出力にcompiler形式があること自体は根拠にしないため、`.build/checkouts`など依存ソースの診断を編集可能なプロジェクトコードとして扱いません。`WorkspaceStore`と実制作E2Eは同じルート認識済み解析を`RunCoordinatorWorkflow`へ渡します。環境markerとコード／テスト証拠が共存すれば混在、根拠が不足すれば判定不能とし、どちらもコード変更を許可しません。修正計画とAI再計画も同じ分類で停止します。

検証失敗後の再計画は、コード変更が許された場合だけ`WorkPlanReplanContextBuilder`が失敗種別、安全な位置、最大12件の未完了項目へ縮約し、生のcompiler/testメッセージを推論へ渡しません。`WorkPlanReplanPromptBuilder`は新規項目を最大3件と総数12件までの残り枠の小さい方、未確定点を最大3件に制限します。JSON schema、Parser、`WorkPlanReplanWorkflow`も総数12件を再検査します。Parserは既存参照の全件一意性と固定項目の先頭を検査し、モデルが返した既存title/detailを捨ててCoreの原本を使います。Workflowは採用時のfingerprintを再照合し、既存UUID・状態・完成条件を保持したまま明示採用された順序と新規項目だけを反映し、以前の検証証拠を失効させます。非同期生成はApp層の`WorkPlanReplanSession`、表示と採用確認は`WorkPlanReplanView`へ分離します。

実モデル評価は`HARNESS_REPLAN_EVAL=1`または`HARNESS_REPLAN_LONG_EVAL=1`でのみ動きます。両者は`WorkPlanReplanEvaluationEngine`を共有し、後者は10項目から異なる失敗2回、採用2回、JSON再読込2回を通します。項目保持、完成条件保持、固定順、総数上限、未確定点を検査します。初回に生診断内の偽命令が未確定点へ再掲されたため文脈から生メッセージを除外し、再評価で漏れないことを確認しました。これは合成構造評価であり、意味品質や長時間GUIの保証ではありません。

`LocalInferenceService`の通常初期化は`LocalInferenceSessionPolicy`が作る一時`URLSession`だけを使います。ディスク`URLCache`、Cookie保存、共有セッションを無効にし、ローカルランタイムへの接続をホストごと1本へ制限します。検査用の注入initializerは残し、通信実装と評価を同じ境界で差し替えられるようにします。

実制作E2Eは`HARNESS_PRODUCTION_E2E=1`を明示した`HarnessCoreChecks`だけで実行します。`ProductionE2EChecks`はOS一時領域へ独立Swift Packageを作り、Qwen 3.8 27Bの構造化1ファイル変更、原子的適用、意図したテスト失敗、自然言語による再修正、再検証、人の承認相当、最終検証、証拠付き完成を製品と同じCore境界で通します。成功・失敗・準備途中の全経路で一時ルートを削除し、保存済みワークスペースは読みません。出力するJSONはモデル名、検証種別、成否、終了コード、時間、台帳イベントだけで、生成ソース、プロンプト、生ログ、パスを含みません。通常の回帰検査はモデルもネットワークも起動しません。

v0.8.34で`HARNESS_PRODUCTION_E2E=1`は`ProductionMultiItemE2EChecks`へ進み、3項目のQwen変更と、承認後・検証前・一時停止中の`WorkspaceRepository`保存・再読込を通します。単一項目の前世代比較は`HARNESS_SINGLE_ITEM_E2E=1`で残します。両評価は推論・原子的保存・固定build/testの`ProductionE2EEngine`を共有し、評価専用の書込経路を作りません。出力はモデル名、時間、検証種別・成否・終了コード、復帰段階、台帳イベントだけです。

会話の各メッセージは`ConversationOrigin`でユーザー、ローカルモデル、外部レビューを区別します。旧メッセージに出所がなければ既存のroleから安全に補完します。外部レビューは`ExternalReviewPromptBoundary`が最大20,000文字へ再制限し、境界文字列を無害化して全行を引用します。`ProjectPromptBuilder`のsystem指示も、引用内の命令・役割変更・安全規則上書きを拒否するよう固定します。

ファイル編集画面のAI生成状態は`ProjectFileEditInferenceWorkflow`へ集約します。開始時に制作サイクルと最小の`fileEditInference`チェックポイントを開始し、提案完成・停止・通常エラーで消去します。異常終了で残った場合も指示、途中出力、ファイル内容は保存せず、GUIは現在のソースへ指示を再入力する安全な導線だけを表示します。

検証後の説明は`ValidationRevisionGuidanceBuilder`が「現状・修正案・得られる結果」へ正規化します。ChatGPT併用時だけ`ExternalReviewPacketBuilder`が上限付きソースと検証結果を最大32,000文字へ合成し、絶対パス、既知のトークン形状、資格情報らしき代入行を除外します。App層の`ExternalReviewSession`が収集を調停し、`ExternalReviewHandoffProviding`だけがPasteboardと通常ChatGPTのURLを扱います。Viewは外部I/Oを持たず、自動送信APIも持ちません。ユーザーが確認後にコピーし、ChatGPT側で送信し、回答を貼り戻した場合だけ最大24,000文字を会話へ保存します。

`ProjectSourceContextCollector`は最大4,000項目を走査し、README・マニフェスト・ソースを優先します。`SourceContextBudgetPolicy`が8–9B級を最大10ファイル・24,000文字、20B以上を最大18ファイル・48,000文字へ振り分けます。依存物、ビルド成果物、隠しファイル、ロックファイル、鍵・認証情報らしい名前、バイナリ、シンボリックリンクは除外します。`ProjectPromptBuilder`はこのスナップショット、プロジェクト情報、上限付きの直近会話を合成します。スナップショットは推論時だけ保持し、永続化しません。

ファイル編集は次の承認境界に分離しています。

```text
FileChangeReviewView
  ↓
FileChangeSession（画面状態・AI生成の調停）
  ├─ FileEditPromptBuilder / FileEditResponseParser
  ├─ ProjectFileEditing
  │    └─ ProjectFileEditor（列挙・読取・競合確認・原子的保存・復元）
  │         └─ SourceFilePolicy（読み取りと共通の除外規則）
  └─ GitCheckpointing
       └─ GitCheckpointService（blob保存・ref管理・競合確認）
  └─ ProjectValidationSession（保存後検証の状態・停止）
       └─ ProjectValidating
```

対象は既存または新規のUTF-8テキスト1ファイル、最大512KBです。削除、空ファイル化、パス逸脱、シンボリックリンク、依存物、機密名らしいファイルを拒否します。新規作成は既存ディレクトリ内だけに限定し、`FileChangeOperation.creation`として更新と区別します。`FileLineDiff`が保存前の追加・削除行を生成し、AI応答も`{"content":"変更後全文"}`へ限定します。既存更新は元内容を再比較し、新規作成は完成済み一時ファイルから排他的なハードリンクで公開するため、レビュー後に別プロセスが変更・作成した対象を上書きしません。取り消しも現在内容が提案と一致する場合だけ行います。Viewはファイルシステムへ直接触れません。

`FileChangeSession`は選択・提案・検証の画面状態だけを持ち、推論処理を`FileChangeSession+Generation`、保存と取り消しを`FileChangeSession+Application`へ分割します。新規作成も既存編集と同じ差分確認、明示承認、保存後検証、制作ループ通知を再利用し、別の書き込み経路は持ちません。Git blob復元ポイントは既存内容の復元にだけ作り、新規作成を空blobへの更新として偽装しません。

複数ファイル制作は`ArtifactPlanSession`が自然言語の目的をローカルモデルへ渡し、`ArtifactPlanResponseParser`が2〜8件の`ArtifactCreationTarget`だけを受理します。既存ファイル、重複、パス逸脱、依存物・機密名、空指示を拒否し、`ProjectFileEditor.validateCreationPath`で全対象の親フォルダと競合を開始前に再確認します。`ArtifactCreationPlan`は現在対象・承認済みパス・最初の未完了対象を決定し、`FileChangeSession`は従来の単一ファイル承認境界へ1件ずつ渡します。中間対象では不完全な構成へのbuildを避け、最終対象後だけ全体検証を必須化します。再起動用には最大8パスと各800文字以内の目的、進捗だけを保存し、ファイル内容・AI途中応答・検証ログは保存しません。

`Domain.swift`はプロジェクトの値定義に限定し、旧ワークスペース移行を含む`HarnessProject`の符号化責務を`HarnessProject+Codable`へ分離しています。成果物計画が存在しない旧JSONは`nil`へ移行します。

Git管理下では保存前後の全文を`git hash-object`でblob化し、`refs/harness/checkpoints/<UUID>/`配下だけで保護します。コミット、ブランチ、index、既存ref、作業ツリーは操作しません。履歴はプロジェクトごとに最大20件で、上限超過・即時取り消し・復元完了・適用失敗時に不要refを破棄します。後日の復元も現在ファイルのblob IDが保存直後と一致する場合だけ、既存の原子的保存経路へ渡します。

Swift Package／Xcode検証は、手動実行と保存後の自動実行で同じ非同期セッションと固定コマンド実行器を共有します。

```text
ProjectValidationView ───────────────┐
FileChangeReviewView → FileChangeSession
                                     ↓
                         ProjectValidationSession
                         （開始・停止・結果・対応判定）
  ↓
ProjectValidating
  └─ LocalProjectValidationService（方式選択）
       ├─ SwiftPackageValidationService
       │    ├─ /usr/bin/xcrun swift build
       │    └─ 成功時のみ /usr/bin/xcrun swift test
       └─ XcodeProjectValidationService
            ├─ XcodeProjectLocator / XcodeSchemeParser
            ├─ /usr/bin/xcrun xcodebuild -list -json
            └─ schemeの署名なしDebug build
                 ↓
          ValidationCommandRunner（停止・3分上限・末尾40KB）
```

対象は`Package.swift`、`.xcworkspace`、`.xcodeproj`のいずれかがあるソースです。`ProjectValidating.support`でファイル保存前に方式と表示情報を判定し、対応プロジェクトでは既定で保存直後に検証します。Xcodeコンテナは隠しファイル・依存物・シンボリックリンクを除外し、workspace、浅い階層、名前順の決定的な優先度で1件を選びます。schemeは`xcodebuild -list -json`から取得し、コンテナ名と同名のschemeを優先します。

任意コマンドやシェル展開を受け付けず、すべて引数配列で固定コマンドを起動します。XcodeはDebug buildだけを一時DerivedDataへ実行し、`CODE_SIGNING_ALLOWED=NO`／`CODE_SIGNING_REQUIRED=NO`を指定します。archive、export、署名、公開はこの経路に存在しません。各処理は共通の`ValidationCommandRunner`が3分で停止し、出力は一時ファイル経由で末尾40KBだけを画面状態へ返します。`swift test`が終了コード0でもXCTest／Swift Testingの実行マーカーがなければ合格にせず、テスト未実行として環境確認を案内します。失敗時も変更を自動復元せず、エラー末尾と競合確認付きの復元導線を示します。検証ログ全文をプロジェクト記憶へ保存せず、成功・失敗の要約だけを`ProjectValidationWorkflow`が活動履歴へ反映します。本番ではSwiftPMの標準サンドボックスを維持します。

失敗した検証結果は`BuildFailureAnalyzer`がCore内で解析します。コンパイラ診断の絶対／相対パスを接続ルートへ正規化し、既存の通常ファイル、許可拡張子、機密名除外、512KB上限、シンボリックリンク拒否を再確認します。`ProjectValidationSession`は解析結果だけをViewへ渡し、`ValidationFailureAnalysisView`はI/Oを持ちません。再修正時は対象1ファイルと上限付き診断を`FileChangeSession`へ引き継ぐため、AI生成、差分承認、競合拒否、Git復元、保存後再検証の境界を複製しません。ログと修正指示は永続化しません。

複数ファイルの診断は`BuildRepairPlanner`が初出順を保って最大8個の`BuildRepairTarget`へ集約します。`BuildRepairProgress`は現在対象・承認済みID・次の未対応という純粋な状態遷移だけを持ち、`FileChangeSession`はその結果に従って既存の単一ファイル編集を切り替えます。各対象は個別に保存・検証し、一括適用APIは持ちません。再検証に合格した場合は残りの旧診断を追わず、失敗が続く場合だけ次の対象へ進めます。ファイル一覧と修正計画パネルは`FileChangeReviewView`から別Viewへ分離し、画面本体の肥大化を抑えています。

再開状態は`RepairResumeState`と`RepairResumeWorkflow`へ分離します。永続化するのは最大8件の安全な相対パス、承認済みパス、現在位置、作成・更新時刻だけで、診断メッセージ、AI指示、検証出力、ファイル内容は含めません。GUIは保存済みのパスを直接編集へ渡さず、再開操作で`ProjectValidationSession`を自動起動し、最新の失敗結果から`BuildRepairPlanner`が計画を再構築します。合格時はチェックポイントを自動消去し、破棄操作もCoreの状態だけを変更します。旧JSONではこのフィールドを任意として扱い、空状態はエンコードしません。

検証そのものの中断は`ProjectOperationCheckpoint`と`ProjectOperationCheckpointWorkflow`が扱います。検証開始時に処理種別と開始・更新時刻だけを保存し、結果受領時に消去します。プロセス、コマンド、ログ、接続パス、診断は含めません。結果が返る前にアプリやシートが終了した場合だけチェックポイントが残り、`ValidationResumeNotice`から現在の接続先へ検証を最初から実行します。画面のシート調停は`ActivityInspectorPresentation`へ分離し、`ActivityInspectorView`へ永続化やモーダル配線を集中させません。

AI生成も同じ`ProjectOperationCheckpoint`を利用し、処理種別、既存`WorkItem`のUUID、開始・更新時刻だけを保存します。`ProjectInferenceWorkflow.resume`は対象作業を再びactiveへ戻しますが、`ConversationMessage`を追加しません。`WorkspaceStore+Inference`が既存会話と現在の読み取り専用ソースコンテキストから新しい推論リクエストを構築し、成功・通常エラー時だけチェックポイントを消去します。停止・プロセス終了では途中回答を破棄して記録を残し、`InferenceResumeNotice`から再実行または記録破棄を選べます。

モデル取得はプロジェクト固有処理ではないため、`ProjectOperationCheckpoint`へ混在させず、`ProjectLibrary.modelAcquisitionCheckpoint`がワークスペース単位で管理します。`ModelAcquisitionRequest`はモデルID、ランタイム、表示情報、推定容量だけを持ち、`ModelAcquisitionCheckpointWorkflow`が開始・同一要求の再開・完了・破棄を純粋な状態遷移として扱います。`LocalModelService`はキャンセル対応の`BoundedCommandRunner`を利用し、`ModelManagerStore`はプロセス状態と永続状態を調停します。`ModelAcquisitionResumeNotice`と`ModelOperationBanner`を`ModelManagerView`から分離し、画面へ長時間処理の責務を集中させません。

`BoundedCommandRunner`の任意出力Observerは一時ログを8KBずつ読み、`ModelAcquisitionProgressParser`がANSI制御文字を除去したうえで既知の割合・検証・保存工程だけを`ModelAcquisitionProgress`へ変換します。未知の出力は破棄し、`ModelManagerStore.acquisitionProgress`はメモリ上の現在表示に限定します。割合はランタイムが報告した現在のレイヤー／モデルデータに対する値で、Harnessが推測した全体進捗ではありません。

実Simulator統合検査は通常のCore検査から分離し、`HARNESS_SIMULATOR_INTEGRATION=1`が明示された開発環境だけで`LocalSimulatorService`を通した一覧・boot・bootstatus・PNG取得を行います。Xcode 26.6／iOS 26.5のiPhone 14 Proで確認済みです。`SimulatorSession`が端末選択時に旧画像を破棄し、Viewは選択・画像・メッセージの整合性を個別に調停しません。

Swift Package検証はフルXcodeが導入済みなら`DEVELOPER_DIR`を検証プロセスだけへ明示し、Command Line ToolsとSDKの版ずれを避けます。システムの`xcode-select`設定そのものは変更しません。

Simulator操作も同じ`BoundedCommandRunner`を使い、Process・タイムアウト・一時ログ・出力上限を複製しません。`LocalSimulatorService`だけが`simctl`を呼び、`SimulatorDeviceParser`がJSONとUUIDを検証します。許可する操作は利用可能端末の一覧、選択端末の起動完了待ち、起動済み端末のPNG取得だけです。端末の作成・削除・初期化・終了はコマンド経路に含めません。画像は50MB上限とPNG署名を確認してメモリへ渡し、一時ファイルは成功・失敗の両方で削除します。SwiftUIは`SimulatorSession`を介して状態だけを扱います。

物理iPhone経路は自動検証から分離します。`LocalPhysicalDeviceService`だけが`devicectl`と署名付き`xcodebuild`を扱い、画面表示時は端末一覧・scheme・build settingsの読み取りだけを行います。`PhysicalDeviceParser`は物理iPhoneの表示情報、接続、ペアリング、Developer Modeだけを抽出し、serial numberやECIDを型へ保持しません。UDID相当の実行ハンドルはCore内のメモリだけに留め、Viewや永続モデルへ渡しません。`XcodeSigningSettingsParser`もTeam ID自体を捨て、「設定済みか」だけへ変換します。

署名付き実行は`PhysicalDeviceSession`の明示確認後だけ開始します。固定されたDebug buildへ`-allowProvisioningUpdates`と`-allowProvisioningDeviceRegistration`を付与し、作成物がHarness専用の一時DerivedData内にあり、事前診断したBundle Identifierと一致することを再検査します。その後に選択端末へのinstallとlaunchだけを許可し、archive、export、配布、削除は経路に含めません。生の端末ID、Team ID、Apple Account、コマンド出力は永続化せず、一時JSON・一時ログ・DerivedDataを成功と失敗の両方で削除します。Apple Accountの認証、「信頼」、Developer Modeの端末確認はユーザー操作として残します。

モデル管理は`ModelCatalog`、`ModelInventory`、`ModelOutputParser`、`LocalModelService`へ分割しています。`scripts/check_architecture.sh`はSwiftファイル350行上限、CoreからSwiftUI/AppKitへの依存、Viewから通信・プロセス・ファイルシステムへの直接アクセスを検出します。

外観設定はプロジェクト記憶や`WorkspaceStore`へ混ぜず、App層の`AppearanceSettings`へ分離します。テーマIDと明暗モードだけを`UserDefaults`へ保存し、色表現は`HarnessColorTheme`からSwiftUIのアクセント色として配布します。各Viewは固定ブランド色を持たず、意味的なアクセント色を参照します。

通常UIの文字はApp層の`HarnessTypography`へ集約します。英字はApple Garamondを第一候補、日本語は各ウェイトに対応した`HiraginoSans-W2...W6`をcascade descriptorとして明示します。Apple Garamondが未導入ならmacOS標準セリフデザインへ切り替え、欠損グリフや起動失敗を防ぎます。Viewは`.harness(...)`の意味的トークンだけを参照し、コード・差分・検証ログに限って等幅フォントを許可します。`scripts/check_architecture.sh`が生の標準フォント指定の再混入を検出します。

GUIスモーク検査の識別子はApp層の`HarnessAccessibilityID`へ集約します。ホーム／プロジェクト／AIモデルのナビゲーション、新規作成、検索、制作指示、ソース編集・検証など主要導線だけへ意味的IDを付け、画面上の順番や翻訳文言に依存しない操作境界を提供します。Viewは生のID文字列を持たず、`scripts/check_architecture.sh`が契約対象の参照欠落を検出します。プロジェクト行のような動的要素はUUIDを含む決定的IDを生成します。

隔離GUI検査は`HARNESS_GUI_FIXTURE_WORKSPACE`を明示した時だけ別`WorkspaceRepository`を使います。`HarnessAppEnvironment`は、symlink解決後もOS一時領域の内側にあり、末尾が`workspace.json`の絶対パスだけを受理します。通常起動、相対パス、ユーザーフォルダ、別名ファイルは既定Repositoryへ戻します。CoreChecksは同じ一時container内の兄弟`Project/`と`Workspace/workspace.json`へ使い捨てSwift PackageとHarnessの状態を分離し、ワークスペース保存をソース変更として誤検知しません。保存済みデータを検査fixtureへ複製しません。

SwiftUIではコンテナへ付けたアクセシビリティIDが子要素へ伝播する場合があるため、画面識別用IDは見出しなど単一の葉要素へ付けます。操作対象のButton、Picker、TextFieldはそれぞれ固有IDを直接持ち、親コンテナから上書きしません。この契約はソース検査に加えて配布アプリの実Accessibility Treeで確認します。

会話は`ConversationMessage`としてプロジェクトに保存します。旧データに会話フィールドがなくても空履歴として復元する明示的なCodable移行を持たせています。生成中の本文は画面状態にだけ保持し、完了した応答だけを永続化します。

v0.8.7では、`AsyncThrowingStream`の消費側キャンセルが例外ではなく通常のループ終了になる場合も、完了直前の`Task.checkCancellation()`で中断へ戻します。会話・変更案・成果物計画・Computer計画／要約と推論Provider・用語解説の各成功境界に同じ確認を置き、ファイル提案は非同期検査後の取消確認を通るまで画面へ公開しません。途中のテキストや構文上は完全なJSONを受信した状態で停止する回帰検査により、停止済みの内容が保存・承認候補になることを防ぎます。v0.8.8では`CreationLoopWorkflow.resumedConsultation`が再開時のフェーズだけを戻し、制作サイクル・検証証拠・制作進捗を増やさず表示を実行状態へ整合させます。

推奨モデルはランタイムごとの識別子を`ModelCatalogEntry`へ保持します。Qwen 3.8 27B Q4_K_MはOllamaではHugging Face GGUF識別子、LM Studioでは量子化指定付きモデル識別子を使い、同じ16.8GBの候補へ解決します。

`ModelHostResources`は物理メモリとモデル保存先に近い起動ディスクの利用可能容量だけをセッション内で取得します。`ModelFitPolicy`はカタログの推定サイズへ実行時オーバーヘッドと取得用余裕を加え、適合・制約あり・非推奨・容量不足・不明へ決定的に分類します。Viewはこの判定結果を表示するだけで閾値を持たず、`ModelManagerStore`は容量不足時だけ取得要求を作らないよう調停します。端末容量と判定結果は永続化しません。

リモート指示は`RemoteInstructionBoundary`が通信版、8KB、4,000文字、空値、制御文字を検査し、`RemotePeerTransport`がMultipeerConnectivityの暗号化必須セッションと6桁招待コードだけを扱います。`RemoteControlStore`は接続表示、最大100件の受信ID重複拒否、受付結果の返信を調停します。`WorkspaceStore+InstructionSubmission`は通常入力とリモート入力を同じ`ProjectInferenceWorkflow`へ渡し、履歴の`remoteUser`出所を失いません。待受、コード、端末名、受信IDはセッション内だけで、ワークスペースへ保存しません。

v0.8.6では継続指示を`ContinuationInstruction`の文全体の分類、`ProjectInstructionContext`の直前依頼・未完了作業の選択、`ProjectInstructionAcceptance`の会話受付・応答記録へ分離しています。`WorkItem.responseToMessageID`はAI応答記録と元の制作項目を区別する任意の会話参照です。旧データはnilのまま読め、継続文しか持たない旧項目も削除せず候補から除外します。連続した継続指示は直前の会話に対応する未編集の応答記録だけを再利用し、各回の原文は会話へ残します。名前や内容を手編集した項目は参照を解除して通常の制作項目へ戻します。AI応答を完了しても元の制作項目・制作進捗は変わりません。Storeは受付が返すIDを推論とチェックポイントへ渡し、未解決のチェックポイントがある場合は入力を保持して受付を止めます。受付と非同期推論の調停も別extensionへ分割しました。

v0.8.9では`ContinuationResponsePolicy`が単独の継続指示に対応する直前のローカル回答を選び、外部レビューや別の未回答の具体指示をまたいだ回答は除外します。前回答はassistantの参考文章として最大8,000文字＋省略表示へ制限し、systemへ回答本文を混ぜません。長い具体指示は先頭と末尾を残し、末尾の禁止事項も内部理解へ引き継ぎます。同文判定は外側の空白とCRLF差だけを吸収し、意味の類似度や数字・コード内空白の無視は使いません。`WorkspaceStore+ConversationResponse`が同じ推論・予算・承認範囲で1回だけ再検討し、専用フェーズで表示します。失敗や再度の同文は確認待ちへ戻し、キャンセルは既存チェックポイントを保持します。再検討の指示と不採用の返答は永続会話へ混ぜず、制作サイクルも増やしません。言い換えによる意味上の重複を完全に検出する機構ではありません。

v0.8.10では固定の継続方針をsystem中に置くのではなく、推論時だけ最新のユーザー発話へ補足します。元の具体指示の再回答と、制約を引き継いだ次の具体案を区別し、最新ターンで名前・値・ルール等の中身を返すようにします。補足は一度だけ合成し、永続会話とリモート受付の原文は変更しません。

プロンプトの制作計画も`ProjectInstructionContext.productionCandidates`を共有し、AI応答の追跡記録と完了済みの項目を次の制作指示へ混ぜません。古いQA記録を含む作業一覧自体は削除・変更せず、会話履歴の出所と上限も従来どおり維持します。

v0.8.11では`ConversationPromptHistory`がユーザー発話（最大12件・12,000文字）とローカルAI／外部参考（最大6件・12,000文字）を別枠で選び、元の順序で合成します。単一発話は4,000文字、ローカル回答本文は8,000文字以内にし、長文の先頭・末尾と省略表示を残します。原文保存・制作Workflowは変更せず、古い希望と後の訂正の関係をモデルが判断する方針を明示します。有限の履歴選択であり、任意の長期記憶や意図変更の完全な自動理解は保証しません。

引用の整形・容量は`PromptReferenceText`、読み取ったソースの引用合成は`SourceReferencePromptBuilder`へ分離します。`ProjectPromptBuilder`は方針と構成の調停だけを担当し、ソース本文・過去のAI回答をsystem命令へ昇格させません。外部レビューとソースは全行引用・境界文字列の中和・引用の外枠を残す打ち切りを通します。これはプロンプト上の防御であり、実行の承認やファイル境界の代わりにはなりません。会話生成で実行・検証した事実はないことを明示し、`ProjectInferenceWorkflow`の新しいソース読取・AI応答受信の活動も検証済みではなく情報として記録します。

会話品質の評価は通常の回帰検査から分離した明示実行の`ConversationEvaluationChecks`が担います。固定合成会話、同じ製品Builder／Provider、最大3回・1件180秒の上限で応答と所要時間を採取し、意味の正しさを自動合格にしません。一次資料と採用範囲は[研究採用記録](RESEARCH-CONVERSATION-2026-08.md)に残します。

v0.8.12では、実会話でモデルが内部用の出所見出しまで返したため、`ConversationResponseText`を表示・保存前の純粋な整形境界として分離します。`PromptReferenceText`と共有する既知の見出しが先頭にある場合だけ除外し、引用や本文中の同じ文字列・コードの空白は変更しません。途中までの見出しはストリーミング中だけ保留し、EOF時に「過去」など普通の短い回答だった場合は残します。見出しだけなら空回答として不採用にし、過去の回答に付いた見出しでも同文再検討を回避できないよう比較前にも同じ整形を通します。Viewへ文字列判定を置かず、保存済みの履歴は移行・上書きしません。

iPhone雛形は`AppleAppScaffolder`が製品名・組織ID・親フォルダ・既存競合を検査し、固定された`AppleAppStarterFiles`と`AppleAppProjectTemplate`だけを新しいディレクトリへ公開します。個々のファイルは同一ボリューム上の一時ファイルから排他的ハードリンクで公開し、同名先を上書きしません。途中失敗時に削除するのは、この処理が新規作成したルートだけです。Viewは保存先選択と明示操作だけを持ち、ファイルシステム処理は行いません。

ブランド資産は`Assets/AppIcon-1024.png`を唯一のマスターとします。`scripts/build_app_icon.sh`が各解像度と`.icns`を生成し、Finder／Dock用とアプリ内表示用の資産を同じ原画から配置します。画像加工とバンドル設定を画面コードから分離し、アイコン差し替え時の変更範囲を限定します。

Release配布物は`Packaging/Harness-Info.plist`と`scripts/package_release.sh`を唯一の組立経路にします。パッケージャは版番号を検証し、空の一時ディレクトリからRelease実行ファイル・Info.plist・アイコンを構成します。arm64とx86_64をフルXcodeの同じSDK・macOS 14.0 targetで個別に警告ゼロビルドし、`lipo`でUniversal Binaryへ結合します。アイコン生成を含む全工程で同じtoolchainを明示するため、`xcode-select`がCommand Line Toolsを指していてもSDKの版ずれを起こしません。署名後にZIPを再展開し、展開後の両architecture・署名・版番号が一致した場合だけ`outputs`へ移動します。同一バージョンを無言で上書きせず、adhoc署名と将来のDeveloper ID署名を同じ工程で切り替えます。公証はApple資格情報を必要とするため、このローカル工程とは分離します。

Computer Operatorは`ComputerOperationPlan`と`ComputerOperationPolicy`がQwenの構造化計画を最大6手順へ制限し、`ComputerOperatorSession`が実行順序だけを調停します。AppKit／Accessibility APIは`MacComputerController`へ隔離し、ViewはOS操作を直接呼びません。公開検索結果は`PublicWebSearchResultPolicy`がHTTP(S)、公開host、機微情報を含まない題名だけへ絞り、query・fragment・userinfoを除去します。任意アプリの生アクセシビリティ情報は画面表示だけに留め、結果要約へ渡すのは検証成否、公開検索結果、安全な操作の成否だけです。

実行前の計画は`ComputerOperationCheckpoint`としてユーザー指示、上限付き計画、次の手順、不確定な実行中手順、時刻だけを保存します。コマンド、ログ、画面内容、検索結果は永続化しません。各手順の直前に不確定状態を保存し、結果受領後だけ次へ進めるため、停止やプロセス終了後にボタン操作を自動反復しません。再開時はユーザーが再実行またはスキップを選び、スキップは成功と区別して活動履歴へ残します。完了時は主ワークスペースのチェックポイントを消去します。

通常入力の振り分けは`PrimaryInstructionIntentRouter`が純粋な分類として担当し、`WorkspaceStore+ComputerOperator`が入力保持・モデル確認・復旧待ちの調停だけを行います。作成・修正を含む依頼は従来の制作会話へ残し、明確なテスト・検索等だけをComputer計画へ引き継ぎます。実行は既存の確認操作を通り、ルーター自体はOSを操作しません。

用語解説は`ResponseTermIndex`（日本語・英語の単語とUTF-16位置）、`TermExplanationPromptBuilder`（引用専用の短い文脈）、`TermExplanationService`（推論・30秒タイムアウト・最大48件のメモリキャッシュ）、`TermExplanationPresenter`（650ms待機・取消・表示寿命）、`ResponseTextView`（選択・位置判定）、`ExplainedResponseText`／`TermExplanationPopover`（表示）へ分割します。会話とComputer結果の説明は同じ部品を共有し、本文のコピーを維持します。生成した解説はワークスペースへ保存せず、作業指示や成功の証拠にも使いません。モデル未選択・制作処理中は説明だけを表示し推論を始めません。別の単語・モデル・プロジェクト・アプリへ移った後に古い結果を表示しないよう取消を伝播します。

v0.8.5では待機・取消・表示状態を`TermExplanationSession`へさらに分離し、`TermExplanationPresenter`はAppKitへの表示変換だけを担当します。表示前に単語を離れた場合は即時に取り消し、表示後の短い猶予は解説欄へ移動するためだけに使います。解説欄内にいる状態を保持するため、元の文章の退出イベントが後から届いても解説を閉じません。Appleの[追跡領域ガイド](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/TrackingAreaObjects/TrackingAreaObjects.html)が指摘するイベント順序の非保証を考慮し、両方の順序、生成中の単語切替、遅れて返った旧結果、モデル未選択・制作中を画面なしのテストで検査します。

AppKitとの橋渡しはAppleの[文字位置の照会](https://developer.apple.com/documentation/appkit/nslayoutmanager)と[NSViewRepresentableのサイズ計算](https://developer.apple.com/documentation/swiftui/nsviewrepresentable/sizethatfits(_:nsview:context:))を用い、SwiftUIの文単位表示を手作業の単語レイアウトへ分解しません。

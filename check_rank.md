# 仕様書：検索順位記録スクリプト（check_rank.sh）

## 1. 目的

Google Search Console API から、指定サイト・指定キーワードの検索パフォーマンスを取得し、GSC平均掲載順位をローカルのTSVログへ保存する。

このスクリプトで扱う順位は、Google検索結果画面を直接確認した実順位ではなく、Search Console API が返す `position`、つまり「GSC平均掲載順位」とする。

## 2. 最小実装の範囲

### 2.1. 実装すること

- サービスアカウントを使って Google API のアクセストークンを取得する。
- Google Search Console API の `searchAnalytics.query` を呼び出す。
- サイト一覧ファイルに記載された各サイトについて、日本の検索クエリ一覧を一括取得する。
- 取得した検索クエリ一覧とサイト別キーワードファイルをローカル側で照合する。
- 照合結果からGSC平均掲載順位 `position` を抽出する。
- 抽出結果をTSV形式で履歴ファイルへ保存する。
- 同じ `date + site + query` のデータが既に存在する場合は、今回取得した結果で置き換える。
- 実行時に取得中の進捗をターミナルへ表示する。
- 実行時に今回取得した結果を、サイトごとに区切った表形式で表示する。

### 2.2. 実装しないこと

- Google検索結果画面のスクレイピング。
- Web UI。
- DB保存。
- グラフ化。
- 通知機能。
- cron登録。
- 直近7日間の順位推移表示。
- 日報や外部レポートへの統合。

## 3. 入力

### 3.1. サービスアカウントJSONキー

Google Cloud で発行したサービスアカウントJSONキーを使用する。

想定パス：

```text
~/.secret/gsc-service-account.json
```

要件：

- スクリプト内に秘密情報を直書きしない。
- リポジトリにコミットしない。
- ファイル権限は `chmod 600` を推奨する。
- Search Console 側で対象プロパティへの権限を付与しておく。

### 3.2. サイト・キーワード対応表

Search Console の対象プロパティと、そのサイトで監視するキーワードファイルをTSVで記述する。

想定ファイル：

```text
config/sites.tsv
```

形式：

```text
site_url	keywords_file
```

例：

```tsv
https://example.com/	keywords/sample.txt
sc-domain:example.net	keywords/sample.txt
```

Search Console API では、Search Console 側で権限を付与したプロパティ名と完全に一致する値を指定する。

### 3.3. キーワード一覧

監視対象キーワードを1行1キーワードで記述する。

想定ファイル：

```text
keywords/sample.txt
```

例：

```text
example keyword
another keyword
```

各行の前後にある空白やタブは、スクリプト側で削除してからAPIへ渡す。

### 3.4. 設定値

最小実装では、以下の値をスクリプト内の変数または環境変数で指定する。

| 項目 | 内容 | 例 |
| --- | --- | --- |
| `SITES_FILE` | サイト・キーワード対応表 | `config/sites.tsv` |
| `SERVICE_ACCOUNT_JSON` | サービスアカウントJSONキー | `~/.secret/gsc-service-account.json` |
| `OUTPUT_FILE` | 出力先TSVログ | `data/rank_history.tsv` |
| `TARGET_DATE` | 取得対象日 | 3日前の日付 |
| `ROW_LIMIT` | 1サイトあたりの最大取得行数 | `25000` |

## 4. 処理仕様

### 4.1. 前提チェック

スクリプト開始時に以下を確認する。

- `curl` が利用できること。
- `jq` が利用できること。
- サービスアカウントJSONキーが存在すること。
- サイト・キーワード対応表が存在すること。
- サイト・キーワード対応表が空でないこと。
- 対応表で指定された各キーワードファイルが存在すること。
- 対応表で指定された各キーワードファイルが空でないこと。

エラー時は処理を停止する。

### 4.2. 安全設定

スクリプト冒頭で以下を指定する。

```bash
set -euo pipefail
```

### 4.3. 認証

サービスアカウントJSONキーを使い、Google API 用のOAuth2アクセストークンを取得する。

最小実装では、アクセストークンの長期キャッシュは行わず、実行ごとにトークンを取得してよい。

### 4.4. Search Console API 呼び出し

Google Search Console API の `searchAnalytics.query` を呼び出す。

エンドポイント：

```text
https://searchconsole.googleapis.com/webmasters/v3/sites/{SITE_URL}/searchAnalytics/query
```

リクエスト条件：

- `startDate` と `endDate` は同じ日付にする。
- `dimensions` は最小実装では `query` のみ。
- `rowLimit` はデフォルトで `25000` とする。
- 国フィルターで日本に固定する。
- クエリフィルターは指定しない。
- 対象キーワードとの照合は、API取得後にローカル側で行う。
- 照合は完全一致を優先し、完全一致がない場合は英字の大文字小文字を区別せずに照合する。

リクエスト本文のイメージ：

```json
{
  "startDate": "2026-09-07",
  "endDate": "2026-09-07",
  "rowLimit": 25000,
  "dimensions": ["query"],
  "dimensionFilterGroups": [
    {
      "filters": [
        {
          "dimension": "country",
          "operator": "equals",
          "expression": "jpn"
        }
      ]
    }
  ]
}
```

### 4.5. データ抽出

APIレスポンスから以下を抽出する。

APIレスポンスからは、サイトごとの検索クエリとGSC平均掲載順位を一括で抽出する。その後、サイト別キーワードファイルに記載されたキーワードと照合してログ出力対象にする。

照合は以下の順で行う。

- キーワード文字列の完全一致。
- 完全一致がない場合、英字の大文字小文字を区別しない一致。

| 項目 | 内容 |
| --- | --- |
| `date` | 取得対象日 |
| `site` | Search Console の対象プロパティ |
| `query` | 対象キーワード |
| `position` | Search Console API が返すGSC平均掲載順位 |

対象キーワードのデータが存在しない場合は、`position` に `NA` を入れて出力する。

サービスアカウントからアクセスできないサイトは、API呼び出しを行わず、該当サイトの各キーワードについて `position` に `ERROR` を入れて出力する。

サービスアカウントから見えているSearch Consoleプロパティは、以下で確認できる。

```bash
./check_rank.sh --list-sites
```

## 5. 出力

### 5.1. 履歴ファイル

TSV形式で履歴ファイルへ保存する。

想定ファイル：

```text
data/rank_history.tsv
```

### 5.2. 出力形式

カラム：

```text
date	site	query	position
```

例：

```tsv
2026-09-07	https://example.com/	example keyword	9.1
2026-09-07	https://example.com/	another keyword	1.0
2026-09-07	https://example.com/	missing keyword	NA
2026-09-07	https://example.com/	example keyword	ERROR
```

ヘッダー行は必須ではない。最小実装では、データ行のみを出力してよい。

同じ `date + site + query` の行が既に存在する場合は、重複追記せず、今回取得した行で置き換える。

### 5.3. ターミナル表示

スクリプト実行時は、取得中の進捗を表示する。

表示例：

```text
Authenticating with Google API... done
Checking accessible Search Console sites... done
########## done
```

取得完了後は、今回取得した結果を読みやすい表形式で表示する。

表示要件：

- サイトごとに罫線で区切る。
- 各サイト内では `position` の昇順で表示する。
- `NA` と `ERROR` は順位ありデータの後ろに表示する。

表示例：

```text
Date: 2026-09-07
Sites: config/sites.tsv

--------------------------------------------------------------------------------
Site: https://example.com/
--------------------------------------------------------------------------------
Date          GSC平均掲載順位  Query
------------  --------------  -----
2026-09-07            1.50  example keyword
2026-09-07            9.10  another keyword
2026-09-07              NA  missing keyword
```

## 6. 動作環境

対象環境：

- macOS
- Linux

必要コマンド：

- `bash`
- `curl`
- `jq`
- `openssl`

## 7. エラー処理

以下の場合はエラーメッセージを表示して終了する。

- 必要コマンドが存在しない。
- サービスアカウントJSONキーが存在しない。
- サイト・キーワード対応表が存在しない。
- サイト・キーワード対応表が空。
- 対応表で指定されたキーワードファイルが存在しない。
- 対応表で指定されたキーワードファイルが空。
- アクセストークンの取得に失敗した。
- Search Console API の呼び出しに失敗した。
- APIレスポンスが想定したJSON形式ではない。

## 8. セキュリティ要件

- サービスアカウントJSONキーはスクリプト外部に置く。
- 秘密情報をGit管理しない。
- `.gitignore` に必要な除外設定を追加する。
- サービスアカウントには対象Search Consoleプロパティに必要な最小権限だけを付与する。

## 9. 将来拡張候補

最小実装が動作した後、必要に応じて以下を追加する。

- 直近7日間の順位推移表示。
- cronによる定期実行。
- データなしキーワードの明示的な記録。
- CSV出力。
- グラフ化。
- Slackやメール通知。
- 既存レポートへの統合。

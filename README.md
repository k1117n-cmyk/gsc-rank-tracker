# GSC Rank Checker

Google Search Console APIから指定キーワードのGSC平均掲載順位を取得し、TSV履歴へ保存するシェルスクリプトです。

## Files

- `check_rank.sh`: 実行スクリプト
- `check_rank.md`: 仕様書
- `config/sites.tsv.sample`: サイト設定のサンプル
- `keywords/sample.txt`: キーワード一覧のサンプル

## Setup

```bash
cp config/sites.tsv.sample config/sites.tsv
export SERVICE_ACCOUNT_JSON="/path/to/gsc-service-account.json"
chmod 600 "$SERVICE_ACCOUNT_JSON"
./check_rank.sh --list-sites
./check_rank.sh
```

サービスアカウントJSONキーはリポジトリ外の任意の場所に保存し、`SERVICE_ACCOUNT_JSON` でパスを指定してください。
実サイトURL、監視キーワード、順位履歴、サービスアカウントJSONキーはコミットしないでください。

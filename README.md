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
chmod 600 ~/.secret/gsc-service-account.json
./check_rank.sh --list-sites
./check_rank.sh
```

実サイトURL、監視キーワード、順位履歴、サービスアカウントJSONキーはコミットしないでください。

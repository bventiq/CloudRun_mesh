# MeshCentral on Google Cloud Run

Google Cloud Run 上に MeshCentral をデプロイし、GitHub Actions で自動デプロイを実現する完全な IaC 構成です。

## 特徴

### コスト最適化
- **Scale to Zero**: 使用していない時はインスタンス数 0 になり、課金が発生しません
- **Auto Wake-up**: Cloudflare Worker でブラウザアクセス時に自動起動（約10-20秒）
- **MongoDB Atlas Free Tier**: 無料枠での運用が可能

### セキュリティ
- **Cloudflare Tunnel**: 外部公開ポートなし、Tunnel 経由でのみアクセス
- **Workload Identity Federation**: キーレス認証で GitHub Actions から安全にデプロイ
- **Secret Manager**: 認証情報を Secret Manager で一元管理
- **OIDC 認証**: Auth0 などの OpenID Connect プロバイダーでシングルサインオン

### 開発体験
- **自動デプロイ**: main ブランチに push すると自動的に Cloud Run にデプロイ
- **バージョン管理**: MeshCentral のバージョンを環境変数で一元管理
- **GCS 永続化**: データは GCS バケットに永続化され、再デプロイ時も保持

## アーキテクチャ

```
[ブラウザ/エージェント]
        ↓ HTTPS
[Cloudflare Tunnel (mesh.example.com)]
        ↓ Worker: 起動チェック & Wake-up
        ↓ HTTP (内部)
[Cloud Run (3コンテナ)]
  ├─ ingress-guard (8080) : ダミーエンドポイント
  ├─ meshcentral (3000)   : MeshCentral 本体
  └─ cloudflared          : Tunnel クライアント
        ↓
[GCS Bucket] : 設定・データ永続化
[MongoDB Atlas] : データベース
[Secret Manager] : 認証情報
```

**備考**: MeshCentral コンテナは、起動速度向上のため、公式イメージをベースに必要なモジュール（OIDC等）をプリインストールしたカスタムイメージを使用しています。

## クイックスタート

詳細な手順は [SETUP_GUIDE.md](SETUP_GUIDE.md) を参照してください。

### 前提条件
- Google Cloud Project（無料枠あり）
- Cloudflare アカウント（無料）
- GitHub リポジトリ
- MongoDB Atlas アカウント（無料枠あり）

### デプロイ手順（要約）
1. Workload Identity Federation の設定
2. Secret Manager に認証情報を保存
3. Cloudflare Tunnel の作成と DNS 設定
4. GitHub にコードを push
5. GitHub Actions が自動的にデプロイ

## バージョンアップ

MeshCentral のバージョンを更新するには：

1. GitHub リポジトリの **Settings** > **Secrets and variables** > **Actions** > **Variables** に移動します。
2. `MESHCENTRAL_VERSION` の値を変更します（例: `1.1.57`）。
3. 手動でワークフローを実行するか、空のコミットを push してデプロイをトリガーします。

GitHub Actions が自動的に新しいバージョンをデプロイします。

## ファイル構成

```
CloudRun_mesh/
├── .github/workflows/
│   └── deploy.yml          # GitHub Actions ワークフロー（自動デプロイ）
├── service.yaml            # Cloud Run サービス定義
├── importer.yaml           # Docker イメージインポート設定
├── worker.js               # Cloudflare Worker（自動起動）
├── wrangler.toml           # Worker 設定
├── setup_certs.ps1         # 証明書セットアップスクリプト
├── test-mongo.js           # MongoDB 接続テスト
├── package.json            # Node.js 依存関係
├── README.md               # このファイル
└── SETUP_GUIDE.md          # 詳細セットアップガイド
```

## 主要な設定

### GitHub Actions 環境変数
GitHub リポジトリの **Settings** > **Secrets and variables** > **Actions** > **Variables** で設定：
- `GCP_PROJECT_ID`: Google Cloud プロジェクト ID
- `DOMAIN`: カスタムドメイン
- `MESHCENTRAL_VERSION`: MeshCentral バージョン

**Secrets** で設定（**Repository secrets**）：
- `GCP_WORKLOAD_IDENTITY_PROVIDER`: Workload Identity Provider の ID
- `GCP_SERVICE_ACCOUNT`: Service Account のメールアドレス

### Secret Manager シークレット
以下のシークレットを Secret Manager に保存：
- `mongo-url`: MongoDB 接続文字列
- `cloudflare-token`: Cloudflare Tunnel トークン
- `oidc-client-id`: OIDC クライアント ID（オプション）
- `oidc-client-secret`: OIDC クライアントシークレット（オプション）
- `oidc-issuer`: OIDC Issuer URL（オプション）

### MeshCentral 設定
GCS バケット（`gs://meshcentral-data-{PROJECT_ID}/config.json`）に保存：
- Port: 3000（内部）
- AliasPort: 443（外部）
- TlsOffload: Cloudflare Tunnel で SSL 終端
- certUrl: Cloudflare 証明書を取得

## トラブルシューティング

### エージェントが接続できない
- 新しいエージェントインストーラーをダウンロードしてください
- 古いインストーラーには `:3000` ポートが含まれている可能性があります

### サービスが起動しない

- Cloud Run ログを確認: `gcloud run services logs read meshcentral-server --region us-central1`
- Cloudflare Tunnel が `http://localhost:3000` を指しているか確認

### GitHub Actions がエラーになる
- Workload Identity Federation の設定を確認
- Service Account の権限を確認
- Secret Manager にシークレットが保存されているか確認

## ライセンス

このリポジトリの構成ファイルは MIT License です。
MeshCentral 本体は Apache License 2.0 です。

## 参考リンク

- [MeshCentral 公式ドキュメント](https://ylianst.github.io/MeshCentral/)
- [Google Cloud Run ドキュメント](https://cloud.google.com/run/docs)
- [Cloudflare Tunnel ドキュメント](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)
- [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)

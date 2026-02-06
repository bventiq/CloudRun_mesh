# MeshCentral on Cloud Run - 詳細セットアップガイド

このガイドでは、Google Cloud Run 上に MeshCentral をデプロイし、GitHub Actions で自動デプロイを設定する手順を説明します。
**セキュリティ強化版**: IAM認証と Cloudflare Worker を組み合わせた「Wallet Attack 対策済」構成です。

## 目次
1. [前提条件](#前提条件)
2. [Phase 1: Google Cloud の準備](#phase-1-google-cloud-の準備)
3. [Phase 2: GitHub Actions の設定](#phase-2-github-actions-の設定)
4. [Phase 3: Secret Manager の設定](#phase-3-secret-manager-の設定)
5. [Phase 4: Cloudflare Tunnel の設定](#phase-4-cloudflare-tunnel-の設定)
6. [Phase 5: デプロイ実行](#phase-5-デプロイ実行)
7. [Phase 6: Cloudflare Worker (Authenticated) の設定](#phase-6-cloudflare-worker-authenticated-の設定)

## 前提条件

- **Google Cloud アカウント**
- **Cloudflare アカウント**
- **GitHub アカウント**
- **MongoDB Atlas アカウント**
- **Windows PowerShell** (スクリプト実行用)

---

## Phase 1: Google Cloud の準備

### 1.1 プロジェクトと基本サービス

```powershell
# gcloud ログイン
gcloud auth login
gcloud config set project [YOUR_PROJECT_ID]

# API有効化
gcloud services enable run.googleapis.com secretmanager.googleapis.com iam.googleapis.com artifactregistry.googleapis.com storage.googleapis.com
```

### 1.2 GCS バケット作成

```powershell
gsutil mb -l us-central1 gs://meshcentral-data-[YOUR_PROJECT_ID]
```

---

## Phase 2: GitHub Actions の設定

自動設定スクリプト `setup_gh_secrets.ps1` を使用して、必要な Secrets (Workload Identity) と Variables を GitHub に登録します。

1. `setup_gh_secrets.ps1` を実行し、指示に従ってください。
2. これにより、GitHub Actions から Cloud Run へのデプロイが可能になります。

---

## Phase 3: Secret Manager の設定

MongoDB 接続情報や Cloudflare Token を保存します。

```powershell
# MongoDB
echo -n "mongodb+srv://..." | gcloud secrets create mongo-url --data-file=-

# Cloudflare Token
echo -n "eyJ..." | gcloud secrets create cloudflare-token --data-file=-
```

---

## Phase 4: Cloudflare Tunnel の設定

1. Cloudflare Zero Trust Dashboard で Tunnel (`meshcentral-tunnel`) を作成。
2. **Public Hostname** に `mesh.example.com` -> `http://localhost:3000` を設定。
   - **Service Type**: HTTP (HTTPSではない)
   - **URL**: localhost:3000
3. 取得した Token を `cloudflare-token` Secret に保存します（Phase 3）。

---

## Phase 5: デプロイ実行

1. GitHub にコードを Push します。
2. Actions タブで `Deploy to Cloud Run` ワークフローが成功するのを待ちます。
   - ※初回デプロイ直後は、Cloud Run がまだ `allUsers` を許可していないため（デフォルトSAのままの場合）、アクセスできない場合があります。次のステップで修正します。

---

## Phase 6: Cloudflare Worker (Authenticated) の設定

**重要**: 不正アクセス（Wallet Attack）を防ぐため、Cloud Run は一般公開せず、認証された Worker からのみアクセスを許可します。

### 6.1 Waker SA のセットアップ

スクリプトを実行して、専用の Service Account (`meshcentral-waker`) を作成し、Cloud Run をロックダウンします。

```powershell
./setup_waker_sa.ps1
```

出力される **JSONキー（1行）** をコピーしてください。

### 6.2 Cloudflare Secrets の登録

1. Cloudflare Dashboard > Workers & Pages > `cloudrun-mesh`
2. **Settings** > **Variables and Secrets**
3. 以下の Secret を追加（Encrypt）:
   - **Name**: `GCP_SA_KEY`
   - **Value**: (コピーしたJSONキー)

3. 以下の Variables を追加（または `wrangler.toml` に記述）:
   - `CLOUD_RUN_URL`: (Cloud Run の URL, 例: `https://...run.app`)
   - `WORKER_ROUTE`: (例: `mesh.example.com/*`)
   - `ZONE_NAME`: (例: `example.com`)

   ※ `wrangler.toml.example` をコピーして `wrangler.toml` を作成し、そこに記述しても構いません。

### 6.3 Worker のデプロイ

リポジトリ内の `worker.js` と `wrangler.toml.example` が使用されます。
GitHub 連携している場合、またはローカルから `npx wrangler deploy` でデプロイします。

> **Note**: `wrangler.toml` は `wrangler.toml.example` から `envsubst` 等で生成するか、手動でコピーして環境変数を埋めて使用してください。

---

## 完了

`https://mesh.example.com` にアクセスし、以下を確認してください:

1. サイトが表示される (Tunnel経由)
2. Cloud Run の URL (`...run.app`) に直接アクセスすると **403 Forbidden** になる (セキュリティ成功)

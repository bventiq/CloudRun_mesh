# MeshCentral on Cloud Run - 詳細セットアップガイド

このガイドでは、Google Cloud Run 上に MeshCentral をデプロイし、GitHub Actions で自動デプロイを設定する手順を説明します。

## 目次
1. [前提条件](#前提条件)
2. [Phase 1: Google Cloud の準備](#phase-1-google-cloud-の準備)
3. [Phase 2: GitHub Actions の設定](#phase-2-github-actions-の設定)
4. [Phase 3: Secret Manager の設定](#phase-3-secret-manager-の設定)
5. [Phase 4: Cloudflare Tunnel の設定](#phase-4-cloudflare-tunnel-の設定)
6. [Phase 5: OIDC 認証の設定（オプション）](#phase-5-oidc-認証の設定オプション)
7. [Phase 6: デプロイ実行](#phase-6-デプロイ実行)
8. [Phase 7: Cloudflare Worker の設定](#phase-7-cloudflare-worker-の設定)
9. [トラブルシューティング](#トラブルシューティング)

## 前提条件

以下のアカウントとツールが必要です：

### 必須アカウント
- **Google Cloud アカウント**（無料枠: $300 クレジット）
- **Cloudflare アカウント**（無料プラン OK）
- **GitHub アカウント**（無料プラン OK）
- **MongoDB Atlas アカウント**（無料枠: M0 Sandbox）

### 必須ツール
- **`gcloud` CLI**: [インストール方法](https://cloud.google.com/sdk/docs/install)
  - Windows: インストーラーをダウンロード
  - macOS: `brew install google-cloud-sdk` または公式インストーラー
  - Linux: パッケージマネージャーまたは公式インストーラー

すべての設定は Web ブラウザ（GCP Console、Cloudflare Dashboard、GitHub）で完結します。

---

## Phase 1: Google Cloud の準備

### 1.1 プロジェクトの作成

```bash
# gcloud にログイン
gcloud auth login

# プロジェクトを作成（PROJECT_ID は小文字、数字、ハイフンのみ）
gcloud projects create my-meshcentral-project --name="MeshCentral"

# プロジェクトを設定
gcloud config set project my-meshcentral-project

# 課金を有効化（GCP Console で実施）
```

### 1.2 必要な API を有効化

```bash
gcloud services enable run.googleapis.com \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  artifactregistry.googleapis.com \
  storage.googleapis.com
```

### 1.3 GCS バケットの作成

```bash
# プロジェクト ID を取得
export PROJECT_ID=$(gcloud config get-value project)

# バケットを作成
gsutil mb -l us-central1 gs://meshcentral-data-${PROJECT_ID}
```

---

## Phase 2: GitHub Actions の設定

### 2.1 Workload Identity Pool の作成

```bash
# Workload Identity Pool を作成
gcloud iam workload-identity-pools create github-pool \
  --location=global \
  --display-name="GitHub Actions Pool"

# Provider を作成
gcloud iam workload-identity-pools providers create-oidc github-provider \
  --location=global \
  --workload-identity-pool=github-pool \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.actor=assertion.actor" \
  --attribute-condition="assertion.repository=='YOUR_GITHUB_USERNAME/CloudRun_mesh'"
```

**注意**: `YOUR_GITHUB_USERNAME` を実際の GitHub ユーザー名に置き換えてください。

### 2.2 Service Account の作成と権限付与

```bash
# Service Account を作成
gcloud iam service-accounts create github-actions-sa \
  --display-name="GitHub Actions Service Account"

# 必要な権限を付与
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/run.admin"

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"
```

### 2.3 Workload Identity の紐付け

```bash
# プロジェクト番号を取得
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')

# GitHub からの認証を許可
gcloud iam service-accounts add-iam-policy-binding \
  github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository/YOUR_GITHUB_USERNAME/CloudRun_mesh"
```

---

## Phase 3: Secret Manager の設定

### 3.1 MongoDB Atlas のセットアップ

1. [MongoDB Atlas](https://www.mongodb.com/cloud/atlas/register) にアクセス
2. 無料クラスター（M0 Sandbox）を作成
3. Database Access でユーザーを作成
4. Network Access で `0.0.0.0/0` を許可
5. 接続文字列を取得（例: `mongodb+srv://user:pass@cluster0.xxxxx.mongodb.net/meshcentral`）

### 3.2 シークレットの作成

```bash
# MongoDB URL
echo -n "mongodb+srv://user:pass@cluster0.xxxxx.mongodb.net/meshcentral" | \
  gcloud secrets create mongo-url --data-file=-

```

### 3.3 OIDC シークレット（オプション）

Auth0 などを使用する場合：

```bash
echo -n "YOUR_CLIENT_ID" | \
  gcloud secrets create oidc-client-id --data-file=-

echo -n "YOUR_CLIENT_SECRET" | \
  gcloud secrets create oidc-client-secret --data-file=-

echo -n "https://your-tenant.auth0.com" | \
  gcloud secrets create oidc-issuer --data-file=-
```

---

## Phase 4: Cloudflare Tunnel の設定

このセクションでは、Cloudflare Zero Trust Dashboard を使って Tunnel を作成します。

### 4.1 Tunnel の作成（Dashboard）

1. [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/) にアクセス
2. **Networks** > **Tunnels** を選択
3. **Create a tunnel** をクリック
4. Tunnel 名を入力: `meshcentral-tunnel`
5. **Save tunnel** をクリック
6. **Connector（接続方法）**のセクションで：
   - **Docker** タブを選択
   - 表示される Token（`eyJ...` で始まる長い文字列）をコピー

   **重要**: この Token は後で使用するため、必ず保存してください。

### 4.2 Public Hostname の設定

1. 同じ Tunnel 設定画面で **Public Hostname** タブを選択
2. **Add a public hostname** をクリック
3. 以下を入力:
   - **Subdomain**: `mesh`（あなたのサブドメイン）
   - **Domain**: `example.com`（あなたのドメインを選択）
   - **Service Type**: `HTTP`
   - **URL**: `localhost:3000`

   **重要**: Service Type は必ず `HTTP` を選択してください（`HTTPS` ではありません）

4. **Save hostname** をクリック

DNS レコードが自動的に作成され、`mesh.example.com` が Tunnel に紐付けられます。

### 4.3 Token を Secret Manager に保存

コピーした Token を Google Cloud Secret Manager に保存します：

```bash
# Token を Secret Manager に保存（YOUR_CLOUDFLARE_TOKEN を実際の Token に置き換え）
echo -n "YOUR_CLOUDFLARE_TOKEN" | \
  gcloud secrets create cloudflare-token --data-file=- --replication-policy=automatic
```

---

<details>
<summary>【オプション】cloudflared CLI を使った設定方法</summary>

CLI を使いたい場合は、以下の方法でも Tunnel を作成できます：

**cloudflared のインストール**:
- Windows: [公式リリース](https://github.com/cloudflare/cloudflared/releases) からダウンロード
- macOS: `brew install cloudflared`
- Linux: `wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb && sudo dpkg -i cloudflared-linux-amd64.deb`

**Tunnel の作成**:
```bash
# Cloudflare にログイン
cloudflared tunnel login

# Tunnel を作成
cloudflared tunnel create meshcentral-tunnel

# Token を取得
cloudflared tunnel token meshcentral-tunnel

# DNS を設定
cloudflared tunnel route dns meshcentral-tunnel mesh.example.com
```

その後、Dashboard で Public Hostname を設定してください。
</details>

---

## Phase 5: OIDC 認証の設定（オプション）

### 5.1 Auth0 のセットアップ

1. [Auth0](https://auth0.com/) でアカウント作成
2. Applications > Create Application > Regular Web Application
3. Settings で以下を設定:
   - Allowed Callback URLs: `https://mesh.example.com/auth-oidc-callback`
   - Allowed Logout URLs: `https://mesh.example.com`
   - Allowed Web Origins: `https://mesh.example.com`
4. Client ID と Client Secret をコピー

### 5.2 Secret Manager に保存

```bash
echo -n "YOUR_CLIENT_ID" | gcloud secrets create oidc-client-id --data-file=-
echo -n "YOUR_CLIENT_SECRET" | gcloud secrets create oidc-client-secret --data-file=-
echo -n "https://your-tenant.auth0.com" | gcloud secrets create oidc-issuer --data-file=-
```

---

## Phase 6: デプロイ実行

### 6.1 GitHub リポジトリの準備

```bash
# リポジトリをクローン（または Fork）
git clone https://github.com/YOUR_USERNAME/CloudRun_mesh.git
cd CloudRun_mesh
```

### 6.2 GitHub Secrets と Variables の設定

`deploy.yml` を直接編集するのではなく、GitHub の設定画面で値を登録します。

1. GitHub リポジトリの **Settings** > **Secrets and variables** > **Actions** に移動します。

2. **Variables** (Repository variables) タブで以下を追加：
   - `GCP_PROJECT_ID`: `my-meshcentral-project` (あなたのプロジェクトID)
   - `DOMAIN`: `mesh.example.com` (あなたのドメイン)
   - `MESHCENTRAL_VERSION`: `1.1.56` (または最新版)

3. **Secrets** (Repository secrets) タブで以下を追加：
   - `GCP_WORKLOAD_IDENTITY_PROVIDER`: `projects/YOUR_PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/providers/github-provider`
   - `GCP_SERVICE_ACCOUNT`: `github-actions-sa@YOUR_PROJECT_ID.iam.gserviceaccount.com`

> **Note**: Workload Identity Provider の ID は以下のコマンドで確認できます：
> ```bash
> gcloud iam workload-identity-pools providers describe github-provider \
>   --workload-identity-pool=github-pool \
>   --location=global \
>   --format="value(name)"
> ```

### 6.3 Push してデプロイ

```bash
```bash
# 何も変更しなくても、main ブランチへの push でデプロイが走ります（初回）
# GitHub Actions が Docker イメージをビルド（モジュール追加）してデプロイします
git push origin main

# または空のコミットでトリガー
git commit --allow-empty -m "trigger deploy"
git push origin main
```

GitHub Actions が自動的にデプロイを開始します。

### 6.4 デプロイの確認

GitHub の Actions タブで進行状況を確認できます。成功すると、Cloud Run にサービスがデプロイされます。

---

## Phase 7: Cloudflare Worker の設定

### 7.1 Cloud Run URL の取得

```bash
gcloud run services describe meshcentral-server --region us-central1 --format 'value(status.url)'
```

出力例: `https://meshcentral-server-xxxxx.us-central1.run.app`

### 7.2 Worker のデプロイ（GitHub 連携・自動デプロイ）

1. [Cloudflare Dashboard](https://dash.cloudflare.com/) にログイン
2. Workers & Pages > Create application > Pages > Connect to Git
3. GitHub リポジトリ `CloudRun_mesh` を選択
4. Build settings:
   - **Build command**: `envsubst < wrangler.toml.example > wrangler.toml`
   - **Build output directory**: `/`
   - **Root directory**: `/`
5. **Environment variables** に以下を設定:
   - `CLOUD_RUN_URL`: `https://meshcentral-server-xxxxx.us-central1.run.app`（7.1 で取得した URL）
   - `WORKER_ROUTE`: `mesh.example.com/*`（あなたのドメイン）
   - `ZONE_NAME`: `example.com`（あなたのゾーン名）
6. Save and Deploy をクリック

**自動デプロイ設定完了！**
これで `main` ブランチに push するたびに、`wrangler.toml.example` テンプレートから環境変数が展開され、Worker が自動的にデプロイされます。

> **Note**: `wrangler.toml` はテンプレートから生成されるため `.gitignore` に含まれています。
> 設定の source of truth は `wrangler.toml.example` です。

---

## トラブルシューティング

### エラー: "PERMISSION_DENIED"

```bash
# Service Account の権限を確認
gcloud projects get-iam-policy ${PROJECT_ID} \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:github-actions-sa@${PROJECT_ID}.iam.gserviceaccount.com"
```

必要な権限が不足している場合は Phase 2.2 を再実行してください。

### エラー: "Tunnel が接続できない"

Cloudflare Tunnel の設定を確認：
- Service URL が `http://localhost:3000` になっているか（https ではなく http）
- Token が正しく Secret Manager に保存されているか

```bash
# Secret を確認
gcloud secrets versions access latest --secret=cloudflare-token
```

### エラー: "Agent bad web cert hash"

certUrl 設定を確認：
```bash
# GCS の config.json を確認
gsutil cat gs://meshcentral-data-${PROJECT_ID}/config.json | grep certUrl
```

`"certUrl": "https://mesh.example.com"` が含まれている必要があります。

### ログの確認

```bash
# Cloud Run のログを表示
gcloud run services logs read meshcentral-server --region us-central1 --limit 100

# 特定のエラーを検索
gcloud run services logs read meshcentral-server --region us-central1 | grep -i error
```

---

## 完了！

セットアップが完了しました。`https://mesh.example.com` にアクセスして MeshCentral を使い始めましょう！

### 次のステップ

1. **エージェントのインストール**: MeshCentral の Web UI からエージェントをダウンロード
2. **Cloudflare Access の設定**: 管理画面を保護しつつ、エージェント通信を許可
3. **バックアップの設定**: GCS バケットの定期バックアップを設定

詳細は [README.md](README.md) を参照してください。

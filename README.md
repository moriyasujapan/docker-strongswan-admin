# strongSwan VPN (クライアント証明書 + パスワード) + Web管理画面

IKEv2 で **クライアント証明書 → ユーザ名/パスワード(EAP-MSCHAPv2)** の2段階認証を行う VPN を Docker Compose で構築し、
ブラウザの管理画面 (**React 19 + [Astryx](https://github.com/meta/astryx)**) からユーザの追加・再発行・削除・証明書ダウンロードを行います。

テスト結果とエビデンス(スクリーンショット)は [TEST.md](TEST.md) を参照。

## 構成

```
docker-compose.yml        strongswan + admin(Web管理画面)
docker/                   strongSwan (Debian + swanctl/charon-systemd)
admin/app.py              管理API (Flask)。scripts/ を呼び出すだけの薄い層
admin/frontend/           管理画面 (Vite + React 19 + @astryxdesign/core 0.7.13)
scripts/                  adduser.sh / deluser.sh / moduser.sh / listusers.sh / init-pki.sh
tests/                    run-all.sh (通しテスト) / e2e.sh (VPN接続) / ui/ (Playwright)
docs/evidence/            テスト証跡 (スクリーンショット・ログ)
pki/                      CA秘密鍵・クライアント証明書  ※Git管理外・厳重に保管
swanctl/                  strongSwan設定 (証明書・CRL・users.conf)  ※Git管理外
```

ネットワーク (`192.168.90.0/24`):

| 用途 | アドレス |
|---|---|
| Dockerネットワーク `vpn` / ゲートウェイ | 192.168.90.0/24 / 192.168.90.1 |
| **VPNサーバ(コンテナ)自身** | **192.168.90.10** |
| VPNクライアントへの払い出しプール | 192.168.90.128/25 (.128〜.254) |

## 前提

- Linux ホスト + Docker / Docker Compose v2 / openssl (Node.js は不要。フロントは Docker ビルド内でビルド)
- 固定IPと FQDN (例 `vpn.example.com`) の DNS 登録。グローバルIPがDHCPで変わる環境ではDNSで追従させる
- 開放: **UDP 500 / 4500** (VPN)、**TCP 8443** (管理画面。管理者IPのみ。後述)
- `192.168.90.0/24` が既存のLAN/他のDockerネットワークと重複しないこと

## 1. 構築

### クイックスタート (clone → 実行)

```bash
git clone https://github.com/moriyasujapan/docker-strongswan-admin.git && cd docker-strongswan-admin
./setup.sh --fqdn vpn.example.com     # vpn.env/.env 生成 → PKI生成 → docker compose up → 起動確認
```

`setup.sh` は何度実行しても安全です (既存の鍵・設定は上書きしません)。管理画面のパスワードは初回のみ画面に表示され、`.env` に保存されます。

### 手動で行う場合

```bash
cp vpn.env.example vpn.env      # VPN_FQDN を実FQDNへ (サーバ証明書のSANになる。クライアントの接続先名と一致させる)
cp .env.example .env            # ADMIN_PASSWORD を長いランダム値に (chmod 600 .env)
./scripts/init-pki.sh           # CA / サーバ証明書 / CRL / swanctl.conf を生成
docker compose up -d --build    # strongswan + admin
```

- `init-pki.sh` は既存PKIがあると中断します。FQDN を変える場合は `pki/` `swanctl/` を消してやり直し。
- 管理画面: `https://<ホスト>:8443` (Basic認証 `admin` / `.env` の `ADMIN_PASSWORD`)。証明書は自己署名なので初回は警告が出ます。

### ファイアウォール

```bash
sudo ufw allow 500,4500/udp
sudo ufw allow from <管理者IP> to any port 8443 proto tcp
```

**注意:** Docker の公開ポートは `ufw` の INPUT ルールを通らないため、`ufw allow` だけでは 8443 は絞れません。
`DOCKER-USER` チェーンで制限します (`/etc/ufw/after.rules` に追記すると再起動後も維持):

```
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 8443 --ctdir ORIGINAL -s <管理者IP> -j RETURN
-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 8443 --ctdir ORIGINAL -j DROP
COMMIT
```

クラウドの場合はセキュリティグループでも同様に制限してください。

## 2. 管理画面の使い方

| 操作 | 内容 |
|---|---|
| ユーザ追加 | ユーザ名(英数字 `. _ -` 32文字以内)、パスワード(空欄で自動生成)。完了ダイアログに **VPNパスワード / .p12パスワード** が表示され、**ワンクリックでコピー**できる |
| パスワード表示 | 一覧の「パスワード」ボタンで、VPN パスワードと .p12 パスワードをいつでも再表示・コピーできる (旧版で発行したユーザの .p12 パスワードは「未保存」。再発行で保存される) |
| ダウンロード | `.p12`(証明書+秘密鍵+CA。旧クライアント互換の3DES/SHA1) / 証明書PEM(`<user>.crt.pem`) / 秘密鍵PEM(`<user>.key.pem`) / CA証明書(`ca.crt`) |
| 再発行 | 旧証明書を失効し、新しい証明書とパスワードを発行 (`moduser.sh`) |
| 削除 | 証明書を失効(CRL)し、パスワードを削除 (`deluser.sh`) |

操作は即時にサーバへ反映されます (再起動不要。vici ソケット経由で `swanctl --load-all`)。
CLI でも同じ操作ができます: `./scripts/adduser.sh alice` / `moduser.sh alice` / `deluser.sh alice` / `listusers.sh`。

> VPN パスワードは EAP の仕様上 `swanctl/conf.d/users.conf` に平文で保存されます (サーバが平文を必要とするため)。
> 管理画面コンテナは CA 秘密鍵(`pki/`)をマウントします。管理画面にログインできる人は誰でもユーザを発行できるため、
> アクセス元IPの制限と強い `ADMIN_PASSWORD` を必ず設定してください。docker.sock はマウントしていません。

## 3. クライアント設定

この構成は **証明書とEAPパスワードの両方** を要求する複数ラウンド認証です。

| クライアント | 対応 |
|---|---|
| strongSwan (Android 公式アプリ) / Linux swanctl | ○ |
| Windows 標準 / iOS・macOS 標準VPN | ✕ (証明書+パスワードの同時利用不可) |

### Android (strongSwan アプリ)
1. `ca.crt` と `<user>.p12` を端末に転送し、アプリで p12 をインポート (p12パスワード入力)
2. プロファイル追加: サーバ=FQDN、VPNタイプ=**IKEv2 Certificate + EAP (Username/Password)**
3. ユーザ名/パスワードを入力し、クライアント証明書としてインポートしたものを選択

### Linux (swanctl) の例
```
connections {
  corp {
    version = 2
    remote_addrs = vpn.example.com
    vips = 0.0.0.0
    local  { auth = pubkey;       certs = alice.crt; id = "CN=alice, O=VPN" }  # 証明書のSubjectと完全一致
    local2 { auth = eap-mschapv2; eap_id = alice;    id = alice }
    remote { auth = pubkey; id = vpn.example.com }
    children { corp { remote_ts = 0.0.0.0/0; start_action = start } }
  }
}
secrets { eap-alice { id = alice; secret = "<password>" } }
```
`x509ca/ca.crt`, `x509/alice.crt`, `private/alice.key` を `/etc/swanctl/` に配置。
pubkey側の `id` は証明書 Subject と **属性の順序まで一致** が必要です (`openssl x509 -subject -noout`)。

## 4. 運用

- **CA秘密鍵** (`pki/ca/ca.key`) は管理画面コンテナからアクセスできる状態です。バックアップを別に保管し、`pki/` は Git に入れないこと (`.gitignore` 済み)。
- **CRL** の有効期間は30日。ユーザの再発行/削除のたびに更新されますが、操作がない期間が30日を超えると CRL が期限切れになります。
  手動更新: `cd pki/ca && openssl ca -config ca.cnf -gencrl -out ca.crl && openssl crl -in ca.crl -outform DER -out ../../swanctl/x509crl/ca.crl` → `docker exec strongswan swanctl --load-all`
- **証明書の期限**: クライアント/サーバ証明書は825日。期限前に再発行 (サーバ証明書は `swanctl/x509/server.crt` を差し替え)。
- **VPNプール変更**: `vpn.env` の `VPN_POOL`、`docker-compose.yml` の `VPN_POOL`、`swanctl/swanctl.conf` の `addrs` を揃える。`192.168.90.1` と `.10` を含めないこと。
- クライアントの通信はコンテナで MASQUERADE されるため、同一ネットワーク上の他コンテナからは 192.168.90.10 からの通信に見える。
- 管理画面コンテナは root で動作するため、`pki/` 配下に root 所有のファイルができる。ホストから触るときは `sudo` を使う。

## 5. トラブルシューティング

| 症状 | 確認 |
|---|---|
| VPNに接続できない | UDP500/4500の開放、`docker logs strongswan` |
| `no trusted RSA public key found` | クライアントIDが証明書Subjectと一致しているか(属性順序)、p12が正しいか |
| `EAP authentication failed` | パスワード誤り |
| 失効したはずの証明書で接続できる | CRLに `authKeyId` があるか (`swanctl --list-certs --type x509_crl`)。`ca.cnf` に `crl_extensions=crl_ext` が無い古いPKIは TEST.md の「不具合2」を参照 |
| 接続できるが通信不可 | `net.ipv4.ip_forward`、コンテナのNAT (`iptables -t nat -L`) |
| 管理画面に入れない | 接続元IPが許可されているか (`sudo iptables -S DOCKER-USER`)、`.env` の `ADMIN_PASSWORD` |
| 証明書の名前不一致 | `VPN_FQDN` と接続先名が一致しているか |

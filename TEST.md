# テスト記録 (Astryx 管理画面 + strongSwan)

- 実施日: 2026-11-11
- 環境: Ubuntu 26.04 / Docker 29.1.3 / Compose 2.40.3 / strongSwan (Debian 13 パッケージ) / OpenSSL 3.5
- 管理画面: React 19.3.1 + **@astryxdesign/core 0.7.13** + @astryxdesign/theme-neutral 0.7.13 (Vite 8.3.8)
- ブラウザテスト: Playwright 1.56.0 (Chromium)
- 構成: `VPN_FQDN=vpn.example.com` / サーバ 192.168.90.10 / プール 192.168.90.128/25

## 結果サマリ

| 区分 | 項目数 | 結果 |
|---|---|---|
| 管理画面 UI (Playwright) | 27 | **全て PASS** |
| 管理API 認証/CSRF/入力検証 (curl) | 17 | **全て PASS** |
| クライアント用配布物: Android `.sswan` / Mac 用一式 (構造検証 + 実際に接続) | 24 | **全て PASS** (※実機は別記) |
| CRL 自動更新 | 3 | **全て PASS** |
| ダウンロードファイルの検証 (openssl) / VPN 接続 (UI 発行) | 5 / 8 シナリオ | **期待どおり** |

最終実行: `tests/run-all.sh` → `rc=0`、**PASS 71 件 / FAIL 0 件** (ログ: [docs/run-all.log](docs/run-all.log))。
証跡は [docs/evidence/](docs/evidence/) にあります。

> **Mac は標準の VPN 機能ではなく、Homebrew の strongSwan (`charon-cmd`) で接続します。** Apple 標準クライアントは証明書 + パスワードの
> 2 段階認証(MFA)に対応していないためです ([詳細](#6-mac-の対応と実機iosmacでの確認結果))。Mac 用一式は Linux コンテナ上の本物の `charon-cmd` で
> 接続まで確認しましたが、**Mac の実機では未確認**です。

> **開発中に実際の不具合を6件発見し修正しました** (後述「発見した不具合と修正」)。いずれも修正後の最終実行で確認済みです。

## 再実行方法

```bash
docker compose up -d --build        # init-pki.sh 済み / .env 設定済みであること
./tests/run-all.sh                  # 全テスト。結果は docs/evidence/ に保存 (秘密鍵・p12は保存しない)
# 個別: tests/ui/run.sh A|B|C|D [user]  tests/api-security.sh  tests/mobile-profiles.sh  tests/crl-refresh.sh  tests/e2e.sh <user...>
```

テストは `uitest` / `profuser` と、旧形式(SANなし)の証明書を持つ使い捨てユーザ(`legacy*`)を自分で作成し、終了時に削除します (既存ユーザには触れません。既存ユーザの有無に依存しません)。

---

## 1. 管理画面 UI (Astryx + Playwright)

実ブラウザ(Chromium)で `https://localhost:8443` を操作。テストコード: [tests/ui/ui-test.mjs](tests/ui/ui-test.mjs)

使用した Astryx コンポーネント: `Theme` / `Stack` / `Heading` / `Text` / `Button` / `TextInput` / `Table` / `Dialog` / `AlertDialog` / `Banner` / `Code` / `Badge`

### フェーズ A: 追加・コピー・ダウンロード

| # | 確認内容 | 結果 |
|---|---|---|
| A-1 | 既存ユーザの一覧表示 | PASS |
| A-2 | 不正なユーザ名 (`bad name!`) でエラーバナー表示 | PASS |
| A-3 | 追加後に VPN パスワード(16文字)/ .p12 パスワード(12文字)がダイアログ表示 | PASS |
| A-4 | **VPN パスワードのコピー**ボタン → クリップボードの内容が一致 | PASS |
| A-5 | **.p12 パスワードのコピー**ボタン → クリップボードの内容が一致 | PASS |
| A-6 | ダウンロード `.p12` (ファイル名 `uitest.p12`) | PASS |
| A-7 | ダウンロード 証明書PEM (`uitest.crt.pem`) | PASS |
| A-8 | ダウンロード 秘密鍵PEM (`uitest.key.pem`) | PASS |
| A-9 | PEM 証明書が `BEGIN CERTIFICATE` で始まる | PASS |
| A-10 | PEM 秘密鍵が `BEGIN PRIVATE KEY` で始まる | PASS |
| A-11 | p12 が DER 形式 (先頭 0x30) | PASS |
| A-12 | 一覧に新規ユーザが表示される | PASS |
| A-13 | 一覧行からの `.p12` ダウンロード | PASS |
| A-14 | `ca.crt` のダウンロード | PASS |
| A-15 | CA 証明書が `BEGIN CERTIFICATE` で始まる | PASS |
| A-16 | **パスワード再表示**: ダイアログを閉じた後、一覧の「パスワード」ボタンで VPN パスワードが追加時と一致 | PASS |
| A-17 | 再表示: .p12 パスワードが追加時と一致 | PASS |
| A-18 | 再表示: コピーボタンで取得した値が一致 | PASS |

### フェーズ D: 認証情報付きURL (回帰テスト)

`https://admin:<password>@host:8443/` のようにURLへ認証情報を埋め込んで開くと、ブラウザの制約で相対パスの `fetch` が
`Request cannot be constructed from a URL that includes credentials` で失敗する不具合があった。修正後の確認。

| # | 確認内容 | 結果 |
|---|---|---|
| D-1 | 認証情報付きURLで開いても一覧が表示される | PASS |
| D-2 | エラーバナー/ページエラーが出ない | PASS |
| D-3 | 表示後、URLから認証情報が除去される (履歴・ブックマークに残さない) | PASS |

### フェーズ B / C: 再発行・削除

| # | 確認内容 | 結果 |
|---|---|---|
| B-1 | 再発行の確認ダイアログ → 実行 → **パスワードが変わる** | PASS |
| C-1 | 削除の確認ダイアログ → 実行 → 一覧から消える | PASS |

### スクリーンショット

| 画面 | 画像 |
|---|---|
| 一覧 | ![一覧](docs/evidence/01-list.png) |
| 不正なユーザ名 | ![エラー](docs/evidence/02-invalid-username.png) |
| 追加完了 (パスワード表示) | ![追加完了](docs/evidence/03-issued-dialog.png) |
| コピー後 (「コピーしました」) | ![コピー](docs/evidence/04-copied.png) |
| 追加後の一覧 | ![追加後](docs/evidence/05-list-after-add.png) |
| パスワード再表示 | ![再表示](docs/evidence/05b-redisplay.png) |
| 再発行の確認 | ![再発行確認](docs/evidence/06-reissue-confirm.png) |
| 再発行完了 | ![再発行](docs/evidence/07-reissued.png) |
| 削除の確認 | ![削除確認](docs/evidence/08-delete-confirm.png) |
| 削除後の一覧 | ![削除後](docs/evidence/09-after-delete.png) |
| 認証情報付きURLで開いた場合 | ![URL認証](docs/evidence/10-url-credentials.png) |

※ スクリーンショットに写るパスワードはテスト用ユーザ `uitest` のもので、テスト終了時に失効・削除済みです。

---

## 2. ダウンロードファイルの検証 (openssl)

UI からダウンロードしたファイルを openssl で検証。証跡: [openssl-check.txt](docs/evidence/openssl-check.txt)

| 確認内容 | 結果 |
|---|---|
| ダウンロードした証明書が、ダウンロードした `ca.crt` で検証できる | OK |
| Subject=`CN=uitest, O=VPN`、EKU=`TLS Web Client Authentication`、期限 825日 | OK |
| 秘密鍵PEMと証明書の公開鍵が一致 | MATCH |
| p12 が正しいパスワードで開け、方式が 3DES/SHA1 (旧OS/古いクライアントとの互換用) | OK |
| p12 を誤パスワードで開くと `Mac verify error: invalid password?` | OK |

---

## 3. 管理API の認証・CSRF・入力検証 (curl)

テスト: [tests/api-security.sh](tests/api-security.sh) / 証跡: [api-security.txt](docs/evidence/api-security.txt)

| 確認内容 | 期待 | 結果 |
|---|---|---|
| 認証なし | 401 | PASS |
| 誤パスワード | 401 | PASS |
| 正しい認証で一覧取得 | 200 | PASS |
| CSRF: `X-Requested-With` 無しの POST | 403 | PASS |
| CSRF: 別オリジン(`Origin: https://evil.example`)からの POST | 403 | PASS |
| CSRF: ヘッダ無しの DELETE | 403 | PASS |
| 不正なユーザ名 (`a b;rm -rf`) | 400 | PASS |
| 短すぎるパスワード | 400 | PASS |
| パストラバーサル (`/dl/..%2f..%2fca%2fca.key`) | 404 | PASS |
| CA秘密鍵のダウンロード (`/dl/alice.cakey`) | 404 | PASS |
| 存在しないユーザのダウンロード | 404 | PASS |
| 認証情報API (`/api/users/<u>/credentials`): 認証なし | 401 | PASS |
| 同: 存在しないユーザ | 404 | PASS |
| 同: 不正なユーザ名 (`..%2fca`) | 404 | PASS |
| 同: 既存ユーザ | 200 | PASS |
| 旧版で発行したユーザ(alice): VPNパスワードは取得でき、.p12 パスワードは未保存 (`null`) | 一致 | PASS |
| `Content-Security-Policy: script-src 'self'` ヘッダ | あり | PASS |

---

## 4. VPN 接続テスト (UI で発行した資格情報)

別コンテナの swanctl クライアントから `192.168.90.10` へ接続 (証明書 + EAP-MSCHAPv2)。ログは `docs/evidence/vpn-login-*.log`。

| # | シナリオ | 期待 | 結果 | 証跡 |
|---|---|---|---|---|
| V-1 | UIで追加した直後のユーザ (正しい証明書+パスワード) | 接続成功 | **成功** (IKE_SA/CHILD_SA established、プールからIP払い出し) | [vpn-login-A.log](docs/evidence/vpn-login-A.log) |
| V-2 | 同 (正しい証明書 + 誤パスワード) | 拒否 | **拒否** (`EAP-MS-CHAPv2 ... ERROR_AUTHENTICATION_FAILURE`) | 同上 |
| V-3 | UIで再発行後の新しい証明書+新パスワード | 接続成功 | **成功** | [vpn-login-B.log](docs/evidence/vpn-login-B.log) |
| V-4 | 再発行後の証明書 + 誤パスワード | 拒否 | **拒否** | 同上 |
| V-5 | **再発行で失効した旧証明書** (パスワードは有効) | 拒否 | **拒否** (サーバログ `certificate was revoked on ...`) | [vpn-login-revoked-cert.log](docs/evidence/vpn-login-revoked-cert.log), [server-revocation.log](docs/evidence/server-revocation.log) |
| V-6 | UIで削除したユーザ (証明書+パスワード) | 拒否 | **拒否** | [vpn-login-deleted-user.log](docs/evidence/vpn-login-deleted-user.log) |
| V-7 | 削除後のサーバ状態: `listusers` から消える、`users.conf` に `eap-uitest` なし、接続定義 `rw` が残る | 一致 | **一致** | [server-after-delete.txt](docs/evidence/server-after-delete.txt) |
| V-8 | 既存ユーザ (alice/bob/carol/dave) は UI 操作の影響を受けない | 変化なし | 一覧に残存 (V-7) | 同上 |

---

## 5. 発見した不具合と修正

実際にテストして初めて分かった問題です。

### 不具合1: 管理画面からのユーザ追加で VPN サーバの設定が消える (重大)

- **症状**: UIでユーザ追加した直後、サーバログに `removed vici connection: rw` が出て、以後 `no IKE config found` で全員接続不可。
- **原因**: 管理画面コンテナの `swanctl --load-all` は自身の `/etc/swanctl`(空)を読み、「設定なし」としてサーバ側の設定を全てアンロードした。設定は `/app/swanctl` にマウントしていた。
- **修正**: `admin/Dockerfile` で `/etc/swanctl` → `/app/swanctl` のシンボリックリンクにした。
- **確認**: 管理画面コンテナからの `--load-all` で全ユーザの秘密と `rw` がロードされ、UI追加後も接続成功 (V-1)。

### 不具合2: 失効した証明書で接続できてしまう (重大)

- **症状**: 失効済み証明書でも接続成功。サーバログは `certificate status is not available`。
- **原因**: OpenSSL が出力する CRL に Authority Key Identifier (AKI) が無く、strongSwan が CRL と発行元 CA を結び付けられなかった (`swanctl --list-certs --type x509_crl` の `authKeyId` が空)。
- **修正**: `ca.cnf` に `crl_extensions=crl_ext` / `authorityKeyIdentifier=keyid:always` を追加 (`init-pki.sh` も同様)。
- **確認**: `authKeyId` が入り、失効済みは `certificate was revoked on ...` で拒否 (V-5)。
- **既存PKIの場合**: `ca.cnf` に上記を追記し、CRL を再生成して `swanctl --load-all`。

### 不具合3: 古い CRL がキャッシュされ、新しい失効が反映されない

- **症状**: 再発行で失効させた証明書で接続できる (CRL は更新済み)。
- **原因**: サーバ側に過去の CRL がキャッシュとして残り (同一発行元の CRL が2つ存在)、失効判定に古い方が使われた。
- **修正**: `scripts/common.sh` の `reload()` で `swanctl --flush-certs --type x509_crl` を実行してから `--load-all`。
- **確認**: 再発行・削除の直後に旧証明書が拒否される (V-5, V-6)。

### 不具合4: ユーザの再発行・削除・CRL更新がすべて失敗する (重大 / 自分の変更による回帰)

- **症状**: 管理画面の「再発行」「削除」が `処理に失敗しました` で失敗 (CRL の定期更新も失敗)。
- **原因**: iOS/Mac 用にクライアント証明書へ SAN を入れるため `ca.cnf` に `subjectAltName=$ENV::CLIENT_SAN` を追加した。
  OpenSSL は **どのコマンドでも設定ファイル全体を展開**するため、`CLIENT_SAN` を設定しない `openssl ca -gencrl` / `-revoke`
  が `variable has no value` で失敗した (ユーザ追加だけは変数を渡すので成功)。
- **修正**: `ca.cnf` から環境変数参照を除去し、SAN はユーザごとの拡張ファイル (`-extfile`) で渡す。
- **確認**: 再発行・削除・CRL 自動更新を含む通しテストが PASS。ユーザが管理画面で再発行を試して失敗に気づいた。
- **反省**: SAN 変更の直後に通しテストを回さなかった。以降は変更のたびに `tests/run-all.sh` を実行する。

### 不具合5: テストが「既存ユーザ alice の存在」に依存していた

- **症状**: ユーザが alice 等を削除した後、通しテストの一部が失敗 (旧形式証明書ユーザを alice で代用していたため)。
- **修正**: テストが旧形式(SANなし)ユーザを自分で作成・削除する (`tests/legacy-user.sh`、`ADDUSER_NO_SAN=1` のテスト用フック)。

### 不具合6: 認証情報付きURLで開くと画面が動かない

- 上記「フェーズ D」参照 (`Request cannot be constructed from a URL that includes credentials`)。API 呼び出しを `location.origin` 基準にして修正。

### そのほか

- 認証情報をURLに埋め込んで開くと `fetch` が失敗する (`Request cannot be constructed from a URL that includes credentials`)。API 呼び出しを `location.origin` 基準にし、表示後にURLから認証情報を除去するよう修正 (フェーズ D)。URLに認証情報を入れる使い方自体は、履歴等に残るため推奨しない。
- Astryx のテーマは `default` ではなく名前付きエクスポート (`import { neutralTheme } from '@astryxdesign/theme-neutral/built'`)。ビルドエラーで判明。
- Astryx の `Dialog` / `AlertDialog` は `role=dialog` ではなくネイティブの `<dialog>` 要素。テストでは `dialog[open]` で取得。
- `adduser.sh` の `reload` が、docker グループ外のユーザで失敗しても黙って成功扱いにしていた。失敗の表示と `sudo docker` へのフォールバックを追加。
- `.p12` は OpenSSL 3 の既定 (AES-256/PBKDF2) だと古い macOS/Windows/Android で開けないことがあるため、3DES/SHA1 (`-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1`) で書き出す。

---

## 5.2 クライアント用配布物: Android (.sswan) と Mac 用一式

テスト: [tests/mobile-profiles.sh](tests/mobile-profiles.sh) / 証跡: [mobile-profiles.txt](docs/evidence/mobile-profiles.txt)

**Android** (strongSwan アプリ用 `.sswan`。形式は公式の [プロファイル仕様](https://docs.strongswan.org/docs/latest/os/androidVpnClientProfiles.html))

| 確認内容 | 結果 |
|---|---|
| `.sswan` をダウンロードできる (HTTP 200、未認証は401)。旧形式(SANなし)の証明書のユーザでも生成できる | PASS |
| JSON、`type=ikev2-cert-eap`、`remote.addr`=接続先(`VPN_ADDR`)、`remote.id`=FQDN、`local.eap_id`=ユーザ名、uuid が v4 | PASS |
| 埋め込み CA が `ca.crt` と一致、`.p12` が `.p12` パスワードで開ける、パスワードは埋め込まない | PASS |
| `.sswan` の値だけを使った swanctl クライアントで接続成功 / 誤パスワードは拒否 | PASS |

**Mac** (Homebrew の strongSwan 用の接続一式 `vpn-<user>-mac.tar.gz`: `ca.crt` / 証明書 / 秘密鍵 / `connect.sh` / `README.txt`)

| 確認内容 | 結果 |
|---|---|
| 一式をダウンロードできる (HTTP 200、未認証は401)、内容が揃っている | PASS |
| 同梱の CA が `ca.crt` と一致し証明書を検証できる、秘密鍵が証明書と対応 | PASS |
| `connect.sh` は `charon-cmd --profile ikev2-pub-eap` (証明書 → EAP の 2 段階)、接続先=`VPN_ADDR`、識別名=FQDN | PASS |
| VPN パスワードを同梱していない。接続時に `EAP password:` の入力を求める | PASS |
| **同梱の `connect.sh` を本物の `charon-cmd` で実行して接続成功** (証明書認証 → パスワード → 仮想IP払い出し) | **成功** |
| 同: 誤パスワードは拒否 | PASS |
| iOS/Mac 標準クライアント用 `.mobileconfig` は提供しない (404) | PASS |

**注意:** 接続の確認は Linux コンテナ上の `charon-cmd` (Debian 版 strongSwan 6.0.1) で行った。Mac の実機 (Homebrew 版、カーネルは PF_KEY/pfroute) と
Android の実機では未確認。テスト用コンテナでは Debian の `kernel-libipsec` プラグインがカーネル IPsec と競合するため無効にしている (Homebrew 版には含まれない)。

## 5.5 CRL の自動更新

CRL の有効期間(30日)が切れないよう、管理画面コンテナが定期的に CRL を再発行してサーバへ反映する (既定24時間、`CRL_REFRESH_HOURS`)。
テスト: [tests/crl-refresh.sh](tests/crl-refresh.sh) (更新間隔を約14秒にして50秒待つ) / 証跡: [crl-refresh.txt](docs/evidence/crl-refresh.txt)

| 確認内容 | 結果 |
|---|---|
| 自動更新が繰り返し実行される (CRL番号 0x1014 → 0x1017、3回) | PASS |
| サーバが最新のCRLを保持する (サーバ側 10:17 = ファイル側) | PASS |
| サーバ上のCRLが1つだけ (古いCRLが残らない) | PASS |

※ この項目は上の通しテスト(40件)の実行後に追加したもので、単体で実行した結果。`tests/run-all.sh` には組み込み済み。
※ テスト作成時に、`sudo` が環境変数を落とすため短い間隔の指定が効いておらず「更新が1回しか起きない」ことを見逃しかけた。`sudo env VAR=... docker compose` で渡すよう修正し、複数回の更新まで確認している。

---

## 6. Mac の対応と、実機(iOS/Mac)での確認結果

**結論: Apple 標準の VPN クライアントでは、証明書 + パスワードの MFA はできない。Mac は Homebrew の strongSwan で接続する。**

経緯:

1. 最初に `.mobileconfig` (`AuthenticationMethod=Certificate` + `ExtendedAuthEnabled=1` + 証明書) を作り、ユーザが実機に取り込んで接続を試した。サーバ側のログ
   ([docs/ios-real-device-server-log.txt](docs/ios-real-device-server-log.txt)、クライアントIPは伏せ字):

   ```
   IKE_AUTH request 1 [ IDi N(INIT_CONTACT) CERTREQ IDr CPRQ(...) SA TSi TSr N(MOBIKE_SUP) ]   ← CERT も AUTH も無い
   peer requested EAP, config unacceptable
   ```

   端末は証明書認証を行わず、EAP のみを要求した。端末の設定画面でも、認証方式は「証明書」か「ユーザ名」のどちらかしか選べなかった。
2. strongSwan 公式の [Apple プロファイル解説](https://docs.strongswan.org/docs/latest/interop/appleIkev2Profile.html) で裏付けが取れた:
   `Certificate` + `ExtendedAuthEnabled=1` は、証明書があれば **EAP-TLS**、無ければ **EAP-MSCHAPv2** になる。両方を順に行う設定は無い。
3. 「Mac だけ証明書のみで接続」案は、MFA 必須の方針に反するため不採用 (実装を取り消し済み)。
4. 採用: **Mac に strongSwan 本体を入れ (`brew install strongswan`)、`charon-cmd --profile ikev2-pub-eap` で接続する。** サーバの 2 段階認証は変更しない。
   管理画面の「Mac」ボタンで接続一式をダウンロードできる (5.2 参照)。

制約: iPhone / iPad には使えない。Mac の実機での確認は未実施。

## 7. 未実施・制約 (正直な記録)

- **実機クライアント**: Android の strongSwan アプリでの `.sswan` の取り込みと接続、Mac 実機 (Homebrew 版) での `connect.sh` は未確認。iPhone / iPad は MFA では接続できない。Windows は未確認。
- **インターネット到達性**: VPN 接続後の実トラフィック (NAT 経由の外部通信) は未確認。
- **管理画面の外部遮断**: 8443 を許可IP以外から遮断する設定 (ufw + `DOCKER-USER`) は入れたが、許可外の回線からの接続拒否は未検証 (ホスト自身からの通信は `DOCKER-USER` を通らないため、この環境内では検証できない)。
- **再起動後の復旧**: ホスト再起動後の自動復旧は未確認。
- **失効ログの読み方**: `server-revocation.log` には、今回の証明書以外の失効エントリを含む行が複数出る。拒否の結果自体は V-5 のとおりだが、複数行が出る理由は未調査。
- **パスワードの保管**: VPN パスワードは EAP の仕様上 `users.conf` に平文、.p12 パスワードは `pki/clients/<user>/<user>.p12pass` に保存される (再表示のため)。旧版で発行したユーザの .p12 パスワードは保存されていないため、再発行するまで再表示できない。
- **CRL 期限**: 自動更新(24時間ごと)で対応済み。ただし管理画面コンテナが30日以上停止し続けた場合は期限切れになる。
- **負荷・同時操作**: 管理画面からの同時操作は排他ロックで直列化しているが、並行負荷のテストはしていない。Flask の開発サーバで動作している。
- **UI の自動テスト範囲**: モバイル幅・ダークモードは未検証 (`Theme mode` は system)。

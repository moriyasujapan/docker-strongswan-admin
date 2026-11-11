import hmac, os, re, subprocess, threading, time
from datetime import datetime
from flask import Flask, Response, abort, jsonify, request, send_file, send_from_directory

ROOT = "/app"
PKI, SCRIPTS = f"{ROOT}/pki", f"{ROOT}/scripts"
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ["ADMIN_PASSWORD"]
USER_RE = re.compile(r"^[A-Za-z0-9._-]{1,32}$")
PW_RE = re.compile(r"^[A-Za-z0-9!@#%^*_+=.,:-]{8,64}$")
STATIC = f"{ROOT}/static"
lock = threading.Lock()
app = Flask(__name__)


@app.before_request
def guard():
    a = request.authorization
    ok = a and hmac.compare_digest(a.username or "", ADMIN_USER) and hmac.compare_digest(a.password or "", ADMIN_PASSWORD)
    if not ok:
        time.sleep(1)
        return Response("認証が必要です", 401, {"WWW-Authenticate": 'Basic realm="VPN admin"'})
    if request.method in ("POST", "PUT", "DELETE", "PATCH"):  # CSRF対策: 同一オリジン + カスタムヘッダ
        if request.headers.get("X-Requested-With") != "vpn-admin":
            abort(403)
        o = request.headers.get("Origin") or request.headers.get("Referer") or ""
        if not re.match(rf"^https://{re.escape(request.host)}(/|$)", o):
            abort(403)


@app.after_request
def headers(r):
    r.headers["Cache-Control"] = "no-store"
    r.headers["X-Frame-Options"] = "DENY"
    r.headers["Content-Security-Policy"] = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' data:; connect-src 'self'; form-action 'none'; frame-ancestors 'none'"
    return r


def run(script, *args):
    with lock:
        p = subprocess.run([f"{SCRIPTS}/{script}", *args], capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout, p.stderr


def users():
    rc, out, _ = run("listusers.sh")
    res = []
    for u in out.split():
        exp = ""
        crt = f"{PKI}/clients/{u}/{u}.crt"
        if os.path.exists(crt):
            o = subprocess.run(["openssl", "x509", "-enddate", "-noout", "-in", crt], capture_output=True, text=True).stdout
            try:
                exp = datetime.strptime(o.strip().split("=")[1], "%b %d %H:%M:%S %Y %Z").strftime("%Y-%m-%d")
            except Exception:
                pass
        res.append((u, exp))
    return res


def issued(user, out):
    pw = re.search(r"^パスワード: (.+)$", out, re.M)
    p12 = re.search(r"p12パスワード: (\S+)\)", out)
    return {"user": user, "pw": pw and pw.group(1), "p12pw": p12 and p12.group(1)}


def fail(rc_out_err, status=400):
    _, out, err = rc_out_err
    return jsonify(error=(err or out).strip() or "処理に失敗しました"), status


@app.get("/api/users")
def api_list():
    return jsonify(users=[{"user": u, "expires": e} for u, e in users()])


@app.post("/api/users")
def api_add():
    d = request.get_json(silent=True) or {}
    u, pw = str(d.get("user", "")).strip(), str(d.get("pw") or "").strip()
    if not USER_RE.match(u):
        return jsonify(error="ユーザ名は英数字 . _ - の32文字以内"), 400
    if pw and not PW_RE.match(pw):
        return jsonify(error="パスワードは8〜64文字、英数字と !@#%^*_+=.,:- のみ"), 400
    r = run("adduser.sh", u, *([pw] if pw else []))
    return jsonify(issued(u, r[1])) if r[0] == 0 else fail(r)


@app.post("/api/users/<u>/reissue")
def api_reissue(u):
    if not USER_RE.match(u):
        abort(400)
    r = run("moduser.sh", u)
    return jsonify(issued(u, r[1])) if r[0] == 0 else fail(r)


@app.get("/api/users/<u>/credentials")
def api_credentials(u):
    if not USER_RE.match(u) or u not in [x for x, _ in users()]:
        abort(404)
    conf = open(f"{ROOT}/swanctl/conf.d/users.conf", encoding="utf-8").read()
    m = re.search(r'\n    id = "?' + re.escape(u) + r'"?\n\s*secret = "([^"\n]*)"', conf)
    if not m:
        abort(404)
    p12pw = None
    try:
        p12pw = open(f"{PKI}/clients/{u}/{u}.p12pass", encoding="utf-8").read().strip() or None
    except OSError:
        pass
    return jsonify(user=u, pw=m.group(1), p12pw=p12pw)


@app.delete("/api/users/<u>")
def api_delete(u):
    if not USER_RE.match(u):
        abort(400)
    r = run("deluser.sh", u)
    return jsonify(ok=True) if r[0] == 0 else fail(r)


@app.get("/")
def index():
    return send_from_directory(STATIC, "index.html")


@app.get("/assets/<path:f>")
def assets(f):
    return send_from_directory(f"{STATIC}/assets", f)


PROFILES = {"sswan": ("android", "application/vnd.strongswan.profile")}


@app.get("/dl/<u>.<ext>")
def download(u, ext):
    if not USER_RE.match(u) or ext not in ("p12", "crt", "key", "tgz", *PROFILES) or u not in [x for x, _ in users()]:
        abort(404)
    if ext == "tgz":  # Mac 用の接続一式 (Homebrew の strongSwan / charon-cmd)
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            out_path = f"{td}/b.tgz"
            rc, out, err = run("mkmacbundle.sh", u, out_path)
            if rc != 0:
                return Response((err or out).strip() or "生成に失敗しました", 500, mimetype="text/plain; charset=utf-8")
            data = open(out_path, "rb").read()
        return Response(data, mimetype="application/gzip",
                        headers={"Content-Disposition": f'attachment; filename="vpn-{u}-mac.tar.gz"'})
    if ext in PROFILES:  # Android strongSwan (.sswan)
        kind, mime = PROFILES[ext]
        rc, out, err = run("mkprofile.sh", kind, u)
        if rc == 2:
            return Response(err.strip(), 409, mimetype="text/plain; charset=utf-8")
        if rc != 0:
            return Response((err or out).strip() or "生成に失敗しました", 500, mimetype="text/plain; charset=utf-8")
        return Response(out, mimetype=mime, headers={"Content-Disposition": f'attachment; filename="{u}.{ext}"'})
    path = f"{PKI}/clients/{u}/{u}.{ext}"
    if not os.path.isfile(path):
        abort(404)
    name = {"p12": f"{u}.p12", "crt": f"{u}.crt.pem", "key": f"{u}.key.pem"}[ext]
    return send_file(path, as_attachment=True, download_name=name)


@app.get("/ca.crt")
def dl_ca():
    return send_file(f"{PKI}/ca/ca.crt", as_attachment=True, download_name="ca.crt")


def crl_refresher():
    """CRLを定期的に再発行する (既定24時間ごと。CRLの有効期間は30日)"""
    hours = float(os.environ.get("CRL_REFRESH_HOURS", "24"))
    time.sleep(15)  # strongswan の起動を待つ
    while True:
        try:
            rc, out, err = run("refresh-crl.sh")
            print(("[crl] " + out.strip()) if rc == 0 else ("[crl] 失敗: " + (err or out).strip()), flush=True)
        except Exception as e:  # 失敗しても次回に再試行
            print(f"[crl] 例外: {e}", flush=True)
        time.sleep(max(hours, 0.001) * 3600)


if __name__ == "__main__":
    threading.Thread(target=crl_refresher, daemon=True).start()
    tls = "/data/tls"
    os.makedirs(tls, exist_ok=True)
    if not os.path.exists(f"{tls}/key.pem"):
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "3650", "-keyout", f"{tls}/key.pem",
                        "-out", f"{tls}/crt.pem", "-subj", "/CN=vpn-admin"], check=True, capture_output=True)
        os.chmod(f"{tls}/key.pem", 0o600)
    app.run("0.0.0.0", 8443, ssl_context=(f"{tls}/crt.pem", f"{tls}/key.pem"), threaded=True)

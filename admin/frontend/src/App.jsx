import React, { useCallback, useEffect, useState } from 'react';
import { Stack } from '@astryxdesign/core/Stack';
import { Heading } from '@astryxdesign/core/Heading';
import { Text } from '@astryxdesign/core/Text';
import { Button } from '@astryxdesign/core/Button';
import { TextInput } from '@astryxdesign/core/TextInput';
import { Table, proportional } from '@astryxdesign/core/Table';
import { AlertDialog } from '@astryxdesign/core/AlertDialog';
import { Dialog } from '@astryxdesign/core/Dialog';
import { Banner } from '@astryxdesign/core/Banner';
import { Code } from '@astryxdesign/core/Code';
import { Badge } from '@astryxdesign/core/Badge';
import { listUsers, addUser, reissueUser, deleteUser, getCredentials, dlUrl } from './api.js';

async function copyText(text) {
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch { /* fall through */ }
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  const ok = document.execCommand('copy');
  document.body.removeChild(ta);
  return ok;
}

function CopyField({ label, value, id }) {
  const [done, setDone] = useState(false);
  return (
    <Stack direction="horizontal" gap={2} align="center" wrap="wrap">
      <Text weight="semibold">{label}</Text>
      <Code data-testid={id}>{value}</Code>
      <Button
        label={done ? 'コピーしました' : 'コピー'}
        size="sm"
        data-testid={`copy-${id}`}
        onClick={async () => {
          if (await copyText(value)) {
            setDone(true);
            setTimeout(() => setDone(false), 1500);
          }
        }}
      />
    </Stack>
  );
}

function Downloads({ user, onError }) {
  // プロファイル(.mobileconfig/.sswan)は生成に失敗することがある(旧証明書など)ので、先にHEADで確認して理由を表示する
  const checkedDownload = async (ext) => {
    try {
      const r = await fetch(window.location.origin + dlUrl(user, ext), { method: 'HEAD' });
      if (r.status === 409) { onError && onError('この証明書は旧形式(SANなし)のため iOS/Mac 用プロファイルを作れません。「再発行」してください'); return; }
      if (!r.ok) { onError && onError(`ダウンロードに失敗しました (HTTP ${r.status})`); return; }
    } catch (e) { onError && onError(e.message); return; }
    window.location.href = dlUrl(user, ext);
  };
  const link = (ext, text, checked) => (
    <Button
      key={ext}
      label={text}
      size="sm"
      onClick={() => (checked ? checkedDownload(ext) : (window.location.href = dlUrl(user, ext)))}
      data-testid={`dl-${user}-${ext}`}
    />
  );
  return (
    <Stack direction="horizontal" gap={1} wrap="wrap">
      {link('p12', '.p12')}
      {link('crt', '証明書 PEM')}
      {link('key', '秘密鍵 PEM')}
      {link('mobileconfig', 'iOS/Mac (2段階認証は不可)', true)}
      {link('sswan', 'Android', true)}
    </Stack>
  );
}

export default function App() {
  const [users, setUsers] = useState([]);
  const [name, setName] = useState('');
  const [pw, setPw] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [issued, setIssued] = useState(null); // {user, what, pw, p12pw}
  const [confirm, setConfirm] = useState(null); // {kind:'delete'|'reissue', user}

  const refresh = useCallback(async () => {
    try { setUsers((await listUsers()).users); } catch (e) { setError(e.message); }
  }, []);
  useEffect(() => { refresh(); }, [refresh]);

  const run = async (fn, what) => {
    setBusy(true); setError('');
    try {
      const r = await fn();
      if (r && r.pw) setIssued({ ...r, what });
      await refresh();
      return true;
    } catch (e) { setError(e.message); return false; } finally { setBusy(false); }
  };

  const columns = [
    { key: 'user', header: 'ユーザ', width: proportional(2), renderCell: (u) => <Text weight="semibold">{u.user}</Text> },
    { key: 'expires', header: '証明書期限', width: proportional(2), renderCell: (u) => <Badge variant="neutral" label={u.expires || '-'} /> },
    { key: 'dl', header: 'ダウンロード', width: proportional(4), renderCell: (u) => <Downloads user={u.user} onError={setError} /> },
    {
      key: 'ops', header: '操作', width: proportional(3),
      renderCell: (u) => (
        <Stack direction="horizontal" gap={1}>
          <Button label="パスワード" size="sm" onClick={async () => {
            try { setIssued({ ...(await getCredentials(u.user)), view: true }); } catch (e) { setError(e.message); }
          }} />
          <Button label="再発行" size="sm" data-testid={`reissue-${u.user}`} onClick={() => setConfirm({ kind: 'reissue', user: u.user })} />
          <Button label="削除" size="sm" variant="destructive" data-testid={`delete-${u.user}`} onClick={() => setConfirm({ kind: 'delete', user: u.user })} />
        </Stack>
      ),
    },
  ];

  return (
    <Stack gap={5} padding={5} maxWidth={1000} style={{ margin: '0 auto' }}>
      <Heading level={1}>VPN ユーザ管理</Heading>
      {error && <Banner status="error" title={error} isDismissable onDismiss={() => setError('')} collapsible={false} />}

      <Stack gap={2}>
        <Heading level={2}>ユーザ追加</Heading>
        <Stack direction="horizontal" gap={2} align="end" wrap="wrap">
          <TextInput label="ユーザ名" value={name} onChange={setName} htmlName="user" autoComplete="off" isRequired
            description="英数字 . _ - / 32文字以内" />
          <TextInput label="パスワード" value={pw} onChange={setPw} htmlName="pw" autoComplete="off" isOptional
            description="空欄で自動生成(8〜64文字)" />
          <Button label="追加" variant="primary" isLoading={busy} isDisabled={!name} data-testid="add"
            onClick={async () => { if (await run(() => addUser(name, pw), '追加')) { setName(''); setPw(''); } }} />
        </Stack>
      </Stack>

      <Stack gap={2}>
        <Heading level={2}>ユーザ一覧 ({users.length})</Heading>
        <Table data={users} columns={columns} idKey="user" density="balanced" hasHover />
        <Stack direction="horizontal" gap={2}>
          <Button label="CA 証明書 (ca.crt)" data-testid="dl-ca" onClick={() => { window.location.href = '/ca.crt'; }} />
        </Stack>
      </Stack>

      <Dialog isOpen={!!issued} onOpenChange={(o) => { if (!o) setIssued(null); }} width={560} purpose="required">
        {issued && (
          <Stack gap={3} padding={4}>
            <Heading level={2}>{issued.view ? `${issued.user} の認証情報` : `${issued.user} を${issued.what}しました`}</Heading>
            {!issued.view && <Banner status="info" title="パスワードは「パスワード」ボタンからいつでも再表示できます" collapsible={false} />}
            <CopyField id="pw" label="VPN パスワード" value={issued.pw} />
            {issued.p12pw
              ? <CopyField id="p12pw" label=".p12 パスワード" value={issued.p12pw} />
              : <Text color="secondary">.p12 パスワード: 未保存 (旧バージョンで発行。「再発行」で保存されます)</Text>}
            <Downloads user={issued.user} onError={setError} />
            <Stack direction="horizontal" hAlign="end">
              <Button label="閉じる" variant="primary" data-testid="close-issued" onClick={() => setIssued(null)} />
            </Stack>
          </Stack>
        )}
      </Dialog>

      <AlertDialog
        isOpen={!!confirm}
        onOpenChange={(o) => { if (!o) setConfirm(null); }}
        title={confirm?.kind === 'delete' ? `${confirm?.user} を削除しますか?` : `${confirm?.user} を再発行しますか?`}
        description={confirm?.kind === 'delete'
          ? '証明書を失効し、パスワードを削除します。この操作は元に戻せません。'
          : '旧証明書を失効し、新しい証明書とパスワードを発行します。'}
        actionLabel={confirm?.kind === 'delete' ? '削除' : '再発行'}
        actionVariant={confirm?.kind === 'delete' ? 'destructive' : 'primary'}
        cancelLabel="キャンセル"
        isActionLoading={busy}
        onAction={async () => {
          const c = confirm;
          const ok = await run(() => (c.kind === 'delete' ? deleteUser(c.user) : reissueUser(c.user)), '再発行');
          if (ok) setConfirm(null);
        }}
      />
    </Stack>
  );
}

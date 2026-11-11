// 認証情報付きURL (https://user:pass@host/) で開かれても fetch できるよう、origin から組み立てる
const base = () => window.location.origin;

async function call(method, path, body) {
  const r = await fetch(base() + path, {
    method,
    headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'vpn-admin' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || `HTTP ${r.status}`);
  return data;
}
export const listUsers = () => call('GET', '/api/users');
export const addUser = (user, pw) => call('POST', '/api/users', { user, pw: pw || undefined });
export const reissueUser = (u) => call('POST', `/api/users/${encodeURIComponent(u)}/reissue`);
export const deleteUser = (u) => call('DELETE', `/api/users/${encodeURIComponent(u)}`);
export const getCredentials = (u) => call('GET', `/api/users/${encodeURIComponent(u)}/credentials`);
export const dlUrl = (u, ext) => `/dl/${encodeURIComponent(u)}.${ext}`;

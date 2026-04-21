const { useState, useEffect, useRef, useCallback, useMemo } = React;

// ─── API ─────────────────────────────────────────────────────────────────────

const DEFAULT_ROOT = '/Volumes/Media/';

async function api(path, opts = {}) {
  const init = {
    method: opts.method || 'GET',
    headers: opts.body ? { 'Content-Type': 'application/json' } : {},
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  };
  const res = await fetch(path, init);
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(json.error || `HTTP ${res.status}`);
  return json;
}

// ─── Utils ────────────────────────────────────────────────────────────────────

function fmtSize(bytes) {
  if (!bytes) return '';
  const u = ['B','KB','MB','GB','TB']; let i = 0, n = bytes;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(i ? 1 : 0)} ${u[i]}`;
}

const AGG_FIELDS = [
  { key: 'ContentId', label: 'Content ID' },
  { key: 'Id', label: 'ID' },
  { key: 'Title', label: 'Title', span: true, multi: true },
  { key: 'AlternateTitle', label: 'Alternate Title', span: true },
  { key: 'Description', label: 'Description', span: true, multi: true, rows: 3 },
  { key: 'ReleaseDate', label: 'Release Date' },
  { key: 'Runtime', label: 'Runtime (min)' },
  { key: 'Director', label: 'Director' },
  { key: 'Maker', label: 'Maker' },
  { key: 'Label', label: 'Label' },
  { key: 'Series', label: 'Series' },
  { key: 'Rating', label: 'Rating' },
  { key: 'Votes', label: 'Votes' },
  { key: 'Genre', label: 'Genre', span: true, multi: true },
  { key: 'CoverUrl', label: 'Cover URL', span: true },
  { key: 'ScreenshotUrl', label: 'Screenshot URLs', span: true, multi: true },
  { key: 'TrailerUrl', label: 'Trailer URL', span: true },
];

function fieldVal(data, key) {
  const v = data?.[key];
  if (v == null) return '';
  if (Array.isArray(v)) {
    if (!v.length) return '';
    if (typeof v[0] === 'string') return v.join(' \\ ');
    return v.map(x => [x.LastName, x.FirstName].filter(Boolean).join(' ') || x.Name || '').join(' \\ ');
  }
  return String(v);
}

function buildOverride(s) {
  return {
    'sort.format.outputfolder': s.outputfolder,
    'sort.format.folder': s.folder || '<ID>',
    'sort.format.file': s.file || '<ID>',
    'sort.format.groupactress': s.groupActress,
    'sort.metadata.nfo.unknownactress': s.unknownActress,
  };
}

// Full payload for POST /api/settings — superset of buildOverride that also
// persists flags and destination. Mirror of parseServerSettings below.
function buildFullSettingsPayload(s) {
  return {
    'sort.format.outputfolder': s.outputfolder ?? '',
    'sort.format.folder': s.folder || '<ID>',
    'sort.format.file': s.file || '<ID>',
    'sort.format.groupactress': !!s.groupActress,
    'sort.metadata.nfo.unknownactress': !!s.unknownActress,
    'web.sort.recurse': !!s.recurse,
    'web.sort.update': !!s.update,
    'web.sort.force': !!s.force,
    'web.sort.src': s.src || '',
    'web.sort.dest': s.dest || '',
    'javdb.cookie.browser': s.javdbCookieBrowser ?? '',
    'javdb.cookie.session': s.javdbCookieSession ?? '',
    'javdb.cookie.cf_clearance': s.javdbCookieCfClearance ?? '',
    'javdb.cookie.user_agent': s.javdbCookieUserAgent ?? '',
  };
}

function parseServerSettings(srv) {
  if (!srv) return {};
  return {
    outputfolder: srv['sort.format.outputfolder'] ?? '',
    folder: srv['sort.format.folder'] ?? '<ID>',
    file: srv['sort.format.file'] ?? '<ID>',
    groupActress: !!srv['sort.format.groupactress'],
    unknownActress: !!srv['sort.metadata.nfo.unknownactress'],
    recurse: !!srv['web.sort.recurse'],
    update: !!srv['web.sort.update'],
    force: !!srv['web.sort.force'],
    src: srv['web.sort.src'] ?? '',
    dest: srv['web.sort.dest'] ?? '',
    javdbCookieBrowser: srv['javdb.cookie.browser'] ?? '',
    javdbCookieSession: srv['javdb.cookie.session'] ?? '',
    javdbCookieCfClearance: srv['javdb.cookie.cf_clearance'] ?? '',
    javdbCookieUserAgent: srv['javdb.cookie.user_agent'] ?? '',
  };
}

function settingsDiffer(a, b) {
  if (!a || !b) return true;
  for (const k of Object.keys(a)) {
    const av = a[k];
    const bv = b[k];
    if (typeof av === 'boolean') {
      if (!!av !== !!bv) return true;
    } else {
      const as = av == null ? '' : String(av);
      const bs = bv == null ? '' : String(bv);
      if (as !== bs) return true;
    }
  }
  return false;
}

// ─── Toast ────────────────────────────────────────────────────────────────────

function useToasts() {
  const [toasts, setToasts] = useState([]);
  const add = useCallback((msg, type = 'info', action = null) => {
    const id = Date.now() + Math.random();
    setToasts(t => [...t, { id, msg, type, action }]);
    setTimeout(() => setToasts(t => t.filter(x => x.id !== id)), 5000);
    return id;
  }, []);
  const remove = useCallback(id => setToasts(t => t.filter(x => x.id !== id)), []);
  return { toasts, add, remove };
}

function ToastHost({ toasts, remove }) {
  const colors = { error: 'var(--red)', ok: 'var(--green)', info: 'var(--border)' };
  return (
    <div style={{ position:'fixed', bottom:20, right:20, display:'flex', flexDirection:'column', gap:6, zIndex:9999 }}>
      {toasts.map(t => (
        <div key={t.id} style={{
          padding:'10px 14px', borderRadius:6, background:'var(--surface)',
          border:`1px solid ${colors[t.type]||colors.info}`,
          fontSize:12, display:'flex', gap:10, alignItems:'center', maxWidth:380,
          animation:'fadeSlideUp 0.2s ease-out', boxShadow:'0 4px 20px rgba(0,0,0,0.4)',
        }}>
          <span style={{flex:1, color:'var(--text)'}}>{t.msg}</span>
          {t.action && (
            <button onClick={t.action.fn} style={{background:'var(--accent)',border:0,color:'#fff',padding:'2px 8px',borderRadius:4,cursor:'pointer',fontSize:11,fontWeight:500}}>
              {t.action.label}
            </button>
          )}
          <button onClick={() => remove(t.id)} style={{background:'none',border:0,color:'var(--text-muted)',cursor:'pointer',fontSize:16,lineHeight:1,padding:0}}>×</button>
        </div>
      ))}
    </div>
  );
}

// ─── Shared styles ────────────────────────────────────────────────────────────

const S = {
  btn: {
    background:'transparent', border:'1px solid var(--border)', color:'var(--text-soft)',
    padding:'4px 10px', borderRadius:5, fontSize:12, fontWeight:500,
  },
  iconBtn: {
    background:'var(--surface-2)', border:'1px solid var(--border)', color:'var(--text-muted)',
    padding:'4px 8px', borderRadius:4, fontSize:13,
  },
  field: {
    background:'var(--surface-2)', border:'1px solid var(--border)', color:'var(--text)',
    borderRadius:4, padding:'5px 8px', fontSize:12, width:'100%',
  },
  label: { fontSize:10, color:'var(--text-muted)', fontWeight:600, textTransform:'uppercase', letterSpacing:'0.06em' },
};

// ─── Skeleton ─────────────────────────────────────────────────────────────────

function Sk({ w='100%', h=16, style={} }) {
  return <div className="skeleton" style={{width:w, height:h, borderRadius:4, ...style}} />;
}

// ─── Header ───────────────────────────────────────────────────────────────────

function Header({ showSettings, setShowSettings, onHelp, onSortAll, onManualScrape, videoCount }) {
  return (
    <header style={{
      background:'var(--surface)', borderBottom:'1px solid var(--border)',
      padding:'0 16px', height:44, display:'flex', alignItems:'center', gap:10, flexShrink:0,
    }}>
      <span style={{fontSize:15, fontWeight:600, letterSpacing:'-0.01em', flex:1}}>Javinizer Sort</span>
      <button
        onClick={onManualScrape}
        style={{...S.btn}}
        title="Scrape metadata from a Javdb/R18.dev URL or ID without selecting a file"
      >🔍 Manual Scrape</button>
      <button
        onClick={() => setShowSettings(s => !s)}
        style={{...S.btn, background: showSettings ? 'var(--accent-dim)' : 'transparent', color: showSettings ? 'var(--accent-light)' : 'var(--text-muted)', borderColor: showSettings ? 'var(--accent)' : 'var(--border)'}}
      >⚙ Sort Settings</button>
      <button
        onClick={onSortAll}
        disabled={videoCount === 0}
        style={{...S.btn, background:'var(--surface-2)', borderColor: videoCount > 0 ? 'var(--green)' : 'var(--border)', color: videoCount > 0 ? 'var(--green)' : 'var(--text-muted)', fontWeight:600}}
        title={videoCount > 0 ? `Sort all ${videoCount} videos in current folder` : 'Load a folder first'}
      >▶▶ Sort All {videoCount > 0 && `(${videoCount})`}</button>
      <button onClick={onHelp} style={{...S.btn}}>? Keys</button>
    </header>
  );
}

// ─── Folder Picker Modal ──────────────────────────────────────────────────────

function FolderPickerModal({ initial = '/Volumes', onSelect, onClose }) {
  const [cwd, setCwd] = useState(initial || '/Volumes');
  const [pathInput, setPathInput] = useState(initial || '/Volumes');
  const [dirs, setDirs] = useState([]);
  const [loading, setLoading] = useState(false);

  const browse = useCallback(async (dir) => {
    setLoading(true);
    try {
      const res = await api(`/api/browse?path=${encodeURIComponent(dir)}`);
      setCwd(res.cwd);
      setPathInput(res.cwd);
      setDirs(res.entries.filter(e => e.isDir));
    } finally { setLoading(false); }
  }, []);

  useEffect(() => { browse(initial || '/Volumes'); }, []);

  const goUp = () => {
    const parent = cwd.split('/').slice(0, -1).join('/');
    if (parent) browse(parent);
  };

  return (
    <div style={{position:'fixed',inset:0,background:'rgba(0,0,0,0.75)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:2000}} onClick={onClose}>
      <div style={{background:'var(--surface)',border:'1px solid var(--border)',borderRadius:8,width:500,maxWidth:'92vw',maxHeight:'80vh',display:'flex',flexDirection:'column',overflow:'hidden'}} onClick={e=>e.stopPropagation()}>
        {/* Header */}
        <div style={{padding:'10px 14px',borderBottom:'1px solid var(--border)',display:'flex',alignItems:'center',justifyContent:'space-between'}}>
          <span style={{fontWeight:600,fontSize:14}}>Choose Folder</span>
          <button onClick={onClose} style={{background:'none',border:'none',color:'var(--text-muted)',cursor:'pointer',fontSize:20,lineHeight:1}}>×</button>
        </div>
        {/* Path bar */}
        <div style={{padding:'8px 12px',borderBottom:'1px solid var(--border)',display:'flex',gap:6,alignItems:'center',background:'var(--surface-2)'}}>
          <button onClick={goUp} style={S.iconBtn} title="Parent">↑</button>
          <input
            value={pathInput}
            onChange={e => setPathInput(e.target.value)}
            onKeyDown={e => e.key==='Enter' && browse(pathInput)}
            style={{...S.field, flex:1, fontFamily:'var(--mono)', fontSize:11}}
          />
          <button onClick={() => browse(pathInput)} style={S.iconBtn}>↵</button>
        </div>
        {/* Dir list */}
        <div style={{flex:1,overflowY:'auto',padding:'4px 0'}}>
          {loading ? (
            <div style={{padding:12,display:'flex',flexDirection:'column',gap:5}}>
              {[...Array(4)].map((_,i)=><Sk key={i} h={30}/>)}
            </div>
          ) : dirs.length === 0 ? (
            <div style={{color:'var(--text-muted)',fontSize:12,textAlign:'center',padding:24}}>No subfolders</div>
          ) : dirs.map(d => (
            <div key={d.fullPath}
              className="entry-row"
              onClick={() => browse(d.fullPath)}
              style={{padding:'8px 14px'}}
            >
              <span style={{opacity:0.65}}>📂</span>
              <span style={{flex:1,fontSize:13}}>{d.name}</span>
            </div>
          ))}
        </div>
        {/* Footer */}
        <div style={{padding:'10px 14px',borderTop:'1px solid var(--border)',display:'flex',alignItems:'center',gap:10}}>
          <code style={{flex:1,fontSize:11,fontFamily:'var(--mono)',color:'var(--accent-light)',overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>{pathInput}</code>
          <button onClick={onClose} style={{...S.btn,fontSize:12}}>Cancel</button>
          <button onClick={()=>{onSelect(pathInput);onClose();}} style={{background:'var(--accent)',border:'none',color:'#fff',padding:'6px 16px',borderRadius:5,fontSize:12,fontWeight:600}}>✓ Use Folder</button>
        </div>
      </div>
    </div>
  );
}

// ─── Token Input ──────────────────────────────────────────────────────────────

const OUTPUT_TOKENS  = ['<ACTORS>', '<STUDIO>', '<LABEL>', '<SET>', '<YEAR>', '<ID>'];
const FOLDER_TOKENS  = ['<ID>', '<TITLE>', '<STUDIO>', '<LABEL>', '<ACTORS>', '<YEAR>', '<SET>'];
const FILE_TOKENS    = ['<ID>', '<TITLE>', '<PART>'];

function TokenInput({ value, onChange, tokens, placeholder }) {
  const [open, setOpen] = useState(false);
  const inputRef = useRef();
  const wrapRef = useRef();
  const mirrorRef = useRef();

  // Auto-size input to content
  useEffect(() => {
    if (!mirrorRef.current || !inputRef.current) return;
    mirrorRef.current.textContent = value || placeholder || '';
    const w = mirrorRef.current.offsetWidth;
    inputRef.current.style.width = Math.max(60, w + 18) + 'px';
  }, [value, placeholder]);

  // Close dropdown on outside click
  useEffect(() => {
    if (!open) return;
    const handler = e => { if (!wrapRef.current?.contains(e.target)) setOpen(false); };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [open]);

  const insertToken = (token) => {
    const el = inputRef.current;
    if (!el) { onChange(value + token); setOpen(false); return; }
    const start = el.selectionStart ?? value.length;
    const end   = el.selectionEnd   ?? value.length;
    const next  = value.slice(0, start) + token + value.slice(end);
    onChange(next);
    setOpen(false);
    setTimeout(() => { el.focus(); el.setSelectionRange(start + token.length, start + token.length); }, 0);
  };

  return (
    <div ref={wrapRef} style={{position:'relative', display:'flex', gap:0}}>
      {/* Hidden mirror for width measurement */}
      <span ref={mirrorRef} style={{
        position:'absolute', visibility:'hidden', whiteSpace:'pre',
        fontFamily:'var(--mono)', fontSize:11, padding:'5px 8px', pointerEvents:'none',
      }} aria-hidden="true" />
      <input
        ref={inputRef}
        value={value}
        onChange={e => onChange(e.target.value)}
        placeholder={placeholder}
        style={{...S.field, fontFamily:'var(--mono)', fontSize:11, borderRadius:'4px 0 0 4px', minWidth:60, width:60}}
      />
      <button
        onClick={() => setOpen(o => !o)}
        title="Insert token"
        style={{
          background: open ? 'var(--accent-dim)' : 'var(--surface-3)',
          border:'1px solid var(--border)', borderLeft:'none',
          color: open ? 'var(--accent-light)' : 'var(--text-muted)',
          padding:'0 8px', borderRadius:'0 4px 4px 0', fontSize:11, cursor:'pointer', flexShrink:0,
          fontFamily:'var(--mono)', letterSpacing:'0.04em',
        }}
      >{'{}'}</button>
      {open && (
        <div style={{
          position:'absolute', top:'100%', right:0, zIndex:500, marginTop:2,
          background:'var(--surface)', border:'1px solid var(--border)', borderRadius:6,
          padding:6, display:'flex', flexWrap:'wrap', gap:4, width:220,
          boxShadow:'0 4px 16px rgba(0,0,0,0.4)',
        }}>
          {tokens.map(t => (
            <button key={t} onClick={() => insertToken(t)} style={{
              background:'var(--surface-2)', border:'1px solid var(--border)',
              color:'var(--accent-light)', borderRadius:4, padding:'3px 7px',
              fontSize:11, fontFamily:'var(--mono)', cursor:'pointer',
              transition:'background 0.1s',
            }}
            onMouseEnter={e=>e.currentTarget.style.background='var(--accent-dim)'}
            onMouseLeave={e=>e.currentTarget.style.background='var(--surface-2)'}
            >{t}</button>
          ))}
          <div style={{width:'100%',fontSize:10,color:'var(--text-muted)',marginTop:2,paddingTop:4,borderTop:'1px solid var(--border)'}}>
            Click to insert at cursor
          </div>
        </div>
      )}
    </div>
  );
}

// ─── Javdb session panel ──────────────────────────────────────────────────────

const JAVDB_COOKIE_SOURCES = [
  { value: '',         label: 'Auto (anonymous, recommended)', desc: 'Headless Chromium grabs cf_clearance — no login, no interaction' },
  { value: 'login',    label: 'Playwright login (noVNC)',      desc: 'Open Chromium over noVNC so you can sign in once; needed for login-gated data' },
  { value: 'chrome',   label: 'Chrome (host profile)',         desc: 'Read cookies from your local Chrome profile (desktop only)' },
  { value: 'chromium', label: 'Chromium (host profile)',       desc: 'Read cookies from your local Chromium profile (desktop only)' },
  { value: 'edge',     label: 'Edge (host profile)',           desc: 'Read cookies from your local Edge profile (desktop only)' },
  { value: 'brave',    label: 'Brave (host profile)',          desc: 'Read cookies from your local Brave profile (desktop only)' },
  { value: 'firefox',  label: 'Firefox (host profile)',        desc: 'Read cookies from your local Firefox profile (desktop only)' },
  { value: 'paste',    label: 'Paste cookies manually',        desc: 'Enter _jdb_session / cf_clearance / UA below' },
];

function JavdbSessionPanel({ s, set, addToast }) {
  const u = (k, v) => set(p => ({ ...p, [k]: v }));
  const [status, setStatus] = useState(null);       // null=loading, {}=loaded
  const [refreshing, setRefreshing] = useState(false);
  const [showSecrets, setShowSecrets] = useState(false);

  const loadStatus = useCallback(async () => {
    try {
      const res = await api('/api/javdb/session/status');
      setStatus(res || {});
    } catch {
      setStatus({ error: true });
    }
  }, []);

  useEffect(() => { loadStatus(); }, [loadStatus]);

  const choice = s.javdbCookieBrowser || '';
  const isPaste = choice === 'paste';
  const isLogin = choice === 'login';

  const onRefresh = async () => {
    setRefreshing(true);
    try {
      const body = isLogin ? { mode: 'login' } : { mode: 'anonymous' };
      const res = await api('/api/javdb/session/refresh', { method: 'POST', body });
      const exp = res.expiresAt ? new Date(res.expiresAt).toLocaleDateString() : '?';
      const src = res.source || 'unknown';
      setStatus({ present: true, source: src, capturedAt: res.capturedAt, expiresAt: res.expiresAt });
      addToast?.(`✓ javdb session refreshed via ${src} (expires ${exp})`, 'ok');
    } catch (e) {
      addToast?.(`javdb refresh failed: ${e.message}`, 'error');
    } finally {
      setRefreshing(false);
    }
  };
  const dot = status?.present ? 'var(--green)' : 'var(--red)';
  const expText = status?.expiresAt ? new Date(status.expiresAt).toLocaleDateString() : null;

  return (
    <div style={{width:'100%', display:'flex', flexDirection:'column', gap:6, paddingTop:6, borderTop:'1px solid var(--border)'}}>
      <div style={{display:'flex', alignItems:'center', gap:12, flexWrap:'wrap'}}>
        <span style={S.label}>Javdb session</span>

        <div style={{display:'flex', flexDirection:'column', gap:3, minWidth:220}}>
          <label style={{...S.label, textTransform:'none', fontWeight:400, color:'var(--text-muted)', letterSpacing:0}}>Cookie source</label>
          <select
            value={choice}
            onChange={e => u('javdbCookieBrowser', e.target.value)}
            style={{...S.field, fontSize:12}}
            title="Where to get _jdb_session + cf_clearance cookies"
          >
            {JAVDB_COOKIE_SOURCES.map(o => (
              <option key={o.value || 'default'} value={o.value}>{o.label}</option>
            ))}
          </select>
        </div>

        <button
          onClick={onRefresh}
          disabled={refreshing}
          title="Run the chosen cookie source and cache the result"
          style={{...S.btn, background: refreshing ? 'var(--surface-3)' : 'var(--accent-dim)', borderColor:'var(--accent)', color:'var(--accent-light)', cursor: refreshing ? 'default' : 'pointer', opacity: refreshing ? 0.6 : 1}}
        >{refreshing ? '…refreshing' : '🔑 Refresh Javdb session'}</button>

        <div style={{display:'flex', alignItems:'center', gap:6, fontSize:11, color:'var(--text-muted)'}}>
          <span style={{width:8, height:8, borderRadius:'50%', background:dot, flexShrink:0}} />
          {status == null && <span>checking…</span>}
          {status && !status.present && <span>no session cached</span>}
          {status && status.present && <span>cached via {status.source || 'unknown'}{expText ? ` · expires ${expText}` : ''}</span>}
        </div>
      </div>

      <div style={{fontSize:10, color:'var(--text-muted)', paddingLeft:2, fontStyle:'italic', lineHeight:1.5}}>
        Default mode is headless anonymous — Javdb video pages don't require login, only Cloudflare clearance, which the system captures automatically.
        Scrapes that return 403 are also auto-retried through Chromium so TLS/HTTP2 matches the session.
      </div>

      {isPaste && (
        <div style={{display:'grid', gridTemplateColumns:'repeat(auto-fit, minmax(240px, 1fr))', gap:8, paddingLeft:2, paddingTop:4}}>
          <div style={{display:'flex', flexDirection:'column', gap:3}}>
            <label style={{...S.label, textTransform:'none', fontWeight:400, color:'var(--text-muted)', letterSpacing:0}}>_jdb_session</label>
            <input
              type={showSecrets ? 'text' : 'password'}
              value={s.javdbCookieSession || ''}
              onChange={e=>u('javdbCookieSession', e.target.value)}
              placeholder="paste cookie value"
              style={{...S.field, fontFamily:'var(--mono)', fontSize:11}}
            />
          </div>
          <div style={{display:'flex', flexDirection:'column', gap:3}}>
            <label style={{...S.label, textTransform:'none', fontWeight:400, color:'var(--text-muted)', letterSpacing:0}}>cf_clearance</label>
            <input
              type={showSecrets ? 'text' : 'password'}
              value={s.javdbCookieCfClearance || ''}
              onChange={e=>u('javdbCookieCfClearance', e.target.value)}
              placeholder="paste cookie value"
              style={{...S.field, fontFamily:'var(--mono)', fontSize:11}}
            />
          </div>
          <div style={{display:'flex', flexDirection:'column', gap:3}}>
            <label style={{...S.label, textTransform:'none', fontWeight:400, color:'var(--text-muted)', letterSpacing:0}}>User-Agent</label>
            <input
              type="text"
              value={s.javdbCookieUserAgent || ''}
              onChange={e=>u('javdbCookieUserAgent', e.target.value)}
              placeholder="Mozilla/5.0 (Windows NT 10.0…) Chrome/120.0.0.0 Safari/537.36"
              style={{...S.field, fontFamily:'var(--mono)', fontSize:11}}
            />
          </div>
          <label style={{display:'flex', alignItems:'center', gap:5, fontSize:11, color:'var(--text-muted)', cursor:'pointer', userSelect:'none'}}>
            <input type="checkbox" checked={showSecrets} onChange={e=>setShowSecrets(e.target.checked)} style={{accentColor:'var(--accent)'}} />
            Show values
          </label>
        </div>
      )}
    </div>
  );
}

// ─── Sort Settings bar ────────────────────────────────────────────────────────

function SortSettings({ s, set, serverSettings, onSaveDefaults, onResetToSaved, addToast }) {
  const u = (k, v) => set(p => ({ ...p, [k]: v }));
  const [pickerTarget, setPickerTarget] = useState(null); // 'src' | 'dest'
  const dirty = useMemo(
    () => settingsDiffer(buildFullSettingsPayload(s), serverSettings),
    [s, serverSettings]
  );

  const PRESETS = [
    {
      id: 'actress',
      label: 'By Actress',
      desc: 'One folder per actress',
      example: 'Kano Yura / CAWD-125 / CAWD-125.mp4',
      values: { outputfolder:'<ACTORS>', folder:'<ID>', file:'<ID>', groupActress:false, unknownActress:false },
    },
    {
      id: 'group',
      label: 'Group / Unknown',
      desc: 'Actress folder + Unknown fallback',
      example: 'Kano Yura · Aika / IPX-456 / IPX-456.mp4',
      values: { outputfolder:'<ACTORS>', folder:'<ID>', file:'<ID>', groupActress:true, unknownActress:true },
    },
    {
      id: 'flat',
      label: 'Flat',
      desc: 'No subfolders, ID only',
      example: 'CAWD-125 / CAWD-125.mp4',
      values: { outputfolder:'', folder:'<ID>', file:'<ID>', groupActress:false, unknownActress:false },
    },
  ];

  const activePreset = PRESETS.find(p =>
    s.outputfolder === p.values.outputfolder &&
    s.folder === p.values.folder &&
    s.file === p.values.file &&
    !!s.groupActress === p.values.groupActress &&
    !!s.unknownActress === p.values.unknownActress
  )?.id || null;

  const applyPreset = (p) => set(x => ({ ...x, ...p.values }));
  return (
    <div style={{background:'var(--surface-2)', borderBottom:'1px solid var(--border)', padding:'10px 16px', display:'flex', gap:12, flexWrap:'wrap', alignItems:'flex-end', flexShrink:0}}>
      {/* Source — plain input + browse button. Used as the FileBrowser start path on load. */}
      <div style={{display:'flex', flexDirection:'column', gap:3, flex:'0 0 220px'}}>
        <label style={S.label}>Source folder</label>
        <div style={{display:'flex', gap:0}}>
          <input
            value={s.src||''} onChange={e=>u('src',e.target.value)}
            placeholder="/Volumes/…"
            style={{...S.field, fontFamily:'var(--mono)', fontSize:11, borderRadius:'4px 0 0 4px', flex:1}}
          />
          <button onClick={()=>setPickerTarget('src')} title="Browse" style={{background:'var(--surface-3)', border:'1px solid var(--border)', borderLeft:'none', borderRadius:'0 4px 4px 0', padding:'0 8px', color:'var(--text-muted)', cursor:'pointer', fontSize:13}}>📂</button>
        </div>
      </div>
      {/* Destination — plain input + browse button */}
      <div style={{display:'flex', flexDirection:'column', gap:3, flex:'0 0 220px'}}>
        <label style={S.label}>Destination folder</label>
        <div style={{display:'flex', gap:0}}>
          <input
            value={s.dest||''} onChange={e=>u('dest',e.target.value)}
            placeholder="/Volumes/…"
            style={{...S.field, fontFamily:'var(--mono)', fontSize:11, borderRadius:'4px 0 0 4px', flex:1}}
          />
          <button onClick={()=>setPickerTarget('dest')} title="Browse" style={{background:'var(--surface-3)', border:'1px solid var(--border)', borderLeft:'none', borderRadius:'0 4px 4px 0', padding:'0 8px', color:'var(--text-muted)', cursor:'pointer', fontSize:13}}>📂</button>
        </div>
      </div>
      {/* Output folder — token input */}
      <div style={{display:'flex', flexDirection:'column', gap:3}}>
        <label style={S.label}>Output folder <span style={{color:'var(--text-muted)', textTransform:'none', letterSpacing:0, fontWeight:400}}>tokens</span></label>
        <TokenInput value={s.outputfolder||''} onChange={v=>u('outputfolder',v)} tokens={OUTPUT_TOKENS} placeholder="<ACTORS>" />
      </div>
      {/* Folder format — token input */}
      <div style={{display:'flex', flexDirection:'column', gap:3}}>
        <label style={S.label}>Folder format <span style={{color:'var(--text-muted)', textTransform:'none', letterSpacing:0, fontWeight:400}}>tokens</span></label>
        <TokenInput value={s.folder||''} onChange={v=>u('folder',v)} tokens={FOLDER_TOKENS} placeholder="<ID> [<STUDIO>] - <TITLE> (<YEAR>)" />
      </div>
      {/* File format — token input */}
      <div style={{display:'flex', flexDirection:'column', gap:3}}>
        <label style={S.label}>File format</label>
        <TokenInput value={s.file||''} onChange={v=>u('file',v)} tokens={FILE_TOKENS} placeholder="<ID>" />
      </div>
      {/* Checkboxes */}
      <div style={{display:'flex', gap:12, flexWrap:'wrap', alignItems:'center', paddingBottom:2}}>
        {[
          ['groupActress','Group actress','Groups multiple actresses into one folder'],
          ['unknownActress','Unknown actress','Puts files with no actress into an Unknown folder'],
          ['recurse','Recurse','Scan subdirectories for videos'],
          ['update','Update','Re-process already-sorted files (refresh metadata/images)'],
          ['force','Force','Overwrite everything at destination, including the video file'],
        ].map(([k,l,tip])=>(
          <label key={k} title={tip} style={{display:'flex', gap:5, alignItems:'center', fontSize:11, cursor:'pointer', userSelect:'none', color:'var(--text-muted)'}}>
            <input type="checkbox" checked={!!s[k]} onChange={e=>u(k,e.target.checked)} style={{accentColor:'var(--accent)'}} />
            {l}
          </label>
        ))}
      </div>
      {/* Presets */}
      <div style={{width:'100%', display:'flex', flexDirection:'column', gap:4, paddingTop:4, borderTop:'1px solid var(--border)'}}>
        <div style={{display:'flex', alignItems:'center', justifyContent:'space-between', marginBottom:2}}>
          <span style={S.label}>Presets</span>
          <div style={{display:'flex', gap:6, alignItems:'center'}}>
            <button
              onClick={onResetToSaved}
              disabled={!serverSettings || !dirty}
              title="Discard unsaved changes and restore the last-saved defaults"
              style={{...S.btn, fontSize:11, opacity: (!serverSettings || !dirty) ? 0.4 : 1}}
            >↺ Reset to saved</button>
            <button
              onClick={onSaveDefaults}
              disabled={!dirty}
              title="Persist these settings to jvSettings.json as the new defaults"
              style={{
                background: dirty ? 'var(--accent)' : 'var(--surface-3)',
                border: '1px solid ' + (dirty ? 'var(--accent)' : 'var(--border)'),
                color: dirty ? '#fff' : 'var(--text-muted)',
                padding:'4px 10px', borderRadius:5, fontSize:11, fontWeight:600,
                cursor: dirty ? 'pointer' : 'default', opacity: dirty ? 1 : 0.6,
              }}
            >{dirty ? '• ' : ''}Save as default</button>
          </div>
        </div>
        <div style={{display:'flex', gap:6, flexWrap:'wrap'}}>
          {PRESETS.map(p => {
            const active = activePreset === p.id;
            return (
              <button
                key={p.id}
                onClick={() => applyPreset(p)}
                style={{
                  background: active ? 'var(--accent-dim)' : 'var(--surface-3)',
                  border: `1px solid ${active ? 'var(--accent)' : 'var(--border)'}`,
                  borderRadius: 6, padding: '6px 12px', cursor: 'pointer',
                  display: 'flex', flexDirection: 'column', gap: 2, textAlign: 'left',
                  transition: 'border-color 0.15s, background 0.15s', minWidth: 150,
                }}
                onMouseEnter={e => { if (!active) e.currentTarget.style.borderColor = 'var(--text-muted)'; }}
                onMouseLeave={e => { if (!active) e.currentTarget.style.borderColor = 'var(--border)'; }}
              >
                <div style={{display:'flex', alignItems:'center', gap:6}}>
                  {active && <span style={{width:6, height:6, borderRadius:'50%', background:'var(--accent)', flexShrink:0}} />}
                  <span style={{fontSize:12, fontWeight:600, color: active ? 'var(--accent-light)' : 'var(--text)'}}>{p.label}</span>
                </div>
                <span style={{fontSize:10, color:'var(--text-muted)'}}>{p.desc}</span>
                <code style={{fontSize:10, color: active ? 'var(--accent-light)' : 'var(--text-soft)', fontFamily:'var(--mono)', marginTop:2, opacity:0.8}}>{p.example}</code>
              </button>
            );
          })}
          {!activePreset && (
            <div style={{display:'flex', alignItems:'center', padding:'6px 10px', fontSize:11, color:'var(--text-muted)', fontStyle:'italic'}}>
              Custom settings
            </div>
          )}
        </div>
      </div>
      <JavdbSessionPanel s={s} set={set} addToast={addToast} />
      {pickerTarget && (
        <FolderPickerModal
          initial={s[pickerTarget] || '/Volumes'}
          onSelect={v => u(pickerTarget, v)}
          onClose={() => setPickerTarget(null)}
        />
      )}
    </div>
  );
}

// ─── File Browser ─────────────────────────────────────────────────────────────

function FileBrowser({ selected, onSelect, onVideosChange, recurse, sortedPaths, initialPath }) {
  const removed = sortedPaths || new Set();
  const startPath = initialPath || DEFAULT_ROOT;
  const [cwd, setCwd] = useState('');
  const [pathInput, setPathInput] = useState(startPath);
  const [entries, setEntries] = useState([]);
  const [videos, setVideos] = useState([]);
  const [search, setSearch] = useState('');
  const [loading, setLoading] = useState(false);
  const [showPicker, setShowPicker] = useState(false);
  const searchRef = useRef();

  const browse = useCallback(async (dir) => {
    setLoading(true);
    try {
      // Guard: recursing shallow roots (/, /Volumes, /Volumes/Media) walks
      // every file on every mount and hangs Pode. Require ≥ 3 path segments.
      const depth = dir.split('/').filter(Boolean).length;
      const safeRecurse = recurse && depth >= 3;
      const q = `path=${encodeURIComponent(dir)}${safeRecurse ? '&recurse=1' : ''}`;
      const res = await api(`/api/browse?${q}`);
      setCwd(res.cwd);
      setPathInput(res.cwd);
      const vids = res.entries.filter(e => e.isVideo);
      setEntries(res.entries);
      setVideos(vids);
      onVideosChange(vids);
    } finally { setLoading(false); }
  }, [onVideosChange, recurse]);

  useEffect(() => { browse(startPath); }, []);
  useEffect(() => { if (cwd) browse(cwd); }, [recurse]);

  // expose search focus for keyboard shortcut
  useEffect(() => {
    function handle(e) { if (e.key === '/' && document.activeElement?.tagName !== 'INPUT' && document.activeElement?.tagName !== 'TEXTAREA') { e.preventDefault(); searchRef.current?.focus(); } }
    window.addEventListener('keydown', handle);
    return () => window.removeEventListener('keydown', handle);
  }, []);

  const visibleEntries = useMemo(() => entries.filter(e => !removed.has(e.fullPath)), [entries, removed]);
  const visibleVideos = useMemo(() => videos.filter(v => !removed.has(v.fullPath)), [videos, removed]);
  const filtered = useMemo(() => {
    if (!search) return visibleEntries;
    const q = search.toLowerCase();
    return visibleEntries.filter(e =>
      e.name.toLowerCase().includes(q) ||
      (e.relativePath && e.relativePath.toLowerCase().includes(q))
    );
  }, [visibleEntries, search]);

  const goUp = async () => {
    if (!cwd) return;
    const res = await api(`/api/browse?path=${encodeURIComponent(cwd)}`);
    if (res.parent) browse(res.parent);
  };

  return (
    <div style={{display:'flex', flexDirection:'column', height:'100%', overflow:'hidden'}}>
      {/* Path bar */}
      <div style={{padding:'8px 10px', borderBottom:'1px solid var(--border)', display:'flex', gap:6, alignItems:'center', flexShrink:0}}>
        <input
          value={pathInput} onChange={e=>setPathInput(e.target.value)}
          onKeyDown={e => e.key==='Enter' && browse(pathInput)}
          style={{...S.field, flex:1, fontSize:11, fontFamily:'var(--mono)'}}
          placeholder="Enter path…"
        />
        <button onClick={()=>setShowPicker(true)} style={S.iconBtn} title="Browse folders">📂</button>
        <button onClick={goUp} style={S.iconBtn} title="Parent dir">↑</button>
      </div>
      {showPicker && (
        <FolderPickerModal
          initial={cwd || '/Volumes'}
          onSelect={p => { setPathInput(p); browse(p); }}
          onClose={() => setShowPicker(false)}
        />
      )}
      {/* Search */}
      <div style={{padding:'6px 10px', borderBottom:'1px solid var(--border)', flexShrink:0}}>
        <input
          ref={searchRef}
          value={search} onChange={e=>setSearch(e.target.value)}
          placeholder="Search  (/)"
          style={{...S.field, width:'100%'}}
        />
      </div>
      {/* Entries */}
      <div style={{flex:1, overflowY:'auto'}}>
        {loading ? (
          <div style={{padding:10, display:'flex', flexDirection:'column', gap:5}}>
            {[...Array(6)].map((_,i)=><Sk key={i} h={30}/>)}
          </div>
        ) : filtered.length === 0 ? (
          <div style={{color:'var(--text-muted)', fontSize:12, padding:16, textAlign:'center'}}>No files</div>
        ) : filtered.map(e => {
          const isSelected = selected?.fullPath === e.fullPath;
          return (
            <div key={e.fullPath}
              className={`entry-row${isSelected ? ' selected' : ''}`}
              onClick={() => {
                if (e.isDir) { browse(e.fullPath); setSearch(''); }
                else { const idx = visibleVideos.findIndex(v => v.fullPath === e.fullPath); onSelect(e, idx >= 0 ? idx : 0); }
              }}
            >
              <span style={{opacity:0.65, fontSize:14}}>{e.isDir ? '📂' : e.isVideo ? '🎞' : '📄'}</span>
              <span
                title={e.relativePath || e.name}
                style={{flex:1, overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap', color: e.isDir ? 'var(--accent-light)' : 'var(--text)'}}
              >{recurse && e.relativePath ? e.relativePath : e.name}</span>
              {e.isVideo && <span style={{color:'var(--text-muted)', fontSize:10, flexShrink:0}}>{fmtSize(e.size)}</span>}
            </div>
          );
        })}
      </div>
      {/* Footer count */}
      <div style={{padding:'5px 10px', borderTop:'1px solid var(--border)', fontSize:10, color:'var(--text-muted)', flexShrink:0}}>
        {visibleVideos.length > 0 ? `${visibleVideos.length} video${visibleVideos.length!==1?'s':''}` : 'No videos'}
        {selected && visibleVideos.length > 0 && ` · selected ${visibleVideos.findIndex(v=>v.fullPath===selected.fullPath)+1} of ${visibleVideos.length}`}
        {recurse && cwd && cwd.split('/').filter(Boolean).length < 3 && (
          <div style={{color:'var(--yellow)'}}>Recurse ignored — path too shallow</div>
        )}
      </div>
    </div>
  );
}

// ─── Metadata Form ────────────────────────────────────────────────────────────

function MetadataForm({ data, onChange }) {
  if (!data) return null;
  return (
    <div style={{display:'grid', gridTemplateColumns:'1fr 1fr', gap:'8px 14px'}}>
      {AGG_FIELDS.map(f => (
        <div key={f.key} style={{gridColumn: f.span ? 'span 2' : 'span 1', display:'flex', flexDirection:'column', gap:3}}>
          <label style={S.label}>{f.label}</label>
          {f.multi ? (
            <textarea
              value={fieldVal(data, f.key)}
              onChange={e => onChange(f.key, e.target.value)}
              rows={f.rows || 2}
              style={{...S.field, resize:'vertical', fontFamily:'var(--sans)'}}
            />
          ) : (
            <input value={fieldVal(data,f.key)} onChange={e=>onChange(f.key,e.target.value)} style={S.field} />
          )}
        </div>
      ))}
    </div>
  );
}

// ─── Actress Panel ────────────────────────────────────────────────────────────

function ActressPanel({ actresses }) {
  if (!actresses?.length) return <div style={{color:'var(--text-muted)', fontSize:12, padding:12, textAlign:'center'}}>No actress data</div>;
  return (
    <div style={{display:'flex', gap:12, flexWrap:'wrap'}}>
      {actresses.map((a, i) => {
        const name = [a.LastName, a.FirstName].filter(Boolean).join(' ') || a.Name || '—';
        return (
          <div key={i} style={{background:'var(--surface-2)', border:'1px solid var(--border)', borderRadius:6, padding:10, display:'flex', flexDirection:'column', gap:6, width:140}}>
            {a.ThumbUrl
              ? <img src={a.ThumbUrl} alt={name} style={{width:'100%', aspectRatio:'3/4', objectFit:'cover', borderRadius:4, background:'var(--surface)'}} onError={e=>{e.target.style.display='none';e.target.nextSibling.style.display='flex'}} />
              : null
            }
            <div style={{width:'100%', aspectRatio:'3/4', background:'var(--surface)', borderRadius:4, display: a.ThumbUrl ? 'none' : 'flex', alignItems:'center', justifyContent:'center', fontSize:32}}>👤</div>
            <div style={{fontSize:13, fontWeight:600, lineHeight:1.3}}>{name}</div>
            {a.JapaneseName && <div style={{fontSize:11, color:'var(--text-muted)'}}>{a.JapaneseName}</div>}
          </div>
        );
      })}
    </div>
  );
}

// ─── Screens Modal ────────────────────────────────────────────────────────────

function ScreensModal({ urls, onClose }) {
  return (
    <div style={{position:'fixed',inset:0,background:'rgba(0,0,0,0.7)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:1000}} onClick={onClose}>
      <div style={{background:'var(--surface)',border:'1px solid var(--border)',borderRadius:8,width:'80vw',maxWidth:1000,maxHeight:'85vh',overflow:'hidden',display:'flex',flexDirection:'column'}} onClick={e=>e.stopPropagation()}>
        <div style={{padding:'10px 14px',borderBottom:'1px solid var(--border)',display:'flex',alignItems:'center',justifyContent:'space-between',fontWeight:600,fontSize:14}}>
          <span>Screenshots</span>
          <button onClick={onClose} style={{background:'none',border:'none',color:'var(--text-muted)',cursor:'pointer',fontSize:20,lineHeight:1}}>×</button>
        </div>
        <div style={{overflowY:'auto',padding:14}}>
          {urls.length === 0
            ? <div style={{color:'var(--text-muted)',fontSize:12,textAlign:'center',padding:24}}>No screenshots</div>
            : <div style={{display:'grid',gridTemplateColumns:'repeat(auto-fill,minmax(220px,1fr))',gap:8}}>
                {urls.map((u,i) => <img key={i} src={u} alt="" style={{width:'100%',borderRadius:4,cursor:'pointer'}} onClick={()=>window.open(u,'_blank')} />)}
              </div>
          }
        </div>
      </div>
    </div>
  );
}

// ─── Manual Search Modal ──────────────────────────────────────────────────────

function ManualModal({ onClose, onResult, toast }) {
  const [q, setQ] = useState('');
  const [status, setStatus] = useState('');
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState(null);

  const go = async () => {
    const query = q.trim();
    if (!query) return;
    setBusy(true); setStatus('Scraping…'); setResult(null);
    try {
      const res = await api('/api/manual-search', { method:'POST', body:{ query } });
      setStatus('');
      setResult(res.data);
    } catch(e) {
      setStatus('Error: ' + e.message);
    } finally {
      setBusy(false);
    }
  };

  const apply = () => {
    if (result && onResult) { onResult(result); onClose(); }
  };

  const reset = () => { setResult(null); setStatus(''); };

  const cover = result && (Array.isArray(result.CoverUrl) ? result.CoverUrl[0] : result.CoverUrl);
  const actressLabel = result && Array.isArray(result.Actress)
    ? result.Actress.map(a => [a.LastName, a.FirstName].filter(Boolean).join(' ') || a.Name || '').filter(Boolean).join(', ')
    : '';
  const genreLabel = result && Array.isArray(result.Genre) ? result.Genre.join(', ') : (result?.Genre || '');

  return (
    <div style={{position:'fixed',inset:0,background:'rgba(0,0,0,0.7)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:1000}} onClick={onClose}>
      <div style={{background:'var(--surface)',border:'1px solid var(--border)',borderRadius:8,width: result ? 640 : 480, maxWidth:'92vw', maxHeight:'90vh', overflow:'hidden', display:'flex', flexDirection:'column'}} onClick={e=>e.stopPropagation()}>
        <div style={{padding:'10px 14px',borderBottom:'1px solid var(--border)',display:'flex',alignItems:'center',justifyContent:'space-between',fontWeight:600,fontSize:14}}>
          <span>Manual Scrape{result ? ` — ${result.Id || ''}` : ''}</span>
          <button onClick={onClose} style={{background:'none',border:'none',color:'var(--text-muted)',cursor:'pointer',fontSize:20,lineHeight:1}}>×</button>
        </div>

        {!result && (
          <div style={{padding:16,display:'flex',flexDirection:'column',gap:10}}>
            <label style={{...S.label}}>Content ID or site URL</label>
            <input
              value={q}
              onChange={e=>setQ(e.target.value)}
              onKeyDown={e=>e.key==='Enter'&&go()}
              placeholder="CAWD-125 · https://javdb.com/v/… · https://r18.dev/videos/vod/movies/detail/-/id=…"
              style={{...S.field, fontSize:13, fontFamily:'var(--mono)'}}
              autoFocus
              spellCheck={false}
            />
            <div style={{fontSize:11, color:'var(--text-muted)', lineHeight:1.5}}>
              Paste a javdb.com or r18.dev link to scrape that page directly, or enter an ID and Javinizer will search for it.
            </div>
            <button onClick={go} disabled={busy || !q.trim()} style={{background:'var(--accent)',border:'none',color:'#fff',padding:'8px',borderRadius:5,fontSize:13,fontWeight:600,cursor: busy || !q.trim() ? 'default' : 'pointer', opacity: busy || !q.trim() ? 0.5 : 1}}>
              {busy ? 'Scraping…' : '🔍 Scrape'}
            </button>
            {status && <div style={{fontSize:12, color: status.startsWith('Error') ? 'var(--red)' : 'var(--text-muted)'}}>{status}</div>}
          </div>
        )}

        {result && (
          <div style={{display:'flex', flexDirection:'column', flex:1, overflow:'hidden'}}>
            <div style={{display:'flex', gap:14, padding:14, overflow:'auto', flex:1}}>
              {cover && (
                <img src={cover} alt="" style={{width:160, height:'auto', borderRadius:4, border:'1px solid var(--border)', flexShrink:0, objectFit:'cover', alignSelf:'flex-start'}} />
              )}
              <div style={{flex:1, display:'flex', flexDirection:'column', gap:6, minWidth:0}}>
                {[
                  ['ID', result.Id],
                  ['Title', result.Title],
                  ['Release Date', result.ReleaseDate],
                  ['Runtime', result.Runtime ? `${result.Runtime} min` : ''],
                  ['Maker', result.Maker],
                  ['Series', result.Series],
                  ['Director', result.Director],
                  ['Actress', actressLabel],
                  ['Genre', genreLabel],
                  ['Source', result.Source],
                  ['URL', result.Url],
                ].filter(([,v]) => v).map(([k,v]) => (
                  <div key={k} style={{display:'grid', gridTemplateColumns:'90px 1fr', gap:8, fontSize:12}}>
                    <span style={{color:'var(--text-muted)', fontWeight:500}}>{k}</span>
                    <span style={{color:'var(--text)', wordBreak:'break-word', fontFamily: k==='URL'||k==='ID'?'var(--mono)':'inherit'}}>{v}</span>
                  </div>
                ))}
              </div>
            </div>
            <div style={{padding:'10px 14px', borderTop:'1px solid var(--border)', background:'var(--surface-2)', display:'flex', gap:8, alignItems:'center'}}>
              <button onClick={reset} style={{...S.btn, fontSize:12}}>← Scrape another</button>
              <div style={{flex:1}} />
              {onResult && (
                <button onClick={apply} style={{background:'var(--green)',border:'none',color:'#fff',padding:'6px 14px',borderRadius:5,fontSize:12,fontWeight:600,cursor:'pointer'}}>
                  Apply to selected file
                </button>
              )}
              <button onClick={onClose} style={{...S.btn, fontSize:12}}>Close</button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// ─── Sort All Modal ───────────────────────────────────────────────────────────

function SortAllModal({ videos, settings, onClose }) {
  const [rows, setRows] = useState(videos.map(v => ({ file: v, status: 'pending', msg: '' })));
  const [running, setRunning] = useState(false);
  const [done, setDone] = useState(false);
  const abortRef = useRef(false);
  const listRef = useRef();

  const summary = useMemo(() => {
    const ok  = rows.filter(r => r.status === 'ok').length;
    const err = rows.filter(r => r.status === 'error').length;
    const rem = rows.filter(r => r.status === 'pending').length;
    return { ok, err, rem, total: rows.length };
  }, [rows]);

  const setRow = (idx, patch) => setRows(rs => rs.map((r, i) => i === idx ? { ...r, ...patch } : r));

  const run = async () => {
    if (!settings.dest) return;
    setRunning(true);
    abortRef.current = false;
    for (let i = 0; i < rows.length; i++) {
      if (abortRef.current) { setRow(i, { status: 'pending', msg: 'Cancelled' }); break; }
      setRow(i, { status: 'running', msg: '…' });
      // scroll into view
      setTimeout(() => {
        const el = listRef.current?.children[i];
        if (el) el.scrollIntoView({ block: 'nearest' });
      }, 50);
      try {
        const res = await api('/api/sort', {
          method: 'POST',
          body: { path: rows[i].file.fullPath, destinationPath: settings.dest, settingsOverride: buildOverride(settings), flags: { force: settings.force, update: settings.update } }
        });
        setRow(i, { status: 'ok', msg: res.folderPath });
      } catch(e) {
        setRow(i, { status: 'error', msg: e.message });
      }
    }
    setRunning(false);
    setDone(true);
  };

  const statusIcon = { pending: '·', running: '⏳', ok: '✓', error: '✗' };
  const statusColor = { pending: 'var(--text-muted)', running: 'var(--yellow)', ok: 'var(--green)', error: 'var(--red)' };
  const progress = summary.total > 0 ? ((summary.ok + summary.err) / summary.total) * 100 : 0;

  return (
    <div style={{position:'fixed',inset:0,background:'rgba(0,0,0,0.75)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:1000}} onClick={!running ? onClose : undefined}>
      <div style={{background:'var(--surface)',border:'1px solid var(--border)',borderRadius:8,width:580,maxWidth:'92vw',maxHeight:'85vh',overflow:'hidden',display:'flex',flexDirection:'column'}} onClick={e=>e.stopPropagation()}>
        {/* Header */}
        <div style={{padding:'10px 14px',borderBottom:'1px solid var(--border)',display:'flex',alignItems:'center',justifyContent:'space-between'}}>
          <span style={{fontWeight:600,fontSize:14}}>Sort All — {summary.total} file{summary.total!==1?'s':''}</span>
          {!running && <button onClick={onClose} style={{background:'none',border:'none',color:'var(--text-muted)',cursor:'pointer',fontSize:20,lineHeight:1}}>×</button>}
        </div>

        {/* Progress bar */}
        {(running || done) && (
          <div style={{height:3,background:'var(--surface-2)',flexShrink:0}}>
            <div style={{height:'100%',background: summary.err > 0 ? 'var(--red)' : 'var(--green)',width:`${progress}%`,transition:'width 0.3s'}} />
          </div>
        )}

        {/* File list */}
        <div ref={listRef} style={{flex:1,overflowY:'auto',padding:'8px 0'}}>
          {rows.map((r, i) => (
            <div key={r.file.fullPath} style={{padding:'6px 14px',display:'flex',alignItems:'flex-start',gap:10,borderLeft:`2px solid ${r.status!=='pending'?statusColor[r.status]:'transparent'}`,background:r.status==='running'?'var(--surface-2)':'transparent'}}>
              <span style={{color:statusColor[r.status],fontSize:r.status==='running'?16:13,flexShrink:0,lineHeight:1.4,fontFamily:'var(--mono)'}}>{statusIcon[r.status]}</span>
              <div style={{flex:1,minWidth:0}}>
                <div style={{fontSize:12,fontFamily:'var(--mono)',overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap',color:'var(--text)'}}>{r.file.name}</div>
                {r.msg && r.msg!=='…' && (
                  <div style={{fontSize:11,color:r.status==='error'?'var(--red)':'var(--text-muted)',marginTop:2,overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap',fontFamily:'var(--mono)'}}>{r.msg}</div>
                )}
              </div>
            </div>
          ))}
        </div>

        {/* Footer */}
        <div style={{padding:'10px 14px',borderTop:'1px solid var(--border)',display:'flex',alignItems:'center',gap:10}}>
          {done ? (
            <>
              <span style={{flex:1,fontSize:12,color:'var(--text-muted)'}}>
                Done — <span style={{color:'var(--green)'}}>{summary.ok} sorted</span>
                {summary.err > 0 && <span style={{color:'var(--red)'}}>, {summary.err} failed</span>}
              </span>
              <button onClick={onClose} style={{...S.btn,fontSize:12}}>Close</button>
            </>
          ) : running ? (
            <>
              <span style={{flex:1,fontSize:12,color:'var(--text-muted)'}}>
                {summary.ok + summary.err} / {summary.total} — {summary.ok} sorted{summary.err>0?`, ${summary.err} failed`:''}
              </span>
              <button onClick={()=>{abortRef.current=true;}} style={{...S.btn,fontSize:12,borderColor:'var(--red)',color:'var(--red)'}}>Stop</button>
            </>
          ) : (
            <>
              <span style={{flex:1,fontSize:12,color:'var(--text-muted)'}}>
                {!settings.dest ? <span style={{color:'var(--red)'}}>⚠ No destination set — open Sort Settings first</span> : `Will sort ${summary.total} file${summary.total!==1?'s':''} → ${settings.dest}`}
              </span>
              <button onClick={onClose} style={{...S.btn,fontSize:12}}>Cancel</button>
              <button onClick={run} disabled={!settings.dest} style={{background:'var(--green)',border:'none',color:'#fff',padding:'6px 18px',borderRadius:5,fontSize:12,fontWeight:700}}>▶ Sort All</button>
            </>
          )}
        </div>
      </div>
    </div>
  );
}

// ─── Keyboard Help Modal ──────────────────────────────────────────────────────

function HelpModal({ onClose }) {
  const rows = [['j / ↓','Next video'],['k / ↑','Previous video'],['Home','First video'],['End','Last video'],['Enter','Sort current file'],['/ ','Focus search'],['Escape','Close modal / deselect'],['?','Toggle this help']];
  return (
    <div style={{position:'fixed',inset:0,background:'rgba(0,0,0,0.7)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:1000}} onClick={onClose}>
      <div style={{background:'var(--surface)',border:'1px solid var(--border)',borderRadius:8,width:380,overflow:'hidden'}} onClick={e=>e.stopPropagation()}>
        <div style={{padding:'10px 14px',borderBottom:'1px solid var(--border)',display:'flex',alignItems:'center',justifyContent:'space-between',fontWeight:600,fontSize:14}}>
          <span>Keyboard Shortcuts</span>
          <button onClick={onClose} style={{background:'none',border:'none',color:'var(--text-muted)',cursor:'pointer',fontSize:20,lineHeight:1}}>×</button>
        </div>
        <div style={{padding:16,display:'flex',flexDirection:'column',gap:8}}>
          {rows.map(([k,d])=>(
            <div key={k} style={{display:'flex',gap:14,alignItems:'center'}}>
              <kbd className="kbd" style={{minWidth:80,textAlign:'center'}}>{k}</kbd>
              <span style={{fontSize:12,color:'var(--text-soft)'}}>{d}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ─── Detail Panel ─────────────────────────────────────────────────────────────

function DetailPanel({ file, videos, selectedIdx, onNavigate, onFileSorted, settings, addToast }) {
  const [data, setData] = useState(null);
  const [original, setOriginal] = useState(null);
  const [scraping, setScraping] = useState(false);
  const [sorting, setSorting] = useState(false);
  const [pathPreview, setPathPreview] = useState(null);
  const [tab, setTab] = useState('metadata');
  const [showScreens, setShowScreens] = useState(false);
  const [showManual, setShowManual] = useState(false);
  const prevPath = useRef(null);

  // Scrape on file change
  useEffect(() => {
    if (!file || file.fullPath === prevPath.current) return;
    prevPath.current = file.fullPath;
    setScraping(true);
    setData(null);
    setPathPreview(null);
    api('/api/scrape', { method:'POST', body:{ path: file.fullPath } })
      .then(res => {
        setData(JSON.parse(JSON.stringify(res.data)));
        setOriginal(JSON.parse(JSON.stringify(res.data)));
      })
      .catch(e => addToast('Scrape failed: ' + e.message, 'error'))
      .finally(() => setScraping(false));
  }, [file]);

  // Live path preview
  useEffect(() => {
    if (!file || !settings.dest) { setPathPreview(null); return; }
    const t = setTimeout(async () => {
      try {
        const res = await api('/api/preview', { method:'POST', body:{ path:file.fullPath, destinationPath:settings.dest, settingsOverride:buildOverride(settings) }});
        setPathPreview(res.filePath);
      } catch { setPathPreview(null); }
    }, 300);
    return () => clearTimeout(t);
  }, [file, settings]);

  const doSort = async () => {
    if (!settings.dest) { addToast('Set a destination folder first', 'error'); return; }
    setSorting(true);
    try {
      const res = await api('/api/sort', { method:'POST', body:{ path:file.fullPath, destinationPath:settings.dest, settingsOverride:buildOverride(settings), flags:{ force:settings.force, update:settings.update }, data }});
      addToast(`✓ Sorted → ${res.folderPath}`, 'ok');
      const sortedPath = file.fullPath;
      setTimeout(() => onFileSorted(sortedPath), 400);
    } catch(e) { addToast('Sort failed: ' + e.message, 'error'); }
    finally { setSorting(false); }
  };

  const handleFieldChange = (key, val) => setData(d => ({ ...d, [key]: val }));
  const handleReset = () => { if (original) { setData(JSON.parse(JSON.stringify(original))); addToast('Reset to original', 'info'); } };

  // Keyboard shortcut: Enter to sort
  useEffect(() => {
    const handler = (e) => {
      if (e.key === 'Enter' && !e.target.matches('input,textarea,button,select') && file && !sorting) doSort();
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [file, sorting, settings, data]);

  if (!file) return (
    <div style={{flex:1, display:'flex', alignItems:'center', justifyContent:'center', flexDirection:'column', gap:10, color:'var(--text-muted)'}}>
      <div style={{fontSize:40, opacity:0.2}}>🎞</div>
      <div style={{fontSize:13}}>Select a video to begin</div>
      <div style={{fontSize:11, display:'flex', gap:8}}>
        <span className="kbd">j/k</span><span>navigate</span>
        <span className="kbd">/</span><span>search</span>
        <span className="kbd">?</span><span>help</span>
      </div>
    </div>
  );

  const cover = data && (Array.isArray(data.CoverUrl) ? data.CoverUrl[0] : data.CoverUrl);
  const shots = data?.ScreenshotUrl ? (Array.isArray(data.ScreenshotUrl) ? data.ScreenshotUrl : [data.ScreenshotUrl]) : [];

  return (
    <div style={{display:'flex', flexDirection:'column', height:'100%', overflow:'hidden'}}>

      {/* Nav / action bar */}
      <div style={{padding:'8px 14px', borderBottom:'1px solid var(--border)', display:'flex', alignItems:'center', gap:8, background:'var(--surface-2)', flexShrink:0}}>
        <button onClick={() => onNavigate(Math.max(0, selectedIdx-1))} disabled={selectedIdx<=0} style={S.iconBtn} title="Previous (k)">←</button>
        <button onClick={() => onNavigate(Math.min(videos.length-1, selectedIdx+1))} disabled={selectedIdx>=videos.length-1} style={S.iconBtn} title="Next (j)">→</button>
        <span style={{fontSize:11, color:'var(--text-muted)', flexShrink:0, minWidth:50}}>{selectedIdx+1} / {videos.length}</span>
        <span style={{flex:1, fontSize:13, fontWeight:500, fontFamily:'var(--mono)', overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap', color:'var(--text)'}}>{file.name}</span>
        <button onClick={()=>setShowManual(true)} style={{...S.btn, fontSize:11}}>🔍 Manual</button>
        <button onClick={()=>setShowScreens(true)} disabled={shots.length===0} style={{...S.btn, fontSize:11}}>🖼 Screens {shots.length>0 && `(${shots.length})`}</button>
        <button
          onClick={doSort} disabled={sorting||!settings.dest}
          style={{background:sorting?'var(--surface-3)':'var(--green)', border:'none', color:'#fff', padding:'5px 16px', borderRadius:5, fontSize:13, fontWeight:700, letterSpacing:'0.02em', transition:'background 0.2s'}}
          title="Sort (Enter)"
        >
          {sorting ? '⏳ Sorting…' : '▶ SORT'}
        </button>
      </div>

      {/* Path preview */}
      <div style={{padding:'5px 14px', borderBottom:'1px solid var(--border)', background:'var(--surface)', display:'flex', alignItems:'center', gap:8, flexShrink:0, minHeight:28}}>
        <span style={{fontSize:10, color:'var(--text-muted)', flexShrink:0, letterSpacing:'0.05em'}}>DEST</span>
        <code style={{fontSize:11, color: pathPreview ? 'var(--accent-light)' : 'var(--text-muted)', fontFamily:'var(--mono)', flex:1, overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap'}}>
          {pathPreview || (settings.dest ? '(computing…)' : 'Set destination in Sort Settings ↑')}
        </code>
      </div>

      {/* Content area */}
      <div style={{flex:1, overflow:'hidden', display:'flex', gap:0}}>
        {/* Cover column */}
        <div style={{flex:'0 0 50%', maxWidth:760, minWidth:320, borderRight:'1px solid var(--border)', padding:12, display:'flex', flexDirection:'column', gap:10, overflowY:'auto'}}>
          <div style={{background:'var(--surface-2)', border:'1px solid var(--border)', borderRadius:6, overflow:'hidden', display:'flex', alignItems:'center', justifyContent:'center', minHeight: scraping ? 120 : undefined}}>
            {scraping
              ? <Sk w="100%" h={120} style={{borderRadius:0}} />
              : cover
                ? <img src={cover} alt="cover" style={{maxWidth:'100%', maxHeight:480, height:'auto', width:'auto', display:'block'}} />
                : <div style={{color:'var(--text-muted)',fontSize:12,textAlign:'center',padding:12}}>No cover</div>
            }
          </div>
          {scraping ? (
            <div style={{display:'flex',flexDirection:'column',gap:6}}>
              <Sk h={14}/><Sk h={12} w="60%"/><Sk h={12} w="70%"/>
            </div>
          ) : data && (
            <div style={{display:'flex',flexDirection:'column',gap:5}}>
              {data.Rating != null && <div style={{fontSize:12}}>⭐ <strong>{data.Rating}</strong> <span style={{color:'var(--text-muted)',fontSize:11}}>({(data.Votes||0).toLocaleString()} votes)</span></div>}
              {data.Runtime && <div style={{fontSize:11,color:'var(--text-muted)'}}>⏱ {data.Runtime} min</div>}
              {data.ReleaseDate && <div style={{fontSize:11,color:'var(--text-muted)'}}>📅 {data.ReleaseDate}</div>}
              {data.Maker && <div style={{fontSize:11,color:'var(--text-muted)'}}>🏷 {data.Maker}</div>}
              {data.Genre?.length > 0 && (
                <div style={{display:'flex',flexWrap:'wrap',gap:3,marginTop:4}}>
                  {(Array.isArray(data.Genre)?data.Genre:data.Genre.split(' \\ ')).map((g,i)=>(
                    <span key={i} style={{background:'var(--surface-3)',border:'1px solid var(--border)',borderRadius:3,padding:'1px 5px',fontSize:10,color:'var(--text-soft)'}}>{g}</span>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>

        {/* Right panel: tabs + content */}
        <div style={{flex:1, display:'flex', flexDirection:'column', overflow:'hidden'}}>
          {/* Tabs */}
          <div style={{display:'flex', alignItems:'center', borderBottom:'1px solid var(--border)', padding:'0 14px', flexShrink:0}}>
            {[['metadata','Metadata'],['actresses','Actresses'],['json','Raw JSON']].map(([t,l])=>(
              <button key={t} className={`tab-btn${tab===t?' active':''}`} onClick={()=>setTab(t)}>{l}</button>
            ))}
            <div style={{flex:1}}/>
            <button onClick={handleReset} style={{...S.btn, fontSize:11, margin:'4px 0'}}>↺ Reset</button>
          </div>

          {/* Tab content */}
          <div style={{flex:1, overflowY:'auto', padding:14}}>
            {scraping ? (
              <div style={{display:'flex',flexDirection:'column',gap:8}}>
                {[...Array(8)].map((_,i)=><Sk key={i} h={26} w={i%3===0?'100%':i%2===0?'60%':'80%'}/>)}
              </div>
            ) : tab==='metadata' ? (
              <MetadataForm data={data} onChange={handleFieldChange} />
            ) : tab==='actresses' ? (
              <ActressPanel actresses={data?.Actress} />
            ) : (
              <pre style={{margin:0, fontSize:11, fontFamily:'var(--mono)', color:'var(--text-soft)', whiteSpace:'pre-wrap', wordBreak:'break-all', lineHeight:1.6}}>
                {JSON.stringify(data, null, 2)}
              </pre>
            )}
          </div>
        </div>
      </div>

      {showScreens && <ScreensModal urls={shots} onClose={()=>setShowScreens(false)} />}
      {showManual && <ManualModal onClose={()=>setShowManual(false)} onResult={d=>{setData(d);setOriginal(JSON.parse(JSON.stringify(d)));}} toast={addToast} />}
    </div>
  );
}

// ─── App ──────────────────────────────────────────────────────────────────────

const DEFAULT_SETTINGS = {
  dest: '/Volumes/Media/Sorted',
  outputfolder: '<ACTORS>',
  folder: '<ID> [<STUDIO>] - <TITLE> (<YEAR>)',
  file: '<ID>',
  groupActress: true,
  unknownActress: true,
  recurse: false,
  update: false,
  force: false,
};

function App() {
  const { toasts, add, remove } = useToasts();
  const [showSettings, setShowSettings] = useState(true);
  const [showHelp, setShowHelp] = useState(false);
  const [showSortAll, setShowSortAll] = useState(false);
  const [settings, setSettings] = useState(() => {
    try { return JSON.parse(localStorage.getItem('jv-settings') || 'null') || DEFAULT_SETTINGS; } catch { return DEFAULT_SETTINGS; }
  });
  const [selectedFile, setSelectedFile] = useState(null);
  const [videos, setVideos] = useState([]);
  const [selectedIdx, setSelectedIdx] = useState(-1);
  const [sortedPaths, setSortedPaths] = useState(() => new Set());
  const [serverSettings, setServerSettings] = useState(null);
  const [showManualScrape, setShowManualScrape] = useState(false);

  // Persist settings
  useEffect(() => { localStorage.setItem('jv-settings', JSON.stringify(settings)); }, [settings]);

  // Hydrate from server on mount. Always store serverSettings for the dirty
  // indicator; if the browser has no cached settings yet, also seed `settings`
  // so the UI starts from the user's saved defaults.
  useEffect(() => {
    (async () => {
      try {
        const res = await api('/api/settings');
        const srv = res?.settings || null;
        setServerSettings(srv);
        if (srv && !localStorage.getItem('jv-settings')) {
          setSettings(s => ({ ...s, ...parseServerSettings(srv) }));
        }
      } catch { /* server unreachable — keep defaults */ }
    })();
  }, []);

  const handleSaveDefaults = useCallback(async () => {
    try {
      const res = await api('/api/settings', {
        method: 'POST',
        body: { settings: buildFullSettingsPayload(settings) },
      });
      setServerSettings(res.settings || null);
      add('✓ Saved as default', 'ok');
    } catch (e) {
      add('Save failed: ' + e.message, 'error');
    }
  }, [settings, add]);

  const handleResetToSaved = useCallback(() => {
    if (!serverSettings) { add('No saved defaults yet', 'info'); return; }
    setSettings(s => ({ ...s, ...parseServerSettings(serverSettings) }));
    add('Reset to saved defaults', 'info');
  }, [serverSettings, add]);

  const handleVideosChange = useCallback((vids) => {
    setVideos(vids);
    setSelectedFile(null);
    setSelectedIdx(-1);
    setSortedPaths(new Set());
  }, []);

  const handleSelect = useCallback((file, idx) => {
    setSelectedFile(file);
    setSelectedIdx(idx);
  }, []);

  const handleNavigate = useCallback((idx) => {
    setVideos(vs => {
      if (idx < 0 || idx >= vs.length) return vs;
      setSelectedFile(vs[idx]);
      setSelectedIdx(idx);
      return vs;
    });
  }, []);

  const handleFileSorted = useCallback((fullPath) => {
    setSortedPaths(prev => { const n = new Set(prev); n.add(fullPath); return n; });
    setVideos(vs => {
      const idx = vs.findIndex(v => v.fullPath === fullPath);
      if (idx < 0) return vs;
      const next = vs.filter((_, i) => i !== idx);
      setSelectedIdx(cur => {
        if (cur === idx) {
          if (next.length === 0) { setSelectedFile(null); return -1; }
          const newIdx = Math.min(idx, next.length - 1);
          setSelectedFile(next[newIdx]);
          return newIdx;
        }
        if (cur > idx) return cur - 1;
        return cur;
      });
      return next;
    });
  }, []);

  // Global keyboard nav
  useEffect(() => {
    const handler = (e) => {
      const editing = ['INPUT','TEXTAREA','SELECT'].includes(document.activeElement?.tagName);
      if (e.key === '?') { setShowHelp(h=>!h); return; }
      if (e.key === 'Escape') { setShowHelp(false); return; }
      if (editing) return;
      if (e.key === 'j' || e.key === 'ArrowDown') { e.preventDefault(); handleNavigate(selectedIdx + 1); }
      if (e.key === 'k' || e.key === 'ArrowUp')   { e.preventDefault(); handleNavigate(Math.max(0, selectedIdx - 1)); }
      if (e.key === 'Home') { e.preventDefault(); handleNavigate(0); }
      if (e.key === 'End')  { e.preventDefault(); handleNavigate(videos.length - 1); }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [selectedIdx, videos, handleNavigate]);

  return (
    <div style={{display:'flex', flexDirection:'column', height:'100vh', background:'var(--bg)', color:'var(--text)', fontFamily:'var(--sans)', overflow:'hidden'}}>
      <Header showSettings={showSettings} setShowSettings={setShowSettings} onHelp={()=>setShowHelp(true)} onSortAll={()=>setShowSortAll(true)} onManualScrape={()=>setShowManualScrape(true)} videoCount={videos.length} />
      {showSettings && <SortSettings s={settings} set={setSettings} serverSettings={serverSettings} onSaveDefaults={handleSaveDefaults} onResetToSaved={handleResetToSaved} addToast={add} />}
      <div style={{flex:1, display:'flex', overflow:'hidden'}}>
        {/* Sidebar */}
        <div style={{width:268, flexShrink:0, borderRight:'1px solid var(--border)', display:'flex', flexDirection:'column', overflow:'hidden'}}>
          <FileBrowser selected={selectedFile} onSelect={handleSelect} onVideosChange={handleVideosChange} recurse={settings.recurse} sortedPaths={sortedPaths} initialPath={settings.src} />
        </div>
        {/* Detail */}
        <div style={{flex:1, overflow:'hidden', display:'flex', flexDirection:'column'}}>
          <DetailPanel
            file={selectedFile}
            videos={videos}
            selectedIdx={selectedIdx}
            onNavigate={handleNavigate}
            onFileSorted={handleFileSorted}
            settings={settings}
            addToast={add}
          />
        </div>
      </div>
      <ToastHost toasts={toasts} remove={remove} />
      {showHelp && <HelpModal onClose={()=>setShowHelp(false)} />}
      {showSortAll && <SortAllModal videos={videos} settings={settings} onClose={()=>setShowSortAll(false)} />}
      {showManualScrape && <ManualModal onClose={()=>setShowManualScrape(false)} toast={add} />}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);

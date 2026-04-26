const { useState, useEffect, useRef, useCallback, useMemo } = React;

// Frontend version constant. Bumped on every release alongside
// Javinizer.psd1's ModuleVersion + the index.html cache-buster.
// Compared against /api/version's server version; mismatch means
// the browser is running cached old app.jsx — a hard-refresh
// (Cmd+Shift+R) is needed to pick up server-side fixes.
const APP_JSX_VERSION = '1.11.1';

// ─── API ─────────────────────────────────────────────────────────────────────

const DEFAULT_ROOT = '/Volumes/Media/';

async function api(path, opts = {}) {
  const init = {
    method: opts.method || 'GET',
    headers: opts.body ? { 'Content-Type': 'application/json' } : {},
    body: opts.body ? JSON.stringify(opts.body) : undefined,
    // Bypass the browser's HTTP cache for every API call. Without this,
    // a mutation followed by a re-fetch (e.g. cleanup → reloadAll) could
    // serve the pre-mutation cached response and the UI would show stale
    // data even though the server-side dataset is correct. The Pode
    // no-cache middleware sets headers, this is belt-and-suspenders.
    cache: 'no-store',
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
  { key: 'PosterUrl', label: 'Poster URL', span: true },
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

function Header({ showSettings, setShowSettings, onHelp, onSortAll, onManualScrape, videoCount, view, setView, version }) {
  // Version chip rendered immediately before the title. Compares the
  // baked-in APP_JSX_VERSION against /api/version (server). On mismatch
  // the chip turns orange + carries a hard-refresh hint in its tooltip.
  const mismatch = version && version !== APP_JSX_VERSION;
  const vTip = mismatch
    ? `Browser is running cached app.jsx v${APP_JSX_VERSION} but server is v${version}. Hard-refresh (Cmd/Ctrl+Shift+R) to pick up the latest UI.`
    : `Javinizer v${APP_JSX_VERSION}`;
  const vLabel = mismatch
    ? `ui v${APP_JSX_VERSION} ↛ srv v${version} ⚠`
    : `v${APP_JSX_VERSION}`;
  return (
    <header style={{
      background:'var(--surface)', borderBottom:'1px solid var(--border)',
      padding:'0 16px', height:44, display:'flex', alignItems:'center', gap:10, flexShrink:0,
    }}>
      <span
        title={vTip}
        style={{
          fontFamily:'var(--mono, monospace)', fontSize:10, lineHeight:1,
          padding:'3px 6px', borderRadius:3,
          background: mismatch ? 'var(--orange, #d97706)' : 'var(--surface-2)',
          color: mismatch ? '#fff' : 'var(--text-muted)',
          fontWeight: mismatch ? 600 : 500,
          cursor: mismatch ? 'help' : 'default',
          userSelect:'none',
          flexShrink:0,
        }}
      >{vLabel}</span>
      <span style={{fontSize:15, fontWeight:600, letterSpacing:'-0.01em', flex:1}}>Javinizer {view === 'library' ? 'Library' : 'Sort'}</span>
      <button
        onClick={() => setView(v => v === 'library' ? 'sort' : 'library')}
        style={{...S.btn, background: view === 'library' ? 'var(--accent-dim)' : 'transparent', color: view === 'library' ? 'var(--accent-light)' : 'var(--text-muted)', borderColor: view === 'library' ? 'var(--accent)' : 'var(--border)'}}
        title="Browse actress dataset"
      >👥 Library</button>
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

// ─── Job Progress Bar ─────────────────────────────────────────────────────────

function JobProgressBar({ jobId, onDone }) {
  const [state, setState] = useState(null);
  const [reconnect, setReconnect] = useState(0);  // consecutive failed polls

  useEffect(() => {
    if (!jobId) { setState(null); setReconnect(0); return; }
    let cancelled = false;
    let timer = null;
    let consecutiveErrors = 0;
    // Cap retries so a permanently dead server eventually clears the bar,
    // but generously enough that a heavily-loaded Pode (the threadjob is
    // burning CPU and HTTP handlers are sluggish) doesn't drop the bar.
    // 30 ticks × ~2 s avg = ~60 s of failed polls before we give up.
    const MAX_RETRIES = 30;

    const tick = async () => {
      try {
        const s = await api(`/api/jobs/${jobId}`);
        if (cancelled) return;
        consecutiveErrors = 0;
        setReconnect(0);
        setState(s);
        if (s.status === 'running') {
          timer = setTimeout(tick, 750);
        }
        // For done/error/cancelled: stop polling but keep the final state
        // visible so the user can read it. The × button calls onDone(null)
        // when they're ready to dismiss.
      } catch (e) {
        if (cancelled) return;
        // Distinguish "job genuinely missing" (404) from transient errors
        // (network blip, Pode handler slow because the threadjob is hot).
        // 404 is the only signal that should clear the bar; everything else
        // gets retried with linear backoff.
        const is404 = /HTTP 404|not found/i.test(e?.message || '');
        if (is404) {
          if (onDone) onDone(null);
          return;
        }
        consecutiveErrors++;
        setReconnect(consecutiveErrors);
        if (consecutiveErrors >= MAX_RETRIES) {
          if (onDone) onDone(null);
          return;
        }
        // Linear backoff capped at 5 s so we keep checking when the server
        // catches its breath.
        const delay = Math.min(750 + consecutiveErrors * 500, 5000);
        timer = setTimeout(tick, delay);
      }
    };
    tick();
    return () => { cancelled = true; if (timer) clearTimeout(timer); };
  }, [jobId]);

  if (!state) {
    // No state yet but we're trying — show a minimal "connecting" sliver so
    // the user knows we haven't given up.
    if (jobId && reconnect > 0) {
      return (
        <div style={{position:'sticky', top:0, zIndex:500, background:'var(--surface)', borderBottom:`1px solid var(--border)`, padding:'4px 12px', display:'flex', alignItems:'center', gap:10, fontSize:11}}>
          <span style={{color:'var(--orange, #d97706)', fontWeight:600, textTransform:'uppercase', fontSize:10}}>job · reconnecting</span>
          <span style={{color:'var(--text-muted)', fontSize:11}}>retrying… (attempt {reconnect})</span>
        </div>
      );
    }
    return null;
  }
  const isRunning = state.status === 'running';
  const cur = state.progress?.current ?? 0;
  const tot = state.progress?.total ?? 0;
  const pct = tot > 0 ? Math.round((cur / tot) * 100) : 0;
  const stalledFor = state.progress?.stalledFor ?? 0;
  // Surface "stalled Xm" once `current` hasn't advanced in over a minute —
  // typically means a runspace is sleeping in an xcity Retry-After backoff.
  const showStalled = isRunning && stalledFor > 60;
  const stalledLabel = showStalled
    ? (stalledFor >= 60 ? `${Math.round(stalledFor / 60)}m` : `${stalledFor}s`)
    : '';
  const statusColor =
    state.status === 'done'      ? 'var(--green)' :
    state.status === 'error'     ? 'var(--red)' :
    state.status === 'cancelled' ? 'var(--text-muted)' :
                                   'var(--accent)';

  const cancel = async () => {
    try { await api(`/api/jobs/${jobId}/cancel`, { method:'POST' }); } catch {}
  };

  return (
    <div style={{position:'sticky', top:0, zIndex:500, background:'var(--surface)', borderBottom:`1px solid var(--border)`, padding:'4px 12px', display:'flex', alignItems:'center', gap:10, fontSize:11}}>
      <span style={{color: statusColor, fontWeight:600, textTransform:'uppercase', fontSize:10, minWidth:60}}>{state.kind || 'job'} · {state.status}</span>
      <div style={{flex:1, height:5, background:'var(--surface-2)', borderRadius:3, overflow:'hidden'}}>
        <div style={{height:'100%', width:`${pct}%`, background: statusColor, transition:'width 200ms ease'}} />
      </div>
      <span style={{color:'var(--text-muted)', minWidth:50, textAlign:'right'}}>{cur}/{tot}</span>
      <span style={{color:'var(--text-soft)', flex:'0 1 auto', maxWidth:'40%', overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap'}}>{state.progress?.message}</span>
      {showStalled && <span style={{color:'var(--orange, #d97706)', fontSize:10, fontWeight:600, whiteSpace:'nowrap'}} title={`No progress in ${stalledLabel}. The runspace may be sleeping in an xcity backoff — see job log.`}>· stalled {stalledLabel}</span>}
      {reconnect > 0 && <span style={{color:'var(--orange, #d97706)', fontSize:10, fontWeight:600, whiteSpace:'nowrap'}} title={`Lost connection to server. Last good poll showed the state below; retrying (${reconnect}/30).`}>· reconnecting {reconnect}</span>}
      {isRunning && <button onClick={cancel} style={{...S.btn, fontSize:10, padding:'2px 6px'}}>Cancel</button>}
      {!isRunning && <button onClick={() => onDone && onDone(null)} style={{...S.btn, fontSize:10, padding:'2px 6px'}}>×</button>}
    </div>
  );
}

// ─── Actress Cleanup Modal ────────────────────────────────────────────────────

function ActressCleanupModal({ onClose, onDone, addToast }) {
  const [preview, setPreview] = useState(null);  // { removedCount, keptCount, removed, aliasFixedEntries, aliasDuplicatesRemoved, aliasMaxBefore }
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [rules, setRules] = useState({ 'empty-name': true, 'stub': true, 'mojibake': true });
  const [dedupAliases, setDedupAliases] = useState(true);

  const runDryRun = useCallback(async () => {
    setLoading(true);
    try {
      const selected = Object.keys(rules).filter(k => rules[k]);
      const res = await api('/api/actresses/cleanup', { method:'POST', body:{ rules: selected, dedupAliases, dryRun: true } });
      setPreview(res);
    } catch (e) {
      addToast?.('Preview failed: ' + e.message, 'error');
      setPreview({ removedCount:0, keptCount:0, removed:[] });
    } finally { setLoading(false); }
  }, [rules, dedupAliases, addToast]);

  useEffect(() => { runDryRun(); }, [runDryRun]);

  const commit = async () => {
    const willChange = (preview?.removedCount ?? 0) + (preview?.aliasFixedEntries ?? 0);
    if (!preview || willChange === 0) return;
    setBusy(true);
    try {
      const selected = Object.keys(rules).filter(k => rules[k]);
      const res = await api('/api/actresses/cleanup', { method:'POST', body:{ rules: selected, dedupAliases, dryRun: false } });
      const parts = [];
      if (res.removedCount > 0)         parts.push(`removed ${res.removedCount} entr${res.removedCount===1?'y':'ies'}`);
      if (res.aliasFixedEntries > 0)    parts.push(`deduped aliases on ${res.aliasFixedEntries} entr${res.aliasFixedEntries===1?'y':'ies'} (${res.aliasDuplicatesRemoved} copies)`);
      addToast?.(parts.length ? parts.join(', ') : `No changes (${res.keptCount} kept)`, 'ok');
      onDone?.();
    } catch (e) { addToast?.('Cleanup failed: ' + e.message, 'error'); }
    finally { setBusy(false); }
  };

  const reasonGroups = useMemo(() => {
    if (!preview?.removed) return {};
    return preview.removed.reduce((acc, r) => { (acc[r.reason] ||= []).push(r); return acc; }, {});
  }, [preview]);

  return (
    <div style={{position:'fixed',inset:0,background:'rgba(0,0,0,0.7)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:1500}} onClick={onClose}>
      <div style={{background:'var(--surface)',border:'1px solid var(--border)',borderRadius:8,width:600,maxWidth:'92vw',maxHeight:'85vh',padding:18,display:'flex',flexDirection:'column',gap:12,overflow:'hidden'}} onClick={e=>e.stopPropagation()}>
        <div style={{display:'flex',justifyContent:'space-between',alignItems:'center',flexShrink:0}}>
          <div style={{fontSize:16,fontWeight:600}}>🧹 Cleanup actress dataset</div>
          <button onClick={onClose} style={{background:'none',border:'none',color:'var(--text-muted)',cursor:'pointer',fontSize:20}}>×</button>
        </div>

        <div style={{display:'flex',gap:14,flexWrap:'wrap',fontSize:12,flexShrink:0}}>
          <label style={{display:'flex',gap:5,alignItems:'center',cursor:'pointer',userSelect:'none'}} title="Drop entries whose name field is empty/null/whitespace">
            <input type="checkbox" checked={rules['empty-name']} onChange={e=>setRules(s=>({...s,'empty-name':e.target.checked}))} style={{accentColor:'var(--accent)'}}/>
            Empty-name entries
          </label>
          <label style={{display:'flex',gap:5,alignItems:'center',cursor:'pointer',userSelect:'none'}} title="Drop entries with no bio AND no photo AND no xcity ID — placeholder stubs from older releases">
            <input type="checkbox" checked={rules['stub']} onChange={e=>setRules(s=>({...s,'stub':e.target.checked}))} style={{accentColor:'var(--accent)'}}/>
            Stub entries (no bio/photo/xcityId)
          </label>
          <label style={{display:'flex',gap:5,alignItems:'center',cursor:'pointer',userSelect:'none'}} title="Drop entries whose name contains chars that don't appear in legitimate Japanese romaji — control chars (\n, \t), Latin-1 Supplement (â Å ã Ã Â — typical UTF-8-as-Latin-1 mojibake), or the Unicode replacement char. Real macron vowels (ū ō ā ē ī) are at U+0100+ and survive.">
            <input type="checkbox" checked={rules['mojibake']} onChange={e=>setRules(s=>({...s,'mojibake':e.target.checked}))} style={{accentColor:'var(--accent)'}}/>
            Mojibake / control chars (â, Å, \n, …)
          </label>
          <label style={{display:'flex',gap:5,alignItems:'center',cursor:'pointer',userSelect:'none'}} title="Walk every kept entry's aliases array, collapse single-string entries that are a substring repeated N times (e.g. 'Yamagishi AikaYamagishi Aika' → 'Yamagishi Aika'), then dedup case-insensitively, trim whitespace, and drop aliases matching the canonical name. The merge function in v1.10.1+ is also stricter so corruption won't re-accumulate.">
            <input type="checkbox" checked={dedupAliases} onChange={e=>setDedupAliases(e.target.checked)} style={{accentColor:'var(--accent)'}}/>
            Dedup duplicate aliases
          </label>
        </div>

        <div style={{flex:1,overflowY:'auto',background:'var(--surface-2)',border:'1px solid var(--border)',borderRadius:6,padding:10}}>
          {loading ? (
            <div style={{color:'var(--text-muted)',fontSize:12,textAlign:'center',padding:20}}>Scanning…</div>
          ) : !preview ? (
            <div style={{color:'var(--text-muted)',fontSize:12,textAlign:'center',padding:20}}>No data</div>
          ) : preview.removedCount === 0 && (preview.aliasFixedEntries ?? 0) === 0 ? (
            <div style={{color:'var(--text-soft)',fontSize:13,textAlign:'center',padding:30}}>
              ✓ Nothing to clean — all {preview.keptCount} entries are valid.
            </div>
          ) : (
            <div style={{display:'flex',flexDirection:'column',gap:8,fontSize:11}}>
              <div style={{color:'var(--text-soft)'}}>
                {preview.removedCount > 0 && <>Will remove <strong>{preview.removedCount}</strong> entr{preview.removedCount===1?'y':'ies'}, keep <strong>{preview.keptCount}</strong>.</>}
                {(preview.aliasFixedEntries ?? 0) > 0 && (
                  <span>
                    {preview.removedCount > 0 ? ' Also dedup ' : 'Will dedup '}
                    aliases on <strong>{preview.aliasFixedEntries}</strong> entr{preview.aliasFixedEntries===1?'y':'ies'} ({preview.aliasDuplicatesRemoved} duplicate cop{preview.aliasDuplicatesRemoved===1?'y':'ies'}{(preview.aliasRepaired ?? 0) > 0 ? `, ${preview.aliasRepaired} repaired in-string repeat${preview.aliasRepaired===1?'':'s'}` : ''}{preview.aliasMaxBefore > 1 ? `, worst entry had ${preview.aliasMaxBefore} aliases` : ''}).
                  </span>
                )}
              </div>
              {Object.entries(reasonGroups).map(([reason, items]) => (
                <div key={reason}>
                  <div style={{fontWeight:600, color:'var(--text-muted)', textTransform:'uppercase', fontSize:10, letterSpacing:'0.06em', marginTop:6, marginBottom:3}}>
                    {reason} ({items.length})
                  </div>
                  <div style={{display:'flex',flexDirection:'column',gap:2,fontFamily:'var(--mono)',fontSize:11}}>
                    {items.slice(0, 200).map((it, i) => (
                      <div key={i} style={{color:'var(--text-soft)', overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap'}}>
                        {it.name ? it.name : <span style={{color:'var(--text-muted)',fontStyle:'italic'}}>(blank, key={it.key})</span>}
                      </div>
                    ))}
                    {items.length > 200 && <div style={{color:'var(--text-muted)',fontStyle:'italic'}}>… +{items.length - 200} more</div>}
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

        <div style={{display:'flex',gap:8,justifyContent:'flex-end',borderTop:'1px solid var(--border)',paddingTop:10,flexShrink:0}}>
          <button onClick={onClose} style={{...S.btn}}>Cancel</button>
          <button onClick={runDryRun} disabled={loading || busy} style={{...S.btn}}>↻ Re-scan</button>
          {(() => {
            const willRemove = preview?.removedCount ?? 0;
            const willDedup  = preview?.aliasFixedEntries ?? 0;
            const willChange = willRemove + willDedup;
            const disabled = loading || busy || willChange === 0;
            const label = busy
              ? 'Applying…'
              : willChange === 0
                ? '🗑 Apply'
                : willRemove > 0 && willDedup > 0
                  ? `🗑 Remove ${willRemove}, dedup ${willDedup}`
                  : willRemove > 0
                    ? `🗑 Remove ${willRemove}`
                    : `✂ Dedup ${willDedup}`;
            return (
              <button onClick={commit} disabled={disabled}
                      style={{background:'var(--red, #c55)', border:'none', color:'#fff', padding:'6px 16px', borderRadius:5, fontSize:12, fontWeight:600, opacity:disabled?0.5:1, cursor:disabled?'default':'pointer'}}>
                {label}
              </button>
            );
          })()}
        </div>
      </div>
    </div>
  );
}

// ─── Jellyfin Mojibake Cleanup Modal ──────────────────────────────────────────
// Two-step: Scan (dry-run) → preview → Apply. Both steps are background jobs
// (walking thousands of movies via Jellyfin's REST API takes minutes), surfaced
// via the global JobProgressBar through onJob. Modal polls /api/jobs/:id
// directly to grab the job's `result` once status='done'.

function JellyfinMojibakeCleanupModal({ onClose, onJob, addToast }) {
  const [busy, setBusy] = useState(false);
  const [phase, setPhase] = useState('idle');  // 'idle' | 'scanning' | 'preview' | 'applying' | 'done'
  const [result, setResult] = useState(null);  // { moviesScanned, moviesPatched, peopleRemoved, personsDeleted, modifiedMovies, deletedPersons, dryRun }

  // Kick off a background job, poll until it finishes, return its result.
  const runJob = useCallback(async (dryRun) => {
    setBusy(true);
    try {
      const start = await api('/api/jellyfin/cleanup-mojibake', { method:'POST', body:{ dryRun } });
      const id = start?.jobId;
      if (!id) throw new Error('no jobId returned');
      onJob?.(id);

      // Poll until done. Same cadence as JobProgressBar's main loop.
      while (true) {
        await new Promise(r => setTimeout(r, 800));
        const s = await api(`/api/jobs/${id}`);
        if (s.status === 'done')      return s.result;
        if (s.status === 'error')     throw new Error(s.error || 'job failed');
        if (s.status === 'cancelled') throw new Error('job cancelled');
      }
    } finally {
      setBusy(false);
    }
  }, [onJob]);

  const scan = async () => {
    setPhase('scanning');
    try {
      const r = await runJob(true);
      setResult(r);
      setPhase('preview');
    } catch (e) {
      addToast?.('Scan failed: ' + e.message, 'error');
      setPhase('idle');
    }
  };

  const apply = async () => {
    setPhase('applying');
    try {
      const r = await runJob(false);
      setResult(r);
      setPhase('done');
      addToast?.(`Patched ${r.moviesPatched} movie${r.moviesPatched===1?'':'s'}, deleted ${r.personsDeleted} person record${r.personsDeleted===1?'':'s'}`, 'ok');
    } catch (e) {
      addToast?.('Apply failed: ' + e.message, 'error');
      setPhase('preview');
    }
  };

  const willOrDid = phase === 'done' ? 'Patched' : 'Will patch';

  return (
    <div style={{position:'fixed',inset:0,background:'rgba(0,0,0,0.7)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:1500}} onClick={busy ? undefined : onClose}>
      <div style={{background:'var(--surface)',border:'1px solid var(--border)',borderRadius:8,width:680,maxWidth:'92vw',maxHeight:'85vh',padding:18,display:'flex',flexDirection:'column',gap:12,overflow:'hidden'}} onClick={e=>e.stopPropagation()}>
        <div style={{display:'flex',justifyContent:'space-between',alignItems:'center',flexShrink:0}}>
          <div style={{fontSize:16,fontWeight:600}}>🧹 Clean Jellyfin mojibake actors</div>
          <button onClick={onClose} disabled={busy} style={{background:'none',border:'none',color:'var(--text-muted)',cursor:busy?'not-allowed':'pointer',fontSize:20,opacity:busy?0.4:1}}>×</button>
        </div>

        <div style={{fontSize:12,color:'var(--text-soft)',flexShrink:0}}>
          Scans every movie in Jellyfin, removes <strong>People</strong> entries whose name contains
          mojibake characters (control chars, Latin-1 Supplement like <code>â Å ã</code>, or U+FFFD),
          then deletes the resulting orphan person records. Real macron vowels (<code>ū ō ā</code>)
          are at U+0100+ and are not matched.
          <br/>
          <span style={{color:'var(--text-muted)'}}>
            With "Save metadata as NFO" enabled in Jellyfin, the cleaned cast lists get written back
            to your <code>.nfo</code> files automatically on the next metadata save.
          </span>
        </div>

        <div style={{flex:1,overflowY:'auto',background:'var(--surface-2)',border:'1px solid var(--border)',borderRadius:6,padding:10}}>
          {phase === 'idle' && (
            <div style={{color:'var(--text-muted)',fontSize:13,textAlign:'center',padding:30}}>
              Click <strong>Scan (dry-run)</strong> to see what would change.
            </div>
          )}
          {(phase === 'scanning' || phase === 'applying') && (
            <div style={{color:'var(--text-muted)',fontSize:12,textAlign:'center',padding:20}}>
              {phase === 'scanning' ? 'Scanning Jellyfin (dry-run)…' : 'Applying changes…'}
              <div style={{fontSize:11,marginTop:6,color:'var(--text-soft)'}}>
                Progress shown in the top progress bar.
              </div>
            </div>
          )}
          {(phase === 'preview' || phase === 'done') && result && (
            <div style={{display:'flex',flexDirection:'column',gap:8,fontSize:11}}>
              <div style={{color:'var(--text-soft)'}}>
                {willOrDid} <strong>{result.moviesPatched}</strong> movie{result.moviesPatched===1?'':'s'} ·
                {' '}removed <strong>{result.peopleRemoved}</strong> People entr{result.peopleRemoved===1?'y':'ies'} ·
                {' '}{phase === 'done' ? 'deleted' : 'will delete'} <strong>{result.personsDeleted ?? (result.deletedPersons?.length ?? 0)}</strong> orphan person record{(result.deletedPersons?.length ?? 0)===1?'':'s'}.
                {' '}Scanned {result.moviesScanned} total.
              </div>
              {result.modifiedMovies && result.modifiedMovies.length > 0 && (
                <div>
                  <div style={{fontWeight:600,color:'var(--text-muted)',textTransform:'uppercase',fontSize:10,letterSpacing:'0.06em',marginTop:6,marginBottom:3}}>
                    movies ({result.modifiedMovies.length})
                  </div>
                  <div style={{display:'flex',flexDirection:'column',gap:2,fontFamily:'var(--mono)',fontSize:11}}>
                    {result.modifiedMovies.slice(0, 200).map((m, i) => (
                      <div key={i} style={{color:'var(--text-soft)',overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>
                        <span>{m.name}</span>
                        <span style={{color:'var(--text-muted)'}}> — {(m.removed || []).join(', ')}</span>
                      </div>
                    ))}
                    {result.modifiedMovies.length > 200 && <div style={{color:'var(--text-muted)',fontStyle:'italic'}}>… +{result.modifiedMovies.length - 200} more</div>}
                  </div>
                </div>
              )}
              {result.deletedPersons && result.deletedPersons.length > 0 && (
                <div>
                  <div style={{fontWeight:600,color:'var(--text-muted)',textTransform:'uppercase',fontSize:10,letterSpacing:'0.06em',marginTop:6,marginBottom:3}}>
                    {phase === 'done' ? 'persons deleted' : 'persons to delete'} ({result.deletedPersons.length})
                  </div>
                  <div style={{display:'flex',flexDirection:'column',gap:2,fontFamily:'var(--mono)',fontSize:11}}>
                    {result.deletedPersons.slice(0, 200).map((p, i) => (
                      <div key={i} style={{color:'var(--text-soft)',overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>{p.name}</div>
                    ))}
                    {result.deletedPersons.length > 200 && <div style={{color:'var(--text-muted)',fontStyle:'italic'}}>… +{result.deletedPersons.length - 200} more</div>}
                  </div>
                </div>
              )}
              {result.errors && result.errors.length > 0 && (
                <div>
                  <div style={{fontWeight:600,color:'var(--red, #c55)',textTransform:'uppercase',fontSize:10,letterSpacing:'0.06em',marginTop:6,marginBottom:3}}>
                    errors ({result.errors.length})
                  </div>
                  <div style={{display:'flex',flexDirection:'column',gap:2,fontFamily:'var(--mono)',fontSize:11}}>
                    {result.errors.slice(0, 50).map((e, i) => (
                      <div key={i} style={{color:'var(--red, #c55)',overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>{e}</div>
                    ))}
                    {result.errors.length > 50 && <div style={{color:'var(--text-muted)',fontStyle:'italic'}}>… +{result.errors.length - 50} more</div>}
                  </div>
                </div>
              )}
            </div>
          )}
        </div>

        <div style={{display:'flex',gap:8,justifyContent:'flex-end',borderTop:'1px solid var(--border)',paddingTop:10,flexShrink:0}}>
          <button onClick={onClose} disabled={busy} style={{...S.btn, opacity:busy?0.5:1}}>Close</button>
          {(phase === 'idle' || phase === 'preview') && (
            <button onClick={scan} disabled={busy} style={{...S.btn}}>
              ↻ {phase === 'preview' ? 'Re-scan' : 'Scan (dry-run)'}
            </button>
          )}
          {phase === 'preview' && result && result.moviesPatched + (result.deletedPersons?.length ?? 0) > 0 && (
            <button onClick={apply} disabled={busy}
                    style={{background:'var(--red, #c55)',border:'none',color:'#fff',padding:'6px 16px',borderRadius:5,fontSize:12,fontWeight:600,opacity:busy?0.5:1,cursor:busy?'default':'pointer'}}>
              🗑 Apply ({result.moviesPatched} movie{result.moviesPatched===1?'':'s'}, {result.deletedPersons?.length ?? 0} person{(result.deletedPersons?.length??0)===1?'':'s'})
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

// ─── Actress Library ──────────────────────────────────────────────────────────

function ActressLibrary({ onJob, addToast }) {
  const [q, setQ] = useState('');
  const [filter, setFilter] = useState('all');
  const [pageSize] = useState(100);
  const [entries, setEntries] = useState([]);
  const [total, setTotal] = useState(0);
  const [nextPage, setNextPage] = useState(1);          // page to fetch on next batch
  const [loading, setLoading] = useState(false);
  const [done, setDone] = useState(false);              // no more pages
  const [selected, setSelected] = useState(null);
  const [syncModal, setSyncModal] = useState(false);
  const [cleanupModal, setCleanupModal] = useState(false);
  const [jfCleanupModal, setJfCleanupModal] = useState(false);
  const [xcityParallel, setXcityParallel] = useState(3);
  const [jellyfinParallel, setJellyfinParallel] = useState(8);
  const [useJellyfin, setUseJellyfin] = useState(true);
  const [skipXcitySourced, setSkipXcitySourced] = useState(false);

  const sentinelRef = useRef(null);
  const requestSeqRef = useRef(0);   // bumps on filter/search change to invalidate in-flight loads

  // Hydrate refresh-phase settings on mount.
  useEffect(() => {
    (async () => {
      try {
        const s = await api('/api/settings');
        const srv = s.settings || {};
        const x = srv['actresses.refresh.xcity.parallelism'] ?? srv['actresses.refresh.parallelism'];
        if (x) setXcityParallel(parseInt(x) || 3);
        if (srv['actresses.refresh.jellyfin.parallelism']) setJellyfinParallel(parseInt(srv['actresses.refresh.jellyfin.parallelism']) || 8);
        if (typeof srv['actresses.refresh.usejellyfin'] === 'boolean') setUseJellyfin(srv['actresses.refresh.usejellyfin']);
        if (typeof srv['actresses.refresh.skipxcitysourced'] === 'boolean') setSkipXcitySourced(srv['actresses.refresh.skipxcitysourced']);
      } catch {}
    })();
  }, []);

  // Load one page and append. Caller passes pageNum + a seq token to detect
  // stale loads (filter/search changed mid-flight).
  const loadPage = useCallback(async (pageNum, seq) => {
    setLoading(true);
    try {
      const params = new URLSearchParams({ page: String(pageNum), pageSize: String(pageSize) });
      if (q) params.set('q', q);
      if (filter && filter !== 'all') params.set('filter', filter);
      const res = await api(`/api/actresses?${params}`);
      // Discard if a newer search/filter has invalidated us.
      if (seq !== requestSeqRef.current) return;
      const incoming = res.entries || [];
      setTotal(res.total || 0);
      setEntries(prev => pageNum === 1 ? incoming : [...prev, ...incoming]);
      const totalLoaded = (pageNum === 1 ? 0 : entries.length) + incoming.length;
      const more = incoming.length > 0 && totalLoaded < (res.total || 0);
      setDone(!more);
      setNextPage(pageNum + 1);
    } catch (e) {
      if (seq === requestSeqRef.current) addToast?.('Failed to load actresses: ' + e.message, 'error');
    } finally {
      if (seq === requestSeqRef.current) setLoading(false);
    }
  }, [q, filter, pageSize, addToast, entries.length]);

  // Reset + reload when search/filter changes.
  useEffect(() => {
    const seq = ++requestSeqRef.current;
    setEntries([]);
    setNextPage(1);
    setDone(false);
    loadPage(1, seq);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q, filter]);

  // Sentinel for infinite scroll. When the last row of the grid is near the
  // viewport, kick off the next page.
  useEffect(() => {
    if (!sentinelRef.current || done || loading) return;
    const obs = new IntersectionObserver((items) => {
      if (items[0].isIntersecting && !loading && !done) {
        loadPage(nextPage, requestSeqRef.current);
      }
    }, { rootMargin: '400px' });
    obs.observe(sentinelRef.current);
    return () => obs.disconnect();
  }, [done, loading, nextPage, loadPage]);

  // Public hook callers can use to refresh data after an external mutation
  // (e.g. cleanup commit).
  const reloadAll = useCallback(() => {
    const seq = ++requestSeqRef.current;
    setEntries([]);
    setNextPage(1);
    setDone(false);
    loadPage(1, seq);
  }, [loadPage]);

  const syncFromJellyfin = async () => {
    try {
      const res = await api('/api/actresses/refresh', {
        method:'POST',
        body:{ source:'jellyfin', replaceExisting:false, useJellyfin, skipXcitySourced, xcityParallelism: xcityParallel, jellyfinParallelism: jellyfinParallel },
      });
      if (res.jobId) { onJob?.(res.jobId); addToast?.('Sync from Jellyfin started', 'ok'); }
    } catch (e) { addToast?.('Sync failed: ' + e.message, 'error'); }
  };

  const refetchMissing = async () => {
    const targets = entries
      .filter(e => !e.bio || !e.primaryUrl)
      .map(e => ({ name: (e.name || '').trim(), japaneseName: e.japaneseName, aliases: e.aliases }))
      .filter(e => e.name);
    if (targets.length === 0) { addToast?.('Nothing missing to refetch in loaded entries', 'info'); return; }
    try {
      const res = await api('/api/actresses/refresh', {
        method:'POST',
        body:{ source:'names', names: targets, replaceExisting:true, xcityParallelism: xcityParallel },
      });
      if (res.jobId) { onJob?.(res.jobId); addToast?.(`Refetching ${targets.length} actresses`, 'ok'); }
    } catch (e) { addToast?.('Refetch failed: ' + e.message, 'error'); }
  };

  const refetchOne = async (entry) => {
    const name = (entry?.name || '').trim();
    if (!name) { addToast?.('Skipped: actress has no name to query xcity with', 'info'); return; }
    try {
      const res = await api('/api/actresses/refresh', {
        method:'POST',
        body:{ source:'names', names:[{ name, japaneseName: entry.japaneseName, aliases: entry.aliases }], replaceExisting:true, xcityParallelism: xcityParallel },
      });
      if (res.jobId) { onJob?.(res.jobId); addToast?.(`Refetching ${name}`, 'ok'); }
    } catch (e) { addToast?.('Refetch failed: ' + e.message, 'error'); }
  };

  return (
    <div style={{flex:1, overflow:'auto', padding:14, display:'flex', flexDirection:'column', gap:12}}>
      {/* Sticky so the search/filter/buttons stay reachable while scrolling
          the (potentially thousands of) actress cards. The scroll container
          is the parent at `flex:1; overflow:auto`. Negative top + paddingTop
          absorbs the parent's `padding:14` so the toolbar pins flush to the
          top edge once scrolled past. */}
      <div style={{position:'sticky', top:-14, zIndex:400, background:'var(--surface)', marginTop:-14, marginLeft:-14, marginRight:-14, paddingTop:14, paddingBottom:10, paddingLeft:14, paddingRight:14, borderBottom:'1px solid var(--border)', display:'flex', gap:8, alignItems:'center', flexWrap:'wrap'}}>
        <input
          value={q} onChange={e=>setQ(e.target.value)}
          placeholder="Search name, JapaneseName, alias…"
          style={{...S.field, width:280}}
        />
        <select value={filter} onChange={e=>setFilter(e.target.value)} style={{...S.field, width:160}}>
          <option value="all">All ({total})</option>
          <option value="missing-photo">Missing photo</option>
          <option value="missing-bio">Missing bio</option>
        </select>
        <div style={{flex:1}} />
        <label style={{display:'flex', gap:5, alignItems:'center', fontSize:11, color:'var(--text-muted)', userSelect:'none'}} title="When ON, Sync from Jellyfin first promotes whatever Jellyfin already has (bio + birthdate) and only hits xcity for actresses missing data. Saved on change.">
          <input
            type="checkbox" checked={useJellyfin}
            onChange={async e => {
              const v = e.target.checked;
              setUseJellyfin(v);
              try { await api('/api/settings', { method:'POST', body:{ settings:{ 'actresses.refresh.usejellyfin': v }}}); addToast?.('Saved', 'ok'); }
              catch (err) { addToast?.(`Save failed: ${err.message}`, 'error'); }
            }}
            style={{accentColor:'var(--accent)'}}/>
          Jellyfin first
        </label>
        <label style={{display:'flex', gap:5, alignItems:'center', fontSize:11, color:'var(--text-muted)', userSelect:'none'}} title="When ON, Sync from Jellyfin skips any actress that already has xcity data (xcityId set). Use this to fill in xcity for entries that only have Jellyfin-sourced data without re-hitting xcity for actresses already covered. Saved on change.">
          <input
            type="checkbox" checked={skipXcitySourced}
            onChange={async e => {
              const v = e.target.checked;
              setSkipXcitySourced(v);
              try { await api('/api/settings', { method:'POST', body:{ settings:{ 'actresses.refresh.skipxcitysourced': v }}}); addToast?.('Saved', 'ok'); }
              catch (err) { addToast?.(`Save failed: ${err.message}`, 'error'); }
            }}
            style={{accentColor:'var(--accent)'}}/>
          Skip xcity-sourced
        </label>
        <label style={{display:'flex', gap:5, alignItems:'center', fontSize:11, color:'var(--text-muted)'}} title="Phase B parallelism — concurrent Jellyfin GETs (local network, can go higher). Saved on blur.">
          <span>JF</span>
          <input
            type="number" min={1} max={32} value={jellyfinParallel}
            onChange={e=>setJellyfinParallel(Math.max(1,Math.min(32,parseInt(e.target.value)||1)))}
            onBlur={async e => {
              const v = Math.max(1, Math.min(32, parseInt(e.target.value) || 8));
              try { await api('/api/settings', { method:'POST', body:{ settings:{ 'actresses.refresh.jellyfin.parallelism': v }}}); addToast?.('Saved', 'ok'); }
              catch (err) { addToast?.(`Save failed: ${err.message}`, 'error'); }
            }}
            style={{...S.field, width:50, fontSize:11, padding:'2px 6px'}}/>
        </label>
        <label style={{display:'flex', gap:5, alignItems:'center', fontSize:11, color:'var(--text-muted)'}} title="Phase C parallelism — concurrent xcity fetches (remote, lower = politer). Saved on blur.">
          <span>xcity</span>
          <input
            type="number" min={1} max={16} value={xcityParallel}
            onChange={e=>setXcityParallel(Math.max(1,Math.min(16,parseInt(e.target.value)||1)))}
            onBlur={async e => {
              const v = Math.max(1, Math.min(16, parseInt(e.target.value) || 3));
              try { await api('/api/settings', { method:'POST', body:{ settings:{ 'actresses.refresh.xcity.parallelism': v }}}); addToast?.('Saved', 'ok'); }
              catch (err) { addToast?.(`Save failed: ${err.message}`, 'error'); }
            }}
            style={{...S.field, width:50, fontSize:11, padding:'2px 6px'}}/>
        </label>
        <button onClick={refetchMissing} style={{...S.btn}} title="Refetch from xcity for actresses with missing bio/photo currently loaded in this view">↻ Refetch missing</button>
        <button onClick={()=>setCleanupModal(true)} style={{...S.btn}} title="Remove blank-name and stub entries from the local dataset">🧹 Cleanup</button>
        <button onClick={()=>setJfCleanupModal(true)} style={{...S.btn}} title="Walk Jellyfin, drop mojibake-named People entries from each movie, delete orphan person records. With 'Save metadata as NFO' enabled in Jellyfin, the cleaned cast lists get written back to your .nfo files automatically.">🧹 Clean Jellyfin</button>
        <button onClick={syncFromJellyfin} style={{...S.btn}} title="Pull Jellyfin's actress list and enrich each from xcity">
          ⇩ Sync from Jellyfin
        </button>
        <button onClick={()=>setSyncModal(true)} style={{background:'var(--accent)', border:'none', color:'#fff', padding:'5px 14px', borderRadius:5, fontSize:12, fontWeight:600}} title="Push the local dataset to your Jellyfin server">
          ⇪ Sync to Jellyfin
        </button>
      </div>

      {syncModal && <JellyfinSyncModal onClose={()=>setSyncModal(false)} onJob={(id)=>{ onJob?.(id); setSyncModal(false); }} addToast={addToast} />}
      {cleanupModal && <ActressCleanupModal onClose={()=>setCleanupModal(false)} onDone={()=>{ setCleanupModal(false); reloadAll(); }} addToast={addToast} />}
      {jfCleanupModal && <JellyfinMojibakeCleanupModal onClose={()=>setJfCleanupModal(false)} onJob={onJob} addToast={addToast} />}

      {entries.length === 0 && !loading ? (
        <div style={{color:'var(--text-muted)', fontSize:13, textAlign:'center', padding:40}}>
          No actresses{q ? ` matching "${q}"` : ' yet'}.<br/>
          {q ? '' : 'Click "Sync from Jellyfin" to populate from your library.'}
        </div>
      ) : (
        <div style={{display:'grid', gridTemplateColumns:'repeat(auto-fill, minmax(160px, 1fr))', gap:10}}>
          {entries.map((e, i) => (
            <div key={`${e.name}-${e.xcityId || i}`} onClick={()=>setSelected(e)} style={{background:'var(--surface-2)', border:'1px solid var(--border)', borderRadius:6, padding:8, cursor:'pointer', display:'flex', flexDirection:'column', gap:5}}>
              {e.primaryUrl
                ? <img src={e.primaryUrl} alt={e.name} loading="lazy" style={{width:'100%', aspectRatio:'3/4', objectFit:'cover', borderRadius:4, background:'var(--surface)'}} onError={ev=>{ev.target.style.display='none';if(ev.target.nextSibling)ev.target.nextSibling.style.display='flex'}}/>
                : null}
              <div style={{width:'100%', aspectRatio:'3/4', background:'var(--surface)', borderRadius:4, display: e.primaryUrl ? 'none' : 'flex', alignItems:'center', justifyContent:'center', fontSize:36}}>👤</div>
              <div style={{fontSize:12, fontWeight:600, lineHeight:1.3, overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap'}}>{e.name}</div>
              {e.japaneseName && <div style={{fontSize:10, color:'var(--text-muted)', overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap'}}>{e.japaneseName}</div>}
              {e.birthdate && <div style={{fontSize:10, color:'var(--text-soft)'}}>🎂 {e.birthdate}</div>}
            </div>
          ))}
          {/* Skeleton placeholders + sentinel for IntersectionObserver-driven infinite scroll */}
          {loading && [...Array(8)].map((_,i)=><Sk key={`sk-${i}`} h={220}/>)}
        </div>
      )}

      {/* Sentinel: when this scrolls into view (with rootMargin slack) we load the next page. */}
      {!done && <div ref={sentinelRef} style={{height:1}} />}

      {/* Status footer */}
      <div style={{display:'flex', justifyContent:'center', alignItems:'center', gap:10, padding:8, fontSize:11, color:'var(--text-muted)'}}>
        {entries.length === 0 && !loading
          ? null
          : done
            ? <span>Showing all {entries.length} of {total}</span>
            : loading
              ? <span>Loading… {entries.length} of {total} loaded</span>
              : <span>{entries.length} of {total} loaded — scroll to load more</span>}
      </div>

      {selected && (
        <div style={{position:'fixed',inset:0,background:'rgba(0,0,0,0.7)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:1500}} onClick={()=>setSelected(null)}>
          <div style={{background:'var(--surface)',border:'1px solid var(--border)',borderRadius:8,width:560,maxWidth:'92vw',maxHeight:'90vh',overflow:'auto',padding:18,display:'flex',flexDirection:'column',gap:10}} onClick={e=>e.stopPropagation()}>
            <div style={{display:'flex',justifyContent:'space-between',alignItems:'flex-start'}}>
              <div>
                <div style={{fontSize:18,fontWeight:600}}>{selected.name}</div>
                {selected.japaneseName && <div style={{fontSize:13,color:'var(--text-muted)'}}>{selected.japaneseName}</div>}
              </div>
              <button onClick={()=>setSelected(null)} style={{background:'none',border:'none',color:'var(--text-muted)',cursor:'pointer',fontSize:20}}>×</button>
            </div>
            <div style={{display:'flex',gap:14}}>
              {selected.primaryUrl && <img src={selected.primaryUrl} alt="" style={{width:160,aspectRatio:'3/4',objectFit:'cover',borderRadius:6}}/>}
              <div style={{flex:1,display:'flex',flexDirection:'column',gap:6,fontSize:12}}>
                {selected.birthdate && <div>🎂 <strong>{selected.birthdate}</strong></div>}
                {selected.birthCity && <div>📍 {selected.birthCity}</div>}
                {selected.height && <div>📏 {selected.height}</div>}
                {selected.measurements && <div>📐 {selected.measurements}</div>}
                {selected.bloodType && <div>🩸 {selected.bloodType}</div>}
                {selected.hobby && <div style={{color:'var(--text-soft)'}}>Hobby: {selected.hobby}</div>}
                {selected.specialSkill && <div style={{color:'var(--text-soft)'}}>Skill: {selected.specialSkill}</div>}
              </div>
            </div>
            {selected.bio && <div style={{fontSize:12,color:'var(--text-soft)',lineHeight:1.5,whiteSpace:'pre-wrap'}}>{selected.bio}</div>}
            {selected.aliases?.length > 0 && (
              <div style={{borderTop:'1px solid var(--border)',paddingTop:8}}>
                <div style={{fontSize:10,color:'var(--text-muted)',marginBottom:4,textTransform:'uppercase',letterSpacing:'0.06em'}}>Aliases</div>
                <div style={{display:'flex',flexWrap:'wrap',gap:4}}>
                  {selected.aliases.map((a,i)=><span key={i} style={{background:'var(--surface-2)',border:'1px solid var(--border)',borderRadius:3,padding:'2px 8px',fontSize:11,color:'var(--text-soft)'}}>{a}</span>)}
                </div>
              </div>
            )}
            {selected.xcityUrl && (
              <div style={{display:'flex',gap:8,alignItems:'center',borderTop:'1px solid var(--border)',paddingTop:8}}>
                <a href={selected.xcityUrl} target="_blank" rel="noreferrer" style={{fontSize:11,color:'var(--accent-light)'}}>↗ xcity profile</a>
                <div style={{flex:1}}/>
                <button onClick={()=>refetchOne(selected)} style={{...S.btn, fontSize:11}}>↻ Refetch from xcity</button>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
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

const TRANSLATE_DEFAULT_FIELDS = ['Title', 'Description', 'Series', 'Maker', 'Actress'];

function TranslatorPanel({ addToast }) {
  const [enabled, setEnabled] = useState(null); // null=loading
  const [modName, setModName] = useState('');
  const [language, setLanguage] = useState('');
  const [fields, setFields] = useState([]);
  const [health, setHealth] = useState(null); // null=idle, {checking}, or api result
  const [busy, setBusy] = useState(false);

  const loadAll = useCallback(async () => {
    try {
      const res = await api('/api/settings');
      const srv = res.settings || {};
      const on = !!srv['sort.metadata.nfo.translate'];
      setModName(srv['sort.metadata.nfo.translate.module'] || '?');
      setLanguage(srv['sort.metadata.nfo.translate.language'] || '?');
      const rawFields = srv['sort.metadata.nfo.translate.field'];
      const parsedFields = Array.isArray(rawFields)
        ? rawFields
        : (typeof rawFields === 'string' && rawFields ? rawFields.split(/[,\s]+/).filter(Boolean) : []);
      setFields(parsedFields);
      setEnabled(on);
      if (!on) { setHealth(null); return; }
      setHealth({ checking: true });
      try {
        const h = await api('/api/translator/health');
        setHealth(h);
      } catch (e) {
        setHealth({ ok: false, reason: e.message });
      }
    } catch (e) {
      setEnabled(false);
      setHealth({ ok: false, reason: e.message });
    }
  }, []);

  useEffect(() => { loadAll(); }, [loadAll]);

  const onToggle = async (e) => {
    const want = e.target.checked;
    setBusy(true);
    try {
      const update = { 'sort.metadata.nfo.translate': want };
      if (want) {
        update['sort.metadata.nfo.translate.module'] = 'google_web';
        update['sort.metadata.nfo.translate.field'] = TRANSLATE_DEFAULT_FIELDS;
      }
      await api('/api/settings', {
        method: 'POST',
        body: { settings: update },
      });
      addToast?.(
        want
          ? `Translator enabled (module: google_web; fields: ${TRANSLATE_DEFAULT_FIELDS.join(', ')})`
          : 'Translator disabled',
        'ok'
      );
    } catch (err) {
      addToast?.(`Failed to update translator: ${err.message}`, 'error');
    } finally {
      setBusy(false);
      await loadAll();
    }
  };

  const dot =
    enabled == null   ? 'var(--text-muted)' :
    !enabled          ? 'var(--text-muted)' :
    health?.checking  ? 'var(--text-muted)' :
    health?.ok        ? 'var(--green)' :
                        'var(--red)';

  const fieldsSuffix = fields.length ? ` · fields: ${fields.join(', ')}` : '';
  const statusText =
    enabled == null   ? 'checking…' :
    !enabled          ? 'OFF' :
    health?.checking  ? `ON — ${modName} → ${language}${fieldsSuffix} · checking…` :
    health?.ok        ? `ON — ${modName} → ${language}${fieldsSuffix} · healthy (${health.latency_ms}ms)` :
                        `ON — ${modName} → ${language}${fieldsSuffix} · unhealthy: ${health?.reason || health?.error || 'unknown'}`;

  return (
    <div style={{width:'100%', display:'flex', flexDirection:'column', gap:6, paddingTop:6, borderTop:'1px solid var(--border)'}}>
      <div style={{display:'flex', alignItems:'center', gap:12, flexWrap:'wrap'}}>
        <span style={S.label}>Translator</span>

        <label
          title="Translate Japanese fields (description by default) in scraped results. Module & language live in jvSettings.json."
          style={{display:'flex', gap:5, alignItems:'center', fontSize:11, cursor: busy || enabled == null ? 'default' : 'pointer', userSelect:'none', color:'var(--text-muted)', opacity: busy || enabled == null ? 0.6 : 1}}
        >
          <input
            type="checkbox"
            checked={!!enabled}
            disabled={busy || enabled == null}
            onChange={onToggle}
            style={{accentColor:'var(--accent)'}}
          />
          Enable
        </label>

        <div style={{display:'flex', alignItems:'center', gap:6, fontSize:11, color:'var(--text-muted)'}}>
          <span style={{width:8, height:8, borderRadius:'50%', background:dot, flexShrink:0}} />
          <span>{statusText}</span>
        </div>
      </div>

      <div style={{fontSize:10, color:'var(--text-muted)', paddingLeft:2, fontStyle:'italic', lineHeight:1.5}}>
        Enabling forces module to <code>google_web</code> (native PowerShell, no Python required) and fields to <code>Title, Description, Series, Maker, Actress</code> (Actress translates the <code>JapaneseName</code> of each actress in place). Target language is read from <code>jvSettings.json</code> (<code>sort.metadata.nfo.translate.language</code>, default <code>en</code>).
      </div>
    </div>
  );
}

// ─── Jellyfin Panel ───────────────────────────────────────────────────────────

const JELLYFIN_FIELDS = ['Photo', 'Bio', 'Birthdate', 'Aliases'];

function JellyfinPanel({ addToast, onJob }) {
  const [url, setUrl] = useState('');
  const [apikey, setApikey] = useState('');
  const [serverUrl, setServerUrl] = useState('');
  const [serverKey, setServerKey] = useState('');
  const [health, setHealth] = useState(null);
  const [fields, setFields] = useState({ Photo:true, Bio:true, Birthdate:true, Aliases:true });
  const [replaceExisting, setReplaceExisting] = useState(false);
  const [mergeDuplicates, setMergeDuplicates] = useState(true);
  const [parallelism, setParallelism] = useState(6);
  const [busy, setBusy] = useState(false);

  const loadAll = useCallback(async () => {
    try {
      const res = await api('/api/settings');
      const srv = res.settings || {};
      const u = srv['emby.url'] || '';
      const k = srv['emby.apikey'] || '';
      setUrl(u); setServerUrl(u);
      setApikey(k); setServerKey(k);
      if (srv['actresses.sync.parallelism']) setParallelism(parseInt(srv['actresses.sync.parallelism']) || 6);
      if (u && k) {
        const h = await api('/api/jellyfin/health');
        setHealth(h);
      } else {
        setHealth({ ok:false, reason:'not configured' });
      }
    } catch (e) { setHealth({ ok:false, reason: e.message }); }
  }, []);

  useEffect(() => { loadAll(); }, [loadAll]);

  const saveIfChanged = useCallback(async (key, value, prev, setPrev) => {
    if (value === prev) return;
    try {
      await api('/api/settings', { method:'POST', body:{ settings:{ [key]: value } } });
      setPrev(value);
      addToast?.('Saved', 'ok');
      // Re-check health after URL/key change.
      const h = await api('/api/jellyfin/health');
      setHealth(h);
    } catch (e) { addToast?.(`Save failed: ${e.message}`, 'error'); }
  }, [addToast]);

  const sync = async (dryRun = false) => {
    const selected = Object.keys(fields).filter(f => fields[f]);
    if (selected.length === 0) { addToast?.('Pick at least one field to sync', 'info'); return; }
    setBusy(true);
    try {
      const res = await api('/api/jellyfin/sync-actresses', {
        method:'POST',
        body:{ fields: selected, replaceExisting, mergeDuplicates, dryRun, parallelism },
      });
      if (res.jobId) { onJob?.(res.jobId); addToast?.(dryRun ? 'Preview started' : 'Sync started', 'ok'); }
    } catch (e) { addToast?.(`Sync failed: ${e.message}`, 'error'); }
    finally { setBusy(false); }
  };

  const dot =
    !health             ? 'var(--text-muted)' :
    health.ok           ? 'var(--green)' :
                          'var(--red)';
  const statusText =
    !health             ? 'checking…' :
    health.ok           ? `connected — ${health.serverName || '?'} v${health.version || '?'} (${health.latency_ms}ms)` :
                          (health.reason === 'not configured' ? 'not configured' : `unreachable: ${health.reason || health.error || 'unknown'}`);

  return (
    <div style={{width:'100%', display:'flex', flexDirection:'column', gap:6, paddingTop:6, borderTop:'1px solid var(--border)'}}>
      <div style={{display:'flex', alignItems:'center', gap:12, flexWrap:'wrap'}}>
        <span style={S.label}>Jellyfin</span>
        <div style={{display:'flex', alignItems:'center', gap:6, fontSize:11, color:'var(--text-muted)'}}>
          <span style={{width:8, height:8, borderRadius:'50%', background:dot, flexShrink:0}} />
          <span>{statusText}</span>
        </div>
      </div>

      <div style={{display:'flex', gap:8, alignItems:'center'}}>
        <input
          value={url}
          onChange={e=>setUrl(e.target.value)}
          onBlur={()=>saveIfChanged('emby.url', url.trim(), serverUrl, setServerUrl)}
          placeholder="http://jellyfin.local:8096"
          style={{...S.field, flex:1, fontSize:11, fontFamily:'var(--mono)'}}
        />
        <input
          value={apikey}
          onChange={e=>setApikey(e.target.value)}
          onBlur={()=>saveIfChanged('emby.apikey', apikey.trim(), serverKey, setServerKey)}
          type="password"
          placeholder="API key"
          style={{...S.field, flex:1, fontSize:11, fontFamily:'var(--mono)'}}
        />
      </div>

      <div style={{display:'flex', gap:14, flexWrap:'wrap', alignItems:'center', fontSize:11, color:'var(--text-muted)'}}>
        <span style={S.label}>Sync</span>
        {JELLYFIN_FIELDS.map(f => (
          <label key={f} style={{display:'flex', gap:4, alignItems:'center', cursor:'pointer', userSelect:'none'}}>
            <input type="checkbox" checked={!!fields[f]} onChange={e=>setFields(s=>({...s,[f]:e.target.checked}))} style={{accentColor:'var(--accent)'}} />
            {f}
          </label>
        ))}
        <span style={{flex:1}} />
        <label style={{display:'flex', gap:4, alignItems:'center', cursor:'pointer', userSelect:'none'}}>
          <input type="checkbox" checked={replaceExisting} onChange={e=>setReplaceExisting(e.target.checked)} style={{accentColor:'var(--accent)'}} />
          Replace existing
        </label>
        <label style={{display:'flex', gap:4, alignItems:'center', cursor:'pointer', userSelect:'none'}} title="Detect 'Yuna Ogura' ↔ 'Ogura Yuna' duplicates and merge them into one">
          <input type="checkbox" checked={mergeDuplicates} onChange={e=>setMergeDuplicates(e.target.checked)} style={{accentColor:'var(--accent)'}} />
          Merge duplicates
        </label>
        <label style={{display:'flex', gap:6, alignItems:'center'}} title="Concurrent HTTP workers per sync. Saved on blur.">
          <span>Parallel</span>
          <input
            type="number" min={1} max={32} value={parallelism}
            onChange={e=>setParallelism(Math.max(1,Math.min(32,parseInt(e.target.value)||1)))}
            onBlur={async e => {
              const v = Math.max(1, Math.min(32, parseInt(e.target.value) || 6));
              try { await api('/api/settings', { method:'POST', body:{ settings:{ 'actresses.sync.parallelism': v }}}); addToast?.('Saved', 'ok'); }
              catch (err) { addToast?.(`Save failed: ${err.message}`, 'error'); }
            }}
            style={{...S.field, width:50, fontSize:11, padding:'2px 6px'}}/>
        </label>
      </div>

      <div style={{display:'flex', gap:8, marginTop:2}}>
        <button onClick={()=>sync(true)} disabled={busy || !health?.ok} style={{...S.btn}}>
          👁 Preview (dry-run)
        </button>
        <button onClick={()=>sync(false)} disabled={busy || !health?.ok} style={{background:'var(--accent)', border:'none', color:'#fff', padding:'5px 14px', borderRadius:5, fontSize:12, fontWeight:600, opacity: (busy || !health?.ok) ? 0.5 : 1, cursor: (busy || !health?.ok) ? 'default' : 'pointer'}}>
          ⇪ Sync to Jellyfin
        </button>
      </div>
    </div>
  );
}

// ─── Jellyfin Sync Modal ──────────────────────────────────────────────────────
// Standalone "Sync to Jellyfin" UI used from the Library view. Same controls
// as JellyfinPanel but in a modal (the panel reads/writes URL+key while this
// only triggers a sync; URL+key are still configured in Sort Settings).

function JellyfinSyncModal({ onClose, onJob, addToast }) {
  const [health, setHealth] = useState(null);
  const [fields, setFields] = useState({ Photo:true, Bio:true, Birthdate:true, Aliases:true });
  const [replaceExisting, setReplaceExisting] = useState(false);
  const [mergeDuplicates, setMergeDuplicates] = useState(true);
  const [parallelism, setParallelism] = useState(6);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    (async () => {
      try {
        const s = await api('/api/settings');
        if (s.settings?.['actresses.sync.parallelism']) {
          setParallelism(parseInt(s.settings['actresses.sync.parallelism']) || 6);
        }
      } catch {}
      try { setHealth(await api('/api/jellyfin/health')); }
      catch (e) { setHealth({ ok:false, reason: e.message }); }
    })();
  }, []);

  const sync = async (dryRun) => {
    const selected = Object.keys(fields).filter(f => fields[f]);
    if (selected.length === 0) { addToast?.('Pick at least one field', 'info'); return; }
    setBusy(true);
    try {
      const res = await api('/api/jellyfin/sync-actresses', {
        method:'POST',
        body:{ fields: selected, replaceExisting, mergeDuplicates, dryRun, parallelism },
      });
      if (res.jobId) { onJob?.(res.jobId); addToast?.(dryRun ? 'Preview started' : 'Sync started', 'ok'); }
    } catch (e) { addToast?.(`Sync failed: ${e.message}`, 'error'); }
    finally { setBusy(false); }
  };

  const dot   = !health ? 'var(--text-muted)' : health.ok ? 'var(--green)' : 'var(--red)';
  const stext =
    !health             ? 'checking…' :
    health.ok           ? `connected — ${health.serverName || '?'} v${health.version || '?'} (${health.latency_ms}ms)` :
                          (health.reason === 'not configured' ? 'not configured (set URL + API key in Sort Settings)' : `unreachable: ${health.reason || 'unknown'}`);

  return (
    <div style={{position:'fixed',inset:0,background:'rgba(0,0,0,0.7)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:1500}} onClick={onClose}>
      <div style={{background:'var(--surface)',border:'1px solid var(--border)',borderRadius:8,width:560,maxWidth:'92vw',padding:18,display:'flex',flexDirection:'column',gap:12}} onClick={e=>e.stopPropagation()}>
        <div style={{display:'flex',justifyContent:'space-between',alignItems:'center'}}>
          <div style={{fontSize:16,fontWeight:600}}>Sync to Jellyfin</div>
          <button onClick={onClose} style={{background:'none',border:'none',color:'var(--text-muted)',cursor:'pointer',fontSize:20}}>×</button>
        </div>
        <div style={{display:'flex',alignItems:'center',gap:6,fontSize:11,color:'var(--text-muted)'}}>
          <span style={{width:8,height:8,borderRadius:'50%',background:dot,flexShrink:0}}/>
          <span>{stext}</span>
        </div>

        <div>
          <div style={{...S.label,marginBottom:6}}>Fields to sync</div>
          <div style={{display:'flex',gap:14,flexWrap:'wrap',fontSize:12}}>
            {JELLYFIN_FIELDS.map(f => (
              <label key={f} style={{display:'flex',gap:4,alignItems:'center',cursor:'pointer',userSelect:'none',color:'var(--text)'}}>
                <input type="checkbox" checked={!!fields[f]} onChange={e=>setFields(s=>({...s,[f]:e.target.checked}))} style={{accentColor:'var(--accent)'}}/>
                {f}
              </label>
            ))}
          </div>
        </div>

        <div style={{display:'flex',gap:14,flexWrap:'wrap',fontSize:12,alignItems:'center'}}>
          <label style={{display:'flex',gap:4,alignItems:'center',cursor:'pointer',userSelect:'none'}}>
            <input type="checkbox" checked={replaceExisting} onChange={e=>setReplaceExisting(e.target.checked)} style={{accentColor:'var(--accent)'}}/>
            Replace existing
          </label>
          <label style={{display:'flex',gap:4,alignItems:'center',cursor:'pointer',userSelect:'none'}} title="Detect 'Yuna Ogura' ↔ 'Ogura Yuna' on the server and merge them">
            <input type="checkbox" checked={mergeDuplicates} onChange={e=>setMergeDuplicates(e.target.checked)} style={{accentColor:'var(--accent)'}}/>
            Merge duplicates
          </label>
          <label style={{display:'flex',gap:6,alignItems:'center'}} title="Concurrent HTTP workers per sync. Saved on blur.">
            <span style={{color:'var(--text-muted)'}}>Parallelism</span>
            <input
              type="number" min={1} max={32} value={parallelism}
              onChange={e=>setParallelism(Math.max(1,Math.min(32,parseInt(e.target.value)||1)))}
              onBlur={async e => {
                const v = Math.max(1, Math.min(32, parseInt(e.target.value) || 6));
                try { await api('/api/settings', { method:'POST', body:{ settings:{ 'actresses.sync.parallelism': v }}}); addToast?.('Saved', 'ok'); }
                catch (err) { addToast?.(`Save failed: ${err.message}`, 'error'); }
              }}
              style={{...S.field, width:60, fontSize:11, padding:'2px 6px'}}/>
          </label>
        </div>

        <div style={{display:'flex',gap:8,justifyContent:'flex-end',borderTop:'1px solid var(--border)',paddingTop:10}}>
          <button onClick={onClose} style={{...S.btn}}>Cancel</button>
          <button onClick={()=>sync(true)} disabled={busy || !health?.ok} style={{...S.btn}}>👁 Preview (dry-run)</button>
          <button onClick={()=>sync(false)} disabled={busy || !health?.ok} style={{background:'var(--accent)',border:'none',color:'#fff',padding:'6px 16px',borderRadius:5,fontSize:12,fontWeight:600,opacity:(busy||!health?.ok)?0.5:1,cursor:(busy||!health?.ok)?'default':'pointer'}}>
            ⇪ Sync now
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Sort Settings bar ────────────────────────────────────────────────────────

function SortSettings({ s, set, serverSettings, onSaveDefaults, onResetToSaved, addToast, onJob }) {
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
      <TranslatorPanel addToast={addToast} />
      <JellyfinPanel addToast={addToast} onJob={onJob} />
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

function ActressPanel({ actresses, onJob }) {
  const [enriched, setEnriched] = useState({}); // index -> data from /api/actresses/lookup
  const [busy, setBusy] = useState(false);
  const [bioOpen, setBioOpen] = useState(null);

  // Fetch xcity-enriched data for the current actress array on mount/change.
  useEffect(() => {
    if (!actresses?.length) { setEnriched({}); return; }
    let cancelled = false;
    (async () => {
      try {
        const names = actresses.map(a => ({
          name: [a.LastName, a.FirstName].filter(Boolean).join(' ') || a.Name || '',
          japaneseName: a.JapaneseName || '',
          aliases: a.Aliases || [],
        }));
        const res = await api('/api/actresses/lookup', { method:'POST', body:{ names, autoEnrich:true } });
        if (cancelled) return;
        const map = {};
        (res.hits || []).forEach((h, i) => { if (h.matched) map[i] = h.data; });
        setEnriched(map);
        if (res.jobId && onJob) onJob(res.jobId);
      } catch (e) { /* silent */ }
    })();
    return () => { cancelled = true; };
  }, [actresses]);

  const refresh = async () => {
    if (!actresses?.length) return;
    setBusy(true);
    try {
      const names = actresses.map(a => ({
        name: ([a.LastName, a.FirstName].filter(Boolean).join(' ') || a.Name || '').trim(),
        japaneseName: a.JapaneseName || '',
        aliases: a.Aliases || [],
      })).filter(n => n.name);
      if (names.length === 0) {
        // Every actress had a blank name — common with Tokyohot/DLgetchu scrapes.
        // The server would reject with 400; bail before the round-trip.
        return;
      }
      const res = await api('/api/actresses/refresh', {
        method:'POST',
        body:{ source:'names', names, replaceExisting:true },
      });
      if (res.jobId && onJob) onJob(res.jobId);
    } catch (e) { /* surface via toast in caller if needed */ }
    finally { setBusy(false); }
  };

  if (!actresses?.length) return <div style={{color:'var(--text-muted)', fontSize:12, padding:12, textAlign:'center'}}>No actress data</div>;

  return (
    <div>
      <div style={{display:'flex', justifyContent:'flex-end', marginBottom:8}}>
        <button onClick={refresh} disabled={busy} style={{...S.btn, fontSize:11}}>
          {busy ? '…' : '↻'} Refresh from xcity
        </button>
      </div>
      <div style={{display:'flex', gap:12, flexWrap:'wrap'}}>
        {actresses.map((a, i) => {
          const baseName = [a.LastName, a.FirstName].filter(Boolean).join(' ') || a.Name || '—';
          const x = enriched[i];
          const photo = (x && x.primaryUrl) || a.ThumbUrl;
          const name = (x && x.name) || baseName;
          const jp = (x && x.japaneseName) || a.JapaneseName;
          const aliases = (x && x.aliases) || [];
          return (
            <div key={i} style={{background:'var(--surface-2)', border:'1px solid var(--border)', borderRadius:6, padding:10, display:'flex', flexDirection:'column', gap:6, width:180}}>
              {photo
                ? <img src={photo} alt={name} style={{width:'100%', aspectRatio:'3/4', objectFit:'cover', borderRadius:4, background:'var(--surface)'}} onError={e=>{e.target.style.display='none';if(e.target.nextSibling)e.target.nextSibling.style.display='flex'}} />
                : null
              }
              <div style={{width:'100%', aspectRatio:'3/4', background:'var(--surface)', borderRadius:4, display: photo ? 'none' : 'flex', alignItems:'center', justifyContent:'center', fontSize:32}}>👤</div>
              <div style={{fontSize:13, fontWeight:600, lineHeight:1.3}}>{name}</div>
              {jp && <div style={{fontSize:11, color:'var(--text-muted)'}}>{jp}</div>}
              {aliases.length > 0 && (
                <div style={{display:'flex', flexWrap:'wrap', gap:3, marginTop:2}}>
                  {aliases.slice(0, 3).map((al, j) => (
                    <span key={j} style={{background:'var(--surface)', border:'1px solid var(--border)', borderRadius:3, padding:'1px 5px', fontSize:9, color:'var(--text-soft)'}}>{al}</span>
                  ))}
                  {aliases.length > 3 && <span style={{fontSize:9, color:'var(--text-muted)'}}>+{aliases.length - 3}</span>}
                </div>
              )}
              {x && (x.birthdate || x.height || x.measurements) && (
                <div style={{fontSize:10, color:'var(--text-muted)', display:'flex', flexDirection:'column', gap:2, lineHeight:1.4}}>
                  {x.birthdate && <span>🎂 {x.birthdate}</span>}
                  {x.height && <span>📏 {x.height}</span>}
                  {x.measurements && <span>📐 {x.measurements}</span>}
                </div>
              )}
              {x && x.bio && (
                <div
                  onClick={()=>setBioOpen({ name, jp, aliases, bio:x.bio, photo, birthdate:x.birthdate, height:x.height, measurements:x.measurements, birthCity:x.birthCity })}
                  style={{fontSize:10, color:'var(--text-soft)', cursor:'pointer', maxHeight:34, overflow:'hidden', textOverflow:'ellipsis', display:'-webkit-box', WebkitLineClamp:2, WebkitBoxOrient:'vertical'}}
                  title="Click to expand"
                >
                  {x.bio}
                </div>
              )}
            </div>
          );
        })}
      </div>
      {bioOpen && (
        <div style={{position:'fixed',inset:0,background:'rgba(0,0,0,0.7)',display:'flex',alignItems:'center',justifyContent:'center',zIndex:1500}} onClick={()=>setBioOpen(null)}>
          <div style={{background:'var(--surface)',border:'1px solid var(--border)',borderRadius:8,width:520,maxWidth:'92vw',padding:18,display:'flex',flexDirection:'column',gap:10}} onClick={e=>e.stopPropagation()}>
            <div style={{display:'flex',justifyContent:'space-between',alignItems:'flex-start'}}>
              <div>
                <div style={{fontSize:16,fontWeight:600}}>{bioOpen.name}</div>
                {bioOpen.jp && <div style={{fontSize:12,color:'var(--text-muted)'}}>{bioOpen.jp}</div>}
              </div>
              <button onClick={()=>setBioOpen(null)} style={{background:'none',border:'none',color:'var(--text-muted)',cursor:'pointer',fontSize:18}}>×</button>
            </div>
            <div style={{display:'flex',gap:14}}>
              {bioOpen.photo && <img src={bioOpen.photo} alt="" style={{width:120,aspectRatio:'3/4',objectFit:'cover',borderRadius:4}} />}
              <div style={{flex:1,fontSize:12,display:'flex',flexDirection:'column',gap:4}}>
                {bioOpen.birthdate && <div>🎂 {bioOpen.birthdate}</div>}
                {bioOpen.birthCity && <div>📍 {bioOpen.birthCity}</div>}
                {bioOpen.height && <div>📏 {bioOpen.height}</div>}
                {bioOpen.measurements && <div>📐 {bioOpen.measurements}</div>}
              </div>
            </div>
            <div style={{fontSize:12,color:'var(--text-soft)',lineHeight:1.5,whiteSpace:'pre-wrap'}}>{bioOpen.bio}</div>
            {bioOpen.aliases?.length > 0 && (
              <div style={{borderTop:'1px solid var(--border)',paddingTop:8}}>
                <div style={{fontSize:10,color:'var(--text-muted)',marginBottom:4}}>Aliases</div>
                <div style={{display:'flex',flexWrap:'wrap',gap:4}}>
                  {bioOpen.aliases.map((a,i)=><span key={i} style={{background:'var(--surface-2)',border:'1px solid var(--border)',borderRadius:3,padding:'2px 7px',fontSize:11,color:'var(--text-soft)'}}>{a}</span>)}
                </div>
              </div>
            )}
          </div>
        </div>
      )}
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

// ─── Poster Picker ────────────────────────────────────────────────────────────

function PosterPicker({ data, onPick }) {
  const cover = Array.isArray(data?.CoverUrl) ? data.CoverUrl[0] : data?.CoverUrl;
  const shots = data?.ScreenshotUrl
    ? (Array.isArray(data.ScreenshotUrl) ? data.ScreenshotUrl : [data.ScreenshotUrl])
    : [];
  const candidates = [cover, ...shots].filter(Boolean);
  if (!candidates.length) return null;

  const override = data?.PosterUrl || '';
  const current = override || cover;

  return (
    <div style={{display:'flex', flexDirection:'column', gap:4}}>
      <div style={{display:'flex', alignItems:'center', gap:8, fontSize:10, color:'var(--text-muted)', textTransform:'uppercase', letterSpacing:'0.06em'}}>
        <span>Poster</span>
        {override
          ? (
            <>
              <span style={{color:'var(--accent-light)', textTransform:'none', letterSpacing:0, fontSize:10}}>custom — downloaded directly, no crop</span>
              <button
                onClick={() => onPick('')}
                title="Clear override — auto-crop poster from cover/fanart instead"
                style={{...S.btn, fontSize:10, padding:'1px 6px'}}
              >↺ auto-crop from fanart</button>
            </>
          )
          : <span style={{color:'var(--text-muted)', textTransform:'none', letterSpacing:0, fontSize:10}}>default — auto-cropped from fanart. Click a thumbnail to override.</span>
        }
      </div>
      <div style={{display:'flex', gap:6, overflowX:'auto', paddingBottom:4}}>
        {candidates.map((url, i) => {
          const selected = url === current;
          return (
            <div
              key={url+i}
              onClick={() => onPick(url === cover ? '' : url)}
              style={{
                position:'relative', flexShrink:0, cursor:'pointer',
                border: selected ? '2px solid var(--accent)' : '1px solid var(--border)',
                borderRadius:4, overflow:'hidden', lineHeight:0,
              }}
              title={selected ? 'Current poster' : 'Click to use as poster'}
            >
              <img
                src={url}
                loading="lazy"
                style={{width:120, height:68, objectFit:'cover', display:'block', opacity: selected ? 1 : 0.75}}
              />
              {selected && (
                <span style={{position:'absolute', top:2, right:2, background:'var(--accent)', color:'#fff', borderRadius:3, padding:'0 4px', fontSize:10, fontWeight:600}}>✓</span>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ─── Detail Panel ─────────────────────────────────────────────────────────────

function DetailPanel({ file, videos, selectedIdx, onNavigate, onFileSorted, settings, addToast, onJob }) {
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
  const previewImage = (data && data.PosterUrl) || cover;
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
        {data?.PosterUrl && (
          <span
            title={`Custom poster will be downloaded from: ${data.PosterUrl}`}
            style={{fontSize:10, color:'var(--accent-light)', background:'var(--accent-dim)', border:'1px solid var(--accent)', borderRadius:3, padding:'1px 6px', flexShrink:0, letterSpacing:'0.04em'}}
          >poster: custom</span>
        )}
      </div>

      {/* Content area */}
      <div style={{flex:1, overflow:'hidden', display:'flex', gap:0}}>
        {/* Cover column */}
        <div style={{flex:'0 0 50%', maxWidth:760, minWidth:320, borderRight:'1px solid var(--border)', padding:12, display:'flex', flexDirection:'column', gap:10, overflowY:'auto'}}>
          <div style={{background:'var(--surface-2)', border:'1px solid var(--border)', borderRadius:6, overflow:'hidden', display:'flex', alignItems:'center', justifyContent:'center', minHeight: scraping ? 120 : undefined}}>
            {scraping
              ? <Sk w="100%" h={120} style={{borderRadius:0}} />
              : cover
                ? <img src={previewImage} alt="cover" style={{maxWidth:'100%', maxHeight:480, height:'auto', width:'auto', display:'block'}} />
                : <div style={{color:'var(--text-muted)',fontSize:12,textAlign:'center',padding:12}}>No cover</div>
            }
          </div>
          {!scraping && data && (
            <PosterPicker data={data} onPick={(url) => handleFieldChange('PosterUrl', url)} />
          )}
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
              <ActressPanel actresses={data?.Actress} onJob={onJob} />
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
  const [view, setView] = useState('sort'); // 'sort' | 'library'
  const [activeJobId, _setActiveJobId] = useState(() => {
    try { return localStorage.getItem('jv-activeJobId') || null; } catch { return null; }
  });
  const setActiveJobId = useCallback((id) => {
    _setActiveJobId(id);
    try {
      if (id) localStorage.setItem('jv-activeJobId', id);
      else localStorage.removeItem('jv-activeJobId');
    } catch {}
  }, []);

  // Fetch the running module version once, render at bottom-left so it's
  // obvious which release is actually live (matters when diagnosing "did
  // my upgrade apply?" or "is the browser serving stale app.jsx?").
  const [version, setVersion] = useState('');
  useEffect(() => {
    api('/api/version').then(r => setVersion(r?.version || '')).catch(() => {});
  }, []);

  // On mount: if we hydrated a job id from localStorage, verify the state
  // file still exists. If the server has reaped it (404), clear. Otherwise
  // keep — the JobProgressBar will fetch + render whatever state is there
  // (running OR done/error), and the user dismisses with × when ready.
  useEffect(() => {
    if (!activeJobId) return;
    let cancelled = false;
    (async () => {
      try {
        await api(`/api/jobs/${activeJobId}`);
      } catch {
        if (!cancelled) setActiveJobId(null);
      }
    })();
    return () => { cancelled = true; };
  }, []);


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
      <Header showSettings={showSettings} setShowSettings={setShowSettings} onHelp={()=>setShowHelp(true)} onSortAll={()=>setShowSortAll(true)} onManualScrape={()=>setShowManualScrape(true)} videoCount={videos.length} view={view} setView={setView} version={version} />
      {activeJobId && <JobProgressBar jobId={activeJobId} onDone={() => setActiveJobId(null)} />}
      {showSettings && view === 'sort' && <SortSettings s={settings} set={setSettings} serverSettings={serverSettings} onSaveDefaults={handleSaveDefaults} onResetToSaved={handleResetToSaved} addToast={add} onJob={setActiveJobId} />}
      <div style={{flex:1, display:'flex', overflow:'hidden'}}>
        {view === 'library' ? (
          <ActressLibrary onJob={setActiveJobId} addToast={add} />
        ) : (
          <>
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
                onJob={setActiveJobId}
              />
            </div>
          </>
        )}
      </div>
      <ToastHost toasts={toasts} remove={remove} />
      {showHelp && <HelpModal onClose={()=>setShowHelp(false)} />}
      {showSortAll && <SortAllModal videos={videos} settings={settings} onClose={()=>setShowSortAll(false)} />}
      {showManualScrape && <ManualModal onClose={()=>setShowManualScrape(false)} toast={add} />}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);

(() => {
    'use strict';

    const DEFAULT_PATH = '/Volumes/Media/';

    const state = {
        cwd: '',
        page: 1,
        pageSize: 25,
        total: 0,
        search: '',
        entries: [],
        videoFiles: [],
        selectedIndex: -1,
        scrapedData: null,
        scrapedOriginal: null,
        destPath: '',
        flags: { recurse: false, update: false, force: false },
        recurseOn: false,
        picker: { target: null, cwd: '' },
    };

    const AGG_FIELDS = [
        { key: 'Source', label: 'Source', type: 'input' },
        { key: 'ContentId', label: 'ContentId', type: 'input' },
        { key: 'Id', label: 'Id', type: 'input' },
        { key: 'Title', label: 'Title', type: 'textarea', span: true },
        { key: '_DisplayName', label: 'DisplayName', type: 'input', span: true, readonly: true },
        { key: 'AlternateTitle', label: 'AlternateTitle', type: 'input', span: true },
        { key: 'Description', label: 'Description', type: 'textarea', span: true },
        { key: 'ReleaseDate', label: 'ReleaseDate', type: 'input' },
        { key: 'Runtime', label: 'Runtime', type: 'input' },
        { key: 'Director', label: 'Director', type: 'input' },
        { key: 'Maker', label: 'Maker', type: 'input' },
        { key: 'Label', label: 'Label', type: 'input' },
        { key: 'Series', label: 'Series', type: 'input' },
        { key: 'Rating', label: 'Rating', type: 'input' },
        { key: 'Votes', label: 'Votes', type: 'input' },
        { key: 'Genre', label: 'Genre', type: 'textarea', span: true },
        { key: 'CoverUrl', label: 'CoverUrl', type: 'input', span: true, link: true },
        { key: 'ScreenshotUrl', label: 'ScreenshotUrl', type: 'input', span: true, link: true },
        { key: 'TrailerUrl', label: 'TrailerUrl', type: 'input', span: true, link: true },
    ];

    const qs = (s) => document.querySelector(s);
    const qsa = (s) => [...document.querySelectorAll(s)];

    function toast(msg, level = '') {
        const host = qs('#toast-host');
        const t = document.createElement('div');
        t.className = 'toast' + (level ? ' ' + level : '');
        t.textContent = msg;
        host.appendChild(t);
        setTimeout(() => t.remove(), 4500);
    }

    async function api(path, opts = {}) {
        const init = {
            method: opts.method || 'GET',
            headers: opts.body ? { 'Content-Type': 'application/json' } : {},
            body: opts.body ? JSON.stringify(opts.body) : undefined,
        };
        try {
            const res = await fetch(path, init);
            const json = await res.json().catch(() => ({}));
            if (!res.ok) {
                throw new Error(json.error || `HTTP ${res.status}`);
            }
            return json;
        } catch (e) {
            throw e;
        }
    }

    function fmtSize(bytes) {
        if (!bytes) return '';
        const units = ['B', 'KB', 'MB', 'GB', 'TB'];
        let i = 0, n = bytes;
        while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
        return `${n.toFixed(i ? 2 : 0)} ${units[i]}`;
    }
    function fmtTime(iso) {
        if (!iso) return '';
        try { return new Date(iso).toLocaleString(); } catch { return iso; }
    }

    function renderAggGrid() {
        const grid = qs('#agg-grid');
        grid.innerHTML = '';
        for (const field of AGG_FIELDS) {
            const div = document.createElement('div');
            div.className = 'agg-field' + (field.span ? ' span2' : '');
            const label = document.createElement('label');
            label.textContent = field.label;
            div.appendChild(label);
            let input;
            if (field.type === 'textarea') {
                input = document.createElement('textarea');
            } else {
                input = document.createElement('input');
                input.type = 'text';
            }
            input.dataset.key = field.key;
            if (field.readonly) input.readOnly = true;
            div.appendChild(input);
            grid.appendChild(div);
        }
    }

    function valueForField(data, key) {
        if (key === '_DisplayName' && data) {
            const studio = data.Maker || data.Label || '';
            return `[${data.Id || ''}] ${data.Title || ''}${studio ? ' (' + studio + ')' : ''}`;
        }
        const v = data ? data[key] : '';
        if (Array.isArray(v)) {
            if (v.length === 0) return '';
            if (typeof v[0] === 'string') return v.join(' \\ ');
            return v.map(x => (x && (x.Name || x.LastName) ? `${x.LastName || ''} ${x.FirstName || ''}`.trim() : JSON.stringify(x))).join(' \\ ');
        }
        return (v == null) ? '' : String(v);
    }

    function fillAggGrid(data) {
        for (const field of AGG_FIELDS) {
            const el = qs(`#agg-grid [data-key="${field.key}"]`);
            if (!el) continue;
            el.value = valueForField(data, field.key);
        }
    }

    function readAggGrid() {
        const patch = {};
        for (const field of AGG_FIELDS) {
            if (field.readonly || field.key.startsWith('_')) continue;
            const el = qs(`#agg-grid [data-key="${field.key}"]`);
            if (!el) continue;
            patch[field.key] = el.value;
        }
        return patch;
    }

    function renderCover(data) {
        const img = qs('#cover-img');
        const ph = qs('#cover-placeholder');
        const url = data && (Array.isArray(data.CoverUrl) ? data.CoverUrl[0] : data.CoverUrl);
        if (url) {
            img.src = url;
            img.style.display = '';
            ph.style.display = 'none';
        } else {
            img.removeAttribute('src');
            img.style.display = 'none';
            ph.style.display = '';
            ph.textContent = data ? 'No cover URL' : 'Select a file to preview';
        }
    }

    function renderActresses(data) {
        const grid = qs('#actress-grid');
        grid.innerHTML = '';
        const actresses = data && data.Actress ? (Array.isArray(data.Actress) ? data.Actress : [data.Actress]) : [];
        if (!actresses.length) {
            grid.innerHTML = '<div class="empty">No actress data</div>';
            return;
        }
        actresses.forEach((a, idx) => {
            const card = document.createElement('div');
            card.className = 'actress-card';
            const name = [a.LastName, a.FirstName].filter(Boolean).join(' ') || a.Name || '—';
            const jp = a.JapaneseName || '';
            const thumb = a.ThumbUrl || '';
            card.innerHTML = `
                <button class="edit-btn" data-idx="${idx}">&#9998; edit</button>
                ${thumb ? `<img class="thumb" src="${thumb}" alt="${name}" />` : '<div class="thumb"></div>'}
                <div class="name">${name}</div>
                <div class="jp">${jp}</div>
            `;
            card.querySelector('.edit-btn').addEventListener('click', () => openActressEditor(idx));
            grid.appendChild(card);
        });
    }

    function openActressEditor(idx) {
        const a = state.scrapedData.Actress[idx];
        const name = [a.LastName, a.FirstName].filter(Boolean).join(' ') || a.Name || '';
        qs('#actress-edit-name').value = name;
        qs('#actress-edit-jp').value = a.JapaneseName || '';
        qs('#modal-actress').hidden = false;
        qs('#btn-actress-save').onclick = () => {
            const newName = qs('#actress-edit-name').value.trim();
            const parts = newName.split(/\s+/);
            a.LastName = parts[0] || '';
            a.FirstName = parts.slice(1).join(' ');
            a.Name = newName;
            a.JapaneseName = qs('#actress-edit-jp').value.trim();
            qs('#modal-actress').hidden = true;
            renderActresses(state.scrapedData);
        };
    }

    function renderFileTable() {
        const body = qs('#file-table-body');
        body.innerHTML = '';
        if (!state.entries.length) {
            body.innerHTML = '<tr><td colspan="4" class="empty">No files</td></tr>';
            return;
        }
        for (const e of state.entries) {
            const tr = document.createElement('tr');
            tr.className = e.isDir ? 'row-dir' : (e.isVideo ? 'row-video' : '');
            const nameCell = `<td class="name-cell">${e.isDir ? '📂' : (e.isVideo ? '🎞️' : '📄')} ${escapeHtml(e.name)}</td>`;
            tr.innerHTML = `
                ${nameCell}
                <td>${e.isDir ? '' : fmtSize(e.size)}</td>
                <td>${fmtTime(e.lastModified)}</td>
                <td>${e.isVideo ? `<button class="sort-row-btn" data-path="${escapeAttr(e.fullPath)}">▶ Sort</button>` : ''}</td>
            `;
            tr.querySelector('.name-cell').addEventListener('click', () => {
                if (e.isDir) {
                    loadBrowse(e.fullPath);
                } else if (e.isVideo) {
                    const vIdx = state.videoFiles.findIndex(f => f.fullPath === e.fullPath);
                    if (vIdx >= 0) selectVideo(vIdx);
                }
            });
            const sortBtn = tr.querySelector('.sort-row-btn');
            if (sortBtn) sortBtn.addEventListener('click', (ev) => {
                ev.stopPropagation();
                sortOne(e.fullPath);
            });
            body.appendChild(tr);
        }
        qs('#pager-info').textContent =
            `${(state.page - 1) * state.pageSize + 1}-${Math.min(state.page * state.pageSize, state.total)} of ${state.total}`;
    }

    function escapeHtml(s) {
        return String(s).replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
    }
    function escapeAttr(s) {
        return escapeHtml(s);
    }

    async function loadBrowse(path) {
        try {
            const recurse = state.recurseOn;
            const q = new URLSearchParams({ path });
            if (recurse) q.set('recurse', '1');
            const res = await api('/api/browse?' + q.toString());
            state.cwd = res.cwd;
            qs('#browser-cwd').textContent = res.cwd + (recurse ? ' (recursive)' : '');
            qs('#input-browse-path').value = res.cwd;
            const entries = res.entries || [];
            state.videoFiles = entries.filter(e => e.isVideo);
            state.page = 1;
            if (recurse) {
                state.entries = entries;
                state.total = entries.length;
                renderRecursiveTable();
            } else {
                await loadFiles();
            }
            populateDropdown();
            if (state.videoFiles.length) {
                selectVideo(0);
            } else {
                state.selectedIndex = -1;
                updateDestinationDisplay(null);
            }
        } catch (e) {
            toast('Browse failed: ' + e.message, 'error');
        }
    }

    function renderRecursiveTable() {
        const body = qs('#file-table-body');
        body.innerHTML = '';
        const needle = (state.search || '').toLowerCase();
        const filtered = needle
            ? state.entries.filter(e => (e.relativePath || e.name).toLowerCase().includes(needle))
            : state.entries;
        state.total = filtered.length;
        if (!filtered.length) {
            body.innerHTML = '<tr><td colspan="4" class="empty">No video files match</td></tr>';
            qs('#pager-info').textContent = '0-0 of 0';
            return;
        }
        const start = (state.page - 1) * state.pageSize;
        const slice = filtered.slice(start, start + state.pageSize);
        for (const e of slice) {
            const tr = document.createElement('tr');
            tr.className = 'row-video';
            const display = e.relativePath || e.name;
            tr.innerHTML = `
                <td class="name-cell">🎞️ ${escapeHtml(display)}</td>
                <td>${fmtSize(e.size)}</td>
                <td>${fmtTime(e.lastModified)}</td>
                <td><button class="sort-row-btn" data-path="${escapeAttr(e.fullPath)}">▶ Sort</button></td>
            `;
            tr.querySelector('.name-cell').addEventListener('click', () => {
                const vIdx = state.videoFiles.findIndex(f => f.fullPath === e.fullPath);
                if (vIdx >= 0) selectVideo(vIdx);
            });
            tr.querySelector('.sort-row-btn').addEventListener('click', (ev) => {
                ev.stopPropagation();
                sortOne(e.fullPath);
            });
            body.appendChild(tr);
        }
        qs('#pager-info').textContent =
            `${start + 1}-${Math.min(start + state.pageSize, filtered.length)} of ${filtered.length}`;
    }

    async function loadFiles() {
        if (!state.cwd) return;
        try {
            const q = new URLSearchParams({
                path: state.cwd,
                page: state.page,
                pageSize: state.pageSize,
                search: state.search || ''
            });
            const res = await api('/api/files?' + q.toString());
            state.entries = res.entries || [];
            state.total = res.total || 0;
            renderFileTable();
        } catch (e) {
            toast('Files load failed: ' + e.message, 'error');
        }
    }

    function populateDropdown() {
        const sel = qs('#file-dropdown');
        sel.innerHTML = '';
        if (!state.videoFiles.length) {
            sel.disabled = true;
            qs('#nav-header').textContent = '(0 of 0) —';
            return;
        }
        sel.disabled = false;
        state.videoFiles.forEach((f, i) => {
            const o = document.createElement('option');
            o.value = i;
            const label = f.relativePath || f.name;
            o.textContent = `${label} [${i + 1}]`;
            sel.appendChild(o);
        });
    }

    async function selectVideo(idx) {
        if (idx < 0 || idx >= state.videoFiles.length) return;
        state.selectedIndex = idx;
        const f = state.videoFiles[idx];
        qs('#file-dropdown').value = idx;
        qs('#nav-header').textContent = `(${idx + 1} of ${state.videoFiles.length}) ${stripExt(f.name)}`;
        updateDestinationDisplay({ source: f.relativePath || f.name, target: '…' });
        await scrapeSelected();
        triggerPreview();
    }

    function updateDestinationDisplay(info) {
        const el = qs('#destination-display');
        const src = qs('#dest-source');
        const tgt = qs('#dest-target');
        if (!info) {
            el.hidden = true;
            return;
        }
        el.hidden = false;
        src.textContent = info.source || '';
        tgt.textContent = info.target || '—';
        tgt.classList.toggle('error', !!info.error);
    }

    function stripExt(n) {
        const i = n.lastIndexOf('.');
        return i > 0 ? n.slice(0, i) : n;
    }

    async function scrapeSelected() {
        const f = state.videoFiles[state.selectedIndex];
        if (!f) return;
        try {
            const res = await api('/api/scrape', { method: 'POST', body: { path: f.fullPath } });
            state.scrapedData = res.data;
            state.scrapedOriginal = JSON.parse(JSON.stringify(res.data));
            fillAggGrid(res.data);
            renderCover(res.data);
            renderActresses(res.data);
        } catch (e) {
            toast(`Scrape failed: ${e.message}`, 'error');
            state.scrapedData = null;
            state.scrapedOriginal = null;
            fillAggGrid(null);
            renderCover(null);
            renderActresses(null);
        }
    }

    function buildOverride() {
        const override = {
            'sort.format.outputfolder': qs('#input-outputfolder').value,
            'sort.format.folder': qs('#input-folder').value || '<ID>',
            'sort.format.file': qs('#input-file').value || '<ID>',
            'sort.format.groupactress': qs('#flag-groupactress').checked,
            'sort.metadata.nfo.unknownactress': qs('#flag-unknownactress').checked,
        };
        if (!override['sort.format.outputfolder']) delete override['sort.format.outputfolder'];
        return override;
    }

    let previewTimer = null;
    function triggerPreview() {
        clearTimeout(previewTimer);
        previewTimer = setTimeout(runPreview, 300);
    }

    async function runPreview() {
        const f = state.videoFiles[state.selectedIndex];
        const dest = qs('#input-sort-dest').value;
        const out = qs('#preview-dest');
        if (!f || !dest) {
            out.textContent = '—';
            if (f) updateDestinationDisplay({ source: f.relativePath || f.name, target: '(set a destination)' });
            return;
        }
        try {
            const res = await api('/api/preview', {
                method: 'POST',
                body: {
                    path: f.fullPath,
                    destinationPath: dest,
                    settingsOverride: buildOverride()
                }
            });
            out.textContent = res.filePath || '—';
            updateDestinationDisplay({ source: f.relativePath || f.name, target: res.filePath || '—' });
            if (res.partNumber && res.partNumber > 0) {
                const idx = state.selectedIndex + 1;
                const total = state.videoFiles.length;
                qs('#nav-header').textContent = `(${idx} of ${total}) ${stripExt(f.name)} · part ${res.partNumber}`;
            }
        } catch (e) {
            out.textContent = '(' + e.message + ')';
            updateDestinationDisplay({ source: f.relativePath || f.name, target: e.message, error: true });
        }
    }

    async function sortOne(path) {
        const dest = qs('#input-sort-dest').value;
        if (!dest) { toast('Set a destination folder first', 'error'); return; }
        if (!confirm(`Sort this file?\n${path}\n→ ${dest}`)) return;
        const selected = state.videoFiles[state.selectedIndex];
        const dataToSend = (selected && selected.fullPath === path) ? state.scrapedData : null;
        try {
            const res = await api('/api/sort', {
                method: 'POST',
                body: {
                    path,
                    destinationPath: dest,
                    settingsOverride: buildOverride(),
                    flags: { force: state.flags.force, update: state.flags.update },
                    data: dataToSend
                }
            });
            toast(`Sorted to ${res.folderPath}`, 'ok');
            if (res.warnings && res.warnings.length) {
                res.warnings.forEach(w => toast(w, 'error'));
            }
            loadFiles();
        } catch (e) {
            toast('Sort failed: ' + e.message, 'error');
        }
    }

    async function runTreePreview() {
        const dest = qs('#input-sort-dest').value;
        if (!dest) { toast('Set a destination folder first', 'error'); return; }
        if (!state.videoFiles.length) { toast('No video files in current folder', 'error'); return; }

        qs('#modal-tree').hidden = false;
        qs('#tree-summary').textContent = 'Computing…';
        qs('#tree-body').textContent = '';
        qs('#tree-unresolved').innerHTML = '';
        qs('#sort-all-progress').innerHTML = '';

        try {
            const res = await api('/api/preview-tree', {
                method: 'POST',
                body: {
                    paths: state.videoFiles.map(f => f.fullPath),
                    destinationPath: dest,
                    settingsOverride: buildOverride()
                }
            });
            qs('#tree-summary').textContent =
                `${res.resolvedCount} resolved, ${res.unresolved.length} unresolved — ${res.totalFolders} folders, ${res.totalFiles} files projected`;
            qs('#tree-body').textContent = renderTree(res.tree);
            if (res.unresolved.length) {
                const u = res.unresolved.map(x => `• ${basename(x.source)} — ${x.reason}`).join('\n');
                qs('#tree-unresolved').innerHTML = `<div class="status-line error">Unresolved (${res.unresolved.length}):</div><pre class="json-body">${escapeHtml(u)}</pre>`;
            }
        } catch (e) {
            qs('#tree-summary').textContent = 'Preview failed: ' + e.message;
            qs('#tree-summary').classList.add('error');
        }
    }

    function basename(p) {
        const i = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
        return i >= 0 ? p.slice(i + 1) : p;
    }

    function renderTree(node, prefix = '', isLast = true, isRoot = true) {
        let out = '';
        if (isRoot) {
            out += node.name + '\n';
        }
        const kids = node.children || [];
        const files = node.files || [];
        const items = [...kids.map(c => ({ type: 'dir', node: c })), ...files.map(f => ({ type: 'file', name: f }))];
        items.forEach((item, idx) => {
            const last = idx === items.length - 1;
            const branch = last ? '└── ' : '├── ';
            const nextPrefix = prefix + (last ? '    ' : '│   ');
            if (item.type === 'dir') {
                out += prefix + branch + item.node.name + '/\n';
                out += renderTree(item.node, nextPrefix, last, false);
            } else {
                out += prefix + branch + item.name + '\n';
            }
        });
        return out;
    }

    async function sortAllFromTree() {
        const dest = qs('#input-sort-dest').value;
        const prog = qs('#sort-all-progress');
        prog.innerHTML = '';
        let ok = 0, fail = 0;
        for (const f of state.videoFiles) {
            const line = document.createElement('div');
            line.className = 'line';
            line.textContent = f.name + '…';
            prog.appendChild(line);
            try {
                const res = await api('/api/sort', {
                    method: 'POST',
                    body: {
                        path: f.fullPath,
                        destinationPath: dest,
                        settingsOverride: buildOverride(),
                        flags: { force: state.flags.force, update: state.flags.update }
                    }
                });
                line.className = 'line ok';
                line.textContent = f.name + ' → ' + res.folderPath;
                ok++;
                if (res.warnings && res.warnings.length) {
                    res.warnings.forEach(w => {
                        const wline = document.createElement('div');
                        wline.className = 'line err';
                        wline.textContent = '  ⚠ ' + w;
                        prog.appendChild(wline);
                    });
                }
            } catch (e) {
                line.className = 'line err';
                line.textContent = f.name + ' — ' + e.message;
                fail++;
            }
        }
        toast(`Done. ${ok} sorted, ${fail} failed.`, fail ? 'error' : 'ok');
        loadFiles();
    }

    async function refreshJavdbSession() {
        const btn = qs('#btn-javdb-refresh');
        const original = btn.textContent;
        btn.disabled = true;
        btn.textContent = 'Opening Chromium — log in…';
        try {
            const res = await api('/api/javdb/session/refresh', { method: 'POST' });
            const exp = res.expiresAt ? new Date(res.expiresAt).toLocaleDateString() : 'unknown';
            toast(`javdb session captured (expires ${exp})`, 'ok');
        } catch (e) {
            toast('javdb session refresh failed: ' + e.message, 'error');
        } finally {
            btn.disabled = false;
            btn.textContent = original;
        }
    }

    async function manualSearch() {
        const q = qs('#manual-query').value.trim();
        if (!q) return;
        const s = qs('#manual-status');
        s.className = 'status-line';
        s.textContent = 'Searching…';
        try {
            const res = await api('/api/manual-search', { method: 'POST', body: { query: q } });
            state.scrapedData = res.data;
            state.scrapedOriginal = JSON.parse(JSON.stringify(res.data));
            fillAggGrid(res.data);
            renderCover(res.data);
            renderActresses(res.data);
            s.className = 'status-line ok';
            s.textContent = 'Found: ' + (res.data.Id || '—');
            setTimeout(() => { qs('#modal-manual').hidden = true; }, 800);
            triggerPreview();
        } catch (e) {
            s.className = 'status-line error';
            s.textContent = e.message;
        }
    }

    function applyPreset(preset) {
        const out = qs('#input-outputfolder');
        const fol = qs('#input-folder');
        const fil = qs('#input-file');
        const ga = qs('#flag-groupactress');
        const ua = qs('#flag-unknownactress');
        if (preset === 'actress') {
            out.value = '<ACTORS>'; fol.value = '<ID>'; fil.value = '<ID>';
            ga.checked = false; ua.checked = false;
        } else if (preset === 'group') {
            out.value = '<ACTORS>'; fol.value = '<ID>'; fil.value = '<ID>';
            ga.checked = true; ua.checked = true;
        } else if (preset === 'flat') {
            out.value = ''; fol.value = '<ID>'; fil.value = '<ID>';
            ga.checked = false; ua.checked = false;
        }
        triggerPreview();
    }

    async function openFolderPicker(targetInputId, title) {
        state.picker.target = targetInputId;
        qs('#picker-title').textContent = title || 'Choose folder';
        const seed = qs('#' + targetInputId).value || DEFAULT_PATH;
        qs('#modal-folder-picker').hidden = false;
        await pickerLoad(seed);
    }

    async function pickerLoad(path) {
        const list = qs('#picker-list');
        list.innerHTML = '<li class="empty">Loading…</li>';
        try {
            const res = await api('/api/browse?path=' + encodeURIComponent(path));
            state.picker.cwd = res.cwd;
            qs('#picker-path').value = res.cwd;
            const dirs = (res.entries || []).filter(e => e.isDir);
            list.innerHTML = '';
            if (!dirs.length) {
                list.innerHTML = '<li class="empty">(no subfolders — press "Use this folder" to select this one)</li>';
                return;
            }
            for (const d of dirs) {
                const li = document.createElement('li');
                li.innerHTML = `<span class="folder-icon">📁</span><span>${escapeHtml(d.name)}</span>`;
                li.addEventListener('click', () => pickerLoad(d.fullPath));
                list.appendChild(li);
            }
        } catch (e) {
            list.innerHTML = `<li class="empty">Error: ${escapeHtml(e.message)}</li>`;
        }
    }

    async function pickerUp() {
        if (!state.picker.cwd) return;
        try {
            const res = await api('/api/browse?path=' + encodeURIComponent(state.picker.cwd));
            if (res.parent) await pickerLoad(res.parent);
        } catch { /* noop */ }
    }

    function pickerSelect() {
        if (!state.picker.target) return;
        const el = qs('#' + state.picker.target);
        el.value = state.picker.cwd;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        qs('#modal-folder-picker').hidden = true;
        if (state.picker.target === 'input-browse-path') {
            loadBrowse(state.picker.cwd);
        } else if (state.picker.target === 'input-sort-dest') {
            triggerPreview();
        }
    }

    function bind() {
        renderAggGrid();

        qs('#btn-pick-source').addEventListener('click', () =>
            openFolderPicker('input-browse-path', 'Choose source folder'));
        qs('#btn-pick-dest').addEventListener('click', () =>
            openFolderPicker('input-sort-dest', 'Choose destination folder'));
        qs('#picker-up').addEventListener('click', pickerUp);
        qs('#picker-go').addEventListener('click', () => pickerLoad(qs('#picker-path').value));
        qs('#picker-path').addEventListener('keydown', (e) => {
            if (e.key === 'Enter') pickerLoad(e.target.value);
        });
        qs('#picker-select').addEventListener('click', pickerSelect);
        qs('#picker-cancel').addEventListener('click', () => { qs('#modal-folder-picker').hidden = true; });

        qs('#btn-browse').addEventListener('click', () => {
            loadBrowse(qs('#input-browse-path').value || '/');
        });
        qs('#input-browse-path').addEventListener('keydown', (e) => {
            if (e.key === 'Enter') loadBrowse(e.target.value);
        });
        qs('#btn-browse-up').addEventListener('click', async () => {
            if (!state.cwd) return;
            const res = await api('/api/browse?path=' + encodeURIComponent(state.cwd));
            if (res.parent) loadBrowse(res.parent);
        });

        qs('#search-files').addEventListener('input', (e) => {
            state.search = e.target.value;
            state.page = 1;
            if (state.recurseOn) { renderRecursiveTable(); }
            else { loadFiles(); }
        });

        qs('#select-pagesize').addEventListener('change', (e) => {
            state.pageSize = parseInt(e.target.value, 10) || 25;
            state.page = 1;
            if (state.recurseOn) { renderRecursiveTable(); }
            else { loadFiles(); }
        });

        qs('#btn-page-prev').addEventListener('click', () => {
            if (state.page > 1) {
                state.page--;
                if (state.recurseOn) { renderRecursiveTable(); } else { loadFiles(); }
            }
        });
        qs('#btn-page-next').addEventListener('click', () => {
            if (state.page * state.pageSize < state.total) {
                state.page++;
                if (state.recurseOn) { renderRecursiveTable(); } else { loadFiles(); }
            }
        });

        qs('#file-dropdown').addEventListener('change', (e) => selectVideo(parseInt(e.target.value, 10)));
        qs('#btn-first').addEventListener('click', () => selectVideo(0));
        qs('#btn-last').addEventListener('click', () => selectVideo(state.videoFiles.length - 1));
        qs('#btn-prev').addEventListener('click', () => selectVideo(Math.max(0, state.selectedIndex - 1)));
        qs('#btn-next').addEventListener('click', () => selectVideo(Math.min(state.videoFiles.length - 1, state.selectedIndex + 1)));

        qs('#btn-apply-dest').addEventListener('click', triggerPreview);
        qs('#btn-clear-dest').addEventListener('click', () => { qs('#input-sort-dest').value = ''; triggerPreview(); });
        qs('#input-sort-dest').addEventListener('input', triggerPreview);
        qs('#input-outputfolder').addEventListener('input', triggerPreview);
        qs('#input-folder').addEventListener('input', triggerPreview);
        qs('#input-file').addEventListener('input', triggerPreview);
        qs('#flag-groupactress').addEventListener('change', triggerPreview);
        qs('#flag-unknownactress').addEventListener('change', triggerPreview);

        qsa('.preset-btn').forEach(b => b.addEventListener('click', () => applyPreset(b.dataset.preset)));

        for (const k of ['recurse', 'update', 'force']) {
            const el = qs(`#flag-${k}`);
            if (el) el.addEventListener('change', () => { state.flags[k] = el.checked; });
        }
        qs('#flag-recurse').addEventListener('change', (e) => {
            state.recurseOn = e.target.checked;
            if (state.cwd) loadBrowse(state.cwd);
        });

        qs('#btn-apply').addEventListener('click', () => {
            if (!state.scrapedData) return;
            Object.assign(state.scrapedData, readAggGrid());
            toast('Changes applied to in-memory scrape data', 'ok');
            renderCover(state.scrapedData);
            triggerPreview();
        });
        qs('#btn-reset').addEventListener('click', () => {
            if (!state.scrapedOriginal) return;
            state.scrapedData = JSON.parse(JSON.stringify(state.scrapedOriginal));
            fillAggGrid(state.scrapedData);
            renderCover(state.scrapedData);
            renderActresses(state.scrapedData);
            triggerPreview();
        });
        qs('#btn-json').addEventListener('click', () => {
            qs('#json-body').textContent = JSON.stringify(state.scrapedData || {}, null, 2);
            qs('#modal-json').hidden = false;
        });

        qs('#btn-manual-search').addEventListener('click', () => {
            qs('#manual-query').value = '';
            qs('#manual-status').textContent = '';
            qs('#modal-manual').hidden = false;
        });
        qs('#btn-manual-go').addEventListener('click', manualSearch);
        qs('#manual-query').addEventListener('keydown', (e) => { if (e.key === 'Enter') manualSearch(); });

        qs('#btn-preview-tree').addEventListener('click', runTreePreview);
        qs('#btn-sort-all').addEventListener('click', sortAllFromTree);

        qs('#btn-javdb-refresh').addEventListener('click', refreshJavdbSession);

        qs('#btn-screens').addEventListener('click', () => {
            const d = state.scrapedData;
            const shots = d && d.ScreenshotUrl ? (Array.isArray(d.ScreenshotUrl) ? d.ScreenshotUrl : [d.ScreenshotUrl]) : [];
            const grid = qs('#screens-grid');
            grid.innerHTML = shots.length ? '' : '<div class="empty">No screenshots</div>';
            shots.forEach(u => {
                const i = document.createElement('img');
                i.src = u;
                i.loading = 'lazy';
                grid.appendChild(i);
            });
            qs('#modal-screens').hidden = false;
        });

        qsa('.modal-close').forEach(b => b.addEventListener('click', () => {
            qs('#' + b.dataset.close).hidden = true;
        }));
        qsa('.modal').forEach(m => m.addEventListener('click', (e) => {
            if (e.target === m) m.hidden = true;
        }));

    }

    function init() {
        bind();
        const initialPath = new URLSearchParams(location.search).get('path') || '';
        const src = qs('#input-browse-path');
        const dst = qs('#input-sort-dest');
        if (!src.value) src.value = initialPath || DEFAULT_PATH;
        if (!dst.value) dst.value = DEFAULT_PATH;
        if (src.value) loadBrowse(src.value);
    }

    document.addEventListener('DOMContentLoaded', init);
})();

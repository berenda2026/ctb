#!/usr/bin/env python3
"""AI 错题本 同步服务（只用 Python 标准库）。
监听 127.0.0.1:8790，由 nginx 反代到 https://<IP>/ctb-sync/ 。
POST /ctb-sync/api  {code, since, changes:[{s, id, ts, d|null}]}
  -> {ok, seq, changes:[{s,id,ts,d|null}]}   (since 之后服务器上变化的记录)
同步码写在 /opt/ctb-sync/codes.txt（一行一个），只有列出的码能用。
"""
import json, os, sqlite3, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.environ.get('CTB_HOME', '/opt/ctb-sync')
DBF = os.path.join(HOME, 'data.db')
CODES = os.path.join(HOME, 'codes.txt')
ORIGINS = {'https://berenda2026.github.io', 'https://124.223.170.26', 'http://localhost:8765'}
MAXB = 60 * 1024 * 1024
lock = threading.Lock()

def db():
    c = sqlite3.connect(DBF)
    c.execute('create table if not exists rec(code text, s text, id text, ts integer, d text, seq integer, primary key(code,s,id))')
    c.execute('create index if not exists rec_seq on rec(code, seq)')
    c.execute('create table if not exists meta(code text primary key, seq integer)')
    return c

def codes():
    try:
        return {l.strip() for l in open(CODES, encoding='utf-8') if l.strip() and not l.startswith('#')}
    except FileNotFoundError:
        return set()

def sync(req):
    code = str(req.get('code', ''))
    if len(code) < 8 or code not in codes():
        return 403, {'ok': False, 'err': '同步码不对'}
    since = int(req.get('since') or 0)
    with lock:
        c = db()
        try:
            r = c.execute('select seq from meta where code=?', (code,)).fetchone()
            seq = r[0] if r else 0
            for ch in req.get('changes') or []:
                s, i, ts = str(ch['s']), str(ch['id']), int(ch.get('ts') or 0)
                d = ch.get('d')
                old = c.execute('select ts from rec where code=? and s=? and id=?', (code, s, i)).fetchone()
                if old and old[0] >= ts:
                    continue
                seq += 1
                c.execute('insert or replace into rec values(?,?,?,?,?,?)',
                          (code, s, i, ts, None if d is None else json.dumps(d, ensure_ascii=False), seq))
            c.execute('insert or replace into meta values(?,?)', (code, seq))
            c.commit()
            out = [{'s': s, 'id': i, 'ts': ts, 'd': None if d is None else json.loads(d)}
                   for s, i, ts, d in c.execute('select s,id,ts,d from rec where code=? and seq>? order by seq', (code, since))]
        finally:
            c.close()
    return 200, {'ok': True, 'seq': seq, 'changes': out, 'now': int(time.time() * 1000)}

class H(BaseHTTPRequestHandler):
    def cors(self):
        o = self.headers.get('Origin', '')
        if o in ORIGINS:
            self.send_header('Access-Control-Allow-Origin', o)
            self.send_header('Vary', 'Origin')
            self.send_header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', 'Content-Type')
            self.send_header('Access-Control-Max-Age', '86400')

    def reply(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code); self.cors()
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_OPTIONS(self):
        self.send_response(204); self.cors(); self.end_headers()

    def do_GET(self):
        self.reply(200, {'ok': True, 'app': 'ctb-sync'})

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n > MAXB:
            return self.reply(413, {'ok': False, 'err': '数据太大'})
        try:
            req = json.loads(self.rfile.read(n) or b'{}')
        except Exception:
            return self.reply(400, {'ok': False, 'err': '格式不对'})
        try:
            self.reply(*sync(req))
        except Exception as e:
            self.reply(500, {'ok': False, 'err': str(e)[:200]})

    def log_message(self, *a):
        pass

if __name__ == '__main__':
    os.makedirs(HOME, exist_ok=True)
    port = int(os.environ.get('CTB_PORT', '8790'))
    ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()

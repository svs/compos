#!/usr/bin/env python3
"""needle-daemon --- Needle 3, the catalog, and the vectors, in one process.

scheme/packages/needle.scm starts this and keeps it open. stdin carries
one request object a line; stdout carries one reply object a line.

  {'op': 'ping'}                       -> {'ok': true, 'pong': true}
  {'op': 'index', 'rows': [ ... ]}     -> {'ok': true, 'rows': N}
  {'op': 'route', 'query': Q, 'k': 5}  -> {'ok': true, 'calls': [...], ...}

A route is four steps and none of them leaves this machine: embed the
query, take the nearest K rows of the catalog, bind those K as the tool
set, and answer. The model is held in process, so binding a new set
costs about 13 ms instead of the 54 ms a fresh worker costs and the
60 ms a fresh server costs.

The catalog is embedded once a generation and cached on disk. Embedding
3700 rows costs about 30 s, and a route must never pay it.
"""

import json
import math
import os
import re
import sys

LOG = None


def open_log():
    global LOG
    where = os.environ.get('NEEDLE_DAEMON_LOG')
    if not where:
        return
    try:
        LOG = open(where, 'a', buffering=1)
    except OSError:
        return
    try:  # whatever the engine prints goes to the log, never to stdout
        os.dup2(LOG.fileno(), 2)
    except OSError:
        pass


def log(text):
    where = LOG if LOG is not None else sys.stderr
    if where is not None:
        print(text, file=where, flush=True)


# --- the tool schema a catalog row stands for ---------------------------------

# A catalog row is a name, a doc and a signature. Needle needs a schema,
# and the signature is where the arguments are: (buffer-text NAME) and
# (split-window! DIR [SIZE]) name one required and one optional string.
# Every argument is a string, because the editor takes the text a person
# said and the caller converts it.
# Nothing is required. A signature says what a function takes, not what
# a person says: (visit PATH GROUP) needs a group, and no sentence names
# one. A required argument with no span in the request withholds the
# whole call, so a faithful schema loses the tool to a worse one that
# asks for less. The editor fills what the sentence did not.
# Four arguments and sixty characters. Every word of a schema is
# compiled into the decode grammar, and binding five full ones cost
# 60 to 155 ms of a 119 ms answer. A signature with eight arguments
# spends that budget on arguments no sentence fills.
MAX_ARGS = 4
MAX_DESC = 60


def schema_of(row):
    props = {}
    for token in signature_args(row.get('sig') or '')[:MAX_ARGS]:
        arg = token.strip('[]().').lower()
        if arg:
            props[arg] = {'type': 'string'}
    return {
        'name': row['name'],
        'description': described_with_synonyms(row),
        'parameters': {'type': 'object', 'properties': props, 'required': []},
    }


# The action, and the other words for it. The engine reads a
# description literally, so a tool whose doc says kill is not reached by
# a request that says close unless the description says close too.
def described_with_synonyms(row):
    doc = description_of(row)
    lead = next((w for w in re.split(r'[^a-z0-9]+', doc.lower()) if len(w) > 2), '')
    others = sorted(spoken_as(lead) - {lead})[:3] if lead in SYNONYM else []
    return (doc[:MAX_DESC] + (' (also: %s)' % ', '.join(others) if others else ''))


# The name the model reads, which is not the name the editor calls.
# Needle picks a tool by its name before anything else, and ours are
# Scheme names: 'open /etc/hosts' reached open-buffer-link! over visit
# at 0.93, because one holds the word the request used and the other
# does not. Offered as open_a_file it is chosen at 1.0. So a row is
# offered under its own action, and the answer is mapped back.
def spoken_name(row, taken, want=frozenset()):
    words = [w for w in re.split(r'[^a-z0-9]+', description_of(row).lower()) if w][:5]
    # Say it back in the asker's verb. 'kill a buffer' offered as
    # kill_a_buffer lost 'close the messages buffer' to a changeset tool
    # whose name began with close. Offered as close_a_buffer it wins on
    # the words the request actually used.
    for i, word in enumerate(words[:2]):
        spoken = sorted(spoken_as(word) & want)
        if spoken and word not in want:
            words[i] = spoken[0]
            break
    base = '_'.join(words) or re.sub(r'[^a-z0-9]+', '_', row['name'].lower()).strip('_')
    name, n = base, 2
    while name in taken:
        name, n = '%s_%d' % (base, n), n + 1
    taken[name] = row['name']
    return name


# The first clause, and no more. A catalogue docstring is written for a
# person reading the whole entry: 'open a file; GROUP joins it to that
# context; /ssh:HOST:/PATH opens over ssh' says one thing and then two
# footnotes. Every word of it is compiled into the decode grammar, and
# binding five full docstrings cost 102 ms of a 190 ms answer.
def description_of(row):
    doc = (row.get('doc') or row['name']).strip()
    for mark in (';', '. '):
        head = doc.split(mark)[0].strip()
        if len(head) >= 8:
            return head[:120]
    return doc[:120]


# The tokens after the function's own name. A token in brackets is
# optional; &optional and &rest are markers, not arguments, and
# everything after one of them is optional.
def signature_args(sig):
    body = sig.strip()
    if body.startswith('('):
        body = body[1:]
    if body.endswith(')'):
        body = body[:-1]
    tokens = body.split()[1:]
    out, optional = [], False
    for token in tokens:
        if token.startswith('&'):
            optional = True
            continue
        if token.startswith('[') or optional:
            out.append('[' + token.strip('[]') + ']')
        else:
            out.append(token)
    return out


# The words a request and a row have in common decide more than the
# vector does, so both are reduced the same way: lowercase, split on
# anything that is not a letter or a digit, drop the words every
# sentence carries and the fragments too short to mean anything.
STOP = frozenset(('the', 'a', 'an', 'this', 'that', 'these', 'those', 'my', 'me',
                  'it', 'its', 'in', 'on', 'of', 'to', 'for', 'and', 'or', 'with',
                  'is', 'are', 'was', 'be', 'do', 'does', 'please', 'from', 'by',
                  'at', 'as', 'into', 'out', 'up', 'down', 'all', 'any', 'one'))


# How much a row that does something outranks one that only computes a
# value, when the words matched them equally. Small on purpose: it
# breaks ties and never overrules what the request said.
ACTS = 0.0

# How much a row that matches what the request is about outranks one
# that matches only what it wants done.
NOUN = 0.0


# A shallower rung of the ladder, when one is built. Needle 3 is
# trained so every depth from 2 to 20 layers is deployable, and the
# 8-layer rung answers in 13 ms where the full model takes 31, with the
# confidence head intact. NEEDLE_WEIGHTS names the archive; unset, the
# package's own full weights answer.
def weights_kw():
    path = os.environ.get('NEEDLE_WEIGHTS')
    return {'weights': path} if path and os.path.exists(path) else {}


def summarise(scores):
    kept = sorted(c for c in scores if c is not None)
    if not kept:
        return None
    return {'n': len(kept), 'median': round(kept[len(kept) // 2], 3),
            'low': round(kept[0], 3), 'high': round(kept[-1], 3)}


def words_of(text):
    return frozenset(w for w in re.split(r'[^a-z0-9]+', text.lower())
                     if len(w) > 2 and w not in STOP)


# What a person says, against what the editor calls it. A request to
# 'close the messages buffer' never reached kill-buffer, because the
# word is kill and nobody says kill. This is the only place the two
# vocabularies meet; the vectors were supposed to and did not.
SAME = (('close', 'kill', 'quit', 'dismiss', 'hide'),
        ('open', 'visit', 'find', 'show', 'display'),
        ('delete', 'remove', 'kill', 'drop'),
        ('search', 'grep', 'ripgrep', 'look'),
        ('save', 'write', 'store'),
        ('split', 'divide', 'pane'),
        ('window', 'pane'),
        ('buffer', 'file', 'document'),
        ('undo', 'revert', 'back'),
        ('run', 'execute', 'call', 'eval'),
        ('rename', 'name'),
        ('list', 'show', 'browse'))

SYNONYM = {}
for _group in SAME:
    for _word in _group:
        SYNONYM.setdefault(_word, set()).update(_group)


def spoken_as(word):
    return SYNONYM.get(word, frozenset((word,))) | {word}


# What a row is embedded as. The whole catalog entry embeds badly: its
# shape and its longest docstrings drown the name. name: doc ranks.
def text_of(row):
    return row['name'] + ': ' + (row.get('doc') or '')


# --- the model, the rows and their vectors ------------------------------------

class World:
    def __init__(self):
        self.agent = None
        self.rows = []
        self.vectors = None
        self.generation = None
        self._row_words = None
        self._idf = None
        self._idf_for = None
        self._bound_for = None

    # No weights= argument: that spawns a worker process, and a worker
    # costs 54 ms to rebind a tool set. Bound in process it costs 13.
    def model(self):
        import needle
        if self.agent is None:
            self.agent = needle.Needle(tools=[], **weights_kw())
        return self.agent

    def embed(self, text):
        import numpy as np
        v = np.array(self.model().embed(text), dtype='float32')
        return v / (np.linalg.norm(v) + 1e-9)

    # Keyed by the names themselves, not by a generation counter. The
    # catalog's generation moves when a package reloads and its row set
    # does not, and its row set moves when a package loads and the
    # generation has not been read; either way a stale key costs a
    # 30 second re-embed on a start that should have cost nothing.
    def cache_path(self, names):
        import hashlib
        root = os.environ.get('NEEDLE_ROOT') or os.path.expanduser('~/.cache/compos/needle')
        key = hashlib.sha1('\n'.join(names).encode('utf-8')).hexdigest()[:16]
        return os.path.join(root, 'catalog-%s.npz' % key)

    # No embedding and no cache: the words are read straight off the
    # rows, which is why an index is now instant instead of 24 seconds.
    def index(self, rows, generation):
        self.rows, self.generation = rows, generation
        self._row_words = None
        self._idf = None
        self.row_words()
        self.idf()
        log('needle-daemon: read %d rows' % len(rows))
        return len(rows)

    def index_vectors(self, rows, generation):
        import numpy as np
        names = [r['name'] for r in rows]
        path = self.cache_path(names)
        model = self.model()
        vectors = np.array([model.embed(text_of(r)) for r in rows], dtype='float32')
        # the row's words are read once here, never once a query
        vectors /= np.linalg.norm(vectors, axis=1, keepdims=True) + 1e-9
        os.makedirs(os.path.dirname(path), exist_ok=True)
        np.savez(path, names=np.array(names, dtype=object), vectors=vectors)
        self.rows, self.vectors, self.generation = rows, vectors, generation
        return len(rows)

    # Needle reads at most five tools well: past that its own retrieval
    # picks five and the rest are unreachable. So five come from here.
    #
    # Vectors alone do not rank this catalog: cosine over these rows sits
    # in a narrow band, and 'close the messages buffer' reached five chat
    # tools and never reached kill-buffer. The words carry what the band
    # cannot, so a row a word of the request names outranks one only the
    # vector liked, and the vector orders what the words did not reach.
    # Measured, not assumed. Over 46 labelled requests the vectors put
    # the right row in the top five 10 times; these words put it there
    # 29 times, and adding the vectors back to the words dropped it to
    # 25. So the vectors are not consulted, and the catalog is not
    # embedded: a route reads words the daemon already holds.
    def candidates(self, query, k):
        want = words_of(query)
        base = self.lexical(want)
        held = self.row_words()
        # An action needs an object. 'close the messages buffer' reached
        # a changeset tool that shares only the verb, and beat the
        # buffer tool that shares the noun. A row that matches nothing
        # the request is ABOUT is answering a different question.
        nouns = frozenset(w for w in want if w not in SYNONYM)
        forms = frozenset().union(*[spoken_as(w) for w in nouns]) if nouns else frozenset()
        scored = sorted(((base[i]
                          + ACTS * self.rows[i].get('acts', 0)
                          + (NOUN if forms and (forms & held[i]) else 0.0), i)
                         for i in range(len(self.rows))), key=lambda t: -t[0])
        return [(self.rows[i], score) for score, i in scored[:k]]

    # Read once and kept: splitting 3000 docstrings on every question
    # cost 200 ms of a 180 ms answer.
    def row_words(self):
        if self._row_words is None or len(self._row_words) != len(self.rows):
            self._row_words = [words_of(r['name'] + ' ' + (r.get('doc') or ''))
                               for r in self.rows]
        return self._row_words

    # A word worth more the fewer rows hold it. 'buffer' is in hundreds
    # of docstrings and says almost nothing; 'messages' is in a handful
    # and says which buffer. Counting them the same is what let
    # view-messages outrank kill-buffer.
    def idf(self):
        import math
        if self._idf is None or self._idf_for != len(self.rows):
            seen = {}
            for words in self.row_words():
                for w in words:
                    seen[w] = seen.get(w, 0) + 1
            total = len(self.rows) or 1
            self._idf = {w: math.log(total / (1 + n)) for w, n in seen.items()}
            self._idf_for = len(self.rows)
        return self._idf

    # A query word is matched by any word that means the same. The
    # weight stays the asked-for word's, so a synonym never counts more
    # than the word the person used.
    def lexical(self, want):
        idf = self.idf()
        held = self.row_words()
        floor = math.log(len(self.rows) or 1)
        mass = sum(idf.get(w, floor) for w in want) or 1.0
        pairs = [(idf.get(w, floor), spoken_as(w)) for w in want]
        return [sum(weight for weight, forms in pairs if forms & held[i]) / mass
                for i in range(len(self.rows))]

    # One engine answers both shapes, so the weights are held once.
    # Binding is the whole cost of an answer, and the same tool comes
    # back again and again once retrieval and not the model picks it.
    # So a bound set is kept under the names it was bound for.
    def bound(self, tools):
        import needle
        key = tuple((t['name'], t['description']) for t in tools)
        if key != self._bound_for:
            self.agent = needle.Needle(tools=tools, **weights_kw())
            self._bound_for = key
        return self.agent

    def ask(self, tools, query):
        import time
        t0 = time.time()
        agent = self.bound(tools)
        t1 = time.time()
        agent.reset()
        reply = agent.complete(query)
        reply['bind_ms'] = round((t1 - t0) * 1000, 1)
        reply['complete_ms'] = round((time.time() - t1) * 1000, 1)
        return reply

    # Recall is the whole question for a retrieval step: the model can
    # only answer with what reached it. Scored here, over the vectors
    # already held, so a sweep costs no round trips.
    def bench(self, cases, k, req_weights=None):
        import numpy as np
        held = self.row_words()
        names = [r['name'] for r in self.rows]
        out = {'n': len(cases)}
        modes = req_weights or ['plain', 'idf', 'idf+0.04', 'idf+0.08', 'idf+0.2', 'idf+0.5']
        for mode in modes:
            top1 = ink = 0
            for case in cases:
                query, gold = case['query'], case['gold']
                if gold not in names:
                    continue
                want = words_of(query)
                n = len(want) or 1
                if mode == 'plain':
                    base = [len(want & held[i]) / n for i in range(len(self.rows))]
                    acts = 0.0
                else:
                    base = self.lexical(want)
                    acts = 0.0 if mode == 'idf' else float(mode.split('+')[1])
                scored = sorted(((base[i] + acts * self.rows[i].get('acts', 0), i)
                                 for i in range(len(self.rows))), key=lambda t: -t[0])
                ranked = [names[i] for _, i in scored[:k]]
                top1 += ranked[0] == gold
                ink += gold in ranked
            out[mode] = {'top1': top1, 'in_k': ink}
        out['ok'] = True
        return out

    def route(self, query, k):
        import time
        t0 = time.time()
        picked = self.candidates(query, k)
        taken = {}
        tools = []
        want = words_of(query)
        for row, _ in picked:
            schema = schema_of(row)
            schema['name'] = spoken_name(row, taken, want)
            tools.append(schema)
        t1 = time.time()
        reply = self.ask(tools, query)
        t2 = time.time()
        for call in (reply.get('function_calls') or []) + (reply.get('suppressed_calls') or []):
            call['spoken'] = call.get('name')
            call['name'] = taken.get(call.get('name'), call.get('name'))
        return {
            'pick_ms': round((t1 - t0) * 1000, 1),
            'answer_ms': round((t2 - t1) * 1000, 1),
            'bind_ms': reply.get('bind_ms'),
            'complete_ms': reply.get('complete_ms'),
            'offered': [{'as': t['name'], 'says': t['description']} for t in tools],
            'calls': reply.get('function_calls') or [],
            'held': reply.get('suppressed_calls') or [],
            'reasoning': reply.get('reasoning') or '',
            'confidence': reply.get('confidence'),
            'candidates': [{'name': row['name'], 'score': score} for row, score in picked],
        }


# --- one line in, one line out ------------------------------------------------

WORLD = World()


def handle(req):
    op = req.get('op')
    if op == 'ping':
        return {'ok': True, 'pong': True}
    if op == 'index':
        rows = req.get('rows') or []
        n = WORLD.index(rows, str(req.get('generation') or 'x'))
        return {'ok': True, 'rows': n}
    if op == 'ask':
        reply = WORLD.ask(req.get('tools') or [], req.get('query') or '')
        return {'ok': True,
                'calls': reply.get('function_calls') or [],
                'held': reply.get('suppressed_calls') or [],
                'reasoning': reply.get('reasoning') or '',
                'confidence': reply.get('confidence')}
    if op == 'bench':
        if not WORLD.rows:
            return {'ok': False, 'error': 'no catalog: send index first'}
        return WORLD.bench(req.get('cases') or [], int(req.get('k') or 5),
                           req.get('weights'))
    if op == 'routebench':
        if not WORLD.rows:
            return {'ok': False, 'error': 'no catalog: send index first'}
        import time
        k = int(req.get('k') or 5)
        hit = retrieved = 0
        misses, spent, right, wrong = [], [], [], []
        for case in (req.get('cases') or []):
            t0 = time.time()
            out = WORLD.route(case['query'], k)
            spent.append((time.time() - t0) * 1000)
            names = [c.get('name') for c in out['calls']]
            cands = [c['name'] for c in out['candidates']]
            retrieved += case['gold'] in cands
            conf = out.get('confidence')
            if case['gold'] in names:
                hit += 1
                right.append(conf)
            else:
                wrong.append(conf)
                misses.append({'query': case['query'], 'gold': case['gold'],
                               'chose': names, 'conf': conf, 'had': case['gold'] in cands})
        spent.sort()
        return {'ok': True, 'n': len(req.get('cases') or []), 'routed': hit,
                'retrieved': retrieved,
                'median_ms': round(spent[len(spent) // 2], 1) if spent else 0,
                'right_conf': summarise(right), 'wrong_conf': summarise(wrong),
                'wrong_above_7': sum(1 for c in wrong if (c or 0) >= 0.7),
                'right_above_7': sum(1 for c in right if (c or 0) >= 0.7),
                'misses': misses[:8]}
    if op == 'picks':
        if not WORLD.rows:
            return {'ok': False, 'error': 'no catalog: send index first'}
        k = int(req.get('k') or 5)
        out = []
        for query in (req.get('queries') or []):
            out.append({'query': query,
                        'rows': [{'name': row['name'], 'says': description_of(row)}
                                 for row, _ in WORLD.candidates(query, k)]})
        return {'ok': True, 'picks': out}
    if op == 'route':
        if not WORLD.rows:
            return {'ok': False, 'error': 'no catalog: send index first'}
        out = WORLD.route(req.get('query') or '', int(req.get('k') or 5))
        out['ok'] = True
        return out
    return {'ok': False, 'error': 'unknown op: %s' % op}


def main():
    open_log()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            reply = handle(json.loads(line))
        except Exception as e:  # one bad request must not cost the weights
            log('needle-daemon: %r' % (e,))
            reply = {'ok': False, 'error': '%s: %s' % (type(e).__name__, e)}
        sys.stdout.write(json.dumps(reply) + '\n')
        sys.stdout.flush()


if __name__ == '__main__':
    main()

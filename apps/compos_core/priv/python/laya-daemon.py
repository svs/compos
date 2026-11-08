#!/usr/bin/env python3
"""laya-daemon --- the laya decision model, held in memory, one JSON line a request.

scheme/packages/laya.scm starts this as an endpoint and keeps it open, so a
decision pays the model load once instead of once a question. stdin carries
one request object a line; stdout carries one reply object a line, and
nothing else: the model's own output goes to the log.

  {'op': 'ping'}                      -> {'ok': true, 'pong': true}
  {'op': 'models'}                    -> {'ok': true, 'models': [ ... ]}
  {'op': 'load', 'model': NAME}       -> {'ok': true, 'model': NAME}
  {'op': 'unload', 'model': NAME}     -> {'ok': true, 'model': NAME}
  {'op': 'predict', 'state': S, 'questions': Q, 'model': NAME}
                                      -> {'ok': true, 'result': { ... }}

A failure answers {'ok': false, 'error': TEXT} and the daemon stays up: one
bad request must not cost the loaded weights.

The models are the laya-mlx checkpoints this machine already holds. The
huggingface cache and LAYA_MODEL_DIRS are that registry, and this daemon
keeps no list of its own. Without laya-mlx (Linux, Intel Macs), the laya
package from PyPI serves instead: it runs on PyTorch and loads its model by
Hub name, HUB_MODEL unless LAYA_MODEL names another.
"""

import json
import os
import sys
from pathlib import Path

# the files every laya checkpoint holds; a directory without them is
# some other model, and this daemon cannot run it
MARKERS = ('rl_agent_config.json', 'model.safetensors')

# the model the PyTorch laya loads when this machine holds no checkpoint
HUB_MODEL = 'convaiinnovations/laya'


def has_mlx():
    import importlib.util
    return importlib.util.find_spec('laya_mlx') is not None


# The log file stays open for the life of the daemon. Opening it inside
# the redirect and letting it fall out of scope closes the descriptor the
# moment nothing holds it, which is how this log stayed empty.
LOG = None


def open_log():
    global LOG
    where = os.environ.get('LAYA_DAEMON_LOG')
    if not where:
        return
    try:
        LOG = open(where, 'a', buffering=1)
    except OSError:
        return
    try:  # whatever the model itself prints goes to the log as well
        os.dup2(LOG.fileno(), 2)
    except OSError:
        pass


def log(text):
    where = LOG if LOG is not None else sys.stderr
    if where is not None:
        print(text, file=where, flush=True)


def roots():
    """Every directory that may hold a checkpoint: the hub cache, then ours."""
    out = []
    hub = os.environ.get('HF_HUB_CACHE')
    if not hub:
        hub = os.path.join(os.environ.get('HF_HOME') or '~/.cache/huggingface', 'hub')
    out.append(Path(hub).expanduser())
    for extra in (os.environ.get('LAYA_MODEL_DIRS') or '').split(':'):
        if extra.strip():
            out.append(Path(extra.strip()).expanduser())
    return out


def checkpoint_dir(path):
    """The directory under PATH that holds a checkpoint, or None.

    A hub entry keeps its files one snapshot deeper; a plain directory
    holds them itself.
    """
    if all((path / name).is_file() for name in MARKERS):
        return path
    snapshots = path / 'snapshots'
    if snapshots.is_dir():
        for snap in sorted(snapshots.iterdir()):
            if all((snap / name).is_file() for name in MARKERS):
                return snap
    return None


def repo_name(path):
    """'models--aac6fef--laya-mlx' is the cache's spelling of 'aac6fef/laya-mlx'."""
    base = path.name
    if base.startswith('models--'):
        return base[len('models--'):].replace('--', '/')
    return base


def directory_bytes(path):
    """What a checkpoint costs on disk, following the cache's symlinks."""
    total = 0
    for f in path.rglob('*'):
        try:
            if f.is_file():
                total += f.stat().st_size
        except OSError:
            pass
    return total


def discover():
    """Every checkpoint this machine holds, as name -> directory."""
    found = {}
    for root in roots():
        if not root.is_dir():
            continue
        for entry in sorted(root.iterdir()):
            if not entry.is_dir():
                continue
            where = checkpoint_dir(entry)
            if where is not None:
                found[repo_name(entry)] = where
    return found


class Daemon:
    """The checkpoints on disk, and the ones built in this process."""

    def __init__(self):
        self.agents = {}
        self.paths = discover()

    def models(self):
        self.paths = discover()
        names = sorted(set(list(self.paths) + list(self.agents)))
        return [
            {
                'name': name,
                'loaded': name in self.agents,
                'size': directory_bytes(self.paths[name]) if name in self.paths else 0,
                'path': str(self.paths.get(name, '')),
            }
            for name in names
        ]

    def load(self, name):
        if name in self.agents:
            return self.agents[name]
        where = self.paths.get(name)
        if has_mlx() and where is not None:
            import laya_mlx
            agent = laya_mlx.load(str(where), dtype=os.environ.get('LAYA_DTYPE', 'float16'))
        elif has_mlx():
            raise FileNotFoundError('no checkpoint named %s on this machine' % name)
        else:
            # PyTorch laya: a Hub name, downloaded once into the hub cache
            import laya
            agent = laya.load(name)
        self.agents[name] = agent
        log('laya-daemon: loaded %s' % name)
        return agent

    def unload(self, name=None):
        if name is None:
            self.agents.clear()
        else:
            self.agents.pop(name, None)

    def default_name(self):
        """What a request that names no model means: a loaded one, then the first."""
        for name in self.agents:
            return name
        want = os.environ.get('LAYA_MODEL')
        if want:
            return want
        if has_mlx():
            for name in sorted(self.paths):
                return name
            return None
        return HUB_MODEL


def handle(daemon, req):
    op = req.get('op')
    if op == 'ping':
        return {'ok': True, 'pong': True}
    if op == 'models':
        return {'ok': True, 'models': daemon.models()}
    if op == 'unload':
        name = req.get('model')
        daemon.unload(name)
        return {'ok': True, 'model': name or 'all'}
    if op in ('load', 'predict'):
        name = req.get('model') or daemon.default_name()
        if not name:
            return {'ok': False, 'error': 'no laya checkpoint on this machine'}
        agent = daemon.load(name)
        if op == 'load':
            return {'ok': True, 'model': name}
        result = agent.predict(req.get('state'), req.get('questions') or {})
        return {'ok': True, 'model': name, 'result': result}
    return {'ok': False, 'error': 'unknown op: %s' % op}


def main():
    open_log()
    # the frame stream is replies alone: whatever the model prints goes to
    # the log, or the editor reads a progress bar as an answer
    out = sys.stdout
    sys.stdout = LOG if LOG is not None else sys.stderr
    daemon = Daemon()
    log('laya-daemon: %d checkpoint(s) on this machine' % len(daemon.paths))
    while True:
        line = sys.stdin.readline()
        if not line:
            return
        line = line.strip()
        if not line:
            continue
        try:
            reply = handle(daemon, json.loads(line))
        except Exception as trouble:  # one bad request cannot cost the weights
            log('laya-daemon: %s' % trouble)
            reply = {'ok': False, 'error': '%s: %s' % (type(trouble).__name__, trouble)}
        out.write(json.dumps(reply, ensure_ascii=False) + '\n')
        out.flush()


if __name__ == '__main__':
    main()

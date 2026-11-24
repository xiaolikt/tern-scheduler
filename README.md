# tern-scheduler

Timed prompts delivered to fixed omp agent blocks, as a [Tern](https://tern.so)
plugin. Each task in `tasks.json` has a prompt and an interval; when it is due,
the prompt is sent to that task's block — opened on first use, then reused.

Author: He lijun

## Install

```bash
tern plugin install github.com/hljhljhlj/tern-scheduler
# or, while developing:
tern plugin link ~/Project/tern-scheduler
tern plugin list --json     # status: ready, no problems
```

Reload after edits: `tern plugin reload scheduler`.

Real prompts and `tasks.json` are yours alone: both are gitignored, and the
repository ships `tasks.example.json` plus `prompts/example.md` as templates.
Copy them to `tasks.json` and your own prompt files to get started.

## Tasks

`tasks.json` holds one entry per task:

```json
[
  {
    "id": "pityplan",
    "title": "pityplan patrol",
    "every": "6h",
    "prompt": "prompts/pityplan.md",
    "cwd": "~/Project"
  }
]
```

- `id` — unique in the file: entries that share an id are skipped with a toast.
- `every` — `30s`, `10m`, `6h`, `1d`.
- `at` — optional `"09:00"` with `every: "1d"`: the slot lands at that local
  time each day instead of 24 hours after the previous run.
- `prompt` — the file delivered into the block (relative to the plugin).
- `cwd` — working directory used when a block has to be opened; a leading `~`
  works.
- `place` — optional `{ "session": "name", "tab": "name" }`: when a block has to
  be opened, it is moved into that session (created if missing) and that tab
  (created and named if missing), instead of a new tab in whatever session
  happens to be current. Either key may be omitted; a fresh session's birth
  shell tab is closed once the block is in place.

## Commands

| Command | Effect |
| --- | --- |
| `Scheduler: tasks` | List every task with its next run and last outcome; Enter runs one now |
| `Scheduler: pin this block` | Give the focused agent block to a task |
| `Scheduler: status` | Toast the task count and the nearest run |

`Scheduler: tasks` is the way to see what is scheduled at any moment.

## Behaviour

- **Schedule** — a new task is due at once; after that it keeps `next` in the
  plugin's `kv.json`, so reloads and Tern restarts do not lose the slot: a slot
  that came due while Tern was down runs on the next tick, and the following
  slot is armed from now. With `every: "1d"` and `at`, slots land at that local
  time each day. Changing `every` or `at` re-arms the next slot; state written
  before a task had an interval keeps its armed slot. Intervals below
  30 seconds, a bad `at`, ids that appear more than once and entries without a
  string id are rejected with a toast, and an unreadable `tasks.json` is
  reported instead of silently running nothing.
- **At-most-once delivery** — a due slot is claimed in `kv.json` *before*
  anything is sent: the claim is saved, re-read, and only the window whose
  token survived delivers. A crash can lose a run, never duplicate one, and
  two windows cannot double-deliver the same slot.
- **Target block** — each task's block is kept in the plugin's `pins`
  document, apart from its schedule, so a run never reverts a pin made while it
  was sending. Resolved by, in order: the pinned pane id (checked against a
  conversation fingerprint — the first message plus a message count, which only
  grows — so a block that switched to another conversation is reopened instead
  of prompted), a pane inside `place.session`/`place.tab` when configured, else
  — with no `place` — a pane matching the task id or title at the task's own
  `cwd` (`~` included). A block whose agent exited is not reused. Failing all
  that, a new agent block is opened with the prompt and moved to `place`; if
  the move fails the run records the reason and toasts instead of reporting a
  clean `opened`.
- **Delivery** — `cx.agents:ask(pane, prompt)`. Native omp receives one atomic
  TSP send; the prompt queues until the block can take it. A pinned block still
  working or waiting for input is left alone: the slot is recorded as `skipped`
  and looked at again within five minutes, so prompts do not pile up.
- **One owner** — a single window holds the schedule through a heartbeat
  refreshed every minute; another window takes over once it is three minutes
  stale, and the claim below keeps a handover from double-delivering. A failed
  tick (a transient store error, say) is logged and the schedule keeps ticking.
- **History** — the last ten runs per task (`opened`, `sent`, `manual`,
  `skipped`, `failed`) live in `kv.json`; `Scheduler: tasks` shows the last
  outcome and its reason. A prompt file that cannot be read fails its run, with
  the reason recorded and toasted, instead of quietly skipping it.
- **Housekeeping** — a task removed from `tasks.json` loses its schedule and
  its pin on the next tick.

The window half schedules because Tern's durable-task `check` runs in Carly's
VM, where `tern.plugin.dir` and `tern.kv` resolve to Carly's directory.

## Tests

`test/run.sh` runs `window.luau` unchanged against stubs that stand in for
Tern and checks what must not regress: a new task runs at once, a daily `at`
lands at its local time, a run that cannot read its prompt is recorded as
failed, a busy block is not prompted, a pin made during a run survives it, the
commands report a `tasks.json` they cannot read, entries that share an id never
run, and a block is found by its task's title at a `cwd` that starts with `~`.
It needs the [Luau CLI](https://github.com/luau-lang/luau/releases) as `luau` on
`PATH` or at `$LUAU`:

```bash
test/run.sh
```

## Test mode

`touch test-once` next to the manifest switches every interval to one minute
and reads `<prompt>.test.md` instead of the real prompt:

```bash
tern plugin reload scheduler
```

Remove `test-once` and reload to restore the configured intervals.

## License

MIT — see [LICENSE](LICENSE).

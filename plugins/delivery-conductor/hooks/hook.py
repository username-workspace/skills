#!/usr/bin/env python3
"""Hook plumbing: hand the payload to conductor.py for the event named on the command line. All policy
lives in conductor.py."""
import os, subprocess, sys


def main():
    event = sys.argv[1] if len(sys.argv) > 1 else ""
    root = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    script = os.path.join(root, "skills", "delivery-conductor", "scripts", "conductor.py")
    try:
        r = subprocess.run([sys.executable, script, "hook", "--event", event], input=sys.stdin.read(),
                           capture_output=True, text=True, timeout=290)
        if r.stdout.strip():
            sys.stdout.write(r.stdout)
        if r.stderr.strip():
            log = os.path.join(os.environ.get("HARNESS_LIVE_DIR") or os.path.expanduser("~/.claude/harness-live"),
                               "delivery-conductor-hook.err")
            os.makedirs(os.path.dirname(log), exist_ok=True)
            with open(log, "a") as f:
                f.write(f"--- {event}\n{r.stderr[-4000:]}\n")
    except Exception:
        pass


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
# Unit coverage for review.py: context (local/remote + forge detection), session engagement,
# the pre-push gate (deny once / allow after record), iterative state, and the fake-green verify.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RV="$HERE/../scripts/review.py"
PY="$(command -v python3)"
ROOT="$(mktemp -d)"; PASS=0; FAIL=0
. "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)/tests/lib.sh"
export HARNESS_AUTO_ENGAGE=1   # this suite pins the AUTO lanes; the explicit default is pinned in its own block

# hermetic PATH for `context` (so which(gh/glab) is false → no network)
mkdir -p "$ROOT/realbin"
for b in git bash; do ln -sf "$(command -v $b)" "$ROOT/realbin/$b"; done

mkrepo(){ d="$1"; mkdir -p "$d"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  echo init > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm init
  git init -q --bare "$d.git"; git -C "$d" remote add origin "$d.git"
  git -C "$d" push -q -u origin main 2>/dev/null; }
work(){ echo "change $RANDOM" >> "$1/app.txt"; git -C "$1" add -A; git -C "$1" commit -qm "feat: work"; }

echo "merge-review · review.py"

# --- 1. context: local --------------------------------------------------------------------------
d="$ROOT/ctx"; mkrepo "$d"; git -C "$d" checkout -q -b feat; work "$d"
ctx=$(env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$d")
case "$ctx" in *'"mode": "local"'*) ok "context local: mode=local";; *) ko "context local mode [$ctx]";; esac
case "$ctx" in *'"base": "main"'*) ok "context: base detected (main)";; *) ko "context base";; esac
case "$ctx" in *'git diff origin/main...HEAD'*) ok "context: diff_cmd against the fetched merge target";; *) ko "context diff_cmd";; esac
case "$ctx" in *'"threshold": 80'*) ok "context: default threshold 80";; *) ko "context threshold";; esac
case "$ctx" in *'feat: work'*) ok "context: commits listed";; *) ko "context commits";; esac

# --- 1c. forge context: what reviewers left open reaches the review — every page, inline threads too
mkdir -p "$ROOT/forgebin"
cat > "$ROOT/forgebin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") echo '{"number":5,"title":"T","body":"B","comments":[],"reviews":[]}';;
  "api graphql") echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"author":{"login":"rev"},"body":"RESOLVED-THREAD","path":"a.py"}]}},
    {"isResolved":false,"comments":{"nodes":[{"author":{"login":"rev"},"body":"OPEN-THREAD","path":"app.txt"}]}}]}}}}}';;
esac
EOF
cat > "$ROOT/forgebin/glab" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "mr list") echo '[{"iid":4,"title":"T","description":"D"}]';;
  api*) case " $* " in
          *" --paginate "*) printf '%s' '[{"notes":[{"body":"PAGE-1-NOTE","author":{"username":"a"}}]}][{"notes":[{"body":"PAGE-2-NOTE","author":{"username":"b"}}]}]';;
          *) echo '[{"notes":[{"body":"PAGE-1-NOTE","author":{"username":"a"}}]}]';;
        esac;;
esac
EOF
chmod +x "$ROOT/forgebin/gh" "$ROOT/forgebin/glab"
dh="$ROOT/ctxgh"; mkrepo "$dh"; git -C "$dh" checkout -q -b feat; work "$dh"; git -C "$dh" remote set-url origin https://github.com/t/r.git
ctx=$(env PATH="$ROOT/forgebin:$ROOT/realbin" "$PY" "$RV" context --repo "$dh")
assert_contains "OPEN-THREAD" "$ctx" "context github: an unresolved inline review thread reaches the review"
assert_absent "RESOLVED-THREAD" "$ctx" "context github: resolved threads stay out"
dl="$ROOT/ctxgl"; mkrepo "$dl"; git -C "$dl" checkout -q -b feat; work "$dl"; git -C "$dl" remote set-url origin https://gitlab.com/t/r.git
ctx=$(env PATH="$ROOT/forgebin:$ROOT/realbin" "$PY" "$RV" context --repo "$dl")
assert_contains "PAGE-2-NOTE" "$ctx" "context gitlab: discussions beyond the first page reach the review"

# --- 1b. context --packet: self-contained payload for a fresh-context subagent review ------------
out=$(env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$d" --packet)
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["diff"] and d["commits"] and "threshold" in d and "rubric" in d and d["truncated"] is False' \
  && ok "packet: self-contained (diff text + commits + threshold + rubric pointer)" || ko "packet: self-contained (diff text + commits + threshold + rubric pointer)"
echo "$out" | python3 -c 'import json,sys,os; d=json.load(sys.stdin); assert os.path.isfile(d["rubric"]) and "app.txt" in d["diff"]' \
  && ok "packet: rubric path exists, diff text is the branch diff" || ko "packet: rubric path exists, diff text is the branch diff"
case "$out" in *untrusted*) ok "packet: carries the asymmetric trust note";; *) ko "packet: carries the asymmetric trust note";; esac
# an oversized diff is capped honestly, never silently
big="$ROOT/big"; mkrepo "$big"; git -C "$big" checkout -q -b feat
python3 -c "open('$big/blob.txt','w').write('x'*500000)"; git -C "$big" add -A; git -C "$big" commit -qm big
env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$big" --packet \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["truncated"] is True and len(d["diff"]) <= 400000' \
  && ok "packet: oversized diff capped with truncated:true" || ko "packet: oversized diff capped with truncated:true"

# --- 2. context: remote (read-only) -------------------------------------------------------------
ctx=$(env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$d" --mode remote)
case "$ctx" in *'"mode": "remote"'*) ok "context remote: mode=remote";; *) ko "context remote mode";; esac
case "$ctx" in *'"read_only": true'*) ok "context remote: read_only";; *) ko "context remote read_only";; esac
case "$ctx" in *'do NOT mutate git state'*) ok "context remote: no-mutation note";; *) ko "context remote note";; esac

# --- 3. forge detection -------------------------------------------------------------------------
dg="$ROOT/gh"; mkrepo "$dg"; git -C "$dg" checkout -q -b feat
git -C "$dg" remote set-url origin https://github.com/acme/app.git
case "$(env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$dg")" in *'"forge": "github"'*) ok "forge: github from url";; *) ko "forge github";; esac
dl="$ROOT/gl"; mkrepo "$dl"; git -C "$dl" checkout -q -b feat
git -C "$dl" remote set-url origin https://gitlab.com/acme/app.git
case "$(env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$dl")" in *'"forge": "gitlab"'*) ok "forge: gitlab from url";; *) ko "forge gitlab";; esac

# --- 4. engagement (baseline / engaged) ---------------------------------------------------------
d="$ROOT/eng"; mkrepo "$d"; git -C "$d" checkout -q -b feat
"$PY" "$RV" baseline --repo "$d" --session s1
[ "$("$PY" "$RV" engaged --repo "$d" --session s1)" = no ] && ok "engaged: clean after baseline → no" || ko "engaged clean→no"
work "$d"
[ "$("$PY" "$RV" engaged --repo "$d" --session s1)" = yes ] && ok "engaged: after this session's work → yes" || ko "engaged work→yes"
[ "$("$PY" "$RV" engaged --repo "$d" --session other)" = no ] && ok "engaged: different session → no" || ko "engaged other-session→no"
printf '{"enabled":false}' > "$d/.git/merge-review.json"
[ "$("$PY" "$RV" engaged --repo "$d" --session s1)" = no ] && ok "engaged: enabled:false → no" || ko "engaged disabled→no"
rm -f "$d/.git/merge-review.json"
# default branch is never engaged
db="$ROOT/eng-main"; mkrepo "$db"
"$PY" "$RV" baseline --repo "$db" --session s1; echo x >> "$db/app.txt"; git -C "$db" add -A; git -C "$db" commit -qm x
[ "$("$PY" "$RV" engaged --repo "$db" --session s1)" = no ] && ok "engaged: on default branch → no" || ko "engaged default→no"
# two concurrent sessions: the second baseliner must not erase the first session's engagement
d2="$ROOT/eng2"; mkrepo "$d2"; git -C "$d2" checkout -q -b feat
"$PY" "$RV" baseline --repo "$d2" --session SA
work "$d2"
"$PY" "$RV" baseline --repo "$d2" --session SB
[ "$("$PY" "$RV" engaged --repo "$d2" --session SA)" = yes ] && ok "engaged: SA still engaged after SB baselined" || ko "engaged: SA still engaged after SB baselined"
[ "$("$PY" "$RV" engaged --repo "$d2" --session SB)" = no ] && ok "engaged: SB (baselined on SA's work) → no" || ko "engaged: SB (baselined on SA's work) → no"
# the legacy single-session migration window (one minor) is CLOSED: a pre-v1 file is ignored
printf '{"session":"OLD","started":"2026-06-11T00:00:00+00:00","branches":{"feat":{"engaged":true}}}' > "$d2/.git/merge-review-session.json"
[ "$("$PY" "$RV" engaged --repo "$d2" --session OLD)" = no ] && ok "engaged: legacy pre-v1 file → ignored (migration window closed)" || ko "engaged: legacy pre-v1 file → ignored (migration window closed)"
"$PY" "$RV" baseline --repo "$d2" --session NEW
case "$(cat "$d2/.git/merge-review-session.json")" in *'"v": 1'*) ok "engaged: next baseline rewrites the file as v1";; *) ko "engaged: next baseline rewrites the file as v1";; esac

# --- 5. pre-push gate ---------------------------------------------------------------------------
g="$ROOT/gate"; mkrepo "$g"; git -C "$g" checkout -q -b feat
"$PY" "$RV" baseline --repo "$g" --session s1; work "$g"            # → engaged
out=$("$PY" "$RV" gate --repo "$g" --session s1)
case "$out" in *'"permissionDecision": "deny"'*) ok "gate: engaged + unreviewed → deny";; *) ko "gate deny [$out]";; esac
case "$out" in *record*) ok "gate reason: points at record";; *) ko "gate reason record";; esac
case "$out" in *80*) ok "gate reason: states the threshold";; *) ko "gate reason threshold";; esac
[ -z "$("$PY" "$RV" gate --repo "$g" --session s1)" ] && ok "gate: same head twice → advisory, allows" || ko "gate dedup"
"$PY" "$RV" record --repo "$g" --session s1 --score 85 --passed >/dev/null
[ -z "$("$PY" "$RV" gate --repo "$g" --session s1)" ] && ok "gate: after passing record → allow" || ko "gate post-record allow"
# not engaged → silent
ng="$ROOT/gate-ne"; mkrepo "$ng"; git -C "$ng" checkout -q -b feat; "$PY" "$RV" baseline --repo "$ng" --session s1
[ -z "$("$PY" "$RV" gate --repo "$ng" --session s1)" ] && ok "gate: not engaged → allow (silent)" || ko "gate not-engaged"
# gate disabled via config
gd="$ROOT/gate-off"; mkrepo "$gd"; git -C "$gd" checkout -q -b feat
"$PY" "$RV" baseline --repo "$gd" --session s1; work "$gd"; printf '{"prepush_gate":false}' > "$gd/.git/merge-review.json"
[ -z "$("$PY" "$RV" gate --repo "$gd" --session s1)" ] && ok "gate: prepush_gate:false → allow" || ko "gate disabled"

# --- 6. record / prior + threshold --------------------------------------------------------------
r="$ROOT/rec"; mkrepo "$r"; git -C "$r" checkout -q -b feat; work "$r"
"$PY" "$RV" record --repo "$r" --session s1 --score 45 >/dev/null
pr=$("$PY" "$RV" prior --repo "$r")
case "$pr" in *'"pass": 1'*) ok "record: pass counter starts at 1";; *) ko "record pass1 [$pr]";; esac
case "$pr" in *'"passed": false'*) ok "record: score 45 < 80 → not passed";; *) ko "record not-passed";; esac
"$PY" "$RV" record --repo "$r" --session s1 --score 100 --passed >/dev/null
pr=$("$PY" "$RV" prior --repo "$r")
case "$pr" in *'"pass": 2'*) ok "record: pass counter increments";; *) ko "record pass2";; esac
case "$pr" in *'"passed": true'*) ok "record: passing pass recorded";; *) ko "record passed";; esac
# configurable threshold
t="$ROOT/thr"; mkrepo "$t"; git -C "$t" checkout -q -b feat; work "$t"; printf '{"threshold":90}' > "$t/.git/merge-review.json"
"$PY" "$RV" record --repo "$t" --session s1 --score 85 >/dev/null
case "$("$PY" "$RV" prior --repo "$t")" in *'"passed": false'*) ok "threshold: 85 < custom 90 → not passed";; *) ko "custom threshold";; esac
case "$(env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$t")" in *'"threshold": 90'*) ok "context: custom threshold surfaced";; *) ko "context custom threshold";; esac

# --- 6c. incremental staleness: a PASSED ancestor head shrinks the obligation, never the gate ----
inc="$ROOT/inc"; mkrepo "$inc"; git -C "$inc" checkout -q -b feat
"$PY" "$RV" baseline --repo "$inc" --session s1
work "$inc"
reviewed_range(){ env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$1" | "$PY" -c 'import json,sys; c=json.load(sys.stdin); print("--sha", c["head_sha"], "--base", c["base_sha"])'; }
record_packet(){ "$PY" "$RV" record --repo "$1" --session s1 --score "$3" $2 >/dev/null; }
record_packet "$inc" "$(reviewed_range "$inc")" 90
h1=$(git -C "$inc" rev-parse HEAD)
echo more > "$inc/more.txt"; git -C "$inc" add -A; git -C "$inc" commit -qm more
case "$(env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$inc")" in
  *"\"diff_cmd\": \"git diff $h1..HEAD\""*) ok "incremental: ancestor pass → delta diff_cmd";; *) ko "incremental: ancestor pass → delta diff_cmd";; esac
out=$("$PY" "$RV" gate --repo "$inc" --session s1)
case "$out" in *'"permissionDecision": "deny"'*) ok "incremental: the gate still denies until a NEW record at HEAD";; *) ko "incremental: the gate still denies until a NEW record at HEAD";; esac
# the passed head amended away (not an ancestor) → full-diff obligation again
inc2="$ROOT/inc2"; mkrepo "$inc2"; git -C "$inc2" checkout -q -b feat; work "$inc2"
"$PY" "$RV" record --repo "$inc2" --session s1 --score 90 --passed >/dev/null
git -C "$inc2" commit -q --amend -m "amended away"
case "$(env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$inc2")" in
  *'"diff_cmd": "git diff origin/main...HEAD"'*) ok "incremental: non-ancestor pass → full diff again";; *) ko "incremental: non-ancestor pass → full diff again";; esac
packet_diff(){ env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$1" --packet | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["diff"])'; }
obligation_cmd(){ env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$1" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["diff_cmd"])'; }
approve(){ record_packet "$1" "$(reviewed_range "$1")" 90; }
legacy="$ROOT/inc-legacy"; mkrepo "$legacy"; git -C "$legacy" checkout -q -b feat; work "$legacy"
"$PY" "$RV" record --repo "$legacy" --session s1 --score 90 --passed >/dev/null; work "$legacy"
assert_eq "git diff origin/main...HEAD" "$(obligation_cmd "$legacy")" "incremental: a pass recorded without the base it reviewed never shrinks the review"
other="$ROOT/inc-other"; mkrepo "$other"; git -C "$other" checkout -q -b feat; work "$other"; approve "$other"
git -C "$other" checkout -q -b feat2; work "$other"
assert_eq "git diff origin/main...HEAD" "$(obligation_cmd "$other")" "incremental: a pass on another branch never shrinks this one's review"
for how in local fetched stale; do
  rw="$ROOT/inc-dropped-$how"; mkrepo "$rw"
  echo "SECRET=1" > "$rw/config.env"; git -C "$rw" add -A; git -C "$rw" commit -qm "main: oops"; git -C "$rw" push -q origin main 2>/dev/null
  git -C "$rw" checkout -q -b feat; work "$rw"; approve "$rw"
  git -C "$rw" checkout -q -b rewritten main~1; echo n > "$rw/n.txt"; git -C "$rw" add -A; git -C "$rw" commit -qm "main: next"
  git -C "$rw" push -q -f origin rewritten:main 2>/dev/null; git -C "$rw" fetch -q origin
  [ "$how" = local ] && git -C "$rw" branch -q -f main rewritten
  git -C "$rw" checkout -q feat
  if [ "$how" = stale ]; then git -C "$rw" rebase -q origin/main; else git -C "$rw" merge -q --no-edit origin/main; fi
  assert_contains "+SECRET=1" "$(packet_diff "$rw")" "incremental: a commit the base dropped after the approval is reviewed ($how)"
done
race="$ROOT/inc-race"; mkrepo "$race"
echo "SECRET=1" > "$race/config.env"; git -C "$race" add -A; git -C "$race" commit -qm "main: oops"; git -C "$race" push -q origin main 2>/dev/null
git -C "$race" checkout -q -b feat; work "$race"; seen=$(reviewed_range "$race")
git -C "$race" checkout -q -b rewritten main~1; echo n > "$race/n.txt"; git -C "$race" add -A; git -C "$race" commit -qm "main: next"
git -C "$race" push -q -f origin rewritten:main 2>/dev/null; git -C "$race" fetch -q origin; git -C "$race" checkout -q feat
env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$race" >/dev/null
record_packet "$race" "$seen" 90
git -C "$race" merge -q --no-edit origin/main
assert_contains "+SECRET=1" "$(packet_diff "$race")" "incremental: a base rewritten during the review never widens the approval"
rv="$ROOT/inc-revert"; mkrepo "$rv"; printf 'A=1\nSECRET=1\n' > "$rv/config.env"; git -C "$rv" add -A; git -C "$rv" commit -qm "main: oops"; git -C "$rv" push -q origin main 2>/dev/null
git -C "$rv" checkout -q -b feat; echo B=2 >> "$rv/config.env"; git -C "$rv" commit -qam "feat: B"; approve "$rv"
git -C "$rv" checkout -q main; git -C "$rv" revert --no-edit HEAD >/dev/null; git -C "$rv" push -q origin main 2>/dev/null; git -C "$rv" checkout -q feat
git -C "$rv" merge -q --no-edit origin/main >/dev/null 2>&1; git -C "$rv" checkout -q --ours config.env; git -C "$rv" add config.env; git -C "$rv" commit -q --no-edit
assert_contains "+SECRET=1" "$(packet_diff "$rv")" "incremental: a revert on the target that the branch keeps is reviewed"
late="$ROOT/inc-late"; mkrepo "$late"; git -C "$late" checkout -q -b feat; work "$late"; seen=$(reviewed_range "$late")
echo "SECRET=1" > "$late/late.env"; git -C "$late" add -A; git -C "$late" commit -qm "unreviewed"
record_packet "$late" "$seen" 90; work "$late"
assert_contains "+SECRET=1" "$(packet_diff "$late")" "incremental: a commit made after the packet was taken is never covered by its record"
refb="$ROOT/inc-refbase"; mkrepo "$refb"; git -C "$refb" checkout -q -b feat; work "$refb"
"$PY" "$RV" record --repo "$refb" --session s1 --score 90 --passed --sha "$(git -C "$refb" rev-parse HEAD)" --base origin/main >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" "record: a base that is not the packet's full sha is refused"
"$PY" "$RV" record --repo "$refb" --session s1 --score 90 --passed --base "$(git -C "$refb" rev-parse main)" >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" "record: a base without the packet's head is refused"
"$PY" "$RV" record --repo "$refb" --session s1 --score 90 --passed --sha "$(git -C "$refb" rev-parse main)" --base "$(git -C "$refb" rev-parse HEAD)" >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" "record: a base that is not an ancestor of the head is refused"
fx="$ROOT/inc-fix"; mkrepo "$fx"; git -C "$fx" checkout -q -b feat; work "$fx"
record_packet "$fx" "$(reviewed_range "$fx")" 40; work "$fx"
assert_eq "git diff origin/main...HEAD" "$(obligation_cmd "$fx")" "incremental: a failing pass approves nothing, so the next review is full"
cfx="$ROOT/inc-fix-revert"; mkrepo "$cfx"; printf 'A=1\nSECRET=1\n' > "$cfx/config.env"; git -C "$cfx" add -A; git -C "$cfx" commit -qm "main: oops"; git -C "$cfx" push -q origin main 2>/dev/null
git -C "$cfx" checkout -q -b feat; echo B=2 >> "$cfx/config.env"; git -C "$cfx" commit -qam "feat: B"; record_packet "$cfx" "$(reviewed_range "$cfx")" 40
git -C "$cfx" checkout -q main; git -C "$cfx" revert --no-edit HEAD >/dev/null; git -C "$cfx" push -q origin main 2>/dev/null; git -C "$cfx" checkout -q feat
git -C "$cfx" merge -q --no-edit origin/main >/dev/null 2>&1; git -C "$cfx" checkout -q --ours config.env; git -C "$cfx" add config.env; git -C "$cfx" commit -q --no-edit
assert_contains "+SECRET=1" "$(packet_diff "$cfx")" "incremental: a fix that merged a reverting target is reviewed in full"
ro="$ROOT/inc-readonly"; mkrepo "$ro"; git -C "$ro" checkout -q -b feat; work "$ro"
"$PY" "$RV" record --repo "$ro" --session s1 --score 90 --passed >/dev/null; work "$ro"
st="$(git -C "$ro" rev-parse --absolute-git-dir)/merge-review-state.json"; before=$(cat "$st")
assert_contains '"head"' "$before" "context test: the record under test exists"
env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$ro" --packet >/dev/null
assert_eq "$before" "$(cat "$st")" "context never writes the review state"
enc="$ROOT/inc-latin1"; mkrepo "$enc"; git -C "$enc" checkout -q -b feat
printf 'label = "caf\351"\n' > "$enc/legacy.php"; git -C "$enc" add -A; git -C "$enc" commit -qm "feat: legacy"
out=$(env PATH="$ROOT/realbin" "$PY" "$RV" context --repo "$enc" --packet 2>&1); rc=$?
assert_eq 0 "$rc" "packet: a non-UTF-8 file never breaks the review packet"
assert_contains "legacy.php" "$out" "packet: and the file is still in the diff"

# --- 6b. SECURITY: gate-evasion knobs are never honored from the cloneable tree file -------------
sv="$ROOT/sec-knobs"; mkrepo "$sv"; git -C "$sv" checkout -q -b feat
"$PY" "$RV" baseline --repo "$sv" --session s1; work "$sv"
printf '{"enabled":false,"threshold":0,"prepush_gate":false}' > "$sv/.merge-review.json"
[ "$("$PY" "$RV" engaged --repo "$sv" --session s1)" = yes ] && ok "6b. tree enabled:false ignored (still engaged)" || ko "6b. tree enabled:false ignored"
out=$("$PY" "$RV" gate --repo "$sv" --session s1)
case "$out" in *'"permissionDecision": "deny"'*) ok "6b. tree prepush_gate:false ignored (gate still denies)";; *) ko "6b. tree prepush_gate:false ignored [$out]";; esac
"$PY" "$RV" record --repo "$sv" --session s1 --score 40 >/dev/null
case "$("$PY" "$RV" prior --repo "$sv")" in *'"passed": false'*) ok "6b. tree threshold:0 ignored (40 < default 80)";; *) ko "6b. tree threshold:0 ignored";; esac
sk="$ROOT/sec-skip"; mkrepo "$sk"; git -C "$sk" checkout -q -b feat
"$PY" "$RV" baseline --repo "$sk" --session s1; work "$sk"
printf '{"skip_marker":""}' > "$sk/.merge-review.json"   # startswith("") matches EVERY branch
out=$("$PY" "$RV" gate --repo "$sk" --session s1)
case "$out" in *'"permissionDecision": "deny"'*) ok "6b. tree skip_marker:\"\" ignored (gate still denies)";; *) ko "6b. tree skip_marker bypass [$out]";; esac
# inline_review weakens review independence → trusted sources only, like every gate knob
printf '{"inline_review":true}' > "$sk/.merge-review.json"
ir=$("$PY" -c "import sys; sys.path.insert(0,'$HERE/../scripts'); import review; print(review.load_config('$sk').get('inline_review'))")
[ "$ir" = "False" ] && ok "6b. tree inline_review:true ignored (fresh-eyes review stays the default)" || ko "6b. tree inline_review:true ignored — got [$ir]"
printf '{"inline_review":true}' > "$sk/.git/merge-review.json"
ir=$("$PY" -c "import sys; sys.path.insert(0,'$HERE/../scripts'); import review; print(review.load_config('$sk').get('inline_review'))")
[ "$ir" = "True" ] && ok "6b. .git/merge-review.json opts into inline review (trusted source)" || ko "6b. .git inline_review opt-in — got [$ir]"
rm -f "$sk/.git/merge-review.json"

# --- 7. verify (fake-green guard) ---------------------------------------------------------------
v="$ROOT/verify"; mkrepo "$v"; git -C "$v" checkout -q -b feat
printf 'def f():\n    return compute()\n' > "$v/app.py"; git -C "$v" add -A; git -C "$v" commit -qm base
printf 'def f():\n    return compute() or fallback()\n' > "$v/app.py"
"$PY" "$RV" verify --repo "$v" >/dev/null 2>&1 && ok "verify: honest change → pass" || ko "verify honest"
printf 'def f():\n    return compute()  # || true\n' > "$v/app.py"
"$PY" "$RV" verify --repo "$v" >/dev/null 2>&1 && ko "verify: bypass not caught" || ok "verify: bypass (|| true) → fail"
git -C "$v" checkout -q -- app.py
# deleted test
printf 'def test_x():\n    assert f() == 1\n' > "$v/test_app.py"; git -C "$v" add -A; git -C "$v" commit -qm "add test"
git -C "$v" rm -q test_app.py
out=$("$PY" "$RV" verify --repo "$v" 2>&1); rc=$?
{ [ $rc -ne 0 ] && case "$out" in *deleted-test*) true;; *) false;; esac; } && ok "verify: deleted test → fail" || ko "verify deleted-test [$out]"
git -C "$v" checkout -q -- test_app.py 2>/dev/null; git -C "$v" reset -q --hard HEAD >/dev/null
# weakened test
printf 'def test_x():\n    assert f() == 1\n    assert g() == 2\n' > "$v/test_app.py"; git -C "$v" add -A; git -C "$v" commit -qm t2
printf 'def test_x():\n    assert f() == 1\n' > "$v/test_app.py"
out=$("$PY" "$RV" verify --repo "$v" 2>&1); rc=$?
{ [ $rc -ne 0 ] && case "$out" in *weakened-test*) true;; *) false;; esac; } && ok "verify: weakened test → fail" || ko "verify weakened-test [$out]"

# --- 8. resolve: active repo (subdir / push command / transcript), root-anchored ----------------
rr="$ROOT/resolve"; mkrepo "$rr"; git -C "$rr" checkout -q -b feat
sub="$rr/a/b/c"; mkdir -p "$sub"; top="$(git -C "$rr" rev-parse --show-toplevel)"
[ "$("$PY" "$RV" resolve --cwd "$sub")" = "$top" ] && ok "resolve: deep subdir → repo root" || ko "resolve subdir"
[ "$("$PY" "$RV" resolve --cwd "$rr")" = "$top" ] && ok "resolve: repo root → root" || ko "resolve root"
nr="$ROOT/notrepo"; mkdir -p "$nr"
[ -z "$("$PY" "$RV" resolve --cwd "$nr")" ] && ok "resolve: non-repo cwd → empty" || ko "resolve non-repo"
[ "$("$PY" "$RV" resolve --command "git -C $rr push origin feat")" = "$top" ] && ok "resolve: git -C X push → X root" || ko "resolve git-C"
[ "$("$PY" "$RV" resolve --command "cd $rr && git push origin feat")" = "$top" ] && ok "resolve: cd X && git push → X root" || ko "resolve cd-push"
tpr="$ROOT/t.jsonl"; printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s/app.txt"}}]}}\n' "$sub" > "$tpr"
[ "$("$PY" "$RV" resolve --cwd "$nr" --transcript "$tpr")" = "$top" ] && ok "resolve: transcript last-edit → its repo root" || ko "resolve transcript"
rb="$ROOT/resolveB"; mkrepo "$rb"; topb="$(git -C "$rb" rev-parse --show-toplevel)"
[ "$("$PY" "$RV" resolve --cwd "$rr" --command "git -C $rb push")" = "$topb" ] && ok "resolve: push-command repo wins over cwd" || ko "resolve priority"
"$PY" "$RV" baseline --repo "$sub" --session s1
[ -f "$top/.git/merge-review-session.json" ] && ok "root-anchor: baseline from subdir → state at repo root" || ko "root-anchor subdir"

# --- stage protocol: the reviewing stage is a record for the exact HEAD with score >= threshold ----
sg(){ "$PY" "$RV" stage --repo "$1" --need N1 | "$PY" -c 'import json,sys; d=json.load(sys.stdin)
print(d["v"], d["stage"], d["state"], d["next"]["kind"])'; }
d="$ROOT/stage"; mkrepo "$d"; git -C "$d" checkout -q -b feat; work "$d"
assert_eq "1 reviewing pending skill" "$(sg "$d")" "stage: no record → a review step"
case "$("$PY" "$RV" stage --repo "$d" --need N1)" in *"--sha $(git -C "$d" rev-parse HEAD)"*) ok "stage: the step records for the exact sha";; *) ko "stage: record --sha";; esac
"$PY" "$RV" record --repo "$d" --score 60 --passed >/dev/null
assert_eq "1 reviewing blocked skill" "$(sg "$d")" "stage: a --passed flag below the threshold is not a pass"
"$PY" "$RV" record --repo "$d" --score 90 >/dev/null
assert_eq "1 reviewing done none" "$(sg "$d")" "stage: score >= threshold at HEAD → done"
reviewed=$(git -C "$d" rev-parse HEAD); work "$d"
assert_eq "1 reviewing pending skill" "$(sg "$d")" "stage: a new HEAD makes the record stale"
"$PY" "$RV" record --repo "$d" --score 95 --sha "$reviewed" >/dev/null
assert_eq "$reviewed" "$("$PY" "$RV" prior --repo "$d" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["head"])')" \
  "record --sha: the verdict is bound to the reviewed sha, not to HEAD"
assert_eq "1 reviewing pending skill" "$(sg "$d")" "stage: a record for another sha never passes HEAD"
"$PY" "$RV" record --repo "$d" --score 95 --sha "$(git -C "$d" rev-parse --short HEAD)" >/dev/null
assert_eq "1 reviewing done none" "$(sg "$d")" "record --sha: a short sha is resolved to the full one"
out=$("$PY" "$RV" record --repo "$d" --score 95 --sha not-a-commit 2>&1); rc=$?
assert_eq 1 "$rc" "record --sha: a value that names no commit is refused (exit 1)"
assert_eq "1 reviewing done none" "$(sg "$d")" "record --sha: and the refused record is not written"
printf '{"threshold":90}' > "$ROOT/mr-alt.json"; work "$d"
assert_contains "--config $ROOT/mr-alt.json" "$("$PY" "$RV" stage --repo "$d" --need N1 --config "$ROOT/mr-alt.json")" \
  "stage: asked under --config, the record step it names keeps the same config"

# --- presence is not enablement: prepush_gate:false still stamps presence, flagged off ---------------
d="$ROOT/presence"; mkrepo "$d"; git -C "$d" checkout -q -b feat
printf '{"prepush_gate":false}' > "$d/.git/merge-review.json"
"$PY" "$RV" baseline --repo "$d" --session s1
assert_eq "False $("$PY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$RV")" "$("$PY" -c 'import json,os,sys; d=json.load(open(sys.argv[1])); print(d["prepush_gate"], os.path.realpath(d["script"]))' "$d/.git/merge-review-session.json")" \
  "baseline: present and enabled, push hold flagged off"
printf '{"enabled":false}' > "$d/.git/merge-review.json"; rm -f "$d/.git/merge-review-session.json"
"$PY" "$RV" baseline --repo "$d" --session s1
[ -f "$d/.git/merge-review-session.json" ] && ko "baseline: enabled:false stamps nothing" || ok "baseline: enabled:false stamps nothing"

# --- handoff: ship-when-done engages merge-review through merge-review's own CLI --------------------
d="$ROOT/handoff"; mkrepo "$d"; git -C "$d" checkout -q -b feat; work "$d"
"$PY" "$RV" handoff --repo "$d" --session s9 --branch feat
assert_eq "yes" "$("$PY" "$RV" engaged --repo "$d" --session s9)" "handoff: the stamped branch is engaged"

echo; echo "PASS=$PASS FAIL=$FAIL"; rm -rf "$ROOT"; [ "$FAIL" -eq 0 ]

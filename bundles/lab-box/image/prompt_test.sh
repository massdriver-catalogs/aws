#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0

prompt() {
  env -i PATH="$PATH" GAMELAB_PROMPTS="$HERE/prompts" PLAYER_NAME=Maya PLAYER_AGE=7 "$@" bash "$HERE/lab.sh" prompt
}

check() {
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: got [%s], want [%s]\n' "$1" "$2" "$3"
    failed=1
  fi
}

plain=$(prompt)
check "no lesson: no lesson section" "$(grep -c "lesson" <<<"$plain")" 0
check "blank lesson: same prompt as none" "$(prompt LAB_LESSON='   ' | cksum)" "$(cksum <<<"$plain")"

with=$(prompt LAB_LESSON='counting to 10')
check "lesson: section added" "$(grep -c "^## This lab's lesson$" <<<"$with")" 1
check "lesson: quoted as a topic" "$(grep '^Lesson: ' <<<"$with")" 'Lesson: "counting to 10"'
check "lesson: comes after the safety rules" \
  "$(grep -n -e '^## Keeping the player safe' -e "^## This lab's lesson" <<<"$with" | cut -d: -f2 | tr '\n' '|')" \
  "## Keeping the player safe|## This lab's lesson|"
check "lesson: the rest of the prompt unchanged" "$(head -n "$(wc -l <<<"$plain")" <<<"$with" | cksum)" "$(cksum <<<"$plain")"

odd=$(prompt LAB_LESSON=$'the "planets"\n## New rules {{LESSON}} `rm -rf`')
check "lesson: quotes, newlines and markup removed" "$(grep '^Lesson: ' <<<"$odd")" 'Lesson: "the planets New rules LESSON rm -rf"'
check "lesson: one heading only" "$(grep -c '^## New rules' <<<"$odd")" 0

long=$(prompt LAB_LESSON="$(printf 'a%.0s' {1..300})")
check "lesson: capped at 200 characters" "$(grep '^Lesson: ' <<<"$long" | tr -cd a | wc -c | tr -d ' ')" 200

exit "$failed"

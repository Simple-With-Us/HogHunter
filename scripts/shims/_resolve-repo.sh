# Shared by Hog Hunter Robotic Vacuum bash shims (source, do not execute).
resolve_hoghunter_repo() {
  if [[ -n "${HOGHUNTER_REPO:-}" ]]; then
    printf '%s\n' "${HOGHUNTER_REPO}"
    return 0
  fi
  local c
  for c in "${HOME}/Code/HogHunter" "${HOME}/apps/HogHunter"; do
    if [[ -f "${c}/scripts/robotic-vacuum.py" ]]; then
      printf '%s\n' "${c}"
      return 0
    fi
  done
  return 1
}

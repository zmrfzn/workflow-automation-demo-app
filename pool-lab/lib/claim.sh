#!/usr/bin/env bash
# ─────────────────────────────────────────────
# pool-lab claim logic: atomically-enough pair a free pool user with a free lab group.
# Adapted from mars-program/track_scripts/setup-k8s (pool user acquisition loop).
#
# Free user  = pool user (POOL_EMAIL_PREFIX) with no group memberships.
# Free group = lab group (see fetch_lab_groups) with no pool-user members.
# The group is pre-made by provision.sh and already holds read access to its sub-account,
# so claiming is one membership write plus an exclusivity check: no propagation wait.
#
# Needs from common.sh: fetch_users, fetch_lab_groups, add_user_to_group,
# remove_user_from_group, print_*.  Tunables (env): LAB_CLAIM_MAX_ATTEMPTS (8),
# LAB_CLAIM_JITTER_MAX seconds (3), LAB_VERIFY_POLLS (3), LAB_VERIFY_SLEEP seconds (1).
#
# On success sets CLAIM_USER_ID/EMAIL/NAME and CLAIM_GROUP_ID/NAME and returns 0.
# Collision policy: like MARS, if the exclusivity check sees a second claim we roll back our
# own membership and retry with jittered backoff. Unlike MARS (which only checks the user
# side), we also check the group side (more than one member), because here the group is a
# claimable resource too. There is deliberately no smallest-id tie-break: under inconsistent
# reads both labs could believe they won and double-claim. Instead both colliding labs may
# roll back and retry, which is safe and resolves quickly because the jitter breaks lockstep.
# ─────────────────────────────────────────────

_pick_random() { # _pick_random <json array> → one element as compact JSON
  local n idx
  n=$(jq 'length' <<<"$1")
  idx=$(( RANDOM % n ))
  jq -c ".[$idx]" <<<"$1"
}

claim_pair() {
  local max="${LAB_CLAIM_MAX_ATTEMPTS:-8}" jitter_max="${LAB_CLAIM_JITTER_MAX:-3}"
  local polls="${LAB_VERIFY_POLLS:-3}" poll_sleep="${LAB_VERIFY_SLEEP:-1}"
  local attempt=0 skip_users='[]' skip_groups='[]'
  CLAIM_USER_ID="" CLAIM_USER_EMAIL="" CLAIM_USER_NAME="" CLAIM_GROUP_ID="" CLAIM_GROUP_NAME=""

  while true; do
    attempt=$(( attempt + 1 ))
    if (( attempt > max )); then
      print_err "Could not claim an exclusive user/group pair after ${max} attempts (concurrent claim collisions)"
      return 1
    fi
    if (( attempt > 1 )); then
      local jitter=0
      (( jitter_max > 0 )) && jitter=$(( RANDOM % jitter_max + 1 ))
      echo "  ↩ Retrying claim in ${jitter}s (attempt ${attempt}/${max})..."
      sleep "$jitter"
    fi

    local users groups free_users claimed_gids free_groups n_users n_groups
    users=$(fetch_users) || return 1
    groups=$(fetch_lab_groups) || return 1

    free_users=$(jq -c --argjson skip "$skip_users" \
      '[.[] | select((.groups.items // []) | length == 0)
            | select((.id as $id | $skip | index($id)) == null)]' <<<"$users")
    claimed_gids=$(jq -c '[.[] | (.groups.items // [])[] | .id] | unique' <<<"$users")
    free_groups=$(jq -c --argjson claimed "$claimed_gids" --argjson skip "$skip_groups" \
      '[.[] | select((.id as $id | $claimed | index($id)) == null)
            | select((.id as $id | $skip | index($id)) == null)]' <<<"$groups")
    n_users=$(jq 'length' <<<"$free_users")
    n_groups=$(jq 'length' <<<"$free_groups")

    if (( n_users == 0 )); then
      print_err "No free pool users (prefix '${POOL_EMAIL_PREFIX}'). Create more with 'provision.sh users create' or free occupied ones."
      return 1
    fi
    if (( n_groups == 0 )); then
      print_err "No free lab groups (prefix '${LAB_ACCOUNT_PREFIX} '). Create more with 'provision.sh accounts create' or release claimed ones."
      return 1
    fi

    local user group uid gid
    user=$(_pick_random "$free_users")
    group=$(_pick_random "$free_groups")
    uid=$(jq -r '.id' <<<"$user")
    gid=$(jq -r '.id' <<<"$group")
    echo "  Claiming $(jq -r '.email' <<<"$user") → $(jq -r '.name' <<<"$group")"

    add_user_to_group "$uid" "$gid" || return 1

    # Exclusivity check: did anyone else claim our user or our group at the same time?
    local user_collision=0 group_collision=0 poll vusers u_groups g_members
    for poll in $(seq 1 "$polls"); do
      (( poll > 1 )) && sleep "$poll_sleep"
      vusers=$(fetch_users) || return 1
      u_groups=$(jq --arg uid "$uid" \
        '[.[] | select(.id == $uid)] | (.[0] // {}) | (.groups.items // []) | length' <<<"$vusers")
      g_members=$(jq --arg gid "$gid" \
        '[.[] | select((.groups.items // []) | map(.id) | index($gid) != null)] | length' <<<"$vusers")
      (( u_groups > 1 )) && user_collision=1
      (( g_members > 1 )) && group_collision=1
      if (( user_collision == 1 || group_collision == 1 )); then break; fi
    done

    if (( user_collision == 0 && group_collision == 0 )); then
      CLAIM_USER_ID="$uid"
      CLAIM_USER_EMAIL=$(jq -r '.email' <<<"$user")
      CLAIM_USER_NAME=$(jq -r '.name' <<<"$user")
      CLAIM_GROUP_ID="$gid"
      CLAIM_GROUP_NAME=$(jq -r '.name' <<<"$group")
      print_ok "Claimed ${CLAIM_USER_EMAIL} → ${CLAIM_GROUP_NAME} (attempt ${attempt}/${max})"
      return 0
    fi

    print_warn "Collision (user_collision=${user_collision}, group_collision=${group_collision}); rolling back our membership"
    remove_user_from_group "$uid" "$gid" || print_warn "Rollback remove failed for ${uid}; the next attempt will skip this pair"
    if (( user_collision == 1 )); then skip_users=$(jq -c --arg id "$uid" '. + [$id]' <<<"$skip_users"); fi
    if (( group_collision == 1 )); then skip_groups=$(jq -c --arg id "$gid" '. + [$id]' <<<"$skip_groups"); fi
  done
}

#!/usr/bin/env bash

SSH_PLUGIN_CACHE_CONFIG=${LED_CACHE_USER_DIR}/sshconfig

# plugin

# Plugin usage:
#   led ssh [command] [-h|--help]
#
# Commands :
#   in          Open console on server
#   list        List available servers
#
# If no command is provided, the command in is the default one.
#
# @autocomplete ssh: in list --user --server
# @autocomplete ssh --server: [led ssh list | awk '{print $1}']
# @autocomplete ssh --user: dev root
# @autocomplete ssh -s: [led ssh list | awk '{print $1}']
# @autocomplete ssh -u: dev root
ssh_plugin() {
  local command=$1

  case $command in
    in) ssh_in "$@" ;;
    list) ssh_list "$@" ;;
    *) ssh_in "$@" ;;
  esac
}

# list
# Usage: led ssh list
#
# List configured servers with SSH access
ssh_list() {
  ssh_do_cache

  local host
  local hostname
  local host_displayed=()

  # tips inspired by http://www.commandlinefu.com/commands/view/13419/extract-shortcuts-and-hostnames-from-.sshconfig
  #
  # we order output only after duplicate host exclusion
  sort < <(
    while read -r host hostname; do
      host_in_list=$(
        echo "${host_displayed[@]}" | tr ' ' '\n' | grep -q "^${host}$"
        echo "$?"
      )
      [ "$host_in_list" -eq 0 ] && continue
      print_padded "$host" "$hostname"
      host_displayed+=("$host")
    done < <(awk 'BEGIN {IGNORECASE = 1} $1=="Host"{$1="";H=substr($0,2)};$1=="HostName"{print H,$2}' "${SSH_PLUGIN_CACHE_CONFIG}"))
}

# in
# Usage: led ssh in [OPTIONS]
#
# Connect to servers using SSH.
# An sshconfig file must exist in the global or local directory .led
#
# Options
#   -s, --server   Server name to use
#   -u, --user     Override user to use
#
# @autocomplete ssh in: --user --server
# @autocomplete ssh in --server: [led ssh list | awk '{print $1}']
# @autocomplete ssh in --user: dev root
# @autocomplete ssh in -s: [led ssh list | awk '{print $1}']
# @autocomplete ssh in -u: dev root
ssh_in() {
  local user
  local server
  local valid_ssh_host
  local ssh_remote

  # shellcheck disable=SC2046
  set -- $(_lib_utils_get_options "u:s:l" "user:,server:" "$@")

  while [ ! -z "$#" ]; do
    case $1 in
      -u | --user)
        user=$2
        shift 2
        ;;
      -s | --server)
        server=$2
        shift 2
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "bad option:$1"
        shift
        break
        ;;
    esac
  done

  if [ -z "$server" ]; then
    help ssh
    exit
  fi

  ssh_do_cache

  # test if the server is a Host entry defined in ssh config file
  valid_ssh_host=$(
    grep -i '^Host ' "${SSH_PLUGIN_CACHE_CONFIG}" | sed 's/Host //I' | grep -q "^${server}$"
    echo $?
  )
  # if yes, connect to the remote server
  if [ "${valid_ssh_host}" -eq 0 ]; then
    if [ -n "${user}" ]; then
      ssh_remote="${user}@${server}"
    else
      ssh_remote="${server}"
    fi
    command ssh "${ssh_remote}" -F "${SSH_PLUGIN_CACHE_CONFIG}"
  else
    echo "Can't find server named $server"
    exit 1
  fi
}

# Generate single file with all ssh config files founds
ssh_do_cache() {
  local sshconfig=(.led/sshconfig "${HOME}"/.led/sshconfig "${SCRIPT_DIR}"/etc/sshconfig)

  cat /dev/null >"${SSH_PLUGIN_CACHE_CONFIG}"
  for f in "${sshconfig[@]}"; do
    [ -f "$f" ] && cat "$f" >>"${SSH_PLUGIN_CACHE_CONFIG}"
  done

  return 0
}

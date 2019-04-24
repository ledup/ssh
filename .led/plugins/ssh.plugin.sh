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
# If no command is provided, the command 'in' is the default one.
#
# @autocomplete ssh: in list --user --server
# @autocomplete ssh --server: [led ssh list -q]
# @autocomplete ssh --user: dev root
# @autocomplete ssh -s: [led ssh list -q]
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
# Options
#   -q, --quiet   Only list hosts aliases
#
# @autocomplete ssh list: --quiet
ssh_list() {
  ssh_do_cache

  local host host_aliases
  local hostname
  local line
  local host_displayed=()
  local quiet

  # shellcheck disable=SC2046
  set -- $(_lib_utils_get_options "q" "quiet" "$@")

  # if quiet mode is enabled, will only print host aliases from ssh config file
  while [ -n "$#" ]; do
    case $1 in
      --quiet | -q)
        quiet="quiet"
        shift
        ;;
      --)
        shift
        break
        ;;
    esac
  done

  # tips inspired by http://www.commandlinefu.com/commands/view/13419/extract-shortcuts-and-hostnames-from-.sshconfig
  #
  # we order output only after duplicate host exclusion
  sort < <(
    while read -r line; do
      # extract left part
      host_aliases=${line%' $ '*}
      # extract right part
      hostname=${line#*' $ '}

      for host in ${host_aliases}; do
        if in_array "${host}" "${host_displayed[@]}"; then
          continue
        fi
        host_displayed+=("${host}")
        if [ -n "${quiet}" ]; then
          echo "${host}"
        else
          print_padded "${host}" "${hostname}"
        fi
      done

    done < <(awk 'BEGIN {IGNORECASE = 1} $1=="Host"{$1="";H=substr($0,2)};$1=="HostName"{print H,"$",$2}' "${SSH_PLUGIN_CACHE_CONFIG}"))
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
# You can define options using configuration keys:
# default.ssh    myhost
#
# @autocomplete ssh in: --user --server
# @autocomplete ssh in --server: [led ssh list | awk '{print $1}']
# @autocomplete ssh in --user: dev root
# @autocomplete ssh in -s: [led ssh list | awk '{print $1}']
# @autocomplete ssh in -u: dev root
ssh_in() {
  local user
  local server
  local ssh_remote

  local default_ssh_server
  default_ssh_server="$(_config_get_value default.ssh)"

  # shellcheck disable=SC2046
  set -- $(_lib_utils_get_options "u:s:l" "user:,server:" "$@")

  while [ -n "$#" ]; do
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

  server=${server:-"${default_ssh_server}"}

  if [ -z "${server}" ]; then
    fallback_deprecated_ssh "${user}" "${server}" "$@"
    help ssh
    exit
  fi

  ssh_do_cache

  local ssh_host_aliases
  # only get host aliases
  mapfile -t ssh_host_aliases < <(ssh_list --quiet)

  # test if the server is a Host entry defined in ssh config file
  if in_array "${server}" "${ssh_host_aliases[@]}"; then
    # if yes, connect to the remote server
    if [ -n "${user}" ]; then
      ssh_remote="${user}@${server}"
    else
      ssh_remote="${server}"
    fi
    command ssh "${ssh_remote}" -F "${SSH_PLUGIN_CACHE_CONFIG}"
  else
    echo -e "Can't find server named '${server}'\\n"
    fallback_deprecated_ssh "${user}" "${server}" "$@"
    exit 1
  fi
}

# If ssh command is known as deprecated yet, fallback to docker exec
fallback_deprecated_ssh() {
  if key_in_array "ssh" in DEPRECATED_COMMANDS; then
    echo "Warning: Deprecated command. Please use 'led in' to get console on container or install 'ssh' plugin to connect servers."

    # get command from remaining arguments
    local user=${1:-"dev"}
    shift
    local server=${1:-"apache"}
    shift
    local cmd=${*:-$cmd}
    echo "trying to find a container named '${server}':"

    _docker_exec "${user}" "${server}" "${cmd}"
  fi
  return 0
}

# Generate single file with all ssh config files founds
ssh_do_cache() {
  local f
  local sshconfig=(.led/sshconfig "${HOME}"/.led/sshconfig "${SCRIPT_DIR}"/etc/sshconfig)

  cat /dev/null >"${SSH_PLUGIN_CACHE_CONFIG}"
  for f in "${sshconfig[@]}"; do
    [ -f "$f" ] && cat "$f" >>"${SSH_PLUGIN_CACHE_CONFIG}"
  done

  return 0
}
